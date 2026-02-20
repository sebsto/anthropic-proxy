import Configuration
import SystemPackage

struct Config: Sendable {
    let hostname: String
    let port: Int
    let region: String
    let proxyAPIKey: String?
    let modelCacheTTL: Int
    let requestTimeout: Int
    let modelsTimeout: Int
    let awsProfile: String?
    let logLevel: String

    init(
        hostnameOverride: String? = nil,
        portOverride: Int? = nil,
        reader: ConfigReader
    ) {
        self.hostname = hostnameOverride
            ?? reader.string(forKey: "PROXY_HOST")
            ?? "127.0.0.1"
        self.port = portOverride
            ?? reader.int(forKey: "PROXY_PORT")
            ?? 8080
        self.region = reader.string(forKey: "AWS_REGION")
            ?? reader.string(forKey: "AWS_DEFAULT_REGION")
            ?? "us-east-1"
        self.proxyAPIKey = reader.string(forKey: "PROXY_API_KEY")
        self.modelCacheTTL = reader.int(forKey: "MODEL_CACHE_TTL_SECONDS") ?? 300
        self.requestTimeout = reader.int(forKey: "REQUEST_TIMEOUT_SECONDS") ?? 600
        self.modelsTimeout = reader.int(forKey: "MODELS_TIMEOUT_SECONDS") ?? 30
        self.awsProfile = reader.string(forKey: "AWS_PROFILE")
        self.logLevel = reader.string(forKey: "LOG_LEVEL") ?? "info"
    }

    init(
        hostname: String = "127.0.0.1",
        port: Int = 8080,
        region: String = "us-east-1",
        proxyAPIKey: String? = nil,
        modelCacheTTL: Int = 300,
        requestTimeout: Int = 600,
        modelsTimeout: Int = 30,
        awsProfile: String? = nil,
        logLevel: String = "info"
    ) {
        self.hostname = hostname
        self.port = port
        self.region = region
        self.proxyAPIKey = proxyAPIKey
        self.modelCacheTTL = modelCacheTTL
        self.requestTimeout = requestTimeout
        self.modelsTimeout = modelsTimeout
        self.awsProfile = awsProfile
        self.logLevel = logLevel
    }

    static func load(
        hostnameOverride: String? = nil,
        portOverride: Int? = nil,
        configFile: String = "config.json"
    ) async -> Config {
        var providers: [any ConfigProvider] = [
            EnvironmentVariablesProvider(),
        ]

        if let fileProvider = try? await FileProvider<JSONSnapshot>(
            filePath: FilePath(configFile),
            allowMissing: true
        ) {
            providers.append(fileProvider)
        }

        let reader = ConfigReader(providers: providers)
        return Config(
            hostnameOverride: hostnameOverride,
            portOverride: portOverride,
            reader: reader
        )
    }
}
