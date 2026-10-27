import Foundation

struct DownloadOperationStore {
    static let maximumRecords = 100
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = LudusStorage.applicationSupportURL
                .appendingPathComponent("download-operations.json")
        }
    }

    func load() -> [DownloadOperation] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([DownloadOperation].self, from: data))?
            .sorted { $0.updatedAt > $1.updatedAt } ?? []
    }

    func save(_ operations: [DownloadOperation]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let bounded = operations
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(Self.maximumRecords)
        try encoder.encode(Array(bounded)).write(to: fileURL, options: [.atomic])
    }
}
