import Foundation

enum DownloadOperationKind: String, Codable, Identifiable, Sendable {
    case install
    case update

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .install: "Installation"
        case .update: "Update"
        }
    }
}

enum DownloadOperationState: String, Codable, Identifiable, Sendable {
    case running
    case paused
    case completed
    case cancelled
    case failed
    case recoveryRequired

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .running: "In progress"
        case .paused: "Paused"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        case .recoveryRequired: "Recovery required"
        }
    }
}

struct DownloadOperation: Identifiable, Codable, Hashable, Sendable {
    static let maximumDetailLength = 4_000

    let id: UUID
    let gameID: UUID
    let gameTitle: String
    let kind: DownloadOperationKind
    let startedAt: Date
    var updatedAt: Date
    var finishedAt: Date?
    var state: DownloadOperationState
    var fraction: Double?
    var detail: String
    var error: String?

    init(
        id: UUID = UUID(),
        gameID: UUID,
        gameTitle: String,
        kind: DownloadOperationKind,
        startedAt: Date = Date(),
        state: DownloadOperationState = .running,
        fraction: Double? = nil,
        detail: String
    ) {
        self.id = id
        self.gameID = gameID
        self.gameTitle = gameTitle
        self.kind = kind
        self.startedAt = startedAt
        self.updatedAt = startedAt
        self.finishedAt = nil
        self.state = state
        self.fraction = fraction.map { min(max($0, 0), 1) }
        self.detail = String(detail.prefix(Self.maximumDetailLength))
        self.error = nil
    }

    mutating func update(
        state: DownloadOperationState? = nil,
        fraction: Double? = nil,
        detail: String? = nil,
        error: String? = nil,
        finishedAt: Date? = nil,
        at date: Date = Date()
    ) {
        updatedAt = date
        if let state { self.state = state }
        if let fraction { self.fraction = min(max(fraction, 0), 1) }
        if let detail { self.detail = String(detail.prefix(Self.maximumDetailLength)) }
        if let error { self.error = String(error.prefix(Self.maximumDetailLength)) }
        if finishedAt != nil { self.finishedAt = finishedAt }
    }
}
