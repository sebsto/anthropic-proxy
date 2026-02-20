#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import AsyncHTTPClient
import Hummingbird
import Logging
import NIOCore

func buildApplication(
    config: Config,
    httpClient: HTTPClient,
    signingClient: AWSSigningClient,
    logger: Logger
) -> some ApplicationProtocol {
    return buildApplication(config: config, signingClient: signingClient, httpClient: httpClient, logger: logger)
}

func buildApplication<Signer: RequestSigning, Client: HTTPRequestSending>(
    config: Config,
    signingClient: Signer,
    httpClient: Client,
    logger: Logger
) -> some ApplicationProtocol {
    let modelCache = ModelCache(ttl: TimeInterval(config.modelCacheTTL))
    let modelsHandler = ModelsHandler(
        signingClient: signingClient,
        httpClient: httpClient,
        cache: modelCache,
        requestTimeout: .seconds(Int64(config.modelsTimeout)),
        logger: logger
    )
    let chatCompletionsHandler = ChatCompletionsHandler(
        signingClient: signingClient,
        httpClient: httpClient,
        modelsHandler: modelsHandler,
        requestTimeout: .seconds(Int64(config.requestTimeout)),
        logger: logger
    )

    let router = Router()
    router.add(middleware: DebugLoggingMiddleware<BasicRequestContext>(logger: logger))

    // Health check (unauthenticated)
    router.get("/health") { _, _ in
        Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(string: #"{"status":"ok"}"#))
        )
    }

    // API routes protected by API key authentication
    let apiRoutes = router.group()
        .add(middleware: APIKeyAuthMiddleware(apiKey: config.proxyAPIKey ?? ""))

    apiRoutes.get("/v1/models") { request, context in
        try await modelsHandler.listModels(request: request, context: context)
    }

    apiRoutes.get("/v1/models/{model_id}") { request, context in
        try await modelsHandler.getModel(request: request, context: context)
    }

    apiRoutes.post("/v1/chat/completions") { request, context in
        try await chatCompletionsHandler.handle(request: request, context: context)
    }

    return Application(
        router: router,
        configuration: .init(address: .hostname(config.hostname, port: config.port))
    )
}
