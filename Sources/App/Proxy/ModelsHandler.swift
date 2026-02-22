#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import AsyncHTTPClient
import Hummingbird
import Logging
import NIOCore
import NIOHTTP1

// MARK: - Model Cache

actor ModelCache {
    private var cachedModels: [Model]?
    private var idMapping: [String: String]?
    private var inferenceProfileMapping: [String: String]?
    private var lastFetch: Date?
    private let ttl: TimeInterval

    init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    func get() -> (models: [Model], mapping: [String: String], inferenceProfiles: [String: String])? {
        guard let models = cachedModels,
              let mapping = idMapping,
              let lastFetch,
              Date().timeIntervalSince(lastFetch) < ttl
        else {
            return nil
        }
        return (models, mapping, inferenceProfileMapping ?? [:])
    }

    func set(_ models: [Model], mapping: [String: String], inferenceProfiles: [String: String]) {
        cachedModels = models
        idMapping = mapping
        inferenceProfileMapping = inferenceProfiles
        lastFetch = Date()
    }
}

// MARK: - Models Handler

struct ModelsHandler<Signer: RequestSigning, Client: HTTPRequestSending>: Sendable {
    let signingClient: Signer
    let httpClient: Client
    let cache: ModelCache
    let requestTimeout: TimeAmount
    let logger: Logger

    func fetchModels() async throws -> [Model] {
        if let cached = await cache.get() {
            logger.trace("Returning \(cached.models.count) cached models")
            return cached.models
        }

        let urlString = "https://\(signingClient.controlPlaneHost)/foundation-models?byProvider=Anthropic"
        guard let url = URL(string: urlString) else {
            throw ModelError.invalidURL(urlString)
        }

        logger.trace("Fetching models from Bedrock", metadata: ["url": "\(urlString)"])

        var request = HTTPClientRequest(url: urlString)
        request.method = .GET
        request.headers.add(name: "Accept", value: "application/json")

        let signedHeaders = try await signingClient.signRequest(
            url: url,
            method: .GET,
            headers: request.headers,
            body: nil
        )
        request.headers = signedHeaders

        let response = try await httpClient.execute(request, timeout: requestTimeout)

        logger.trace("Bedrock ListFoundationModels response", metadata: ["status": "\(response.status.code)"])

        guard (200..<300).contains(response.status.code) else {
            let errorBody = try? await response.body.collect(upTo: 1024 * 1024)
            if let errorBody, let bodyStr = errorBody.getString(at: errorBody.readerIndex, length: errorBody.readableBytes) {
                logger.trace("Bedrock error body: \(bodyStr)")
            }
            throw ModelError.bedrockRequestFailed(Int(response.status.code))
        }

        let body = try await response.body.collect(upTo: 1024 * 1024)
        let decoded = try JSONDecoder().decode(ListFoundationModelsResponse.self, from: body)

        let activeSummaries = decoded.modelSummaries.filter {
            $0.modelLifecycle?.status == "ACTIVE"
        }

        var models: [Model] = []
        var mapping: [String: String] = [:]

        for summary in activeSummaries {
            let openAIId = translateModelId(summary.modelId)
            let created = extractCreatedTimestamp(from: summary.modelId)
            let ownedBy = summary.providerName.lowercased()

            let model = Model(
                id: openAIId,
                object: "model",
                created: created,
                ownedBy: ownedBy
            )
            models.append(model)
            mapping[openAIId] = summary.modelId
        }

        // Also fetch inference profiles (best-effort, returns empty on failure)
        let inferenceProfiles = await fetchInferenceProfiles()

        models.sort { $0.created > $1.created }
        await cache.set(models, mapping: mapping, inferenceProfiles: inferenceProfiles)
        return models
    }

    func resolveModelID(_ clientModel: String) async throws -> String {
        var input = clientModel
        if input.hasPrefix("anthropic/") {
            input = String(input.dropFirst("anthropic/".count))
        }

        // Ensure cache is populated (at most one fetch).
        // Uses try? because raw Bedrock IDs (anthropic.*) don't need the cache to resolve —
        // it's only needed for inference profile lookup, which is best-effort.
        if await cache.get() == nil {
            _ = try? await fetchModels()
        }

        // Resolve bedrockId — works even without cache for raw Bedrock IDs
        let bedrockId: String
        if input.contains("anthropic.") {
            bedrockId = input
        } else {
            guard let cached = await cache.get() else {
                throw ModelError.modelNotFound(clientModel)
            }
            if let id = cached.mapping[input] {
                bedrockId = id
            } else {
                let normalized = input.replacingOccurrences(of: ".", with: "-")
                guard let id = cached.models.first(where: { $0.id.hasPrefix(normalized) })
                    .flatMap({ cached.mapping[$0.id] }) else {
                    throw ModelError.modelNotFound(clientModel)
                }
                bedrockId = id
            }
        }

        // Prefer inference profile when available (required for some newer models)
        if let cached = await cache.get(),
           let profileId = cached.inferenceProfiles[bedrockId] {
            logger.trace(
                "Using inference profile",
                metadata: [
                    "modelId": "\(bedrockId)",
                    "profileId": "\(profileId)",
                ]
            )
            return profileId
        }

        return bedrockId
    }

