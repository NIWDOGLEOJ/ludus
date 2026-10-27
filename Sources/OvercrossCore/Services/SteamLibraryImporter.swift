import Foundation

enum SteamLibraryImportError: LocalizedError {
    case invalidLibrary(URL)
    case noManifests(URL)

    var errorDescription: String? {
        switch self {
        case .invalidLibrary(let url):
            "The selected folder does not contain a Steam library manifest directory: \(url.path)"
        case .noManifests(let url):
            "No Steam app manifests were found in \(url.path)."
        }
    }
}

struct SteamLibraryImporter {
    func importGames(from selectedURL: URL) throws -> [Game] {
        let steamAppsURL = selectedURL.lastPathComponent == "steamapps"
            ? selectedURL
            : selectedURL.appendingPathComponent("steamapps", isDirectory: true)

        var libraryIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: steamAppsURL.path, isDirectory: &libraryIsDirectory), libraryIsDirectory.boolValue else {
            throw SteamLibraryImportError.invalidLibrary(steamAppsURL)
        }

        let manifestURLs = try FileManager.default.contentsOfDirectory(
            at: steamAppsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.lastPathComponent.hasPrefix("appmanifest_") && $0.pathExtension == "acf" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !manifestURLs.isEmpty else {
            throw SteamLibraryImportError.noManifests(steamAppsURL)
        }

        let games = manifestURLs.compactMap { manifestURL -> Game? in
            guard
                let content = try? String(contentsOf: manifestURL, encoding: .utf8),
                let fields = SteamManifestParser.parse(content),
                let appID = fields["appid"],
                let numericAppID = Int(appID),
                numericAppID > 0
            else { return nil }

            let title = fields["name"]?.isEmpty == false
                ? fields["name"]!
                : "Steam App \(appID)"
            let installDirectory = fields["installdir"].map {
                steamAppsURL.appendingPathComponent("common", isDirectory: true)
                    .appendingPathComponent($0, isDirectory: true)
            }.flatMap { isDirectory($0) ? $0.standardizedFileURL : nil }

            let artworkURL = SteamArtwork.libraryPortraitURL(forAppID: appID)

            return Game(
                title: title,
                store: .steam,
                storeApplicationID: appID,
                ownershipEvidence: .steamLocalManifest,
                artworkURL: artworkURL,
                installationURL: installDirectory,
                installationMethod: "Steam local library manifest",
                compatibilityStatus: .notTested
            )
        }

        guard !games.isEmpty else {
            throw SteamLibraryImportError.noManifests(steamAppsURL)
        }
        return games
    }

    private func isDirectory(_ url: URL) -> Bool {
        var directory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            && directory.boolValue
    }

    static func defaultSteamLibraryURLs() -> [URL] {
        var urls: [URL] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultMacSteam = home.appendingPathComponent("Library/Application Support/Steam", isDirectory: true)

        let vdfPath = defaultMacSteam.appendingPathComponent("steamapps/libraryfolders.vdf").path
        if let content = try? String(contentsOfFile: vdfPath, encoding: .utf8) {
            let pattern = #"\"path\"\s+\"([^\"]+)\""#
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(content.startIndex..<content.endIndex, in: content)
                let matches = regex.matches(in: content, range: range)
                for match in matches {
                    if let pathRange = Range(match.range(at: 1), in: content) {
                        let path = String(content[pathRange])
                        let url = URL(fileURLWithPath: path, isDirectory: true)
                        if FileManager.default.fileExists(atPath: url.path), !urls.contains(url) {
                            urls.append(url)
                        }
                    }
                }
            }
        }

        var candidates = [
            defaultMacSteam,
            URL(fileURLWithPath: "/Volumes/sata ssd 1/SteamLibrary", isDirectory: true),
            URL(fileURLWithPath: "/Volumes/sata ssd 1/Steam", isDirectory: true)
        ]
        if let volumes = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") {
            for vol in volumes {
                let v = "/Volumes/\(vol)"
                candidates.append(URL(fileURLWithPath: "\(v)/SteamLibrary", isDirectory: true))
                candidates.append(URL(fileURLWithPath: "\(v)/Steam", isDirectory: true))
                candidates.append(URL(fileURLWithPath: "\(v)/SteamApps", isDirectory: true))
                candidates.append(URL(fileURLWithPath: "\(v)/Library/Application Support/Steam", isDirectory: true))
            }
        }

        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate.path), !urls.contains(candidate) {
                urls.append(candidate)
            }
        }
        return urls
    }
}

private enum SteamManifestParser {
    static func parse(_ content: String) -> [String: String]? {
        var fields: [String: String] = [:]
        let pattern = #"^\s*"([^"\\]+)"\s+"([^"\\]*)""#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return nil
        }

        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        expression.enumerateMatches(in: content, options: [], range: range) { match, _, _ in
            guard let match, match.numberOfRanges == 3 else { return }
            guard
                let keyRange = Range(match.range(at: 1), in: content),
                let valueRange = Range(match.range(at: 2), in: content)
            else { return }
            let key = String(content[keyRange])
            if fields[key] == nil {
                fields[key] = String(content[valueRange])
            }
        }
        return fields
    }
}
