import XCTest
import Darwin
@testable import ClaudeNotch

/// The port is busy at exactly one predictable moment: while the copy of this
/// app that is being replaced finishes exiting. Every update and every quick
/// restart passes through it. Giving up there left the app running deaf until
/// somebody relaunched it by hand.
@MainActor
final class BindRetryTests: XCTestCase {

    private let port: UInt16 = 53931

    /// Hold the port the way a departing predecessor does.
    private func squat(_ port: UInt16) -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        Darwin.listen(fd, 4)
        return fd
    }

    private func canConnect(_ port: UInt16) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    /// A busy port is not an error to report, it is a thing to wait out.
    func testStartingOnABusyPortDoesNotThrow() throws {
        let held = squat(port)
        defer { Darwin.close(held) }

        let server = EventServer(port: port, state: AppState())
        defer { server.stop() }
        XCTAssertNoThrow(try server.start())
    }

    /// And when the other process lets go, the app takes the port by itself
    /// rather than sitting there deaf until someone relaunches it.
    func testThePortIsTakenOnceItIsFree() throws {
        let held = squat(port)
        let server = EventServer(port: port, state: AppState())
        defer { server.stop() }
        try server.start()

        Darwin.close(held)   // the predecessor finishes exiting
        XCTAssertTrue(waitUntil(15) { self.canConnect(self.port) },
                      "the server should have taken the port after it was released")
    }

    /// A quick restart must not raise the warning: it is the one message that
    /// has to mean something when it appears.
    func testAShortConflictIsNotReported() throws {
        let state = AppState()
        let held = squat(port)
        defer { Darwin.close(held) }

        let server = EventServer(port: port, state: state)
        defer { server.stop() }
        try server.start()

        // Well inside the grace period.
        _ = waitUntil(2) { false }
        XCTAssertEqual(state.serverStatus, .listening)
        XCTAssertTrue(state.permissionQueue.isEmpty)
    }

    /// The timings have to hold their shape: quiet for a restart, loud for a
    /// squatter, and still trying either way.
    func testTheRetryPolicyIsSane() {
        XCTAssertGreaterThan(EventServer.bindGrace, EventServer.bindRetryInterval)
        XCTAssertLessThan(EventServer.bindRetryInterval, EventServer.bindRetrySlowInterval)
        XCTAssertLessThanOrEqual(EventServer.bindGrace, 30)
    }
}
