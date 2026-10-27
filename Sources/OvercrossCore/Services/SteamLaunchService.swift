import AppKit
import Foundation

enum SteamLaunchError: LocalizedError, Sendable {
    case invalidApplicationID
    case couldNotOpenURL

    var errorDescription: String? {
        switch self {
        case .invalidApplicationID:
            "This Steam entry has no valid numeric application ID."
        case .couldNotOpenURL:
            "macOS could not hand the game launch request to Steam."
        }
    }
}

struct SteamLaunchService: Sendable {
    static func launchURL(applicationID: String) throws -> URL {
        guard let numericID = UInt32(applicationID.trimmingCharacters(in: .whitespacesAndNewlines)),
              numericID > 0
        else {
            throw SteamLaunchError.invalidApplicationID
        }

        var components = URLComponents()
        components.scheme = "steam"
        components.host = "run"
        components.path = "/\(numericID)"
        guard let url = components.url else {
            throw SteamLaunchError.invalidApplicationID
        }
        return url
    }

    func launch(applicationID: String) throws {
        let url = try Self.launchURL(applicationID: applicationID)
        guard NSWorkspace.shared.open(url) else {
            throw SteamLaunchError.couldNotOpenURL
        }
    }
}
