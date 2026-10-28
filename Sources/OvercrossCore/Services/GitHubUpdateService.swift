import Foundation
#if canImport(AppKit)
import AppKit
#endif

public struct AppUpdateInfo: Equatable, Sendable {
    public let version: String
    public let title: String
    public let notes: String
    public let releasePageURL: URL
    public let dmgDownloadURL: URL?
    public let publishedAt: Date?

    public init(
        version: String,
        title: String,
        notes: String,
        releasePageURL: URL,
        dmgDownloadURL: URL?,
        publishedAt: Date? = nil
    ) {
        self.version = version
        self.title = title
        self.notes = notes
        self.releasePageURL = releasePageURL
        self.dmgDownloadURL = dmgDownloadURL
        self.publishedAt = publishedAt
    }
}

public enum UpdateError: LocalizedError, Sendable {
    case noUpdateAvailable
    case networkError(String)
    case missingDownloadURL
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noUpdateAvailable:
            return "You are running the latest version of Ludus."
        case let .networkError(detail):
            return "Failed to check for updates: \(detail)"
        case .missingDownloadURL:
            return "The latest release does not include a downloadable Ludus.dmg asset."
        case let .downloadFailed(detail):
            return "Failed to download update: \(detail)"
        }
    }
}

public final class GitHubUpdateService: @unchecked Sendable {
    public static let shared = GitHubUpdateService()

    public let repositoryOwner: String
    public let repositoryName: String

    public init(
        repositoryOwner: String = "NIWDOGLEOJ",
        repositoryName: String = "ludus"
    ) {
        self.repositoryOwner = repositoryOwner
        self.repositoryName = repositoryName
    }

    public var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.1"
    }

    public func checkForUpdates() async throws -> AppUpdateInfo? {
        let endpoint = "https://api.github.com/repos/\(repositoryOwner)/\(repositoryName)/releases/latest"
        guard let url = URL(string: endpoint) else {
            throw UpdateError.networkError("Invalid endpoint URL")
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("Ludus-App-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UpdateError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateError.networkError("Invalid server response")
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 404 {
                // No releases published yet on this repo
                return nil
            }
            throw UpdateError.networkError("HTTP status \(httpResponse.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String else {
            throw UpdateError.networkError("Malformed release metadata")
        }

        let rawVersion = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        let releaseName = (json["name"] as? String) ?? "Ludus \(rawVersion)"
        let body = (json["body"] as? String) ?? ""
        let htmlUrlString = (json["html_url"] as? String) ?? "https://github.com/\(repositoryOwner)/\(repositoryName)/releases"
        let releasePageURL = URL(string: htmlUrlString) ?? URL(string: "https://github.com/\(repositoryOwner)/\(repositoryName)")!

        var dmgURL: URL?
        if let assets = json["assets"] as? [[String: Any]] {
            for asset in assets {
                if let name = asset["name"] as? String,
                   name.lowercased().hasSuffix(".dmg"),
                   let downloadUrlString = asset["browser_download_url"] as? String {
                    dmgURL = URL(string: downloadUrlString)
                    break
                }
            }
        }

        // Compare versions
        if Self.isVersion(rawVersion, newerThan: currentVersion) {
            return AppUpdateInfo(
                version: rawVersion,
                title: releaseName,
                notes: body,
                releasePageURL: releasePageURL,
                dmgDownloadURL: dmgURL
            )
        }

        return nil
    }

    public static func isVersion(_ v1: String, newerThan v2: String) -> Bool {
        let clean1 = v1.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        let clean2 = v2.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        let parts1 = clean1.split(separator: ".").compactMap { Int($0) }
        let parts2 = clean2.split(separator: ".").compactMap { Int($0) }

        let count = max(parts1.count, parts2.count)
        for i in 0..<count {
            let p1 = i < parts1.count ? parts1[i] : 0
            let p2 = i < parts2.count ? parts2[i] : 0
            if p1 > p2 { return true }
            if p1 < p2 { return false }
        }
        return false
    }

    public func downloadAndOpenDMG(
        from url: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let (tempLocalURL, response) = try await URLSession.shared.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw UpdateError.downloadFailed("Server returned invalid status")
        }

        let destinationDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LudusUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let destinationDMG = destinationDir.appendingPathComponent("Ludus.dmg")
        try FileManager.default.moveItem(at: tempLocalURL, to: destinationDMG)

        #if canImport(AppKit)
        DispatchQueue.main.async {
            NSWorkspace.shared.open(destinationDMG)
        }
        #endif
    }
}
