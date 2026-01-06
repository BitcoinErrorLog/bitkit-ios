//
//  PaykitKeychainStorage.swift
//  Bitkit
//
//  Helper for storing Paykit data in Keychain using generic password items.
//

import Foundation
import UIKit

/// Helper class for storing Paykit-specific data in Keychain
/// Uses generic password items with custom account names
public class PaykitKeychainStorage {
    
    public static let shared = PaykitKeychainStorage()
    
    /// Service identifier includes device name to isolate simulators during testing
    private var serviceIdentifier: String {
        #if targetEnvironment(simulator)
        // Use device name to isolate different simulators
        let deviceName = UIDevice.current.name.replacingOccurrences(of: " ", with: "_")
        return "to.bitkit.paykit.\(deviceName)"
        #else
        return "to.bitkit.paykit"
        #endif
    }
    
    /// Legacy service identifier (before device isolation was added)
    private let legacyServiceIdentifier = "to.bitkit.paykit"
    
    public init() {}
    
    /// Store data in keychain
    public func store(key: String, data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
            kSecAttrAccessGroup as String: Env.keychainGroup,
        ]
        
        // Delete existing item if present
        SecItemDelete(query as CFDictionary)
        
        // Add new item
        let status = SecItemAdd(query as CFDictionary, nil)
        
        if status != noErr {
            Logger.error("Failed to store Paykit keychain item: \(key), status: \(status)", context: "PaykitKeychainStorage")
            throw PaykitStorageError.saveFailed(key: key)
        }
        
