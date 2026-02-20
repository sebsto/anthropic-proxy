#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import AsyncHTTPClient
import Logging
import NIOCore
import NIOHTTP1
import SotoCore
import SotoSignerV4

/// Handles AWS credential loading and SigV4 signing for Bedrock requests.
///
/// Uses soto-core's `AWSClient` with the default credential chain (env vars,
/// ~/.aws/credentials, ~/.aws/config, SSO, IMDS) and signs outbound requests
/// with the "bedrock" service name for both runtime and control plane endpoints.
struct AWSSigningClient: Sendable {
    let awsClient: AWSClient
    let region: String
    let logger: Logger

    var runtimeHost: String { "bedrock-runtime.\(region).amazonaws.com" }
    var controlPlaneHost: String { "bedrock.\(region).amazonaws.com" }

    /// Initialize with the AWS credential chain.
    ///
    /// When `profile` is provided, the credential chain uses that profile name
    /// for both the config file provider (`~/.aws/credentials`) and the login/SSO
    /// provider (`~/.aws/config`). When `nil`, falls back to `AWS_PROFILE` env var
    /// or `"default"`.
    ///
    /// The caller is responsible for calling ``shutdown()`` before the process exits
    /// to cleanly tear down credential refresh tasks.
    ///
    /// - Parameters:
    ///   - region: AWS region (e.g. "us-east-1")
    ///   - profile: AWS profile name (e.g. "my-sso-profile"). Nil uses the default chain.
    ///   - httpClient: AsyncHTTPClient shared with the rest of the application
    ///   - logger: Logger for credential resolution diagnostics
    init(region: String, profile: String?, httpClient: HTTPClient, logger: Logger) {
        self.region = region
        self.logger = logger

        let credentialProvider: CredentialProviderFactory
        if let profile {
            credentialProvider = .selector(
                .environment,
                .configFile(profile: profile),
                .sso(profileName: profile),
                .login(profileName: profile)
            )
        } else {
            credentialProvider = .default
        }

        self.awsClient = AWSClient(
            credentialProvider: credentialProvider,
            httpClient: httpClient,
            logger: logger
        )
    }

    /// Sign an HTTP request for the Bedrock service using SigV4.
    ///
    /// Returns a complete set of headers including Authorization, X-Amz-Date,
    /// X-Amz-Content-Sha256, and X-Amz-Security-Token (when using temporary credentials).
    ///
    /// - Parameters:
    ///   - url: The full request URL
    ///   - method: HTTP method
    ///   - headers: Existing headers to include in the signed request
    ///   - body: Optional request body that participates in the signature
    /// - Returns: Signed headers ready to attach to the outbound request
    func signRequest(
        url: URL,
        method: HTTPMethod,
        headers: HTTPHeaders,
        body: ByteBuffer?
    ) async throws -> HTTPHeaders {
        logger.trace("Resolving AWS credentials...")
        let credential = try await awsClient.getCredential(logger: logger)

        let accessKeyPrefix = String(credential.accessKeyId.prefix(8))
        let hasSession = credential.sessionToken != nil
        logger.trace(
            "Credentials resolved",
            metadata: [
                "accessKeyId": "\(accessKeyPrefix)...",
                "hasSessionToken": "\(hasSession)",
            ]
        )

        logger.trace(
            "Signing request",
            metadata: [
                "method": "\(method)",
                "url": "\(url.absoluteString)",
                "service": "bedrock",
                "region": "\(region)",
            ]
        )

        let signer = AWSSigner(credentials: credential, name: "bedrock", region: region)
        let bodyData: AWSSigner.BodyData? = body.map { .byteBuffer($0) }
        let signed = signer.signHeaders(url: url, method: method, headers: headers, body: bodyData)

        logger.trace(
            "Signed headers",
            metadata: [
                "authorization": "\(String(signed["Authorization"].first?.prefix(60) ?? ""))...",
                "x-amz-date": "\(signed["X-Amz-Date"].first ?? "n/a")",
                "x-amz-security-token": "\(signed["X-Amz-Security-Token"].first != nil ? "present" : "absent")",
            ]
        )

        return signed
    }

    /// Build the full URL for a Bedrock runtime request (e.g. InvokeModel).
    func runtimeURL(path: String) -> URL? {
        URL(string: "https://\(runtimeHost)\(path)")
    }

    /// Build the full URL for a Bedrock control plane request (e.g. ListFoundationModels).
    func controlPlaneURL(path: String) -> URL? {
        URL(string: "https://\(controlPlaneHost)\(path)")
    }

    /// Shut down the underlying AWSClient, releasing credential refresh tasks.
    func shutdown() async throws {
        try await awsClient.shutdown()
    }
}
