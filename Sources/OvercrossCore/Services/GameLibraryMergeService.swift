import Foundation

/// Merges store imports into the persistent library without losing user-owned
/// configuration such as a selected executable, favorite state, or categories.
/// A local executable can be promoted to a store record only when its path is
/// demonstrably inside the imported installation directory; title matching is
/// deliberately not used because it can combine unrelated games.
struct GameLibraryMergeService: Sendable {
    static func merge(existing: [Game], imported: [Game]) -> [Game] {
        var mergedGames = existing

        for importedGame in imported {
            if let index = matchingIndex(for: importedGame, in: mergedGames) {
                mergedGames[index] = merge(mergedGames[index], with: importedGame)
            } else {
                mergedGames.append(importedGame)
            }
        }

        return mergedGames
    }

    private static func matchingIndex(for importedGame: Game, in games: [Game]) -> Int? {
        if let storeApplicationID = importedGame.storeApplicationID,
           let index = games.firstIndex(where: {
               $0.store == importedGame.store &&
               $0.storeApplicationID == storeApplicationID
           }) {
            return index
        }

        guard importedGame.store != .local,
              let importedInstallationURL = importedGame.installationURL else {
            return nil
        }

        let canonicalImportedInstallation = canonicalURL(importedInstallationURL)
        return games.firstIndex { existingGame in
            guard existingGame.store == .local else { return false }
            if let existingInstallationURL = existingGame.installationURL,
               canonicalURL(existingInstallationURL) == canonicalImportedInstallation {
                return true
            }
            guard let existingExecutableURL = existingGame.executableURL else { return false }
            return isInside(
                canonicalURL(existingExecutableURL),
                directory: canonicalImportedInstallation
            )
        }
    }

    private static func merge(_ existing: Game, with imported: Game) -> Game {
        var merged = existing
        if existing.store == .local, imported.store != .local {
            merged.store = imported.store
            merged.storeApplicationID = imported.storeApplicationID
        }
        if existing.platform == .unknown, imported.platform != .unknown {
            merged.platform = imported.platform
        }
        merged.title = imported.title
        if imported.ownershipEvidence.confidence > existing.ownershipEvidence.confidence {
            merged.ownershipEvidence = imported.ownershipEvidence
        }
        if let installationURL = imported.installationURL {
            merged.installationURL = installationURL
        }
        if let executableURL = imported.executableURL {
            merged.executableURL = executableURL
        }
        if let importedMethod = imported.installationMethod,
           !(existing.installationMethod ?? "").contains(importedMethod) {
            merged.installationMethod = [existing.installationMethod, importedMethod]
                .compactMap { $0 }
                .joined(separator: "; ")
        }
        if merged.artworkURL == nil, let artworkURL = imported.artworkURL {
            merged.artworkURL = artworkURL
        }
        return merged
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func isInside(_ candidate: URL, directory: URL) -> Bool {
        candidate.path.hasPrefix(directory.path + "/")
    }
}
