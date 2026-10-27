import Foundation

enum HeroicMoveError: LocalizedError, Sendable {
    case invalidApplicationName
    case missingConfigurationDirectory
    case missingDestinationDirectory
    case destinationInsideCurrentInstallation
    case legendaryExecutableNotFound
    case commandFailed(Int32, String)
    case moveNotVerified

    var errorDescription: String? {
        switch self {
        case .invalidApplicationName:
            "The Heroic application name is missing or contains unsafe control characters."
        case .missingConfigurationDirectory:
            "Import Heroic or Legendary's installed.json first so Ludus can reuse the selected configuration."
        case .missingDestinationDirectory:
            "Choose an existing destination folder before moving the installation."
        case .destinationInsideCurrentInstallation:
            "The destination cannot be the current installation or a folder inside it. Choose a separate location."
        case .legendaryExecutableNotFound:
            "Heroic's bundled Legendary executable was not found in the standard macOS application locations."
        case let .commandFailed(status, detail):
            detail.isEmpty
                ? "Heroic's move command exited with status \(status)."
                : "Heroic's move command exited with status \(status): \(detail)"
        case .moveNotVerified:
            "Heroic completed the move command, but installed.json did not verify the game inside the selected destination."
        }
    }
}

struct HeroicMoveResult: Sendable {
    let output: String
    let evidence: HeroicInstalledEvidence
}

struct HeroicMoveService: Sendable {
    static func makeArguments(
        applicationName: String,
        destinationDirectory: URL
    ) throws -> [String] {
        let trimmedName = applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              !trimmedName.hasPrefix("-"),
              !trimmedName.contains("/"),
              !trimmedName.contains("\\"),
              !trimmedName.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw HeroicMoveError.invalidApplicationName
        }
        return ["move", trimmedName, destinationDirectory.path]
    }

    func move(
        applicationName: String,
        configurationDirectory: URL,
        destinationDirectory: URL,
        currentInstallationURL: URL
    ) async throws -> HeroicMoveResult {
        guard isDirectory(configurationDirectory) else {
            throw HeroicMoveError.missingConfigurationDirectory
        }
        guard isDirectory(destinationDirectory) else {
            throw HeroicMoveError.missingDestinationDirectory
        }
        guard !isInsideOrEqual(destinationDirectory, directory: currentInstallationURL) else {
            throw HeroicMoveError.destinationInsideCurrentInstallation
        }
        guard let legendaryURL = HeroicInstallService.bundledLegendaryURL() else {
            throw HeroicMoveError.legendaryExecutableNotFound
        }

        let arguments = try Self.makeArguments(
            applicationName: applicationName,
            destinationDirectory: destinationDirectory
        )
        var mutableEnv = ProcessInfo.processInfo.environment
        mutableEnv["LEGENDARY_CONFIG_PATH"] = configurationDirectory.path
        let environment = mutableEnv
        let runner = ProcessRunner()
        let result = try await Task.detached(priority: .userInitiated) {
            try runner.run(
                legendaryURL.path,
                arguments: arguments,
                environment: environment
            )
        }.value

        guard result.status == 0 else {
            throw HeroicMoveError.commandFailed(result.status, result.errorOutput)
        }

        let evidence: HeroicInstalledEvidence
        do {
            evidence = try HeroicInstallService.verifiedEvidence(
                applicationName: applicationName.trimmingCharacters(in: .whitespacesAndNewlines),
                configurationDirectory: configurationDirectory
            )
        } catch {
            throw HeroicMoveError.moveNotVerified
        }

        guard isInside(evidence.installationURL, directory: destinationDirectory) else {
            throw HeroicMoveError.moveNotVerified
        }
        return HeroicMoveResult(output: result.output, evidence: evidence)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var directory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            && directory.boolValue
    }

    private func isInside(_ candidate: URL, directory: URL) -> Bool {
        let candidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        let directoryPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        return candidatePath.hasPrefix(directoryPath + "/")
    }

    private func isInsideOrEqual(_ candidate: URL, directory: URL) -> Bool {
        let candidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        let directoryPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        return candidatePath == directoryPath || candidatePath.hasPrefix(directoryPath + "/")
    }
}
