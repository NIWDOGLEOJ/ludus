import Foundation
import Combine

struct EpicGameEntry: Identifiable, Hashable, Sendable {
    var id: String { appName }
    let appName: String
    let title: String
    let artworkURL: URL?
    let isWindowsSupported: Bool
    let estimatedSizeBytes: Int64?
    let antiCheatStatus: AntiCheatStatus

    init(
        appName: String,
        title: String,
        artworkURL: URL? = nil,
        isWindowsSupported: Bool = true,
        estimatedSizeBytes: Int64? = nil,
        antiCheatStatus: AntiCheatStatus? = nil
    ) {
        self.appName = appName
        self.title = title
        self.artworkURL = artworkURL
        self.isWindowsSupported = isWindowsSupported
        self.estimatedSizeBytes = estimatedSizeBytes
        self.antiCheatStatus = antiCheatStatus ?? AntiCheatRegistry.inspect(title: title)
    }
}

enum EpicAuthStatus: Equatable, Sendable {
    case notConnected
    case connected(displayName: String)
}

struct EpicService: Sendable {
    let configurationDirectory: URL
    let allowAutoImportFromHeroic: Bool
    private let processRunner = ProcessRunner()

    init(configurationDirectory: URL? = nil, allowAutoImportFromHeroic: Bool = true) {
        self.allowAutoImportFromHeroic = allowAutoImportFromHeroic
        if let configurationDirectory {
            self.configurationDirectory = configurationDirectory
        } else {
            self.configurationDirectory = LudusStorage.applicationSupportURL.appendingPathComponent("Store/Epic", isDirectory: true)
        }
    }

