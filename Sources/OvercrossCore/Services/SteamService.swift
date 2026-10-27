import Foundation

struct SteamGameEntry: Identifiable, Hashable, Sendable {
    var id: String { "\(appID)" }
    let appID: UInt32
    let title: String
    let artworkURL: URL?
    let isWindowsSupported: Bool
    let antiCheatStatus: AntiCheatStatus

    init(
        appID: UInt32,
        title: String,
        artworkURL: URL? = nil,
        isWindowsSupported: Bool = true,
        antiCheatStatus: AntiCheatStatus? = nil
    ) {
        self.appID = appID
        self.title = title
        self.artworkURL = artworkURL ?? SteamArtwork.libraryPortraitURL(forAppID: "\(appID)")
        self.isWindowsSupported = isWindowsSupported
        self.antiCheatStatus = antiCheatStatus ?? AntiCheatRegistry.inspect(title: title, storeApplicationID: "\(appID)")
    }
}

enum SteamAuthStatus: Equatable, Sendable {
    case notConnected
    case connected(steamID: String)
}

struct SteamService: Sendable {
    private let accountStore = SteamAccountStore()
    private let apiClient = SteamWebAPIClient()

    init() {}

    var hasAPIKey: Bool {
        accountStore.hasAPIKey
    }

    var apiKey: String? {
        accountStore.apiKey
    }

    var steamID: String? {
        accountStore.steamID
    }

    func checkAuthStatus() -> SteamAuthStatus {
        guard let steamID = accountStore.steamID else {
            return .notConnected
        }
        return .connected(steamID: steamID)
    }

    func saveAccount(steamID: String, apiKey: String? = nil) throws {
        if let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty {
            try accountStore.save(steamID: steamID, apiKey: apiKey)
        } else {
            try accountStore.saveSteamID(steamID)
        }
    }

    func disconnect() throws {
        try accountStore.clear()
    }

    func fetchLibrary() async throws -> [SteamGameEntry] {
        guard let steamID = accountStore.steamID else {
            return []
        }

        // 1. If Web API key is available, fetch library from Steam API
        if let apiKey = accountStore.apiKey, !apiKey.isEmpty {
            let games = try await apiClient.fetchOwnedGames(steamID: steamID, apiKey: apiKey)
            return games.map { game in
                let name = game.name ?? "Steam App \(game.appID)"
                return SteamGameEntry(
                    appID: game.appID,
                    title: name,
                    artworkURL: SteamArtwork.libraryPortraitURL(forAppID: "\(game.appID)"),
                    isWindowsSupported: true
                )
            }
        }

        // 2. Discover local Steam libraries if Steam was installed on Mac
        let importer = SteamLibraryImporter()
        let discovered = SteamLibraryImporter.defaultSteamLibraryURLs()
        var entries: [SteamGameEntry] = []
        for lib in discovered {
            if let games = try? importer.importGames(from: lib) {
                for g in games {
                    if let appID = g.storeApplicationID.flatMap({ UInt32($0) }) {
                        entries.append(SteamGameEntry(
                            appID: appID,
                            title: g.title,
                            artworkURL: g.artworkURL,
                            isWindowsSupported: true
                        ))
                    }
                }
            }
        }

        if entries.isEmpty {
            throw NSError(
                domain: "SteamService",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Steam Web API key is missing. Add your API key in Accounts to sync games from Valve's servers."]
            )
        }

        return entries
    }

    /// Prepares a downloaded Steam game directory for offline launch by writing steam_appid.txt.
    func prepareGameDirectory(at directoryURL: URL, appID: UInt32) throws {
        let appIDFile = directoryURL.appendingPathComponent("steam_appid.txt")
        if !FileManager.default.fileExists(atPath: appIDFile.path) {
            try "\(appID)\n".write(to: appIDFile, atomically: true, encoding: .utf8)
        }
    }
}
