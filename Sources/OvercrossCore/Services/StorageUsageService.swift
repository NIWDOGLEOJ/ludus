import Foundation

struct StorageUsageService: Sendable {
    func usage(for game: Game) -> Int64? {
        guard let installationURL = game.installationURL else { return nil }
        return usage(at: installationURL)
    }

    func totalUsage(for games: [Game]) -> Int64 {
        var visitedPaths = Set<String>()
        var total: Int64 = 0
        for game in games {
            guard let installationURL = game.installationURL else { continue }
            let normalizedPath = installationURL.standardizedFileURL.path
            guard visitedPaths.insert(normalizedPath).inserted else { continue }
            total += usage(at: installationURL)
        }
        return total
    }

    private func usage(at url: URL) -> Int64 {
        var total: Int64 = 0
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]

        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return 0
        }

        for case let childURL as URL in enumerator {
            guard let values = try? childURL.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
