import Foundation

struct HeroicLibraryEntry: Equatable, Sendable {
    let appName: String
    let title: String
}

enum HeroicLibraryError: LocalizedError, Sendable {
    case missingConfigurationDirectory
    case legendaryExecutableNotFound
    case commandFailed(Int32, String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .missingConfigurationDirectory:
            return "Import Heroic or Legendary's installed.json first so Ludus can reuse the selected Heroic configuration."
        case .legendaryExecutableNotFound:
            return "Heroic's bundled Legendary executable was not found in the standard macOS application locations."
        case let .commandFailed(status, detail):
            if detail.isEmpty {
                return "Heroic library discovery exited with status \(status). Heroic may require authentication or reconnection."
            } else {
                return "Heroic library discovery failed with status \(status): \(detail)"
            }
        case .malformedResponse:
            return "Heroic returned a library response that Ludus could not safely understand."
        }
    }
}

struct HeroicLibraryService: Sendable {
    static let libraryArguments = [
        "list",
        "--third-party",
        "--platform", "Windows",
        "--json"
    ]

    func fetchLibrary(configurationDirectory: URL) async throws -> [HeroicLibraryEntry] {
        guard isDirectory(configurationDirectory) else {
            throw HeroicLibraryError.missingConfigurationDirectory
        }
        guard let legendaryURL = HeroicInstallService.bundledLegendaryURL() else {
            throw HeroicLibraryError.legendaryExecutableNotFound
        }

        var environment = ProcessInfo.processInfo.environment
        environment["LEGENDARY_CONFIG_PATH"] = configurationDirectory.path
        let runner = ProcessRunner()
        let result = try await Task.detached(priority: .userInitiated) {
            try runner.run(
                legendaryURL.path,
                arguments: Self.libraryArguments,
                environment: environment,
                outputLimit: 64 * 1024 * 1024
            )
        }.value

        guard result.status == 0 else {
            throw HeroicLibraryError.commandFailed(result.status, result.errorOutput)
        }
        guard let data = EpicService.extractJSONData(from: result.output) else {
            throw HeroicLibraryError.malformedResponse
        }
        return try Self.decodeLibrary(data)
    }

    static func decodeLibrary(_ data: Data) throws -> [HeroicLibraryEntry] {
        let decoder = JSONDecoder()
        let rawEntries: [RawLibraryEntry]
        do {
            rawEntries = try decoder.decode([RawLibraryEntry].self, from: data)
        } catch {
            throw HeroicLibraryError.malformedResponse
        }

        return rawEntries.compactMap { entry -> HeroicLibraryEntry? in
            guard !entry.isDLC,
                  let appName = entry.appName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !appName.isEmpty else {
                return nil
            }
            let trimmedTitle = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title: String
            if let trimmedTitle, !trimmedTitle.isEmpty {
                title = trimmedTitle
            } else {
                title = appName
            }
            return HeroicLibraryEntry(appName: appName, title: title)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var directory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            && directory.boolValue
    }

    private struct RawLibraryEntry: Decodable {
        let appName: String?
        let title: String?
        let isDLC: Bool

        private enum CodingKeys: String, CodingKey {
            case appName = "app_name"
            case appTitle = "app_title"
            case title
            case isDLC = "is_dlc"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            appName = try container.decodeIfPresent(String.self, forKey: .appName)
            let appTitle = try container.decodeIfPresent(String.self, forKey: .appTitle)
            let genericTitle = try container.decodeIfPresent(String.self, forKey: .title)
            title = appTitle ?? genericTitle
            isDLC = try container.decodeIfPresent(Bool.self, forKey: .isDLC) ?? false
        }
    }
}
