#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

struct ListFoundationModelsResponse: Codable, Sendable {
    var modelSummaries: [FoundationModelSummary]
}

struct FoundationModelSummary: Codable, Sendable {
    var modelId: String
    var modelArn: String?
    var modelName: String
    var providerName: String
    var inputModalities: [String]?
    var outputModalities: [String]?
    var responseStreamingSupported: Bool?
    var modelLifecycle: ModelLifecycle?
}

struct ModelLifecycle: Codable, Sendable {
    var status: String
}

// MARK: - Inference Profiles

struct ListInferenceProfilesResponse: Codable, Sendable {
    var inferenceProfileSummaries: [InferenceProfileSummary]
}

struct InferenceProfileSummary: Codable, Sendable {
    var inferenceProfileId: String
    var models: [InferenceProfileModel]?
    var status: String?
    var type: String?
}

struct InferenceProfileModel: Codable, Sendable {
    var modelArn: String
}
