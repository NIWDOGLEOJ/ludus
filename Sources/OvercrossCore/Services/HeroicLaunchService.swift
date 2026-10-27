import AppKit
import Foundation

enum HeroicLaunchError: LocalizedError, Sendable {
    case missingApplicationName
    case couldNotOpenURL

    var errorDescription: String? {
        switch self {
        case .missingApplicationName:
            "This Epic entry has no Heroic application name."
        case .couldNotOpenURL:
            "macOS could not hand the game launch request to Heroic."
        }
    }
}

struct HeroicLaunchService: Sendable {
    static func launchURL(appName: String) throws -> URL {
        let normalizedName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw HeroicLaunchError.missingApplicationName
        }

        var components = URLComponents()
        components.scheme = "heroic"
        components.host = "launch"
        components.queryItems = [
            URLQueryItem(name: "appName", value: normalizedName),
            URLQueryItem(name: "runner", value: "legendary")
        ]
        guard let url = components.url else {
            throw HeroicLaunchError.missingApplicationName
        }
        return url
    }

    func launch(appName: String) throws {
        let url = try Self.launchURL(appName: appName)
        guard NSWorkspace.shared.open(url) else {
            throw HeroicLaunchError.couldNotOpenURL
        }
    }
}
