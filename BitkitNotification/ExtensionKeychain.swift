import Foundation
import Security

enum KeychainEntryType {
    case bip39Mnemonic(index: Int)
    case bip39Passphrase(index: Int)
    case pushNotificationPrivateKey
    case securityPin

    var storageKey: String {
        switch self {
        case let .bip39Mnemonic(index):
            return "bip39_mnemonic_\(index)"
        case let .bip39Passphrase(index):
            return "bip39_passphrase_\(index)"
        case .pushNotificationPrivateKey:
            return "push_notification_private_key"
        case .securityPin:
            return "security_pin"
        }
    }
}

enum KeychainError: Error {
    case failedToSave
    case failedToSaveAlreadyExists
    case failedToLoad
    case failedToDelete
}

class Keychain {
    class func load(key: KeychainEntryType) throws -> Data? {
        let query =
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: key.storageKey,
                kSecReturnData as String: kCFBooleanTrue!,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecAttrAccessGroup as String: Env.keychainGroup,
            ] as [String: Any]

        var dataTypeRef: AnyObject?

        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        if status == errSecItemNotFound {
            return nil
        }

        if status != noErr {
            throw KeychainError.failedToLoad
        }

        return dataTypeRef as! Data?
    }
}