        Logger.debug("Stored Paykit keychain item: \(key)", context: "PaykitKeychainStorage")
    }
    
    /// Retrieve data from keychain
    /// Falls back to legacy service identifier for migration
    func retrieve(key: String) throws -> Data? {
        // Try current (device-specific) service first
        if let data = try retrieveFromService(key: key, service: serviceIdentifier) {
            return data
        }
        
        // Fallback to legacy service for migration
        #if targetEnvironment(simulator)
        if serviceIdentifier != legacyServiceIdentifier {
            if let legacyData = try retrieveFromService(key: key, service: legacyServiceIdentifier) {
                Logger.info("Found legacy keychain item: \(key), migrating...", context: "PaykitKeychainStorage")
                // Migrate to new service
                try? storeToService(key: key, data: legacyData, service: serviceIdentifier)
                return legacyData
            }
        }
        #endif
        
        return nil
    }
    
    /// Retrieve from a specific service identifier
    private func retrieveFromService(key: String, service: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessGroup as String: Env.keychainGroup,
        ]
        
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        
        if status == errSecItemNotFound {
            return nil
        }
        
        if status != noErr {
            Logger.error("Failed to retrieve Paykit keychain item: \(key) from \(service), status: \(status)", context: "PaykitKeychainStorage")
            throw PaykitStorageError.loadFailed(key: key)
        }
        
        Logger.debug("Retrieved Paykit keychain item: \(key) from \(service)", context: "PaykitKeychainStorage")
        return dataTypeRef as? Data
    }
    
    /// Store to a specific service identifier
    private func storeToService(key: String, data: Data, service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
            kSecAttrAccessGroup as String: Env.keychainGroup,
        ]
        
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        
        if status != noErr {
            throw PaykitStorageError.saveFailed(key: key)
        }
    }
    
    /// Delete data from keychain (deletes from both current and legacy namespaces)
    func delete(key: String) throws {
        // Delete from current namespace
        let currentQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: Env.keychainGroup,
        ]
        
        let currentStatus = SecItemDelete(currentQuery as CFDictionary)
        
        if currentStatus != noErr && currentStatus != errSecItemNotFound {
            Logger.error("Failed to delete Paykit keychain item: \(key), status: \(currentStatus)", context: "PaykitKeychainStorage")
            throw PaykitStorageError.deleteFailed(key: key)
        }
        
        // Also delete from legacy namespace to prevent re-migration
        #if targetEnvironment(simulator)
        if serviceIdentifier != legacyServiceIdentifier {
            let legacyQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: legacyServiceIdentifier,
                kSecAttrAccount as String: key,
                kSecAttrAccessGroup as String: Env.keychainGroup,
            ]
            SecItemDelete(legacyQuery as CFDictionary)
        }
        #endif
        
        Logger.debug("Deleted Paykit keychain item: \(key) from all namespaces", context: "PaykitKeychainStorage")
    }
    
    /// Delete ALL keys with a given prefix from both namespaces
    public func deleteAllWithPrefix(_ prefix: String) {
        Logger.info("Deleting all keychain items with prefix: \(prefix)", context: "PaykitKeychainStorage")
        
        // Get all keys with the prefix from current namespace
        let keys = listKeys(withPrefix: prefix)
        for key in keys {
            try? delete(key: key)
        }
        
        // Also delete from legacy namespace
        #if targetEnvironment(simulator)
        if serviceIdentifier != legacyServiceIdentifier {
            let legacyKeys = listKeysFromService(withPrefix: prefix, service: legacyServiceIdentifier)
            for key in legacyKeys {
                let legacyQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: legacyServiceIdentifier,
                    kSecAttrAccount as String: key,
                    kSecAttrAccessGroup as String: Env.keychainGroup,
                ]
                SecItemDelete(legacyQuery as CFDictionary)
            }
        }
        #endif
    }
    
    /// List keys from a specific service identifier
    private func listKeysFromService(withPrefix prefix: String, service: String) -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrAccessGroup as String: Env.keychainGroup,
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == noErr, let items = result as? [[String: Any]] else {
            return []
        }
        
        return items.compactMap { item -> String? in
            guard let account = item[kSecAttrAccount as String] as? String else {
                return nil
            }
            return account.hasPrefix(prefix) ? account : nil
        }
    }
    
    /// Check if key exists
    func exists(key: String) -> Bool {
        do {
            return try retrieve(key: key) != nil
        } catch {
            return false
        }
    }
    
    // MARK: - Convenience Methods
    
    /// Store data using set/get naming convention
    public func set(key: String, value: Data) {
        do {
            try store(key: key, data: value)
        } catch {
            Logger.error("Failed to set keychain value: \(error)", context: "PaykitKeychainStorage")
        }
    }
    
    /// Get data using set/get naming convention
    public func get(key: String) -> Data? {
        do {
            return try retrieve(key: key)
        } catch {
            Logger.error("Failed to get keychain value: \(error)", context: "PaykitKeychainStorage")
            return nil
        }
    }
    
    /// Delete without throwing (convenience method)
    public func deleteQuietly(key: String) {
        do {
            try delete(key: key) as Void
        } catch {
            Logger.error("Failed to delete keychain value: \(error)", context: "PaykitKeychainStorage")
        }
    }
    
    /// List all keys with a given prefix
    /// - Parameter prefix: The key prefix to filter by
    /// - Returns: Array of matching keys
    public func listKeys(withPrefix prefix: String) -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecReturnAttributes as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrAccessGroup as String: Env.keychainGroup,
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == noErr else {
            if status == errSecItemNotFound {
                return []
            }
            Logger.error("Failed to list keychain items, status: \(status)", context: "PaykitKeychainStorage")
            return []
        }
        
        guard let items = result as? [[String: Any]] else {
            return []
        }
        
        return items.compactMap { item -> String? in
            guard let account = item[kSecAttrAccount as String] as? String else {
                return nil
            }
            return account.hasPrefix(prefix) ? account : nil
        }
    }
}

enum PaykitStorageError: LocalizedError {
    case saveFailed(key: String)
    case loadFailed(key: String)
    case deleteFailed(key: String)
    case encodingFailed
    case decodingFailed
    
    var errorDescription: String? {
        switch self {
        case .saveFailed(let key):
            return "Failed to save Paykit data: \(key)"
        case .loadFailed(let key):
            return "Failed to load Paykit data: \(key)"
        case .deleteFailed(let key):
            return "Failed to delete Paykit data: \(key)"
        case .encodingFailed:
            return "Failed to encode Paykit data"
        case .decodingFailed:
            return "Failed to decode Paykit data"
        }
    }
}

