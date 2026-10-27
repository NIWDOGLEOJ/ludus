import Foundation

struct HeroicDownloadEstimate: Codable, Equatable, Sendable {
    let downloadBytes: Int64?
    let diskBytes: Int64?

    /// The larger known value is the conservative minimum used for the
    /// preflight. It is still only a lower bound when the launcher reports
    /// neither value or when optional content is selected by the launcher.
    var minimumFreeBytes: Int64? {
        switch (downloadBytes, diskBytes) {
        case let (download?, disk?):
            return max(download, disk)
        case let (download?, nil):
            return download
        case let (nil, disk?):
            return disk
        case (nil, nil):
            return nil
        }
    }
}

enum HeroicGameInfoError: LocalizedError, Sendable {
    case invalidApplicationName
    case missingConfigurationDirectory
    case legendaryExecutableNotFound
    case commandFailed(Int32, String)
    case sizeMetadataUnavailable
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .invalidApplicationName:
            return "The Heroic application name is missing or contains unsafe path characters."
        case .missingConfigurationDirectory:
            return "Import Heroic or Legendary's installed.json first so Ludus can reuse the selected configuration."
        case .legendaryExecutableNotFound:
            return "Heroic's bundled Legendary executable was not found in the standard macOS application locations."
        case let .commandFailed(status, detail):
            if detail.isEmpty {
                return "Heroic metadata lookup exited with status " + String(status) + "."
            }
            return "Heroic metadata lookup failed with status " + String(status) + ": " + detail
        case .sizeMetadataUnavailable:
            return "Heroic returned game metadata without a reliable download or disk-size value."
        case .malformedResponse:
            return "Heroic returned game metadata that Ludus could not safely understand."
        }
    }
}

struct HeroicGameInfoService: Sendable {
    static func infoArguments(applicationName: String) throws -> [String] {
        let trimmedName = applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              !trimmedName.contains("/"),
              !trimmedName.contains("\\"),
              !trimmedName.hasPrefix("-"),
              !trimmedName.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw HeroicGameInfoError.invalidApplicationName
        }
        return ["info", trimmedName, "--json", "--platform", "Windows"]
    }

    func fetch(
        applicationName: String,
        configurationDirectory: URL
    ) async throws -> HeroicDownloadEstimate {
        guard isDirectory(configurationDirectory) else {
            throw HeroicGameInfoError.missingConfigurationDirectory
        }
        guard let legendaryURL = HeroicInstallService.bundledLegendaryURL() else {
            throw HeroicGameInfoError.legendaryExecutableNotFound
        }
        let arguments = try Self.infoArguments(applicationName: applicationName)
        var environment = ProcessInfo.processInfo.environment
        environment["LEGENDARY_CONFIG_PATH"] = configurationDirectory.path
        let runner = ProcessRunner()
        let result = try await Task.detached(priority: .userInitiated) {
            try runner.run(
                legendaryURL.path,
                arguments: arguments,
                environment: environment,
                outputLimit: 512 * 1024
            )
        }.value

        guard result.status == 0 else {
            throw HeroicGameInfoError.commandFailed(result.status, result.errorOutput)
        }
        return try Self.decode(Data(result.output.utf8))
    }

    static func decode(_ data: Data) throws -> HeroicDownloadEstimate {
        struct Response: Decodable {
            let manifest: Manifest?
        }
        struct Manifest: Decodable {
            let downloadBytes: Int64?
            let diskBytes: Int64?

            private enum CodingKeys: String, CodingKey {
                case downloadBytes = "download_size"
                case diskBytes = "disk_size"
            }
        }

        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw HeroicGameInfoError.malformedResponse
        }
        guard let manifest = response.manifest else {
            throw HeroicGameInfoError.sizeMetadataUnavailable
        }
        let estimate = HeroicDownloadEstimate(
            downloadBytes: manifest.downloadBytes.flatMap { $0 > 0 ? $0 : nil },
            diskBytes: manifest.diskBytes.flatMap { $0 > 0 ? $0 : nil }
        )
        guard estimate.minimumFreeBytes != nil else {
            throw HeroicGameInfoError.sizeMetadataUnavailable
        }
        return estimate
    }

    private func isDirectory(_ url: URL) -> Bool {
        var directory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            && directory.boolValue
    }
}
