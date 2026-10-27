import Foundation

enum LaunchKind: String, Codable, Identifiable, Sendable {
    case native
    case windowsThroughWine

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .native: "Native"
        case .windowsThroughWine: "Windows through Wine"
        }
    }
}

struct LaunchLogRecord: Identifiable, Codable, Hashable, Sendable {
    static let maximumStreamLength = 64 * 1024

    let id: UUID
    let gameID: UUID
    let startedAt: Date
    let finishedAt: Date
    let kind: LaunchKind
    let exitStatus: Int32?
    let summary: String
    let standardOutput: String
    let standardError: String

    init(
        id: UUID = UUID(),
        gameID: UUID,
        startedAt: Date,
        finishedAt: Date,
        kind: LaunchKind,
        exitStatus: Int32?,
        summary: String,
        standardOutput: String = "",
        standardError: String = ""
    ) {
        self.id = id
        self.gameID = gameID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.kind = kind
        self.exitStatus = exitStatus
        self.summary = summary
        self.standardOutput = String(standardOutput.prefix(Self.maximumStreamLength))
        self.standardError = String(standardError.prefix(Self.maximumStreamLength))
    }

    var combinedText: String {
        [summary, standardOutput, standardError]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
