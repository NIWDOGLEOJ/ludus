import Foundation

/// Provides automated Steam client emulation and profile provisioning for games running in Wine bottles.
struct SteamStubService: Sendable {
    init() {}

    /// Base64 encoded 4KB Windows PE helper (`ludus_steam_stub.exe`) that acquires a live Wine PID,
    /// populates `HKCU\Software\Valve\Steam\ActiveProcess` (pid, ActiveUser=1, Universe=Public, SteamPath, SteamClientDll64),
    /// and enters an idle sleep so `SteamAPI_IsSteamRunning()` returns true for game processes.
    static let embeddedStubBase64 = "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AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="

    /// Ensures `ludus_steam_stub.exe` is deployed into `<prefixURL>/drive_c/windows/system32/`.
    @discardableResult
    static func ensureStubInstalled(in prefixURL: URL) -> URL? {
        let system32URL = prefixURL.appendingPathComponent("drive_c/windows/system32")
        let targetURL = system32URL.appendingPathComponent("ludus_steam_stub.exe")
        guard let data = Data(base64Encoded: embeddedStubBase64) else { return nil }

        if FileManager.default.fileExists(atPath: targetURL.path) {
            let existingSize = (try? FileManager.default.attributesOfItem(atPath: targetURL.path)[.size] as? Int) ?? 0
            if existingSize == data.count {
                return targetURL
            }
        }

        try? FileManager.default.createDirectory(at: system32URL, withIntermediateDirectories: true)
        do {
            try data.write(to: targetURL, options: .atomic)
            return targetURL
        } catch {
            return nil
        }
    }