    static func findLegendaryBinary() -> URL? {
        let managedLegendary = LudusStorage.applicationSupportURL.appendingPathComponent("Runtime/bin/legendary")
        if FileManager.default.isExecutableFile(atPath: managedLegendary.path) {
            return managedLegendary
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/Applications/Heroic.app/Contents/Resources/app.asar.unpacked/build/bin/arm64/darwin/legendary",
            "\(home)/Applications/Heroic.app/Contents/Resources/app.asar.unpacked/build/bin/x64/darwin/legendary",
            "/Applications/Heroic.app/Contents/Resources/app.asar.unpacked/build/bin/arm64/darwin/legendary",
            "/Applications/Heroic.app/Contents/Resources/app.asar.unpacked/build/bin/x64/darwin/legendary",
            "/Applications/Heroic.app/Contents/Resources/app.asar.unpacked/build/bin/darwin/arm64/legendary",
            "/Applications/Heroic.app/Contents/Resources/app.asar.unpacked/build/bin/darwin/x64/legendary",
            "/opt/homebrew/bin/legendary",
            "/usr/local/bin/legendary",
            "/Library/Frameworks/Python.framework/Versions/3.13/bin/legendary",
            "/Library/Frameworks/Python.framework/Versions/3.12/bin/legendary",
            "/Library/Frameworks/Python.framework/Versions/3.11/bin/legendary",
            "/Library/Frameworks/Python.framework/Versions/Current/bin/legendary",
            "\(home)/.local/bin/legendary"
        ]
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                // Auto-stage into Overcross/Runtime/bin/legendary for future calls
                try? FileManager.default.createDirectory(at: managedLegendary.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: managedLegendary)
                try? FileManager.default.copyItem(at: URL(fileURLWithPath: candidate), to: managedLegendary)
                return managedLegendary
            }
        }
        return nil
    }

    /// Automatically discovers and copies an existing Legendary session from Heroic or standard paths
    /// if Ludus does not have a valid authenticated user yet.
    func ensureConfigurationImported() {
        guard allowAutoImportFromHeroic else { return }
        let userJson = configurationDirectory.appendingPathComponent("user.json")
        if FileManager.default.fileExists(atPath: userJson.path),
           let data = try? Data(contentsOf: userJson),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["expires_at"] != nil || json["access_token"] != nil {
            return
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidateDirs = [
            home.appendingPathComponent("Library/Application Support/heroic/legendaryConfig/legendary"),
            home.appendingPathComponent(".config/legendary"),
            home.appendingPathComponent("Library/Application Support/legendary")
        ]

        for dir in candidateDirs {
            let candidateUser = dir.appendingPathComponent("user.json")
            if FileManager.default.fileExists(atPath: candidateUser.path),
               let data = try? Data(contentsOf: candidateUser),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["expires_at"] != nil || json["access_token"] != nil {
                try? FileManager.default.createDirectory(at: configurationDirectory, withIntermediateDirectories: true)
                if let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                    for item in contents {
                        let dest = configurationDirectory.appendingPathComponent(item.lastPathComponent)
                        try? FileManager.default.removeItem(at: dest)
                        try? FileManager.default.copyItem(at: item, to: dest)
                    }
                }
                break
            }
        }
    }

    func checkAuthStatus() -> EpicAuthStatus {
        ensureConfigurationImported()
        let userJson = configurationDirectory.appendingPathComponent("user.json")
        guard FileManager.default.fileExists(atPath: userJson.path),
              let data = try? Data(contentsOf: userJson),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .notConnected
        }

        // Must have real authentication credentials (not dummy mock data)
        guard json["access_token"] != nil || json["expires_at"] != nil || json["refresh_token"] != nil else {
            return .notConnected
        }

        let displayName = (json["displayName"] as? String) ?? (json["user_name"] as? String) ?? "Epic Games User"
        return .connected(displayName: displayName)
    }

    func disconnect() throws {
        let userJson = configurationDirectory.appendingPathComponent("user.json")
        try? FileManager.default.removeItem(at: userJson)
        if let bin = Self.findLegendaryBinary() {
            var env = ProcessInfo.processInfo.environment
            env["LEGENDARY_CONFIG_PATH"] = configurationDirectory.path
            _ = try? processRunner.run(bin.path, arguments: ["auth", "--delete"], environment: env)
        }
    }

    func oauthLoginURL() -> URL {
        URL(string: "https://www.epicgames.com/id/login?redirectUrl=https%3A%2F%2Fwww.epicgames.com%2Fid%2Fapi%2Fredirect%3FclientId%3D34a02cf8f4414e29b15921876da36f9a%26responseType%3Dcode")!
    }

    static func extractAuthCode(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // If user pasted a JSON string e.g. {"redirectUrl":"...","authorizationCode":"..."}
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let authCode = json["authorizationCode"] as? String, !authCode.isEmpty {
                return authCode.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let sid = json["sid"] as? String, !sid.isEmpty {
                return sid.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // If user pasted a redirect URL e.g. https://www.epicgames.com/id/api/redirect?code=xyz
        if let url = URL(string: trimmed), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            if let code = components.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty {
                return code.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return trimmed
    }

    func submitAuthCode(_ rawInput: String) async throws -> String {
        try FileManager.default.createDirectory(at: configurationDirectory, withIntermediateDirectories: true)
        let trimmed = Self.extractAuthCode(from: rawInput)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "EpicService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Authorization code cannot be empty."])
        }

        guard let legendaryURL = Self.findLegendaryBinary() else {
            throw NSError(
                domain: "EpicService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Legendary compatibility engine not found. Please wait for runtime setup to complete."]
            )
        }

        var env = ProcessInfo.processInfo.environment
        env["LEGENDARY_CONFIG_PATH"] = configurationDirectory.path

        var result = try await Task.detached(priority: .userInitiated) {
            try processRunner.run(
                legendaryURL.path,
                arguments: ["auth", "--code", trimmed],
                environment: env,
                outputLimit: 64 * 1024
            )
        }.value

        if result.status != 0 {
            // If code flag failed, attempt sid flag in case user passed session id
            let sidResult = try await Task.detached(priority: .userInitiated) {
                try processRunner.run(
                    legendaryURL.path,
                    arguments: ["auth", "--sid", trimmed],
                    environment: env,
                    outputLimit: 64 * 1024
                )
            }.value
            if sidResult.status == 0 {
                result = sidResult
            }
        }

        guard result.status == 0 else {
            let errorMsg = result.errorOutput.isEmpty ? result.output : result.errorOutput
            throw NSError(domain: "EpicService", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: "Epic authentication failed: \(errorMsg)"])
        }

        if case let .connected(name) = checkAuthStatus() {
            return name
        }
        return "Epic Games User"
    }

    /// Safely isolates the JSON array from Legendary CLI's stdout, which can contain prefix log lines.
    static func extractJSONData(from rawOutput: String) -> Data? {
        let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") && !trimmed.hasPrefix("[Core]") && !trimmed.hasPrefix("[cli]") {
            return trimmed.data(using: .utf8)
        }

        var jsonSubstring: Substring?
        if let range = rawOutput.range(of: "[{\"") ?? rawOutput.range(of: "[{\n") ?? rawOutput.range(of: "[{\r\n") {
            let sub = rawOutput[range.lowerBound...]
            if let lastBracket = sub.lastIndex(of: "]") {
                jsonSubstring = sub[...lastBracket]
            }
        } else if let range = rawOutput.range(of: "[]") {
            jsonSubstring = rawOutput[range]
        }

        return jsonSubstring.flatMap { String($0).data(using: .utf8) }
    }

    func fetchLibrary() async throws -> [EpicGameEntry] {
        ensureConfigurationImported()
        try FileManager.default.createDirectory(at: configurationDirectory, withIntermediateDirectories: true)
        guard let legendaryURL = Self.findLegendaryBinary() else {
            throw NSError(domain: "EpicService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Legendary compatibility engine not found."])
        }

        var env = ProcessInfo.processInfo.environment
        env["LEGENDARY_CONFIG_PATH"] = configurationDirectory.path

        let result = try await Task.detached(priority: .userInitiated) {
            try processRunner.run(
                legendaryURL.path,
                arguments: ["list", "--platform", "Windows", "-T", "--json"],
                environment: env,
                outputLimit: 64 * 1024 * 1024 // 64 MB to comfortably hold full catalog JSON
            )
        }.value

        guard result.status == 0 else {
            let errorDetail = result.errorOutput.isEmpty ? result.output : result.errorOutput
            throw NSError(domain: "EpicService", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: "Epic library list failed: \(errorDetail)"])
        }

        guard let data = Self.extractJSONData(from: result.output) else {
            throw NSError(domain: "EpicService", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to extract JSON game entries from Legendary output."])
        }

        return try decodeLibraryEntries(from: data)
    }

    func decodeLibraryEntries(from data: Data) throws -> [EpicGameEntry] {
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        var entries: [EpicGameEntry] = []
        for item in items {
            guard let appName = item["app_name"] as? String,
                  let title = item["app_title"] as? String else {
                continue
            }

            if let isDLC = item["is_dlc"] as? Bool, isDLC {
                continue
            }

            let keyImages = (item["metadata"] as? [String: Any])?["keyImages"] as? [[String: Any]]
            let preferredTypes = ["DieselGameBoxTall", "OfferImageTall", "DieselGameBox", "OfferImageWide", "Featured"]
            var artwork: URL?
            for pType in preferredTypes {
                if let urlStr = keyImages?.first(where: { ($0["type"] as? String) == pType })?["url"] as? String,
                   let url = URL(string: urlStr) {
                    artwork = url
                    break
                }
            }
            if artwork == nil, let firstUrl = keyImages?.first?["url"] as? String {
                artwork = URL(string: firstUrl)
            }
            if artwork == nil {
                artwork = HeroicArtworkService.resolveArtworkURL(appName: appName, configurationDirectory: configurationDirectory)
            }

            entries.append(EpicGameEntry(
                appName: appName,
                title: title,
                artworkURL: artwork,
                isWindowsSupported: true,
                estimatedSizeBytes: nil
            ))
        }
        return entries
    }

    func install(
        appName: String,
        targetDirectory: URL,
        progress: @escaping @Sendable (HeroicInstallProgress) -> Void
    ) async throws -> HeroicInstalledEvidence {
        guard Self.findLegendaryBinary() != nil else {
            throw NSError(domain: "EpicService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Legendary downloader binary is missing."])
        }

        Self.cleanupStaleLocksAndOrphans(configurationDirectory: configurationDirectory)

        var env = ProcessInfo.processInfo.environment
        env["LEGENDARY_CONFIG_PATH"] = configurationDirectory.path

        let runner = HeroicInstallService()
        let result = try await runner.install(
            applicationName: appName,
            baseDirectory: targetDirectory,
            configurationDirectory: configurationDirectory,
            updateOnly: false,
            installPrerequisites: true
        ) { installProgress in
            progress(installProgress)
        }

        let resumeFile = configurationDirectory.appendingPathComponent("tmp/\(appName).resume")
        if FileManager.default.fileExists(atPath: resumeFile.path) {
            throw NSError(
                domain: "EpicService",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Download paused or interrupted before completion. Resume is available."]
            )
        }

        guard result.exitStatus == 0 else {
            throw NSError(domain: "EpicService", code: Int(result.exitStatus), userInfo: [NSLocalizedDescriptionKey: "Epic download failed with status \(result.exitStatus)"])
        }

        return result.evidence
    }

    func install(
        appName: String,
        targetDirectory: URL,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> HeroicInstalledEvidence {
        try await install(appName: appName, targetDirectory: targetDirectory) { installProgress in
            let fraction = installProgress.fraction ?? 0.0
            progress(fraction, installProgress.detail)
        }
    }

    func isGameResumable(appName: String) -> Bool {
        let resumeFile = configurationDirectory.appendingPathComponent("tmp/\(appName).resume")
        return FileManager.default.fileExists(atPath: resumeFile.path)
    }

    public struct InstalledEpicEntry: Decodable, Sendable {
        public let appName: String
        public let title: String?
        public let installPath: String?
        public let executable: String?
        public let launchParameters: String?

        private enum CodingKeys: String, CodingKey {
            case appName = "app_name"
            case title
            case installPath = "install_path"
            case executable
            case launchParameters = "launch_parameters"
        }
    }

    public func loadInstalledGames() -> [String: InstalledEpicEntry] {
        let fileURL = configurationDirectory.appendingPathComponent("installed.json")
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: InstalledEpicEntry].self, from: data) else {
            return [:]
        }
        return decoded
    }

    /// Discovers if a local directory or executable matches a registered Epic Games Store title.
    public func findApplicationID(installationURL: URL?, executableURL: URL?) -> String? {
        let installed = loadInstalledGames()
        if installed.isEmpty { return nil }

        let installPath = installationURL?.resolvingSymlinksInPath().standardizedFileURL.path
        let execPath = executableURL?.resolvingSymlinksInPath().standardizedFileURL.path

        for (appName, entry) in installed {
            guard let rawEntryPath = entry.installPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawEntryPath.isEmpty else {
                continue
            }
            let entryPath = URL(fileURLWithPath: rawEntryPath).resolvingSymlinksInPath().standardizedFileURL.path

            if let installPath {
                if installPath == entryPath ||
                   installPath.hasPrefix(entryPath + "/") ||
                   entryPath.hasPrefix(installPath + "/") ||
                   installPath.lowercased() == entryPath.lowercased() {
                    return appName
                }
            }

            if let execPath {
                if execPath.hasPrefix(entryPath + "/") || execPath == entryPath {
                    return appName
                }
                if let entryExec = entry.executable, !entryExec.isEmpty {
                    if execPath.hasSuffix("/" + entryExec) {
                        let execParent = URL(fileURLWithPath: execPath).deletingLastPathComponent().lastPathComponent.lowercased()
                        let entryFolder = URL(fileURLWithPath: entryPath).lastPathComponent.lowercased()
                        if execParent == entryFolder || entryFolder.contains(execParent) || execParent.contains(entryFolder) {
                            return appName
                        }
                    }
                }
            }
        }
        return nil
    }

    /// Obtains authentication and launcher parameters for an Epic Games store title (e.g. -EpicPortal, -AUTH_LOGIN, etc.)
    func getLaunchArguments(for appName: String) async -> [String] {
        ensureConfigurationImported()
        guard let legendaryURL = Self.findLegendaryBinary() else {
            return fallbackLaunchArguments(for: appName)
        }
        Self.cleanupStaleLocksAndOrphans(configurationDirectory: configurationDirectory)

        var env = ProcessInfo.processInfo.environment
        env["LEGENDARY_CONFIG_PATH"] = configurationDirectory.path

        let fetchedArgs = await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = legendaryURL
            process.arguments = ["launch", appName, "--json"]
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                guard let text = String(data: data, encoding: .utf8) else { return [String]() }
                for line in text.components(separatedBy: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("{") && trimmed.contains("egl_parameters"),
                       let jsonData = trimmed.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                        var args: [String] = []
                        if let gameParams = json["game_parameters"] as? [String] {
                            args.append(contentsOf: gameParams)
                        }
                        if let eglParams = json["egl_parameters"] as? [String] {
                            args.append(contentsOf: eglParams)
                        }
                        return args
                    }
                }
            } catch {
                return [String]()
            }
            return [String]()
        }.value

        if !fetchedArgs.isEmpty {
            return fetchedArgs
        }
        return fallbackLaunchArguments(for: appName)
    }

    private func fallbackLaunchArguments(for appName: String) -> [String] {
        let installed = loadInstalledGames()
        var args: [String] = []
        if let entry = installed[appName], let rawParams = entry.launchParameters {
            let parts = rawParams.split(separator: " ").map(String.init)
            args.append(contentsOf: parts)
        }
        if !args.contains("-EpicPortal") {
            args.append("-EpicPortal")
        }
        return args
    }

    func deleteDownloadData(appName: String, targetDirectory: URL) {
        let resumeFile = configurationDirectory.appendingPathComponent("tmp/\(appName).resume")
        try? FileManager.default.removeItem(at: resumeFile)
        let jsonFile = configurationDirectory.appendingPathComponent("tmp/\(appName).json")
        try? FileManager.default.removeItem(at: jsonFile)
    }

    public static func cleanupStaleLocksAndOrphans(configurationDirectory: URL) {
        let lockURL = configurationDirectory.appendingPathComponent("installed.json.lock")
        guard FileManager.default.fileExists(atPath: lockURL.path) else { return }

        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-t", lockURL.path]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        try? lsof.run()
        lsof.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let pids = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isWhitespace)
            .compactMap { Int32($0) }

        if pids.isEmpty {
            try? FileManager.default.removeItem(at: lockURL)
        } else {
            for pid in pids {
                kill(pid, SIGTERM)
            }
            usleep(250_000)
            try? FileManager.default.removeItem(at: lockURL)
        }
    }
}
