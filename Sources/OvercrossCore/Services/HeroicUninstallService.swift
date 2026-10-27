import Foundation

enum HeroicUninstallError: LocalizedError, Sendable {
    case invalidApplicationName
    case missingConfigurationDirectory
    case legendaryExecutableNotFound
    case commandFailed(Int32, String)
    case installedManifestNotReadable
    case uninstallNotVerified
    case filesRemain(URL)

    var errorDescription: String? {
        switch self {
        case .invalidApplicationName:
            "The Heroic application name is missing or contains unsafe control characters."
        case .missingConfigurationDirectory:
            "Import Heroic or Legendary's installed.json first so Ludus can reuse the selected configuration."
        case .legendaryExecutableNotFound:
            "Heroic's bundled Legendary executable was not found in the standard macOS application locations."
        case let .commandFailed(status, detail):
            detail.isEmpty
                ? "Heroic's uninstall command exited with status \(status)."
                : "Heroic's uninstall command exited with status \(status): \(detail)"
        case .installedManifestNotReadable:
            "Heroic completed the uninstall command, but installed.json could not be read to verify the library state."
        case .uninstallNotVerified:
            "Heroic completed the uninstall command, but installed.json still contains the game. The library record was not changed."
        case let .filesRemain(url):
            "Heroic removed the installed record, but files remain at \(url.path). They were not deleted by Ludus."
        }
    }
}

struct HeroicUninstallService: Sendable {
    static let uninstallArgumentsPrefix = ["uninstall"]

    static func makeArguments(applicationName: String, preserveFiles: Bool) throws -> [String] {
        let trimmedName = applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              !trimmedName.hasPrefix("-"),
              !trimmedName.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw HeroicUninstallError.invalidApplicationName
        }
        var arguments = uninstallArgumentsPrefix + [trimmedName]
        if preserveFiles {
            arguments.append("--keep-files")
        }
        arguments.append("-y")
        return arguments
    }

    func uninstall(
        applicationName: String,
        configurationDirectory: URL,
        installationURL: URL?,
        preserveFiles: Bool
    ) async throws {
        guard isDirectory(configurationDirectory) else {
            throw HeroicUninstallError.missingConfigurationDirectory
        }
        guard let legendaryURL = HeroicInstallService.bundledLegendaryURL() else {
            throw HeroicUninstallError.legendaryExecutableNotFound
        }

        let arguments = try Self.makeArguments(
            applicationName: applicationName,
            preserveFiles: preserveFiles
        )

        var environment = ProcessInfo.processInfo.environment
        environment["LEGENDARY_CONFIG_PATH"] = configurationDirectory.path
        let runner = ProcessRunner()
        let result = try await Task.detached(priority: .userInitiated) {
            try runner.run(
                legendaryURL.path,
                arguments: arguments,
                environment: environment
            )
        }.value

        guard result.status == 0 else {
            throw HeroicUninstallError.commandFailed(result.status, result.errorOutput)
        }
        let trimmedName = applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let remainingEntries = try Self.readInstalledEntries(in: configurationDirectory)
        guard !remainingEntries.contains(trimmedName) else {
            throw HeroicUninstallError.uninstallNotVerified
        }
        if !preserveFiles,
           let installationURL,
           FileManager.default.fileExists(atPath: installationURL.path) {
            throw HeroicUninstallError.filesRemain(installationURL)
        }
    }

    static func installedEntries(in configurationDirectory: URL) -> Set<String> {
        (try? readInstalledEntries(in: configurationDirectory)) ?? []
    }

    private static func readInstalledEntries(in configurationDirectory: URL) throws -> Set<String> {
        let installedJSON = configurationDirectory.appendingPathComponent("installed.json")
        guard let data = try? Data(contentsOf: installedJSON),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw HeroicUninstallError.installedManifestNotReadable
        }
        return Set(dictionary.keys)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var directory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            && directory.boolValue
    }
}