    /// Auto-detects Steam Application ID from `steam_appid.txt`, `steam_emu.ini`, or `GoldbergSteamEmu.ini`.
    static func detectSteamAppID(installationURL: URL) -> String? {
        let appidTxtURL = installationURL.appendingPathComponent("steam_appid.txt")
        if let content = try? String(contentsOf: appidTxtURL, encoding: .utf8) {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed.allSatisfy({ $0.isNumber }) {
                return trimmed
            }
        }

        let iniCandidates = [
            installationURL.appendingPathComponent("steam_emu.ini"),
            installationURL.appendingPathComponent("GoldbergSteamEmu.ini")
        ]
        for iniURL in iniCandidates {
            guard let content = try? String(contentsOf: iniURL, encoding: .utf8) else { continue }
            for line in content.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let lower = trimmed.lowercased()
                if lower.hasPrefix("appid=") || lower.hasPrefix("appid =") {
                    let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
                    if parts.count == 2 {
                        let id = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                        if !id.isEmpty && id.allSatisfy({ $0.isNumber }) {
                            return id
                        }
                    }
                }
            }
        }
        return nil
    }

    /// Determines if the given title requires an active Steam process stub.
    static func shouldLaunchSteamStub(game: Game, installationURL: URL) -> Bool {
        if game.store == .steam || game.storeApplicationID != nil {
            return true
        }
        if detectSteamAppID(installationURL: installationURL) != nil {
            return true
        }
        let hasSteamApi = FileManager.default.fileExists(atPath: installationURL.appendingPathComponent("steam_api64.dll").path) ||
                          FileManager.default.fileExists(atPath: installationURL.appendingPathComponent("steam_api.dll").path)
        if hasSteamApi {
            return true
        }
        let titleLower = game.title.lowercased()
        if titleLower.contains("forza") {
            return true
        }
        return false
    }

    /// Provisions Steam save directories, profile folders, and symlinks (CODEX -> RUNE).
    @discardableResult
    static func provisionProfileAndSaveDirectories(
        prefixURL: URL,
        installationURL: URL,
        appID: String?,
        gameTitle: String
    ) -> [String] {
        var actions: [String] = []
        let effectiveAppID = appID ?? detectSteamAppID(installationURL: installationURL) ?? (gameTitle.localizedCaseInsensitiveContains("forza horizon 6") ? "2483190" : nil)

        let publicDocsURL = prefixURL.appendingPathComponent("drive_c/users/Public/Documents")
        let steamPublicURL = publicDocsURL.appendingPathComponent("Steam")
        let msStorePublicURL = publicDocsURL.appendingPathComponent("MicrosoftStore")

        // 1. Steam/RUNE/<AppId> directories
        if let effectiveAppID, !effectiveAppID.isEmpty {
            let runeAppURL = steamPublicURL.appendingPathComponent("RUNE/\(effectiveAppID)")
            let localURL = runeAppURL.appendingPathComponent("local")
            let remoteURL = runeAppURL.appendingPathComponent("remote")
            try? FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: remoteURL, withIntermediateDirectories: true)

            // Ensure CODEX -> RUNE symlink or folder exists
            let codexSymlink = steamPublicURL.appendingPathComponent("CODEX")
            if !FileManager.default.fileExists(atPath: codexSymlink.path) {
                try? FileManager.default.createSymbolicLink(at: codexSymlink, withDestinationURL: URL(fileURLWithPath: "RUNE"))
                actions.append("Provisioned Steam save link (CODEX -> RUNE)")
            }
        }

        // 2. MicrosoftStore profile directories for Forza
        if gameTitle.localizedCaseInsensitiveContains("forza") {
            let msRuneForzaURL = msStorePublicURL.appendingPathComponent("RUNE/Forza Horizon 6 [7BF69384]/1337133713371337")
            let plsURL = msRuneForzaURL.appendingPathComponent("PersistentLocalStorage")
            let sgURL = msRuneForzaURL.appendingPathComponent("SaveGames")
            try? FileManager.default.createDirectory(at: plsURL, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: sgURL, withIntermediateDirectories: true)

            let msCodexSymlink = msStorePublicURL.appendingPathComponent("CODEX")
            if !FileManager.default.fileExists(atPath: msCodexSymlink.path) {
                try? FileManager.default.createSymbolicLink(at: msCodexSymlink, withDestinationURL: URL(fileURLWithPath: "RUNE"))
                actions.append("Provisioned MicrosoftStore profile link (CODEX -> RUNE)")
            }
        }

        return actions
    }

    /// Launches `ludus_steam_stub.exe` as a background daemon before game launch.
    static func launchStubDaemon(
        runtimeExecutableURL: URL,
        prefixURL: URL,
        bottleName: String,
        installationURL: URL
    ) -> Process? {
        let isWine = runtimeExecutableURL.lastPathComponent.lowercased().contains("wine") ||
                     runtimeExecutableURL.path.contains("CrossOver")
        guard isWine else { return nil }
        guard ensureStubInstalled(in: prefixURL) != nil else { return nil }

        let isCrossOverWine = runtimeExecutableURL.path.contains("SharedSupport/CrossOver") ||
                              runtimeExecutableURL.path.contains("CrossOver") ||
                              runtimeExecutableURL.lastPathComponent == "wine"

        var arguments: [String] = []
        if isCrossOverWine {
            arguments.append(contentsOf: ["--bottle", bottleName])
        }

        // Convert installation URL to Wine Z: path
        let posixPath = installationURL.path
        let winInstallationPath = "Z:" + posixPath.replacingOccurrences(of: "/", with: "\\")
        let steamSubdir = winInstallationPath + "\\Steam"
        let steamClientDll = winInstallationPath + "\\Steam\\steamclient64.dll"

        let stubWinePath = "C:\\windows\\system32\\ludus_steam_stub.exe"
        arguments.append(contentsOf: [stubWinePath, steamSubdir, steamClientDll])

        let process = Process()
        process.executableURL = runtimeExecutableURL
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment

        do {
            try process.run()
            // Brief pause to allow the stub to register itself into HKCU\Software\Valve\Steam\ActiveProcess
            Thread.sleep(forTimeInterval: 0.25)
            return process
        } catch {
            return nil
        }
    }
}
