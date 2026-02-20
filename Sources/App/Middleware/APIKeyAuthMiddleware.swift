#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import HTTPTypes
import Hummingbird
import NIOCore

struct APIKeyAuthMiddleware<Context: RequestContext>: RouterMiddleware {
    let apiKey: String

    private var xAPIKeyName: HTTPField.Name { HTTPField.Name("x-api-key")! }

    func handle(
        _ input: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard input.headers[values: xAPIKeyName].contains(where: { $0 == apiKey }) else {
            let error = OpenAIErrorResponse(error: OpenAIError(
                message: "Invalid API key",
                type: "invalid_request_error",
                code: "invalid_api_key"
            ))
            let body = try JSONEncoder().encode(error)
            return Response(
                status: .unauthorized,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(bytes: body))
            )
        }

        return try await next(input, context)
    }
}
