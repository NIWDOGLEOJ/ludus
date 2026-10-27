import Foundation

enum GraphicsBackend: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case d3dmetal
    case dxvk
    case dxmt
    case native
    case moltenVK
    case unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .d3dmetal: "D3DMetal (Apple GPTK)"
        case .dxvk: "DXVK (Vulkan)"
        case .dxmt: "DXMT (Direct3D to Metal)"
        case .native: "Native"
        case .moltenVK: "MoltenVK"
        case .unknown: "Unknown"
        }
    }
}

enum ProfileTestResult: String, CaseIterable, Codable, Identifiable, Sendable {
    case notTested
    case working
    case partiallyWorking
    case failed
    case unsupported

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notTested: "Not tested"
        case .working: "Working"
        case .partiallyWorking: "Partially working"
        case .failed: "Failed"
        case .unsupported: "Unsupported"
        }
    }
}

struct CompatibilityProfile: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var store: GameStore
    var storeApplicationID: String?
    var executableRelativePath: String?
    var requiredLauncher: String?
    var runtimeIdentifier: String?
    var prefixID: UUID?
    var prefixArchitecture: PrefixArchitecture?
    var graphicsBackend: GraphicsBackend
    var dependencies: [String]
    var launchArguments: [String]
    var environment: [String: String]
    var knownWorkarounds: [String]
    var knownIssues: [String]
    var lastVerifiedAt: Date?
    var testEnvironment: String?
    var testResult: ProfileTestResult

    init(
        id: UUID = UUID(),
        store: GameStore,
        storeApplicationID: String?,
        executableRelativePath: String? = nil,
        requiredLauncher: String? = nil,
        runtimeIdentifier: String? = nil,
        prefixID: UUID? = nil,
        prefixArchitecture: PrefixArchitecture? = nil,
        graphicsBackend: GraphicsBackend = .automatic,
        dependencies: [String] = [],
        launchArguments: [String] = [],
        environment: [String: String] = [:],
        knownWorkarounds: [String] = [],
        knownIssues: [String] = [],
        lastVerifiedAt: Date? = nil,
        testEnvironment: String? = nil,
        testResult: ProfileTestResult = .notTested
    ) {
        self.id = id
        self.store = store
        self.storeApplicationID = storeApplicationID
        self.executableRelativePath = executableRelativePath
        self.requiredLauncher = requiredLauncher
        self.runtimeIdentifier = runtimeIdentifier
        self.prefixID = prefixID
        self.prefixArchitecture = prefixArchitecture
        self.graphicsBackend = graphicsBackend
        self.dependencies = dependencies
        self.launchArguments = launchArguments
        self.environment = environment
        self.knownWorkarounds = knownWorkarounds
        self.knownIssues = knownIssues
        self.lastVerifiedAt = lastVerifiedAt
        self.testEnvironment = testEnvironment
        self.testResult = testResult
    }

    var isVerified: Bool {
        (testResult == .working || testResult == .partiallyWorking) && hasRecordedEvidence
    }

    var hasRecordedEvidence: Bool {
        guard let testEnvironment else { return false }
        return !testEnvironment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
