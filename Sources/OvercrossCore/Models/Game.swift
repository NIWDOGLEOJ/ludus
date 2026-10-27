import Foundation

enum GameStore: String, CaseIterable, Codable, Identifiable, Sendable {
    case steam
    case epic
    case local

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .steam: "Steam"
        case .epic: "Epic Games"
        case .local: "Local"
        }
    }
}

enum GamePlatform: String, CaseIterable, Codable, Identifiable, Sendable {
    case nativeMacOS
    case windows
    case unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nativeMacOS: "Native macOS"
        case .windows: "Windows"
        case .unknown: "Platform unknown"
        }
    }

    static func inferred(from executableURL: URL) -> GamePlatform {
        switch executableURL.pathExtension.lowercased() {
        case "exe", "msi", "bat", "cmd": .windows
        case "app": .nativeMacOS
        default:
            executableURL.pathComponents.contains { $0.lowercased().hasSuffix(".app") }
                ? .nativeMacOS
                : .unknown
        }
    }
}

enum OwnershipEvidence: String, Codable, Identifiable, Sendable {
    case unknown
    case userSelectedLocal
    case steamLocalManifest
    case heroicInstalledCache
    case steamWebAPI
    case heroicAuthenticatedLibrary

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .unknown:
            "Not established"
        case .userSelectedLocal:
            "User-selected local executable (ownership not confirmed)"
        case .steamLocalManifest:
            "Steam local manifest (ownership not confirmed)"
        case .heroicInstalledCache:
            "Heroic installed cache (ownership not confirmed)"
        case .steamWebAPI:
            "Steam Web API visible library"
        case .heroicAuthenticatedLibrary:
            "Heroic authenticated library"
        }
    }

    var confidence: Int {
        switch self {
        case .unknown: 0
        case .userSelectedLocal: 1
        case .steamLocalManifest, .heroicInstalledCache: 2
        case .steamWebAPI, .heroicAuthenticatedLibrary: 3
        }
    }
}

enum CompatibilityStatus: String, CaseIterable, Codable, Identifiable, Sendable {
    case nativeMacOS
    case windowsCompatibilityAvailable
    case testedWorking
    case partiallyWorking
    case knownIssues
    case unsupported
    case notTested

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nativeMacOS: "Native macOS"
        case .windowsCompatibilityAvailable: "Windows compatibility available"
        case .testedWorking: "Tested working"
        case .partiallyWorking: "Partially working"
        case .knownIssues: "Known issues"
        case .unsupported: "Unsupported"
        case .notTested: "Not tested"
        }
    }
}

