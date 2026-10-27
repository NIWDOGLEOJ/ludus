import Foundation

enum GameLibraryStoreError: LocalizedError {
    case couldNotSave(Error)

    var errorDescription: String? {
        switch self {
        case .couldNotSave(let error):
            "Could not save the game library: \(error.localizedDescription)"
        }
    }
}

struct GameLibraryStore {
    private let fileManager = FileManager.default
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = LudusStorage.applicationSupportURL
                .appendingPathComponent("games.json")
        }
    }

    func load() -> [Game] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder.iso8601.decode([Game].self, from: data)) ?? []
    }

    func save(_ games: [Game]) throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder.prettyPrintedISO8601.encode(games)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw GameLibraryStoreError.couldNotSave(error)
        }
    }
}

private extension JSONEncoder {
    static var prettyPrintedISO8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
