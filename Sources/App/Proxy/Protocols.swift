#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import AsyncHTTPClient
import NIOCore
import NIOHTTP1

// MARK: - HTTP Request Sending

protocol HTTPRequestSending: Sendable {
    func execute(
        _ request: HTTPClientRequest,
        timeout: TimeAmount
    ) async throws -> HTTPClientResponse
}

extension HTTPClient: HTTPRequestSending {
    func execute(
        _ request: HTTPClientRequest,
        timeout: TimeAmount
    ) async throws -> HTTPClientResponse {
        try await execute(request, timeout: timeout, logger: nil)
    }
}

// MARK: - Request Signing

protocol RequestSigning: Sendable {
    var runtimeHost: String { get }
    var controlPlaneHost: String { get }

    func signRequest(
        url: URL,
        method: HTTPMethod,
        headers: HTTPHeaders,
        body: ByteBuffer?
    ) async throws -> HTTPHeaders
}

extension AWSSigningClient: RequestSigning {}
