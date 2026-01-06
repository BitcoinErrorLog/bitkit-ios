//
//  ProfileStorage.swift
//  Bitkit
//
//  Persistent storage for user profile using Keychain.
//

import Foundation

/// Manages persistent storage of the user's profile
public class ProfileStorage {
    
    public static let shared = ProfileStorage()
    
    private let keychain: PaykitKeychainStorage
    
    // In-memory cache
    private var profileCache: PubkyProfile?
    private var cachedPubkey: String?
    
    private func profileKey(for pubkey: String) -> String {
        "paykit.profile.\(pubkey)"
    }
    
    public init(keychain: PaykitKeychainStorage = PaykitKeychainStorage()) {
        self.keychain = keychain
    }
    
    // MARK: - CRUD Operations
    
    /// Get the stored profile for a pubkey
    public func getProfile(for pubkey: String) -> PubkyProfile? {
        // Check cache first
        if let cached = profileCache, cachedPubkey == pubkey {
            return cached
        }
        
        do {
            guard let data = try keychain.retrieve(key: profileKey(for: pubkey)) else {
                return nil
            }
            let profile = try JSONDecoder().decode(PubkyProfile.self, from: data)
            profileCache = profile
            cachedPubkey = pubkey
            return profile
        } catch {
            Logger.error("ProfileStorage: Failed to load profile: \(error)", context: "ProfileStorage")
            return nil
        }
    }
    
    /// Save the profile for a pubkey
    public func saveProfile(_ profile: PubkyProfile, for pubkey: String) throws {
        let data = try JSONEncoder().encode(profile)
        try keychain.store(key: profileKey(for: pubkey), data: data)
        
        // Update cache
        profileCache = profile
        cachedPubkey = pubkey
        
        Logger.debug("ProfileStorage: Saved profile for \(pubkey.prefix(12))...", context: "ProfileStorage")
    }
    
    /// Delete the stored profile for a pubkey
    public func deleteProfile(for pubkey: String) {
        do {
            try keychain.delete(key: profileKey(for: pubkey))
            if cachedPubkey == pubkey {
                profileCache = nil
                cachedPubkey = nil
            }
        } catch {
            Logger.debug("ProfileStorage: Failed to delete profile: \(error)", context: "ProfileStorage")
        }
    }
    
    /// Clear all cached data and keychain storage
    public func clearCache() {
        // Clear in-memory cache
        profileCache = nil
        cachedPubkey = nil
        
        // Clear all profile data from keychain (handles both namespaces)
        keychain.deleteAllWithPrefix("paykit.profile.")
        
        Logger.info("ProfileStorage: Cleared all profile data", context: "ProfileStorage")
    }
}

