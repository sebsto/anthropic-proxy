import ArgumentParser
import AsyncHTTPClient
import Hummingbird
import Logging
import ServiceLifecycle

@main
struct ProxyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "anthropic-proxy",
        abstract: "OpenAI-to-Bedrock proxy for Xcode"
    )

    @Option(name: .long, help: "Hostname to listen on")
    var hostname: String = "127.0.0.1"

    @Option(name: .long, help: "Port to listen on")
    var port: Int = 8080

    @Option(name: .long, help: "AWS profile name from ~/.aws/config")
    var awsProfile: String?

    func run() async throws {
        let config = await Config.load(hostnameOverride: hostname, portOverride: port, awsProfileOverride: awsProfile)
        var logger = Logger(label: "anthropic-proxy")
        logger.logLevel = Logger.Level(rawValue: config.logLevel) ?? .info

        guard config.proxyAPIKey != nil else {
            logger.critical("PROXY_API_KEY is not set. Refusing to start without an API key.")
            throw ExitCode.failure
        }

        if let profile = config.awsProfile {
            logger.info("Using AWS profile: \(profile)")
        }

        let httpClient = HTTPClient()
        let signingClient = AWSSigningClient(
            region: config.region,
            profile: config.awsProfile,
            httpClient: httpClient,
            logger: logger
        )

        // Verify AWS credentials are resolvable before starting the server.
        // This catches misconfiguration early (e.g. container without ~/.aws mount).
        do {
            _ = try await signingClient.awsClient.getCredential(logger: logger)
            logger.info("AWS credentials resolved successfully")
        } catch {
            logger.critical("Failed to resolve AWS credentials. If running in a container, ensure AWS credentials are available via environment variables (AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY), a mounted ~/.aws directory, or an instance profile (IMDS).")
            logger.critical("Credential error: \(error)")
            try? await signingClient.shutdown()
            try? await httpClient.shutdown().get()
            throw ExitCode.failure
        }

        let retryingClient = RetryingHTTPClient(
            wrapped: httpClient,
            logger: logger
        )

        let app = buildApplication(
            config: config,
            signingClient: signingClient,
            httpClient: retryingClient,
            logger: logger
        )

        // ServiceGroup manages graceful shutdown in reverse order:
        //   1. Application stops accepting connections and drains in-flight requests
        //   2. AWSClient shuts down (stops credential refresh)
        //   3. HTTPClient shuts down (releases connection pool)
        let serviceGroup = ServiceGroup(
            configuration: .init(
                services: [
                    .init(service: HTTPClientService(client: httpClient)),
                    .init(service: signingClient.awsClient),
                    .init(service: app, successTerminationBehavior: .gracefullyShutdownGroup),
                ],
                gracefulShutdownSignals: [.sigterm, .sigint],
                logger: logger
            )
        )

        try await serviceGroup.run()
    }
}

/// Wraps an `HTTPClient` as a `Service` so it participates in `ServiceGroup` lifecycle.
///
/// On graceful shutdown the client's connection pool is drained and released.
struct HTTPClientService: Service {
    let client: HTTPClient

    func run() async throws {
        try? await gracefulShutdown()
        try await client.shutdown().get()
    }
}
