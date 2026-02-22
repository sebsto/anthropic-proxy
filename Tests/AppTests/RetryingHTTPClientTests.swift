#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import AsyncHTTPClient
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import Testing

@testable import App

@Suite("RetryingHTTPClient Tests")
struct RetryingHTTPClientTests {

    private func makeRequest(url: String = "https://bedrock.us-east-1.amazonaws.com/test") -> HTTPClientRequest {
        HTTPClientRequest(url: url)
    }

    private func makeResponse(status: HTTPResponseStatus) -> HTTPClientResponse {
        HTTPClientResponse(
            status: status,
            headers: HTTPHeaders([("content-type", "application/json")]),
            body: .bytes(ByteBuffer(string: #"{"ok":true}"#))
        )
    }

    private var logger: Logger { Logger(label: "test-retry") }
    private var noOpSleep: @Sendable (Duration) async throws -> Void { { _ in } }

    @Test("Successful 200 response is returned immediately with no retries")
    func successNoRetry() async throws {
        let attemptCount = NIOLockedValueBox<Int>(0)

        let mock = MockHTTPClient { _ in
            attemptCount.withLockedValue { $0 += 1 }
            return makeResponse(status: .ok)
        }

        let client = RetryingHTTPClient(
            wrapped: mock,
            logger: logger,
            sleepFunction: noOpSleep
        )

        let response = try await client.execute(makeRequest(), timeout: .seconds(30))

        #expect(response.status == .ok)
        #expect(attemptCount.withLockedValue { $0 } == 1)
    }

    @Test("429 triggers retries and eventually succeeds")
    func retryOn429ThenSucceed() async throws {
        let attemptCount = NIOLockedValueBox<Int>(0)

        let mock = MockHTTPClient { _ in
            let current = attemptCount.withLockedValue { n -> Int in
                n += 1
                return n
            }
            if current < 3 {
                return makeResponse(status: .tooManyRequests)
            }
            return makeResponse(status: .ok)
        }

        let client = RetryingHTTPClient(
            wrapped: mock,
            maxAttempts: 3,
            logger: logger,
            sleepFunction: noOpSleep
        )

        let response = try await client.execute(makeRequest(), timeout: .seconds(30))

        #expect(response.status == .ok)
        #expect(attemptCount.withLockedValue { $0 } == 3)
    }

    @Test("500 triggers retries and eventually succeeds")
    func retryOn500ThenSucceed() async throws {
        let attemptCount = NIOLockedValueBox<Int>(0)

        let mock = MockHTTPClient { _ in
            let current = attemptCount.withLockedValue { n -> Int in
                n += 1
                return n
            }
            if current == 1 {
                return makeResponse(status: .internalServerError)
            }
            return makeResponse(status: .ok)
        }

        let client = RetryingHTTPClient(
            wrapped: mock,
            maxAttempts: 3,
            logger: logger,
            sleepFunction: noOpSleep
        )

        let response = try await client.execute(makeRequest(), timeout: .seconds(30))

        #expect(response.status == .ok)
        #expect(attemptCount.withLockedValue { $0 } == 2)
    }

    @Test("400 client error is NOT retried")
    func noRetryOn400() async throws {
        let attemptCount = NIOLockedValueBox<Int>(0)

        let mock = MockHTTPClient { _ in
            attemptCount.withLockedValue { $0 += 1 }
            return makeResponse(status: .badRequest)
        }

        let client = RetryingHTTPClient(
            wrapped: mock,
            logger: logger,
            sleepFunction: noOpSleep
        )

        let response = try await client.execute(makeRequest(), timeout: .seconds(30))

        #expect(response.status == .badRequest)
        #expect(attemptCount.withLockedValue { $0 } == 1)
    }

    @Test("All retries exhausted returns the last error response")
    func allRetriesExhausted() async throws {
        let attemptCount = NIOLockedValueBox<Int>(0)

        let mock = MockHTTPClient { _ in
            attemptCount.withLockedValue { $0 += 1 }
            return makeResponse(status: .serviceUnavailable)
        }

        let client = RetryingHTTPClient(
            wrapped: mock,
            maxAttempts: 3,
            logger: logger,
            sleepFunction: noOpSleep
        )

        let response = try await client.execute(makeRequest(), timeout: .seconds(30))

        #expect(response.status == .serviceUnavailable)
        #expect(attemptCount.withLockedValue { $0 } == 3)
    }

    @Test("Attempt count matches maxAttempts configuration")
    func attemptCountMatchesConfig() async throws {
        let attemptCount = NIOLockedValueBox<Int>(0)

        let mock = MockHTTPClient { _ in
            attemptCount.withLockedValue { $0 += 1 }
            return makeResponse(status: .internalServerError)
        }

        let client = RetryingHTTPClient(
            wrapped: mock,
            maxAttempts: 5,
            logger: logger,
            sleepFunction: noOpSleep
        )

        let response = try await client.execute(makeRequest(), timeout: .seconds(30))

        #expect(response.status == .internalServerError)
        #expect(attemptCount.withLockedValue { $0 } == 5)
    }

    @Test("403 Forbidden is NOT retried")
    func noRetryOn403() async throws {
        let attemptCount = NIOLockedValueBox<Int>(0)

        let mock = MockHTTPClient { _ in
            attemptCount.withLockedValue { $0 += 1 }
            return makeResponse(status: .forbidden)
        }

        let client = RetryingHTTPClient(
            wrapped: mock,
            logger: logger,
            sleepFunction: noOpSleep
        )

        let response = try await client.execute(makeRequest(), timeout: .seconds(30))

        #expect(response.status == .forbidden)
        #expect(attemptCount.withLockedValue { $0 } == 1)
    }
}
