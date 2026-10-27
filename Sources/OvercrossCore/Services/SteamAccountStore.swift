import Foundation

enum SteamAccountStoreError: LocalizedError, Sendable {
    case invalidSteamID
    case emptyAPIKey

    var errorDescription: String? {
        switch self {
        case .invalidSteamID:
            "Enter a valid non-zero 64-bit SteamID."
        case .emptyAPIKey:
            "Enter a Steam Web API key."
        }
    }
}

struct SteamAccountStore: Sendable {
    private static let steamIDDefaultsKey = "overcross.steam.steamID"
    private static let apiKeyAccount = "steam-web-api-key"

    private let keychain: KeychainSecretStore

    init(keychain: KeychainSecretStore = KeychainSecretStore()) {
        self.keychain = keychain
    }

    var steamID: String? {
        UserDefaults.standard.string(forKey: Self.steamIDDefaultsKey)
    }

    var hasAPIKey: Bool {
        apiKey != nil
    }

    var apiKey: String? {
        keychain.read(account: Self.apiKeyAccount)
    }

    func save(steamID: String, apiKey: String) throws {
        let trimmedID = steamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let numericID = UInt64(trimmedID), numericID > 0 else {
            throw SteamAccountStoreError.invalidSteamID
        }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw SteamAccountStoreError.emptyAPIKey
        }
        try keychain.save(trimmedKey, account: Self.apiKeyAccount)
        try saveSteamID(trimmedID)
    }

    func saveSteamID(_ steamID: String) throws {
        let trimmedID = steamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let numericID = UInt64(trimmedID), numericID > 0 else {
            throw SteamAccountStoreError.invalidSteamID
        }
        UserDefaults.standard.set(String(numericID), forKey: Self.steamIDDefaultsKey)
    }

    func clear() throws {
        try keychain.delete(account: Self.apiKeyAccount)
        UserDefaults.standard.removeObject(forKey: Self.steamIDDefaultsKey)
    }
}
