import Foundation

struct RuntimeStore: Sendable {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = LudusStorage.applicationSupportURL
                .appendingPathComponent("runtimes.json")
        }
    }

    func load() -> [DetectedRuntime] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        return (try? decoder.decode([DetectedRuntime].self, from: data)) ?? []
    }

    func save(_ runtimes: [DetectedRuntime]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(runtimes)
        try data.write(to: fileURL, options: [.atomic])
    }
}
