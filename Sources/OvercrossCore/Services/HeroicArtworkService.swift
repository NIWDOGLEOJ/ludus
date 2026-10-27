import Foundation

/// Resolves cover artwork and box art for Heroic and Legendary Epic Games installations
/// by reading local metadata or cached artwork.
public struct HeroicArtworkService: Sendable {
    public init() {}

    /// Attempts to locate artwork for the given Epic application name.
    public static func resolveArtworkURL(
        appName: String,
        configurationDirectory: URL? = nil
    ) -> URL? {
        let trimmedName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        // 1. Check <configurationDirectory>/metadata/<appName>.json
        if let configurationDirectory {
            let metadataURL = configurationDirectory
                .appendingPathComponent("metadata", isDirectory: true)
                .appendingPathComponent("\(trimmedName).json")
            if let artwork = artworkFromLegendaryMetadata(at: metadataURL) {
                return artwork
            }
        }

        // 2. Check standard user configuration paths for legendary metadata
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidateMetadataDirs = [
            home.appendingPathComponent(".config/legendary/metadata", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/legendary/metadata", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/heroic/legendaryConfig/legendary/metadata", isDirectory: true)
        ]
        for dir in candidateMetadataDirs {
            let metadataURL = dir.appendingPathComponent("\(trimmedName).json")
            if let artwork = artworkFromLegendaryMetadata(at: metadataURL) {
                return artwork
            }
        }

        // 3. Check Heroic store cache
        let candidateCacheFiles = [
            home.appendingPathComponent("Library/Application Support/heroic/store_cache/legendary_library.json"),
            home.appendingPathComponent(".config/heroic/store_cache/legendary_library.json")
        ]
        for cacheFile in candidateCacheFiles {
            if let artwork = artworkFromHeroicStoreCache(at: cacheFile, appName: trimmedName) {
                return artwork
            }
        }

        // 4. Check local cover image file cache
        let imageExtensions = ["png", "jpg", "jpeg", "webp"]
        let candidateImageDirs = [
            home.appendingPathComponent("Library/Application Support/heroic/store_cache/images", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/heroic/covers", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/heroic/store_cache", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/heroic/tools", isDirectory: true),
            home.appendingPathComponent(".config/heroic/store_cache/images", isDirectory: true),
            home.appendingPathComponent(".config/heroic/covers", isDirectory: true),
            home.appendingPathComponent(".config/heroic/store_cache", isDirectory: true)
        ]
        for dir in candidateImageDirs {
            for ext in imageExtensions {
                let imgURL = dir.appendingPathComponent("\(trimmedName).\(ext)")
                if FileManager.default.fileExists(atPath: imgURL.path) {
                    return imgURL
                }
            }
        }

        return nil
    }

    public static func artworkFromLegendaryMetadata(at url: URL) -> URL? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let keyImages = (json["keyImages"] as? [[String: Any]])
            ?? ((json["metadata"] as? [String: Any])?["keyImages"] as? [[String: Any]])
        if let keyImages {
            let preferredTypes = ["DieselGameBoxTall", "DieselGameBox", "Thumbnail", "OfferImageTall", "OfferImageWide"]
            for type in preferredTypes {
                if let match = keyImages.first(where: { ($0["type"] as? String) == type }),
                   let urlString = match["url"] as? String,
                   let url = URL(string: urlString) {
                    return url
                }
            }
            if let first = keyImages.first,
               let urlString = first["url"] as? String,
               let url = URL(string: urlString) {
                return url
            }
        }
        return nil
    }

    private static func artworkFromHeroicStoreCache(at url: URL, appName: String) -> URL? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data)
        else { return nil }

        if let dict = json as? [String: [String: Any]],
           let entry = dict[appName] {
            if let art = entry["art"] as? [String: Any],
               let cover = art["cover"] as? String,
               let coverURL = URL(string: cover) {
                return coverURL
            }
            if let box = entry["box_art"] as? String, let boxURL = URL(string: box) {
                return boxURL
            }
        } else if let array = json as? [[String: Any]] {
            if let entry = array.first(where: { ($0["app_name"] as? String) == appName }) {
                if let art = entry["art"] as? [String: Any],
                   let cover = art["cover"] as? String,
                   let coverURL = URL(string: cover) {
                    return coverURL
                }
                if let box = entry["box_art"] as? String, let boxURL = URL(string: box) {
                    return boxURL
                }
            }
        }
        return nil
    }
}