struct Game: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    var store: GameStore
    var platform: GamePlatform
    var storeApplicationID: String?
    var ownershipEvidence: OwnershipEvidence
    var artworkURL: URL?
    var installationURL: URL?
    var executableURL: URL?
    var installationMethod: String?
    var graphicsBackend: String?
    var compatibilityStatus: CompatibilityStatus
    var runtimeIdentifier: String?
    var prefixID: UUID?
    var lastLaunchAt: Date?
    var lastLaunchResult: String?
    var isFavorite: Bool
    var isHidden: Bool
    var categories: [String]
    var createdAt: Date

    // Apple Silicon Performance, Custom Launch Arguments & Environment Overrides
    var customLaunchArguments: [String]
    var customEnvironment: [String: String]
    var metalHUDEnabled: Bool?
    var msyncEnabled: Bool?
    var esyncEnabled: Bool?
    var retinaScalingEnabled: Bool?

    func resolvedGraphicsBackend(appSettings: AppSettings? = nil) -> GraphicsBackend {
        if let graphicsBackend, let parsed = GraphicsBackend(rawValue: graphicsBackend), parsed != .unknown {
            return parsed
        }
        if let appDefault = appSettings?.defaultGraphicsBackend, appDefault != .automatic && appDefault != .unknown {
            return appDefault
        }
        return .automatic
    }

    var resolvedGraphicsBackend: GraphicsBackend {
        resolvedGraphicsBackend(appSettings: nil)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, store, platform, storeApplicationID, ownershipEvidence, artworkURL, installationURL, executableURL
        case installationMethod, graphicsBackend, compatibilityStatus, runtimeIdentifier, prefixID
        case lastLaunchAt, lastLaunchResult, isFavorite, isHidden, categories, createdAt
        case customLaunchArguments, customEnvironment, metalHUDEnabled, msyncEnabled, esyncEnabled, retinaScalingEnabled
    }

    init(
        id: UUID = UUID(),
        title: String,
        store: GameStore,
        platform: GamePlatform = .unknown,
        storeApplicationID: String? = nil,
        ownershipEvidence: OwnershipEvidence = .unknown,
        artworkURL: URL? = nil,
        installationURL: URL? = nil,
        executableURL: URL? = nil,
        installationMethod: String? = nil,
        graphicsBackend: String? = nil,
        compatibilityStatus: CompatibilityStatus = .notTested,
        runtimeIdentifier: String? = nil,
        prefixID: UUID? = nil,
        lastLaunchAt: Date? = nil,
        lastLaunchResult: String? = nil,
        isFavorite: Bool = false,
        isHidden: Bool = false,
        categories: [String] = [],
        createdAt: Date = Date(),
        customLaunchArguments: [String] = [],
        customEnvironment: [String: String] = [:],
        metalHUDEnabled: Bool? = nil,
        msyncEnabled: Bool? = nil,
        esyncEnabled: Bool? = nil,
        retinaScalingEnabled: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.store = store
        self.platform = platform
        self.storeApplicationID = storeApplicationID
        self.ownershipEvidence = ownershipEvidence
        self.artworkURL = artworkURL
        self.installationURL = installationURL
        self.executableURL = executableURL
        self.installationMethod = installationMethod
        self.graphicsBackend = graphicsBackend
        self.compatibilityStatus = compatibilityStatus
        self.runtimeIdentifier = runtimeIdentifier
        self.prefixID = prefixID
        self.lastLaunchAt = lastLaunchAt
        self.lastLaunchResult = lastLaunchResult
        self.isFavorite = isFavorite
        self.isHidden = isHidden
        self.categories = categories
        self.createdAt = createdAt
        self.customLaunchArguments = customLaunchArguments
        self.customEnvironment = customEnvironment
        self.metalHUDEnabled = metalHUDEnabled
        self.msyncEnabled = msyncEnabled
        self.esyncEnabled = esyncEnabled
        self.retinaScalingEnabled = retinaScalingEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        store = try container.decode(GameStore.self, forKey: .store)
        platform = try container.decodeIfPresent(GamePlatform.self, forKey: .platform) ?? .unknown
        storeApplicationID = try container.decodeIfPresent(String.self, forKey: .storeApplicationID)
        ownershipEvidence = try container.decodeIfPresent(OwnershipEvidence.self, forKey: .ownershipEvidence) ?? .unknown
        artworkURL = try container.decodeIfPresent(URL.self, forKey: .artworkURL)
        installationURL = try container.decodeIfPresent(URL.self, forKey: .installationURL)
        executableURL = try container.decodeIfPresent(URL.self, forKey: .executableURL)
        installationMethod = try container.decodeIfPresent(String.self, forKey: .installationMethod)
        graphicsBackend = try container.decodeIfPresent(String.self, forKey: .graphicsBackend)
        compatibilityStatus = try container.decode(CompatibilityStatus.self, forKey: .compatibilityStatus)
        runtimeIdentifier = try container.decodeIfPresent(String.self, forKey: .runtimeIdentifier)
        prefixID = try container.decodeIfPresent(UUID.self, forKey: .prefixID)
        lastLaunchAt = try container.decodeIfPresent(Date.self, forKey: .lastLaunchAt)
        lastLaunchResult = try container.decodeIfPresent(String.self, forKey: .lastLaunchResult)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        categories = try container.decodeIfPresent([String].self, forKey: .categories) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        customLaunchArguments = try container.decodeIfPresent([String].self, forKey: .customLaunchArguments) ?? []
        customEnvironment = try container.decodeIfPresent([String: String].self, forKey: .customEnvironment) ?? [:]
        metalHUDEnabled = try container.decodeIfPresent(Bool.self, forKey: .metalHUDEnabled)
        msyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .msyncEnabled)
        esyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .esyncEnabled)
        retinaScalingEnabled = try container.decodeIfPresent(Bool.self, forKey: .retinaScalingEnabled)
    }
}
