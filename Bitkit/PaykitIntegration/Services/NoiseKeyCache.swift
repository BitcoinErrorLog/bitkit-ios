//
//  NoiseKeyCache.swift
//  Bitkit
//
//  X25519 Key Cache for Noise Protocol
//

import Foundation

/// Cache for X25519 Noise protocol keys
public final class NoiseKeyCache {
    
    public static let shared = NoiseKeyCache()
    
    private let keychain: PaykitKeychainStorage
    private var memoryCache: [String: Data] = [:]
    private let cacheQueue = DispatchQueue(label: "to.bitkit.paykit.noise.cache", attributes: .concurrent)
    
    public var maxCachedEpochs: Int = 5
    
    private init() {
        self.keychain = PaykitKeychainStorage()
    }
    
    /// Get a cached key if available
    ///
    /// Thread-safe: Uses barrier sync for atomic read-check-write operation
    public func getKey(deviceId: String, epoch: UInt32) -> Data? {
        let key = cacheKey(deviceId: deviceId, epoch: epoch)
        
        // Use barrier sync for atomic read-check-write to prevent race conditions
        // where multiple threads could simultaneously load from keychain
        return cacheQueue.sync(flags: .barrier) { () -> Data? in
            // Check memory cache first
            if let cached = memoryCache[key] {
                return cached
            }
            
            // Check persistent cache (within the same barrier to ensure atomicity)
            if let keyData = try? keychain.retrieve(key: key) {
                memoryCache[key] = keyData
                return keyData
            }
            
            return nil
        }
    }
    
    /// Store a key in the cache
    ///
    /// Thread-safe: Uses barrier sync for atomic write
    public func setKey(_ keyData: Data, deviceId: String, epoch: UInt32) {
        let key = cacheKey(deviceId: deviceId, epoch: epoch)
        
        // Store in memory cache with barrier sync to ensure write completes before returning
        cacheQueue.sync(flags: .barrier) {
            self.memoryCache[key] = keyData
        }
        
        // Store in keychain (outside barrier, as keychain has its own thread safety)
        try? keychain.store(key: key, data: keyData)
        
        // Cleanup old epochs if needed
        cleanupOldEpochs(deviceId: deviceId, currentEpoch: epoch)
    }
    
    /// Clear all cached keys
    ///
    /// Thread-safe: Uses barrier sync for atomic write
    public func clearAll() {
        cacheQueue.sync(flags: .barrier) {
            self.memoryCache.removeAll()
        }
    }
    
    // MARK: - Private
    
    private func cacheKey(deviceId: String, epoch: UInt32) -> String {
        return "noise.key.cache.\(deviceId).\(epoch)"
    }
    
    private func cleanupOldEpochs(deviceId: String, currentEpoch: UInt32) {
        // Implementation would clean up old epochs beyond maxCachedEpochs
        // Simplified for now
    }
}

