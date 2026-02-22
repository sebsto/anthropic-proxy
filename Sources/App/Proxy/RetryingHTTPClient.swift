#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import AsyncHTTPClient
import Logging
import NIOCore
import NIOHTTP1

/// A drop-in wrapper around any ``HTTPRequestSending`` conformer that adds
/// automatic retry logic with exponential backoff and jitter.
///
/// Only transient failures are retried: HTTP 429 (rate-limit) and 5xx
/// (server errors). Client errors (4xx other than 429) are considered
/// permanent and returned immediately.
struct RetryingHTTPClient<Wrapped: HTTPRequestSending>: HTTPRequestSending, Sendable {

    /// The underlying HTTP client whose requests are retried on transient failure.
    let wrapped: Wrapped

    /// Maximum number of attempts (1 initial + retries).
    let maxAttempts: Int

    /// Base delay for exponential backoff. The actual delay for attempt *n* is
    /// `baseDelay * 2^n`, randomised by ±25 % to avoid thundering-herd effects.
    let baseDelay: Duration

    /// Logger used to emit `.warning`-level messages on each retry.
    let logger: Logger

    /// Injectable sleep function for testability. Defaults to `Task.sleep(for:)`.
    let sleepFunction: @Sendable (Duration) async throws -> Void

    /// Creates a retrying wrapper around an existing HTTP client.
    ///
    /// - Parameters:
    ///   - wrapped: The HTTP client to delegate requests to.
    ///   - maxAttempts: Total attempts including the initial one. Defaults to `3`.
    ///   - baseDelay: Starting backoff interval. Defaults to `.milliseconds(500)`.
    ///   - logger: Logger for retry warnings.
    ///   - sleepFunction: Async sleep used between retries. Override in tests
    ///     to avoid real delays.
    init(
        wrapped: Wrapped,
        maxAttempts: Int = 3,
        baseDelay: Duration = .milliseconds(500),
        logger: Logger,
        sleepFunction: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.wrapped = wrapped
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.logger = logger
        self.sleepFunction = sleepFunction
    }

    /// Executes an HTTP request, retrying on transient failures.
    ///
    /// - Parameters:
    ///   - request: The outbound HTTP request.
    ///   - timeout: Per-attempt timeout forwarded to the wrapped client.
    /// - Returns: The HTTP response from the first successful attempt, or the
    ///   last response after all retries are exhausted.
    func execute(
        _ request: HTTPClientRequest,
        timeout: TimeAmount
    ) async throws -> HTTPClientResponse {
        var lastResponse: HTTPClientResponse?

        for attempt in 0..<maxAttempts {
            let response = try await wrapped.execute(request, timeout: timeout)

            guard shouldRetry(statusCode: response.status.code) else {
                return response
            }

            lastResponse = response

            let isLastAttempt = attempt == maxAttempts - 1
            if !isLastAttempt {
                let delay = jitteredDelay(for: attempt)
                logger.warning(
                    "Retrying request",
                    metadata: [
                        "attempt": "\(attempt + 1)/\(maxAttempts)",
                        "statusCode": "\(response.status.code)",
                        "delaySeconds": "\(Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18)",
                        "url": "\(request.url)",
                    ]
                )
                try await sleepFunction(delay)
            }
        }

        // All retries exhausted — return the last error response.
        return lastResponse!
    }

    // MARK: - Private

    private func shouldRetry(statusCode: UInt) -> Bool {
        statusCode == 429 || (500...599).contains(statusCode)
    }

    private func jitteredDelay(for attempt: Int) -> Duration {
        // Exponential: baseDelay * 2^attempt
        let multiplier = 1 << attempt  // 2^attempt
        let baseNanos = baseDelay.components.attoseconds / 1_000_000_000
            + Int64(baseDelay.components.seconds) * 1_000_000_000
        let delayNanos = baseNanos * Int64(multiplier)

        // ±25 % jitter
        let jitterRange = delayNanos / 4
        let jitter = Int64.random(in: -jitterRange...jitterRange)
        let finalNanos = max(0, delayNanos + jitter)

        return .nanoseconds(finalNanos)
    }
}
