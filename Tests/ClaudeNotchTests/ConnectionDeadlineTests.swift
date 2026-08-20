import XCTest
import Darwin
@testable import ClaudeNotch

/// A socket this app accepts has two ways to be held open forever: a request
/// that never finishes arriving, and a request that arrives and is never
/// answered. Both used to be possible; the first was fixed when the transport
/// was written, the second only by every blocking path remembering to reply.
final class ConnectionDeadlineTests: XCTestCase {

    private let queue = DispatchQueue(label: "test.hooksocket")

    /// A connected pair of descriptors. One end becomes a HookConnection, the
    /// other stands in for the peer, so no listener or port is involved.
    private func pair() throws -> (ours: Int32, peer: Int32) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw XCTSkip("socketpair unavailable")
        }
        fcntl(fds[0], F_SETFL, O_NONBLOCK)
        return (fds[0], fds[1])
    }

    /// Whether the connection's end has been closed, by asking the kernel about
    /// our own descriptor rather than trusting a flag on the object.
    private func isClosed(_ fd: Int32) -> Bool {
        fcntl(fd, F_GETFD) == -1 && errno == EBADF
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(20_000)
        }
        return condition()
    }

    /// Half a request, then silence. Enough of these and the app runs out of
    /// descriptors, which costs the other process nothing.
    func testAnUnfinishedRequestIsClosed() throws {
        let (ours, peer) = try pair()
        defer { Darwin.close(peer) }
        let conn = HookConnection(fd: ours, queue: queue,
                                  requestDeadline: 0.4, responseDeadline: 30)
        conn.read(max: 1024) { _ in false }   // never a complete request

        _ = write(peer, "POST /ping HTTP/1.1\r\n", 21)
        XCTAssertTrue(waitUntil(3) { self.isClosed(ours) },
                      "an unfinished request should be closed at its deadline")
    }

    /// The one this test file exists for: a handler takes the connection and
    /// never answers. Before, that descriptor was held until the process died.
    func testARequestThatIsNeverAnsweredIsClosed() throws {
        let (ours, peer) = try pair()
        defer { Darwin.close(peer) }
        let conn = HookConnection(fd: ours, queue: queue,
                                  requestDeadline: 30, responseDeadline: 0.4)
        conn.read(max: 4096) { _ in true }    // taken over, and deliberately never answered

        let request = "POST /ping HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 2\r\n\r\n{}"
        _ = request.withCString { write(peer, $0, strlen($0)) }
        XCTAssertTrue(waitUntil(3) { self.isClosed(ours) },
                      "an unanswered request should be closed at the response deadline")
    }

    /// And a connection that is answered normally is not closed by a timer: it
    /// is closed by the answer, straight away.
    func testAnAnsweredRequestClosesOnTheAnswer() throws {
        let (ours, peer) = try pair()
        defer { Darwin.close(peer) }
        let conn = HookConnection(fd: ours, queue: queue,
                                  requestDeadline: 30, responseDeadline: 30)
        conn.read(max: 4096) { _ in
            self.queue.async { conn.send(body: "{\"ok\":true}") }
            return true
        }

        let request = "POST /ping HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 2\r\n\r\n{}"
        _ = request.withCString { write(peer, $0, strlen($0)) }

        // The peer sees the reply...
        var buf = [UInt8](repeating: 0, count: 256)
        XCTAssertTrue(waitUntil(3) { read(peer, &buf, buf.count) > 0 })
        XCTAssertTrue(String(decoding: buf, as: UTF8.self).contains("ok"))
        // ...and our end goes with it, well inside either deadline.
        XCTAssertTrue(waitUntil(3) { self.isClosed(ours) })
    }

    /// Closing twice must not close a descriptor number that has since been
    /// handed to something else.
    func testClosingIsIdempotent() throws {
        let (ours, peer) = try pair()
        defer { Darwin.close(peer) }
        let conn = HookConnection(fd: ours, queue: queue)
        conn.close()
        conn.close()
        conn.close()
        XCTAssertTrue(isClosed(ours))
    }

    /// The response deadline has to outlast the longest wait the app itself
    /// takes, or it would cut off a card someone is still looking at.
    func testTheResponseDeadlineOutlastsTheDecisionWindow() {
        XCTAssertGreaterThan(HookConnection.responseDeadline, 285)
        XCTAssertLessThan(HookConnection.requestDeadline, HookConnection.responseDeadline)
    }
}
