import Foundation
import Darwin

// The loopback socket the hook server listens on.
//
// This exists because Network.framework would not give the port up
// exclusively. NWListener sets SO_REUSEPORT on its socket whatever
// `allowLocalEndpointReuse` says, and SO_REUSEPORT means a second process
// running as the same user can bind the same port and take a share of the
// connections. Those connections carry PreToolUse and PermissionRequest, which
// block until they are answered, so a process that wins the race decides
// whether a tool call runs. Removing the flag changed nothing; measuring it
// is what showed that.
//
// A socket we bind ourselves takes no options at all, so the second bind is
// refused, which is the whole point. Binding it by hand also lets us bind the
// loopback addresses specifically rather than the wildcard, so the question of
// what the listener answers on stops being a question.

/// One accepted connection: read the request, write one response, close.
///
/// Not a general HTTP connection. Every hook is one request and one response,
/// and a blocking hook holds the socket open in between for as long as the card
/// is on screen, which is the only reason this is not synchronous.
final class HookConnection: @unchecked Sendable {
    private let fd: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var deadline: DispatchSourceTimer?
    private let lock = NSLock()
    private var closed = false

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
    }

    /// How long a connection may take to produce a complete request.
    ///
    /// A peer that opens a socket, sends half a request and stops used to hold
    /// that socket for as long as it liked: the parser keeps returning "not yet"
    /// and the read source keeps waiting. Enough of those and the app runs out
    /// of descriptors, which is a denial of service any local process can spend
    /// nothing to cause. A hook is a local program writing a few KB down a
    /// loopback socket it already has open; thirty seconds is generous.
    ///
    /// This covers the request only. Once a request is parsed the handler owns
    /// the connection, and a blocking hook is meant to sit there for minutes
    /// waiting for a human, so the deadline is cancelled at that point.
    static let requestDeadline: TimeInterval = 30

    /// Read until `onRequest` accepts the bytes as a complete request, the peer
    /// hangs up, the ceiling is hit, or the deadline passes. `onRequest` returns
    /// true when it has taken ownership of the connection (it will answer and
    /// close).
    func read(max: Int, onRequest: @escaping (Data) -> Bool) {
        let deadline = DispatchSource.makeTimerSource(queue: queue)
        deadline.schedule(deadline: .now() + Self.requestDeadline)
        deadline.setEventHandler { [weak self] in
            guard let self else { return }
            NSLog("ClaudeNotch: closing a connection that never finished its request")
            self.close()
        }
        deadline.resume()
        self.deadline = deadline
        var buffer = Data()
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source = src
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let n = Darwin.read(self.fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                if buffer.count > max {
                    NSLog("ClaudeNotch: dropping oversized request (%d bytes)", buffer.count)
                    self.close()
                    return
                }
                if onRequest(buffer) {
                    // Handled: stop reading, and stop the deadline — the
                    // handler owns the connection now and a blocking hook is
                    // supposed to hold it. Leave the socket open for the answer.
                    self.source?.cancel()
                    self.source = nil
                    self.deadline?.cancel()
                    self.deadline = nil
                }
                return
            }
            // 0 = orderly shutdown, <0 = error. EAGAIN cannot happen here: the
            // source only fires when there is something to read.
            if n == 0 || (n < 0 && errno != EINTR) { self.close() }
        }
        // No cancel handler on purpose: cancelling the read source happens both
        // when the handler takes the connection over and when we close it, and
        // only `close()` owns the descriptor.
        src.resume()
    }

    /// Write one HTTP response and close. Loopback responses are a couple of KB
    /// at most, so a short write loop is the whole of it.
    func send(body: String) {
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        var bytes = Array(response.utf8)
        lock.lock()
        let isClosed = closed
        lock.unlock()
        guard !isClosed else { return }

        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw -> Int in
                Darwin.write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written > 0 { offset += written; continue }
            if written < 0 && (errno == EINTR) { continue }
            if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                // The socket is non-blocking for reads; a full send buffer on
                // loopback with a KB of response is close to impossible, but
                // waiting beats spinning or dropping the answer.
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&pfd, 1, 2000) > 0 { continue }
            }
            break   // peer gone, or we waited long enough
        }
        close()
    }

    func close() {
        lock.lock()
        let alreadyClosed = closed
        closed = true
        lock.unlock()
        guard !alreadyClosed else { return }
        source?.cancel()
        source = nil
        deadline?.cancel()
        deadline = nil
        Darwin.close(fd)
    }
}

