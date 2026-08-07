import XCTest
@testable import ClaudeNotch

/// `parseRequest` is the one place raw bytes off a socket become a structure the
/// rest of the app trusts, and the example-based tests next door only cover the
/// shapes someone thought to write down. This drives random and deliberately
/// hostile bytes through it and asserts the properties that have to hold for
/// every input, not just the ones we imagined.
///
/// Seeded, so a failure here reproduces exactly rather than showing up once in
/// someone's CI run and never again.
final class EventServerFuzzTests: XCTestCase {

    /// Small deterministic PRNG. Foundation's is not reproducible across runs,
    /// which is the one thing a fuzz test cannot do without.
    private struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        mutating func int(_ upperBound: Int) -> Int {
            upperBound <= 0 ? 0 : Int(next() % UInt64(upperBound))
        }
        mutating func byte() -> UInt8 { UInt8(next() & 0xFF) }
    }

    // MARK: - Properties every parse must satisfy

    /// Checks the invariants and returns the parse, so a caller can assert more.
    @discardableResult
    private func assertInvariants(_ data: Data,
                                  _ message: @autoclosure () -> String = "",
                                  file: StaticString = #filePath,
                                  line: UInt = #line) -> EventServer.HTTPRequest? {
        guard let r = EventServer.parseRequest(data) else { return nil }

        // The body can never be longer than the buffer it came out of, nor
        // longer than the ceiling the reader enforces.
        XCTAssertLessThanOrEqual(r.body.count, data.count, message(), file: file, line: line)
        XCTAssertLessThanOrEqual(r.body.count, EventServer.maxRequestBytes, message(), file: file, line: line)

        // Whatever it returned, the body has to be bytes that were actually in
        // the input, contiguously. A parser that invents or reorders bytes here
        // would hand the handlers a payload nobody sent.
        if !r.body.isEmpty {
            XCTAssertTrue(data.range(of: r.body) != nil, message(), file: file, line: line)
        }

        // Pure: the handler path parses the same buffer more than once as it
        // grows, so the same bytes must always give the same answer.
        let again = EventServer.parseRequest(data)
        XCTAssertEqual(again?.method, r.method, message(), file: file, line: line)
        XCTAssertEqual(again?.path, r.path, message(), file: file, line: line)
        XCTAssertEqual(again?.body, r.body, message(), file: file, line: line)
        return r
    }

    // MARK: - Random bytes

    /// Pure garbage. The only claim is that it never traps and never violates
    /// the invariants above.
    func testRandomBytesNeverTrap() {
        var rng = Rng(state: 0x9E3779B97F4A7C15)
        for _ in 0..<3_000 {
            var data = Data()
            for _ in 0..<rng.int(300) { data.append(rng.byte()) }
            assertInvariants(data, "random bytes: \(data as NSData)")
        }
    }

    /// Random bytes that happen to contain a header terminator, which is what
    /// gets past the first guard and into the interesting code.
    func testRandomBytesAroundATerminator() {
        var rng = Rng(state: 0xDEADBEEFCAFEF00D)
        for _ in 0..<3_000 {
            var data = Data("POST /x HTTP/1.1\r\n".utf8)
            for _ in 0..<rng.int(120) { data.append(rng.byte()) }
            data.append(contentsOf: [13, 10, 13, 10])
            for _ in 0..<rng.int(120) { data.append(rng.byte()) }
            assertInvariants(data, "seeded garbage: \(data as NSData)")
        }
    }

    /// Mutate a well-formed request one byte at a time. Most mutations are
    /// uninteresting; the ones that land on Content-Length digits or on the
    /// terminator are the point.
    func testBitFlipsOnAValidRequest() {
        let valid = Array("POST /permission HTTP/1.1\r\nHost: 127.0.0.1:53127\r\nContent-Length: 13\r\n\r\n{\"a\":\"hello\"}".utf8)
        var rng = Rng(state: 0x123456789ABCDEF)
        for _ in 0..<4_000 {
            var bytes = valid
            for _ in 0..<(1 + rng.int(3)) {
                bytes[rng.int(bytes.count)] = rng.byte()
            }
            assertInvariants(Data(bytes), "mutated: \(String(decoding: bytes, as: UTF8.self))")
        }
    }

    // MARK: - The streaming invariant

    /// The server calls parseRequest on a buffer that only ever grows. If a
    /// prefix parses, the answer must not change when the rest of the bytes
    /// arrive: otherwise the server acts on a request that was still in flight,
    /// and a sender could make the body it acted on differ from the body it
    /// finally received.
    func testAPrefixThatParsesStaysStableAsBytesArrive() {
        let full = Data("POST /hook HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 20\r\n\r\n{\"session_id\":\"ab\"}!".utf8)
        var firstParse: EventServer.HTTPRequest?
        for n in 0...full.count {
            let prefix = full.prefix(n)
            guard let r = EventServer.parseRequest(Data(prefix)) else { continue }
            if let first = firstParse {
                XCTAssertEqual(r.method, first.method, "answer changed at \(n) bytes")
                XCTAssertEqual(r.path, first.path, "answer changed at \(n) bytes")
                XCTAssertEqual(r.body, first.body, "body changed at \(n) bytes")
            } else {
                firstParse = r
            }
        }
        XCTAssertNotNil(firstParse, "the full request should parse at some prefix length")
    }

    /// Same property, random shapes: split every generated buffer at every
    /// length and confirm the first successful parse is the final one.
    func testStabilityAcrossRandomBufferGrowth() {
        var rng = Rng(state: 0x5DEECE66D)
        for _ in 0..<300 {
            let bodyLen = rng.int(40)
            let body = String(repeating: "x", count: bodyLen)
            let data = Data("POST /x HTTP/1.1\r\nContent-Length: \(bodyLen)\r\n\r\n\(body)".utf8)
            var seen: Data?
            for n in 0...data.count {
                guard let r = EventServer.parseRequest(data.prefix(n)) else { continue }
                if let s = seen { XCTAssertEqual(r.body, s) } else { seen = r.body }
            }
        }
    }

    // MARK: - Deliberately hostile shapes

    func testContentLengthAbuse() {
        // Past the ceiling: refused outright rather than waited on, or the
        // reader keeps asking for a body that is never coming.
        XCTAssertNil(EventServer.parseRequest(Data("POST /x HTTP/1.1\r\nContent-Length: 999999999\r\n\r\nhi".utf8)))
        XCTAssertNil(EventServer.parseRequest(Data("POST /x HTTP/1.1\r\nContent-Length: -1\r\n\r\nhi".utf8)))
        // Not a number at all. Treating it as zero would silently drop a body
        // the sender believed it had declared.
        XCTAssertNil(EventServer.parseRequest(Data("POST /x HTTP/1.1\r\nContent-Length: abc\r\n\r\nhi".utf8)))
        XCTAssertNil(EventServer.parseRequest(Data("POST /x HTTP/1.1\r\nContent-Length: 1 2\r\n\r\nhi".utf8)))
        // Overflows Int: must not trap.
        XCTAssertNil(EventServer.parseRequest(Data("POST /x HTTP/1.1\r\nContent-Length: 99999999999999999999999\r\n\r\n".utf8)))
    }

    /// Two lengths is a malformed request. Picking one of them is how a parser
    /// ends up disagreeing with whatever else reads the same bytes.
    func testDuplicateContentLengthIsRefused() {
        XCTAssertNil(EventServer.parseRequest(
            Data("POST /x HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 9\r\n\r\nhistuff".utf8)))
        // Including when they agree: still not a request anyone legitimately sends.
        XCTAssertNil(EventServer.parseRequest(
            Data("POST /x HTTP/1.1\r\nContent-Length: 2\r\ncontent-length: 2\r\n\r\nhi".utf8)))
    }

    func testHeaderShapesThatCouldConfuseTheSplitter() {
        // No colon anywhere: skipped, not crashed.
        XCTAssertNotNil(EventServer.parseRequest(Data("POST /x HTTP/1.1\r\ngarbage\r\n\r\n".utf8)))
        // Colon first: an empty header name, which matches nothing.
        XCTAssertNotNil(EventServer.parseRequest(Data("POST /x HTTP/1.1\r\n: value\r\n\r\n".utf8)))
        // Value containing a colon must survive intact.
        let r = EventServer.parseRequest(Data("POST /x HTTP/1.1\r\nHost: 127.0.0.1:53127\r\n\r\n".utf8))
        XCTAssertEqual(r?.host, "127.0.0.1:53127")
        // A very long header line must not be quadratic or trap.
        let long = String(repeating: "a", count: 100_000)
        XCTAssertNotNil(EventServer.parseRequest(Data("POST /x HTTP/1.1\r\nX-Long: \(long)\r\n\r\n".utf8)))
    }

    func testRequestLineShapes() {
        XCTAssertNil(EventServer.parseRequest(Data("POST\r\n\r\n".utf8)))          // one token
        XCTAssertNil(EventServer.parseRequest(Data("\r\n\r\n".utf8)))              // empty
        // Three-plus tokens is normal; the version is ignored.
        XCTAssertEqual(EventServer.parseRequest(Data("POST /x HTTP/1.1 extra\r\n\r\n".utf8))?.path, "/x")
        // A NUL in the path must be carried, not truncate anything.
        XCTAssertNotNil(EventServer.parseRequest(Data("POST /x\u{0}y HTTP/1.1\r\n\r\n".utf8)))
    }

    /// A body is arbitrary bytes, including invalid UTF-8. Only the header
    /// block has to decode.
    func testBinaryBodyIsCarriedVerbatim() {
        var data = Data("POST /x HTTP/1.1\r\nContent-Length: 3\r\n\r\n".utf8)
        data.append(contentsOf: [0xFF, 0x00, 0xFE])
        let r = EventServer.parseRequest(data)
        XCTAssertEqual(r?.body, Data([0xFF, 0x00, 0xFE]))
    }

    /// A lone LF is not a header terminator. Accepting one would let a sender
    /// end the headers somewhere the next reader of the same bytes would not.
    func testLoneLFDoesNotTerminateHeaders() {
        XCTAssertNil(EventServer.parseRequest(Data("POST /x HTTP/1.1\n\nbody".utf8)))
    }
}
