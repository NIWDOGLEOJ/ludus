import Foundation

struct LaunchLogStore {
    private static let maximumRecords = 200
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = LudusStorage.applicationSupportURL
                .appendingPathComponent("launch-logs.json")
        }
    }

    func load() -> [LaunchLogRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([LaunchLogRecord].self, from: data)) ?? []
    }

    func save(_ records: [LaunchLogRecord]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let boundedRecords = records
            .sorted { $0.finishedAt > $1.finishedAt }
            .prefix(Self.maximumRecords)
        let data = try encoder.encode(Array(boundedRecords))
        try data.write(to: fileURL, options: [.atomic])
    }
}
