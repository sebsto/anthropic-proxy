#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import NIOCore

struct EventStreamError: Error, Sendable {
    let exceptionType: String?
    let message: String
}

struct EventStreamParser: Sendable {

    func parseFrame(_ buffer: inout ByteBuffer) throws -> Data? {
        // 1. Read total_length (4 bytes, big-endian UInt32)
        guard let totalLength = buffer.readInteger(as: UInt32.self) else {
            throw EventStreamError(exceptionType: nil, message: "Failed to read total_length from frame")
        }
        let frameSize = Int(totalLength)

        // 2. Read headers_length (4 bytes, big-endian UInt32)
        guard let headersLength = buffer.readInteger(as: UInt32.self) else {
            throw EventStreamError(exceptionType: nil, message: "Failed to read headers_length from frame")
        }

        // 3. Read prelude_crc (4 bytes) -- skip CRC validation for now
        guard buffer.readInteger(as: UInt32.self) != nil else {
            throw EventStreamError(exceptionType: nil, message: "Failed to read prelude_crc from frame")
        }

        // 4. Read headers (headersLength bytes)
        let headers = parseHeaders(&buffer, length: Int(headersLength))

        // 5. Compute payload_length = total_length - 12 (prelude) - headers_length - 4 (message_crc)
        let payloadLength = frameSize - 12 - Int(headersLength) - 4

        // 6. Read payload (payloadLength bytes)
        let payloadBytes: ByteBuffer?
        if payloadLength > 0 {
            payloadBytes = buffer.readSlice(length: payloadLength)
        } else {
            payloadBytes = nil
        }

        // 7. Read message_crc (4 bytes) -- skip validation for now
        guard buffer.readInteger(as: UInt32.self) != nil else {
            throw EventStreamError(exceptionType: nil, message: "Failed to read message_crc from frame")
        }

        // 8. Check headers: if :message-type is "exception", throw an error with the payload content
        let messageType = headers[":message-type"]
        if messageType == "exception" {
            let exceptionType = headers[":exception-type"]
            var errorMessage = "EventStream exception"
            if let payload = payloadBytes, let payloadString = payload.getString(at: payload.readerIndex, length: payload.readableBytes) {
                errorMessage = payloadString
            }
            throw EventStreamError(exceptionType: exceptionType, message: errorMessage)
        }

        // 9. If :event-type is "chunk", decode payload as EventStreamPayload
        let eventType = headers[":event-type"]
        guard eventType == "chunk" else {
            return nil
        }

        guard let payload = payloadBytes, payload.readableBytes > 0 else {
            return nil
        }

        let payloadData = Data(payload.readableBytesView)

        let decoder = JSONDecoder()
        let eventStreamPayload = try decoder.decode(EventStreamPayload.self, from: payloadData)

        // 10. Base64-decode the bytes field to get the Anthropic event JSON
        guard let decodedData = Data(base64Encoded: eventStreamPayload.bytes) else {
            throw EventStreamError(
                exceptionType: nil,
                message: "Failed to base64-decode bytes field from EventStream payload"
            )
        }

        // 11. Return the decoded bytes as Data
        return decodedData
    }

    func parse<S: AsyncSequence & Sendable>(
        _ source: S
    ) -> AsyncThrowingStream<Data, Error> where S.Element == ByteBuffer {
        let parser = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                var accumulator = ByteBuffer()
                do {
                    for try await chunk in source {
                        var chunk = chunk
                        accumulator.writeBuffer(&chunk)

                        // Try to parse complete frames from the accumulator
                        while accumulator.readableBytes >= 12 {
                            // Peek at total_length without consuming
                            let readerIndex = accumulator.readerIndex
                            guard let totalLength = accumulator.getInteger(
                                at: readerIndex,
                                as: UInt32.self
                            ) else {
                                break
                            }
                            let frameSize = Int(totalLength)

                            guard accumulator.readableBytes >= frameSize else {
                                break
                            }

                            // Parse the complete frame
                            if let jsonData = try parser.parseFrame(&accumulator) {
                                continuation.yield(jsonData)
                            }
                        }

                        // Compact the buffer to avoid unbounded growth
                        accumulator.discardReadBytes()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Private

    private func parseHeaders(_ buffer: inout ByteBuffer, length: Int) -> [String: String] {
        var headers: [String: String] = [:]
        let endIndex = buffer.readerIndex + length

        while buffer.readerIndex < endIndex {
            // name_length: 1 byte
            guard let nameLength = buffer.readInteger(as: UInt8.self) else { break }
            // name: nameLength bytes
            guard let name = buffer.readString(length: Int(nameLength)) else { break }
            // type: 1 byte (7 = string)
            guard let headerType = buffer.readInteger(as: UInt8.self) else { break }

            if headerType == 7 {
                // String type: value_length (2 bytes big-endian) + value
                guard let valueLength = buffer.readInteger(as: UInt16.self) else { break }
                guard let value = buffer.readString(length: Int(valueLength)) else { break }
                headers[name] = value
            } else {
                // Unknown header type -- skip remaining headers to avoid misaligned reads
                buffer.moveReaderIndex(to: endIndex)
                break
            }
        }

        return headers
    }
}
