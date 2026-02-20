#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Hummingbird
import Logging

struct DebugLoggingMiddleware<Context: RequestContext>: RouterMiddleware {
    let logger: Logger

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let method = request.method.rawValue
        let path = request.uri.path

        if logger.logLevel <= .debug {
            logRequestDetails(method: method, path: path, headers: request.headers)
        }

        let clock = ContinuousClock()
        let start = clock.now

        let response = try await next(request, context)

        let elapsed = clock.now - start
        let milliseconds = elapsed.components.seconds * 1000
            + elapsed.components.attoseconds / 1_000_000_000_000_000

        logger.info("\(method) \(path) → \(response.status.code) (\(milliseconds)ms)")

        if logger.logLevel <= .debug {
            logResponseDetails(response: response)
        }

        return response
    }

    private func logRequestDetails(method: String, path: String, headers: HTTPFields) {
        logger.debug("--- Inbound Request ---")
        logger.debug("\(method) \(path)")

        for field in headers {
            logger.debug("  \(field.name): \(field.value)")
        }

        if let contentType = headers[.contentType] {
            logger.debug("Content-Type: \(contentType)")
        }
        if let contentLength = headers[.contentLength] {
            logger.debug("Content-Length: \(contentLength)")
        }
    }

    private func logResponseDetails(response: Response) {
        logger.debug("--- Outbound Response ---")
        logger.debug("Status: \(response.status.code)")

        for field in response.headers {
            logger.debug("  \(field.name): \(field.value)")
        }

        let isStreaming = response.headers[.contentType] == "text/event-stream"
        if isStreaming {
            logger.debug("Response body: [streaming]")
        }
    }
}
