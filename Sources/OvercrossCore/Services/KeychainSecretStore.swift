import Foundation
import Security

enum KeychainSecretStoreError: LocalizedError, Sendable {
    case couldNotSave(OSStatus)
    case couldNotDelete(OSStatus)

    var errorDescription: String? {
        switch self {
        case .couldNotSave(let status):
            "macOS Keychain could not save the secret (status \(status))."
        case .couldNotDelete(let status):
            "macOS Keychain could not remove the secret (status \(status))."
        }
    }
}

struct KeychainSecretStore: Sendable {
    private let service: String

    init(service: String = "com.overcross.secrets") {
        self.service = service
    }

    func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func save(_ secret: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let data = Data(secret.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainSecretStoreError.couldNotSave(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainSecretStoreError.couldNotSave(updateStatus)
        }
    }

    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainSecretStoreError.couldNotDelete(status)
        }
    }
}
