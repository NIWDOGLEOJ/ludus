import Foundation

enum HeroicLibraryImportError: LocalizedError, Sendable {
    case wrongFile
    case malformedFile

    var errorDescription: String? {
        switch self {
        case .wrongFile:
            "Select Heroic or Legendary's installed.json file."
        case .malformedFile:
            "The selected installed.json file could not be read as a Heroic/Legendary installation cache."
        }
    }
}

struct HeroicLibraryImporter: Sendable {
    private struct InstalledGame: Decodable, Sendable {
        let installPath: String?
        let executable: String?

        private enum CodingKeys: String, CodingKey {
            case installPath = "install_path"
            case executable
        }
    }

    func importGames(from fileURL: URL) throws -> [Game] {
        guard fileURL.lastPathComponent.lowercased() == "installed.json" else {
            throw HeroicLibraryImportError.wrongFile
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw HeroicLibraryImportError.malformedFile
        }

        let installedGames: [String: InstalledGame]
        do {
            installedGames = try JSONDecoder().decode([String: InstalledGame].self, from: data)
        } catch {
            throw HeroicLibraryImportError.malformedFile
        }

        return installedGames.compactMap { appName, installedGame in
            guard let installPath = installedGame.installPath,
                  !installPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }

            let installationURL = URL(fileURLWithPath: installPath).standardizedFileURL
            guard isDirectory(installationURL) else {
                return nil
            }

            let executableURL = resolveExecutable(
                installedGame.executable,
                inside: installationURL
            )

            let artworkURL = HeroicArtworkService.resolveArtworkURL(
                appName: appName,
                configurationDirectory: fileURL.deletingLastPathComponent()
            )

            return Game(
                title: appName,
                store: .epic,
                platform: .windows,
                storeApplicationID: appName,
                ownershipEvidence: .heroicInstalledCache,
                artworkURL: artworkURL,
                installationURL: installationURL,
                executableURL: executableURL,
                installationMethod: "Heroic/Legendary local installed.json import",
                compatibilityStatus: .notTested
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// `installed.json` is stored in Legendary's configuration directory by
    /// the supported Heroic/Legendary workflow. The caller may persist this
    /// non-secret directory so installation commands reuse the same account
    /// configuration without reading credentials into Ludus.
    func configurationDirectory(for fileURL: URL) -> URL {
        URL(fileURLWithPath: fileURL.deletingLastPathComponent().path).standardizedFileURL
    }

    private func resolveExecutable(_ value: String?, inside installationURL: URL) -> URL? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let candidate = URL(fileURLWithPath: value, relativeTo: installationURL).standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        let resolvedInstallation = installationURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedCandidate.path.hasPrefix(resolvedInstallation.path + "/"),
              isRegularFile(resolvedCandidate),
              FileManager.default.isExecutableFile(atPath: resolvedCandidate.path)
        else {
            return nil
        }
        return candidate
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }
}
