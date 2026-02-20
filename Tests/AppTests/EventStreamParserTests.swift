#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import NIOCore
import Testing
@testable import App

// MARK: - Helpers

/// Build a valid AWS EventStream binary frame.
/// Headers are string-typed (type byte = 7).
private func buildEventStreamFrame(headers: [(String, String)], payload: Data) -> ByteBuffer {
    var headersBytes = Data()
    for (name, value) in headers {
        headersBytes.append(UInt8(name.utf8.count))
        headersBytes.append(contentsOf: name.utf8)
        headersBytes.append(7) // string type
        let valueLen = UInt16(value.utf8.count).bigEndian
        withUnsafeBytes(of: valueLen) { headersBytes.append(contentsOf: $0) }
        headersBytes.append(contentsOf: value.utf8)
    }

    let headersLength = UInt32(headersBytes.count)
    let totalLength = UInt32(12 + headersBytes.count + payload.count + 4)

    var frame = Data()
    // Prelude: total_length (4) + headers_length (4) + prelude_crc (4)
    var tl = totalLength.bigEndian
    withUnsafeBytes(of: &tl) { frame.append(contentsOf: $0) }
    var hl = headersLength.bigEndian
    withUnsafeBytes(of: &hl) { frame.append(contentsOf: $0) }
    frame.append(contentsOf: [0, 0, 0, 0]) // prelude_crc placeholder
    // Headers
    frame.append(headersBytes)
    // Payload
    frame.append(payload)
    // Message CRC placeholder
    frame.append(contentsOf: [0, 0, 0, 0])

    var buffer = ByteBuffer()
    buffer.writeBytes(frame)
    return buffer
}

/// Wrap an Anthropic event JSON string as a chunk payload:
/// `{"bytes":"<base64-encoded-json>"}`
private func makeChunkPayload(_ anthropicEventJSON: String) -> Data {
    let base64 = Data(anthropicEventJSON.utf8).base64EncodedString()
    let payloadJSON = #"{"bytes":"\#(base64)"}"#
    return Data(payloadJSON.utf8)
}

// MARK: - Tests

@Suite("EventStreamParser Tests")
struct EventStreamParserTests {

    // MARK: - parseFrame

    @Test("Parse a text delta frame and verify decoded JSON matches")
    func testParseTextDeltaFrame() throws {
        let anthropicJSON = """
        {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}
        """
        let payload = makeChunkPayload(anthropicJSON)
        var buffer = buildEventStreamFrame(
            headers: [
                (":message-type", "event"),
                (":event-type", "chunk"),
            ],
            payload: payload
        )

        let result = try EventStreamParser().parseFrame(&buffer)
        let data = try #require(result)

        let decoded = try JSONDecoder().decode(ContentBlockDeltaEvent.self, from: data)
        #expect(decoded.delta.type == "text_delta")
        #expect(decoded.delta.text == "Hello")
        #expect(decoded.index == 0)
    }

    @Test("Parse two frames back-to-back from a single ByteBuffer")
    func testParseMultipleFrames() throws {
        let json1 = """
        {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}
        """
        let json2 = """
        {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" there"}}
        """

        let frame1 = buildEventStreamFrame(
            headers: [(":message-type", "event"), (":event-type", "chunk")],
            payload: makeChunkPayload(json1)
        )
        let frame2 = buildEventStreamFrame(
            headers: [(":message-type", "event"), (":event-type", "chunk")],
            payload: makeChunkPayload(json2)
        )

        var combined = ByteBuffer()
        var f1 = frame1
        var f2 = frame2
        combined.writeBuffer(&f1)
        combined.writeBuffer(&f2)

        let result1 = try EventStreamParser().parseFrame(&combined)
        let data1 = try #require(result1)
        let event1 = try JSONDecoder().decode(ContentBlockDeltaEvent.self, from: data1)
        #expect(event1.delta.text == "Hi")

        let result2 = try EventStreamParser().parseFrame(&combined)
        let data2 = try #require(result2)
        let event2 = try JSONDecoder().decode(ContentBlockDeltaEvent.self, from: data2)
        #expect(event2.delta.text == " there")
    }

    @Test("Partial frame buffering across two chunks yields correct event")
    func testPartialFrameBuffering() async throws {
        let anthropicJSON = """
        {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"buffered"}}
        """
        let payload = makeChunkPayload(anthropicJSON)
        let fullFrame = buildEventStreamFrame(
            headers: [(":message-type", "event"), (":event-type", "chunk")],
            payload: payload
        )

        let frameBytes = Data(fullFrame.readableBytesView)
        let splitIndex = frameBytes.count / 2

        let chunk1 = frameBytes[..<splitIndex]
        let chunk2 = frameBytes[splitIndex...]

        var buf1 = ByteBuffer()
        buf1.writeBytes(chunk1)
        var buf2 = ByteBuffer()
        buf2.writeBytes(chunk2)

        let source = AsyncStream<ByteBuffer> { continuation in
            continuation.yield(buf1)
            continuation.yield(buf2)
            continuation.finish()
        }

        let stream = EventStreamParser().parse(source)

        var events: [Data] = []
        for try await data in stream {
            events.append(data)
        }

        #expect(events.count == 1)
        let decoded = try JSONDecoder().decode(ContentBlockDeltaEvent.self, from: events[0])
        #expect(decoded.delta.text == "buffered")
    }

    @Test("Exception frame throws EventStreamError")
    func testExceptionFrame() throws {
        let errorPayload = Data(#"{"message":"Rate limit exceeded"}"#.utf8)
        var buffer = buildEventStreamFrame(
            headers: [
                (":message-type", "exception"),
                (":exception-type", "throttlingException"),
            ],
            payload: errorPayload
        )

        #expect(throws: EventStreamError.self) {
            _ = try EventStreamParser().parseFrame(&buffer)
        }
    }

    @Test("Non-chunk event type returns nil")
    func testNonChunkEventSkipped() throws {
        let payload = Data(#"{"some":"data"}"#.utf8)
        var buffer = buildEventStreamFrame(
            headers: [
                (":message-type", "event"),
                (":event-type", "initial-response"),
            ],
            payload: payload
        )

        let result = try EventStreamParser().parseFrame(&buffer)
        #expect(result == nil)
    }
}
