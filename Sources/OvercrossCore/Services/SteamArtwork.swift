import Foundation

/// Provides Steam CDN artwork URLs for games discovered via local manifests,
/// auto-scanned libraries, or the Steam Web API.
public enum SteamArtwork {
    /// High-resolution portrait library capsule artwork (600x900).
    public static func libraryPortraitURL(forAppID appID: String) -> URL? {
        let trimmed = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = Int(trimmed), id > 0 else { return nil }
        return URL(string: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(trimmed)/library_600x900.jpg")
    }

    /// Wide header banner artwork.
    public static func headerURL(forAppID appID: String) -> URL? {
        let trimmed = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = Int(trimmed), id > 0 else { return nil }
        return URL(string: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(trimmed)/header.jpg")
    }
}
