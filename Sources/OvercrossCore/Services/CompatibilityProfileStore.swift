import Foundation

enum CompatibilityProfileStoreError: LocalizedError {
    case wrongFile
    case malformedFile
    case emptyFile

    var errorDescription: String? {
        switch self {
        case .wrongFile:
            "Select a JSON compatibility-profile file."
        case .malformedFile:
            "The selected file is not a valid Ludus compatibility-profile list."
        case .emptyFile:
            "The selected compatibility-profile file contains no profiles."
        }
    }
}

struct CompatibilityProfileStore {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = LudusStorage.applicationSupportURL
                .appendingPathComponent("compatibility-profiles.json")
        }
    }

    func load() -> [CompatibilityProfile] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? Self.decodeProfiles(data)) ?? []
    }

    func importProfiles(from profileURL: URL) throws -> [CompatibilityProfile] {
        guard profileURL.pathExtension.lowercased() == "json" else {
            throw CompatibilityProfileStoreError.wrongFile
        }
        let data: Data
        do {
            data = try Data(contentsOf: profileURL)
        } catch {
            throw CompatibilityProfileStoreError.malformedFile
        }
        return try Self.decodeProfiles(data)
    }

    func save(_ profiles: [CompatibilityProfile]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(profiles)
        try data.write(to: fileURL, options: [.atomic])
    }

    private static func decodeProfiles(_ data: Data) throws -> [CompatibilityProfile] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let profiles: [CompatibilityProfile]
        do {
            profiles = try decoder.decode([CompatibilityProfile].self, from: data)
        } catch {
            throw CompatibilityProfileStoreError.malformedFile
        }
        guard !profiles.isEmpty else {
            throw CompatibilityProfileStoreError.emptyFile
        }
        return profiles
    }
}
