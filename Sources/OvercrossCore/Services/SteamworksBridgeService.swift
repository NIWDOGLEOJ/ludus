import Foundation

public struct SteamworksBridgeService: Sendable {
    public init() {}

    /// Known locations of the native macOS Steam client installation and dynamic libraries.
    public static let standardSteamClientPaths: [String] = [
        ("~/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib" as NSString).expandingTildeInPath,
        ("~/Library/Application Support/Steam/steamclient.dylib" as NSString).expandingTildeInPath
    ]

    public static let standardSteamDataDirectory: String = {
        ("~/Library/Application Support/Steam" as NSString).expandingTildeInPath
    }()

    /// Detects if the native macOS Steam client is installed.
    public static func isNativeSteamInstalled() -> Bool {
        if standardSteamClientPaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
            return true
        }
        return FileManager.default.fileExists(atPath: standardSteamDataDirectory)
    }

    /// Resolves the installed steamclient.dylib URL if present.
    public static func resolvedSteamClientDylibURL() -> URL? {
        for path in standardSteamClientPaths {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// Prepares environment variables for Steamworks bridge.
    public static func steamworksEnvironment(for appID: String?) -> [String: String] {
        var env: [String: String] = [:]
        if let appID = appID, !appID.isEmpty {
            env["SteamAppId"] = appID
            env["SteamGameId"] = appID
            env["STEAM_COMPAT_APP_ID"] = appID
        }
        if isNativeSteamInstalled() {
            env["STEAM_COMPAT_CLIENT_INSTALL_PATH"] = standardSteamDataDirectory
        }
        return env
    }

    /// Wine DLL overrides to route Steamworks calls through lsteamclient bridge.
    public static let steamworksDllOverrides = "steam_api,steam_api64=native,builtin"
}
