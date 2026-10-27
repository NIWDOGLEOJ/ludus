import Foundation

enum DiagnosticSeverity: String, Codable, Identifiable, Sendable {
    case info
    case success
    case warning
    case error

    var id: String { rawValue }
}

enum FixActionKind: String, Codable, Hashable, Sendable {
    case installHeroic
    case installWine
    case installSteam
    case configureDeveloperTools
}

struct DiagnosticFinding: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let title: String
    let detail: String
    let severity: DiagnosticSeverity
    let fixActionTitle: String?
    let fixActionKind: FixActionKind?

    init(
        id: UUID = UUID(),
        title: String,
        detail: String,
        severity: DiagnosticSeverity,
        fixActionTitle: String? = nil,
        fixActionKind: FixActionKind? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.severity = severity
        self.fixActionTitle = fixActionTitle
        self.fixActionKind = fixActionKind
    }
}

struct RuntimeDiagnosticReport: Codable, Hashable, Sendable {
    let generatedAt: Date
    let hostArchitecture: String
    let macOSVersion: String
    let developerDirectory: String?
    let findings: [DiagnosticFinding]
    let runtimes: [DetectedRuntime]

    static let empty = RuntimeDiagnosticReport(
        generatedAt: .distantPast,
        hostArchitecture: "Unknown",
        macOSVersion: "Unknown",
        developerDirectory: nil,
        findings: [],
        runtimes: []
    )

    var hasErrors: Bool {
        findings.contains { $0.severity == .error }
    }
}

struct DetectedRuntime: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let name: String
    let executableURL: URL
    let winebootURL: URL?
    let version: String
    let architecture: String
    let status: String

    init(
        id: UUID = UUID(),
        name: String,
        executableURL: URL,
        winebootURL: URL? = nil,
        version: String,
        architecture: String,
        status: String
    ) {
        self.id = id
        self.name = name
        self.executableURL = executableURL
        self.winebootURL = winebootURL
        self.version = version
        self.architecture = architecture
        self.status = status
    }
}
