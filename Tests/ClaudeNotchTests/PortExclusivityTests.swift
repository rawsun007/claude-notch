import XCTest
import Darwin
@testable import ClaudeNotch

/// The hook port must belong to exactly one process.
///
/// ClaudeNotch answers PreToolUse and PermissionRequest, which are blocking
/// hooks: the process that replies decides whether a tool call runs. When the
/// listener carried SO_REUSEPORT (via NWParameters.allowLocalEndpointReuse), a
/// second process running as the same user could bind the same port, take a
/// share of the connections, and answer "allow" to everything without a card
/// ever appearing. This suite is the regression test for that.
final class PortExclusivityTests: XCTestCase {

    /// A port in the ephemeral range, so a developer machine running the real
    /// app on 53127 does not collide with the test.
    private let testPort: UInt16 = 53929

    /// Bind 127.0.0.1:port, optionally asking for the socket options an
    /// attacker would use. Returns the fd, or the errno that refused it.
    private func attemptBind(port: UInt16, reusePort: Bool, reuseAddr: Bool) -> Result<Int32, Int32> {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(errno) }
        var on: Int32 = 1
        if reusePort { setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, socklen_t(MemoryLayout<Int32>.size)) }
        if reuseAddr { setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size)) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc != 0 {
            let err = errno
            close(fd)
            return .failure(err)
        }
        if listen(fd, 4) != 0 {
            let err = errno
            close(fd)
            return .failure(err)
        }
        return .success(fd)
    }

    /// Start the real server, give the listener a moment to come up, and hand
    /// back a teardown.
    @MainActor
    private func startServer() throws -> EventServer {
        let server = EventServer(port: testPort, state: AppState())
        try server.start()
        // NWListener binds asynchronously; poll until the port is taken rather
        // than sleeping a fixed amount and hoping.
        for _ in 0..<100 {
            if case .failure = attemptBind(port: testPort, reusePort: false, reuseAddr: false) { return server }
            usleep(20_000)
        }
        XCTFail("server never took the port")
        return server
    }

    /// The finding, as a test: with the flag gone, an attacker asking for
    /// SO_REUSEPORT is refused like anyone else.
    @MainActor
    func testASecondListenerCannotShareThePort() throws {
        let server = try startServer()
        defer { server.stop() }

        switch attemptBind(port: testPort, reusePort: true, reuseAddr: true) {
        case .success(let fd):
            close(fd)
            XCTFail("a second process shared the hook port: it can answer permission prompts")
        case .failure(let err):
            XCTAssertEqual(err, EADDRINUSE, "expected the bind to be refused as in-use")
        }
    }

    /// Each option on its own, since either one alone was enough to get in.
    @MainActor
    func testNeitherReuseOptionGetsIn() throws {
        let server = try startServer()
        defer { server.stop() }

        for (reusePort, reuseAddr) in [(true, false), (false, true), (false, false)] {
            switch attemptBind(port: testPort, reusePort: reusePort, reuseAddr: reuseAddr) {
            case .success(let fd):
                close(fd)
                XCTFail("bind succeeded with SO_REUSEPORT=\(reusePort) SO_REUSEADDR=\(reuseAddr)")
            case .failure(let err):
                XCTAssertEqual(err, EADDRINUSE)
            }
        }
    }

    /// And the port is genuinely released on stop, or every restart of the app
    /// would need the flag we just removed.
    @MainActor
    func testThePortIsFreedOnStopSoARestartCanRebind() throws {
        let server = try startServer()
        server.stop()

        var rebound = false
        for _ in 0..<100 {
            if case .success(let fd) = attemptBind(port: testPort, reusePort: false, reuseAddr: false) {
                close(fd)
                rebound = true
                break
            }
            usleep(20_000)
        }
        XCTAssertTrue(rebound, "port still held after stop: the app could not restart without SO_REUSEPORT")
    }
}
