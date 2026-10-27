import Foundation

struct SteamOwnedGame: Decodable, Sendable {
    let appID: UInt32
    let name: String?
    let playtimeForeverMinutes: UInt32?

    private enum CodingKeys: String, CodingKey {
        case appID = "appid"
        case name
        case playtimeForeverMinutes = "playtime_forever"
    }
}

enum SteamWebAPIError: LocalizedError, Sendable {
    case invalidConfiguration
    case httpStatus(Int)
    case malformedResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Steam library discovery needs a valid SteamID and a Keychain-backed Web API key."
        case .httpStatus(let status):
            "Steam library discovery returned HTTP status \(status)."
        case .malformedResponse:
            "Steam returned a response that Ludus could not understand."
        case .requestFailed(let message):
            "Steam library discovery failed: \(message)"
        }
    }
}

struct SteamWebAPIClient: Sendable {
    private static let endpoint = URL(string: "https://api.steampowered.com/IPlayerService/GetOwnedGames/v1/")!

    func fetchOwnedGames(steamID: String, apiKey: String) async throws -> [SteamOwnedGame] {
        let request = try Self.makeRequest(steamID: steamID, apiKey: apiKey)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SteamWebAPIError.requestFailed(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SteamWebAPIError.malformedResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SteamWebAPIError.httpStatus(httpResponse.statusCode)
        }
        return try Self.decodeOwnedGames(data)
    }

    static func makeRequest(steamID: String, apiKey: String) throws -> URLRequest {
        guard let numericID = UInt64(steamID.trimmingCharacters(in: .whitespacesAndNewlines)),
              numericID > 0,
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SteamWebAPIError.invalidConfiguration
        }

        var urlComponents = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        urlComponents?.queryItems = [
            URLQueryItem(name: "key", value: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "steamid", value: String(numericID)),
            URLQueryItem(name: "include_appinfo", value: "1"),
            URLQueryItem(name: "include_played_free_games", value: "1"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = urlComponents?.url else {
            throw SteamWebAPIError.invalidConfiguration
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        return request
    }

    static func decodeOwnedGames(_ data: Data) throws -> [SteamOwnedGame] {
        struct OwnedGamesResponse: Decodable {
            let games: [SteamOwnedGame]?
        }
        struct APIResponse: Decodable {
            let response: OwnedGamesResponse?
        }

        let decoder = JSONDecoder()
        guard let decoded = try? decoder.decode(APIResponse.self, from: data),
              let response = decoded.response else {
            throw SteamWebAPIError.malformedResponse
        }
        return response.games ?? []
    }
}
