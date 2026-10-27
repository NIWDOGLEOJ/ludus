import Foundation

public enum LudusStorage {
    public static let appName = "Ludus"
    public static let legacyAppName = "Overcross"

    public static var applicationSupportURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let ludusURL = base.appendingPathComponent(appName, isDirectory: true)
        let overcrossURL = base.appendingPathComponent(legacyAppName, isDirectory: true)

        if !FileManager.default.fileExists(atPath: ludusURL.path) && FileManager.default.fileExists(atPath: overcrossURL.path) {
            try? FileManager.default.createSymbolicLink(at: ludusURL, withDestinationURL: overcrossURL)
        }

        if !FileManager.default.fileExists(atPath: ludusURL.path) {
            try? FileManager.default.createDirectory(at: ludusURL, withIntermediateDirectories: true)
        }

        return FileManager.default.fileExists(atPath: ludusURL.path) ? ludusURL : overcrossURL
    }

    public static var cachesURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
        let ludusURL = base.appendingPathComponent(appName, isDirectory: true)
        let overcrossURL = base.appendingPathComponent(legacyAppName, isDirectory: true)

        if !FileManager.default.fileExists(atPath: ludusURL.path) && FileManager.default.fileExists(atPath: overcrossURL.path) {
            try? FileManager.default.createSymbolicLink(at: ludusURL, withDestinationURL: overcrossURL)
        }

        if !FileManager.default.fileExists(atPath: ludusURL.path) {
            try? FileManager.default.createDirectory(at: ludusURL, withIntermediateDirectories: true)
        }

        return FileManager.default.fileExists(atPath: ludusURL.path) ? ludusURL : overcrossURL
    }

    public static func defaultGamesURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let ludusGames = home.appendingPathComponent("Games/Ludus", isDirectory: true)
        let overcrossGames = home.appendingPathComponent("Games/Overcross", isDirectory: true)
        if FileManager.default.fileExists(atPath: overcrossGames.path) && !FileManager.default.fileExists(atPath: ludusGames.path) {
            return overcrossGames
        }
        return ludusGames
    }
}