/// The listening sockets. Both loopback addresses, because a hook that posts to
/// `localhost` may resolve to either one.
final class HookListener: @unchecked Sendable {

    enum ListenError: Error, CustomStringConvertible {
        case inUse(port: UInt16)
        case failed(port: UInt16, errno: Int32)

        var description: String {
            switch self {
            case .inUse(let p):
                return "port \(p) is already taken by another process"
            case .failed(let p, let e):
                return "could not listen on port \(p): \(String(cString: strerror(e)))"
            }
        }
    }

    private var fds: [Int32] = []
    private var sources: [DispatchSourceRead] = []
    private let queue: DispatchQueue

    init(queue: DispatchQueue) { self.queue = queue }

    /// Bind 127.0.0.1 and ::1 and start accepting.
    ///
    /// The v4 socket is the one that must work: every forwarder this app
    /// installs posts to 127.0.0.1. The v6 socket is best-effort, so a machine
    /// with IPv6 disabled still gets a working server.
    func start(port: UInt16, onConnection: @escaping (HookConnection) -> Void) throws {
        var lastErrno: Int32 = 0
        var boundV4 = false

        for family in [AF_INET, AF_INET6] {
            let fd = socket(family, SOCK_STREAM, 0)
            guard fd >= 0 else { lastErrno = errno; continue }

            // No SO_REUSEADDR and no SO_REUSEPORT. Both of them are how another
            // process gets a foot in this door, and neither is needed: a
            // listening socket does not enter TIME_WAIT.
            if family == AF_INET6 {
                var on: Int32 = 1   // v6 socket answers on ::1 only, never v4-mapped
                setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
            }
            fcntl(fd, F_SETFD, FD_CLOEXEC)

            var rc: Int32 = -1
            if family == AF_INET {
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = port.bigEndian
                addr.sin_addr.s_addr = inet_addr("127.0.0.1")
                rc = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            } else {
                var addr = sockaddr_in6()
                addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                addr.sin6_family = sa_family_t(AF_INET6)
                addr.sin6_port = port.bigEndian
                addr.sin6_addr = in6addr_loopback
                rc = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                    }
                }
            }

            // Non-blocking: the accept loop below drains the backlog and stops
            // on EAGAIN, which it never sees on a blocking socket.
            fcntl(fd, F_SETFL, O_NONBLOCK)

            if rc != 0 || listen(fd, 32) != 0 {
                lastErrno = errno
                Darwin.close(fd)
                continue
            }

            if family == AF_INET { boundV4 = true }
            fds.append(fd)
            accept(on: fd, onConnection: onConnection)
        }

        guard boundV4 else {
            cancel()
            throw lastErrno == EADDRINUSE ? ListenError.inUse(port: port)
                                          : ListenError.failed(port: port, errno: lastErrno)
        }
    }

    private func accept(on fd: Int32, onConnection: @escaping (HookConnection) -> Void) {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler {
            while true {
                let client = Darwin.accept(fd, nil, nil)
                if client < 0 { break }   // EAGAIN: drained the backlog
                fcntl(client, F_SETFL, O_NONBLOCK)
                fcntl(client, F_SETFD, FD_CLOEXEC)
                onConnection(HookConnection(fd: client, queue: self.queue))
            }
        }
        src.resume()
        sources.append(src)
    }

    func cancel() {
        for src in sources { src.cancel() }
        sources.removeAll()
        for fd in fds { Darwin.close(fd) }
        fds.removeAll()
    }
}
