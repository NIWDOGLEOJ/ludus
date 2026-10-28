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
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.3"
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

    /// Automatically downloads the DMG, extracts the new application, replaces the old installation in-place, and relaunches without requiring manual file handling.
    public func downloadAndApplyUpdate(
        from url: URL,
        progress: (@Sendable (Double) -> Void)? = nil,
        targetAppURL: URL? = nil,
        terminateCurrentApp: Bool = true
    ) async throws {
        let (tempLocalURL, response) = try await URLSession.shared.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw UpdateError.downloadFailed("Server returned invalid HTTP status")
        }

        let fileManager = FileManager.default
        let stagingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("LudusUpdate-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let destinationDMG = stagingRoot.appendingPathComponent("Ludus.dmg")
        try fileManager.moveItem(at: tempLocalURL, to: destinationDMG)

        try await applyDownloadedDMG(
            dmgURL: destinationDMG,
            stagingRoot: stagingRoot,
            targetAppURL: targetAppURL,
            terminateCurrentApp: terminateCurrentApp
        )
    }

    /// Mounts, stages, extracts, and swaps an application update from a downloaded DMG.
    public func applyDownloadedDMG(
        dmgURL: URL,
        stagingRoot: URL,
        targetAppURL: URL? = nil,
        terminateCurrentApp: Bool = true
    ) async throws {
        let fileManager = FileManager.default
        let mountPoint = stagingRoot.appendingPathComponent("mount", isDirectory: true)
        try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        // 1. Mount the DMG silently without opening Finder
        let mountResult = try ProcessRunner().run(
            "/usr/bin/hdiutil",
            arguments: ["attach", dmgURL.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint.path]
        )
        guard mountResult.status == 0 else {
            try? fileManager.removeItem(at: stagingRoot)
            throw UpdateError.downloadFailed("Could not mount update disk image: \(mountResult.errorOutput)")
        }

        defer {
            _ = try? ProcessRunner().run("/usr/bin/hdiutil", arguments: ["detach", mountPoint.path, "-force"])
        }

        // 2. Locate Ludus.app inside the mounted volume
        let candidateApps = (try? fileManager.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)) ?? []
        guard let sourceApp = candidateApps.first(where: { $0.lastPathComponent == "Ludus.app" || $0.pathExtension == "app" }) else {
            try? fileManager.removeItem(at: stagingRoot)
            throw UpdateError.downloadFailed("The update disk image does not contain Ludus.app.")
        }

        // 3. Stage the extracted application
        let stagedApp = stagingRoot.appendingPathComponent("Staged/Ludus.app")
        try fileManager.createDirectory(at: stagedApp.deletingLastPathComponent(), withIntermediateDirectories: true)
        let copyResult = try ProcessRunner().run(
            "/usr/bin/ditto",
            arguments: [sourceApp.path, stagedApp.path]
        )
        guard copyResult.status == 0 else {
            try? fileManager.removeItem(at: stagingRoot)
            throw UpdateError.downloadFailed("Failed to extract update package: \(copyResult.errorOutput)")
        }

        // 4. Detach DMG early since files are fully staged
        _ = try? ProcessRunner().run("/usr/bin/hdiutil", arguments: ["detach", mountPoint.path, "-force"])
        try? fileManager.removeItem(at: dmgURL)

        // Strip Gatekeeper quarantine on staged files
        _ = try? ProcessRunner().run("/usr/bin/xattr", arguments: ["-cr", stagedApp.path])

        // 5. Determine destination target
        let resolvedTarget: URL
        if let targetAppURL {
            resolvedTarget = targetAppURL
        } else {
            let bundle = Bundle.main.bundleURL
            if bundle.pathExtension.lowercased() == "app" {
                resolvedTarget = bundle
            } else {
                resolvedTarget = URL(fileURLWithPath: "/Applications/Ludus.app")
            }
        }

        // 6. Generate and launch the detached swap and relaunch script
        let scriptURL = stagingRoot.appendingPathComponent("apply_update.sh")
        let scriptContent = """
        #!/bin/sh
        PID="$1"
        TARGET="$2"
        STAGED="$3"
        CLEANUP="$4"

        # Wait for old app PID to exit cleanly (max 10s)
        COUNT=0
        while kill -0 "$PID" 2>/dev/null && [ $COUNT -lt 50 ]; do
            sleep 0.2
            COUNT=$((COUNT + 1))
        done

        # In-place replace target application bundle
        FINAL_APP="$TARGET"
        if rm -rf "$TARGET" 2>/dev/null && /usr/bin/ditto "$STAGED" "$TARGET" 2>/dev/null; then
            /usr/bin/xattr -cr "$TARGET" 2>/dev/null || true
            FINAL_APP="$TARGET"
        elif /usr/bin/ditto "$STAGED" "$TARGET" 2>/dev/null; then
            /usr/bin/xattr -cr "$TARGET" 2>/dev/null || true
            FINAL_APP="$TARGET"
        else
            # Fallback if /Applications is read-only: copy to user's ~/Applications
            USER_APPS="$HOME/Applications"
            mkdir -p "$USER_APPS"
            USER_TARGET="$USER_APPS/$(basename "$TARGET")"
            rm -rf "$USER_TARGET" 2>/dev/null || true
            /usr/bin/ditto "$STAGED" "$USER_TARGET" 2>/dev/null || true
            /usr/bin/xattr -cr "$USER_TARGET" 2>/dev/null || true
            FINAL_APP="$USER_TARGET"
        fi

        # Clean staging directory
        rm -rf "$CLEANUP" 2>/dev/null || true

        # Relaunch updated application
        /usr/bin/open "$FINAL_APP"
        """
        try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let helperProcess = Process()
        helperProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        helperProcess.arguments = [
            scriptURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            resolvedTarget.path,
            stagedApp.path,
            stagingRoot.path
        ]
        try helperProcess.run()

        // 7. Terminate current application if requested
        if terminateCurrentApp {
            #if canImport(AppKit)
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
            #endif
        }
    }
}