    // MARK: - Route Handlers

    func listModels(request: Request, context: some RequestContext) async throws -> Response {
        let models = try await fetchModels()
        let modelList = ModelList(object: "list", data: models)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(modelList)
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }

    func getModel(request: Request, context: some RequestContext) async throws -> Response {
        let modelId = context.parameters.get("model_id") ?? ""
        let models = try await fetchModels()
        guard let model = models.first(where: { $0.id == modelId }) else {
            let error = OpenAIErrorResponse(
                error: OpenAIError(
                    message: "The model '\(modelId)' does not exist",
                    type: "invalid_request_error",
                    code: "model_not_found"
                )
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(error)
            return Response(
                status: .notFound,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(model)
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }

    // MARK: - Inference Profiles

    private func fetchInferenceProfiles() async -> [String: String] {
        let urlString = "https://\(signingClient.controlPlaneHost)/inference-profiles?maxResults=1000&typeEquals=SYSTEM_DEFINED"
        guard let url = URL(string: urlString) else { return [:] }

        logger.trace("Fetching inference profiles from Bedrock", metadata: ["url": "\(urlString)"])

        var request = HTTPClientRequest(url: urlString)
        request.method = .GET
        request.headers.add(name: "Accept", value: "application/json")

        guard let signedHeaders = try? await signingClient.signRequest(
            url: url, method: .GET, headers: request.headers, body: nil
        ) else {
            logger.trace("Failed to sign inference profiles request")
            return [:]
        }
        request.headers = signedHeaders

        guard let response = try? await httpClient.execute(request, timeout: requestTimeout),
              (200..<300).contains(response.status.code),
              let body = try? await response.body.collect(upTo: 2 * 1024 * 1024),
              let decoded = try? JSONDecoder().decode(ListInferenceProfilesResponse.self, from: body)
        else {
            logger.trace("Failed to fetch inference profiles")
            return [:]
        }

        var mapping: [String: String] = [:]
        for profile in decoded.inferenceProfileSummaries {
            guard profile.status == "ACTIVE" else { continue }
            guard profile.inferenceProfileId.contains("anthropic.") else { continue }
            if let models = profile.models {
                for model in models {
                    if let modelId = extractModelIdFromArn(model.modelArn) {
                        mapping[modelId] = profile.inferenceProfileId
                    }
                }
            }
        }

        logger.trace("Fetched inference profiles", metadata: ["count": "\(mapping.count)"])
        return mapping
    }

    private func extractModelIdFromArn(_ arn: String) -> String? {
        guard let lastSlash = arn.lastIndex(of: "/") else { return nil }
        let modelId = String(arn[arn.index(after: lastSlash)...])
        return modelId.isEmpty ? nil : modelId
    }

    // MARK: - Translation Helpers

    func translateModelId(_ bedrockId: String) -> String {
        var id = bedrockId
        if id.hasPrefix("anthropic.") {
            id = String(id.dropFirst("anthropic.".count))
        }
        if let range = id.range(of: #"-v\d+:\d+$"#, options: .regularExpression) {
            id = String(id[id.startIndex..<range.lowerBound])
        }
        return id
    }

    func extractCreatedTimestamp(from modelId: String) -> Int {
        guard let range = modelId.range(of: #"\d{8}"#, options: .regularExpression) else {
            return 0
        }
        let dateString = String(modelId[range])
        guard dateString.count == 8 else { return 0 }

        let yearStr = dateString.prefix(4)
        let monthStr = dateString.dropFirst(4).prefix(2)
        let dayStr = dateString.dropFirst(6).prefix(2)

        guard let year = Int(yearStr),
              let month = Int(monthStr),
              let day = Int(dayStr),
              (1970...2100).contains(year),
              (1...12).contains(month),
              (1...31).contains(day)
        else {
            return 0
        }

        return utcTimestamp(year: year, month: month, day: day)
    }

    /// Compute a Unix timestamp for a UTC date without Calendar/DateComponents.
    /// Uses the standard days-since-epoch formula for the proleptic Gregorian calendar.
    private func utcTimestamp(year: Int, month: Int, day: Int) -> Int {
        // Cumulative days before each month in a non-leap year (index 0 unused)
        let cumulativeDays = [0, 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]

        let isLeapYear = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
        let leapAdjustment = (month > 2 && isLeapYear) ? 1 : 0

        // Leap years between 1970 and year-1
        let leapYearsBefore = { (y: Int) -> Int in
            (y / 4) - (y / 100) + (y / 400)
        }
        let daysInPriorYears = 365 * (year - 1970)
            + leapYearsBefore(year - 1) - leapYearsBefore(1969)

        let totalDays = daysInPriorYears + cumulativeDays[month] + day - 1 + leapAdjustment

        return totalDays * 86400
    }
}

// MARK: - Errors

enum ModelError: Error {
    case invalidURL(String)
    case bedrockRequestFailed(Int)
    case modelNotFound(String)
}
