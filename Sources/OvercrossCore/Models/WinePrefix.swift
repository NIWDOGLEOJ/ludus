import Foundation

enum PrefixArchitecture: String, CaseIterable, Codable, Identifiable, Sendable {
    case win64
    case win32

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .win64: "win64"
        case .win32: "win32"
        }
    }
}

struct WinePrefix: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var url: URL
    var runtimeURL: URL
    var architecture: PrefixArchitecture
    var createdAt: Date
    var status: String

    init(
        id: UUID = UUID(),
        name: String,
        url: URL,
        runtimeURL: URL,
        architecture: PrefixArchitecture,
        createdAt: Date = Date(),
        status: String = "Ready"
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.runtimeURL = runtimeURL
        self.architecture = architecture
        self.createdAt = createdAt
        self.status = status
    }
}

struct PrefixComponentInfo: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    var category: String
    var isInstalled: Bool
    var relativePath: String

    init(
        id: String,
        name: String,
        category: String,
        isInstalled: Bool,
        relativePath: String
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.isInstalled = isInstalled
        self.relativePath = relativePath
    }
}

