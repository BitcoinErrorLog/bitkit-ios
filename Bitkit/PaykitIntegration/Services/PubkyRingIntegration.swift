//
//  PubkyRingIntegration.swift
//  Bitkit
//
//  Pubky Ring Integration for X25519 noise keypair retrieval
//  X25519 keys are derived by Ring and cached locally - no local derivation
//

import Foundation
// PaykitMobile types are available from FFI/PaykitMobile.swift

/// Integration for X25519 keypair retrieval from Pubky Ring
/// 
/// SECURITY: All key derivation happens in Pubky Ring.
/// This class only retrieves cached keypairs that were received via Ring callbacks.
/// If no cached keypair is available, callers must request new keys from Ring.
public final class PubkyRingIntegration {
    
    public static let shared = PubkyRingIntegration()
    
    private let keyManager: PaykitKeyManager
    private let noiseKeyCache: NoiseKeyCache
    
    private init() {
        self.keyManager = PaykitKeyManager.shared
        self.noiseKeyCache = NoiseKeyCache.shared
    }
    
    /// Get cached X25519 keypair for the given epoch
    /// 
    /// This retrieves a keypair that was previously received from Pubky Ring.
    /// If no keypair is cached, the caller should request new keys via PubkyRingBridge.
    ///
    /// - Parameters:
    ///   - deviceId: The device ID used for derivation context
    ///   - epoch: The epoch for this keypair
    /// - Returns: The cached keypair
    /// - Throws: PaykitRingError.noKeypairCached if no keypair is available
    public func getCachedKeypair(deviceId: String, epoch: UInt32) throws -> X25519Keypair {
        // First check NoiseKeyCache (legacy cache)
        if let cachedSecret = noiseKeyCache.getKey(deviceId: deviceId, epoch: epoch) {
            // We have a cached secret but need the full keypair
            // Check KeyManager for full keypair
            if let keypair = keyManager.getCachedNoiseKeypair(epoch: epoch) {
                return keypair
            }
        }
        
        // Check KeyManager directly
        if let keypair = keyManager.getCachedNoiseKeypair(epoch: epoch) {
            return keypair
        }
        
        throw PaykitRingError.noKeypairCached(
            "No X25519 keypair cached for epoch \(epoch). Please reconnect to Pubky Ring."
        )
    }
    
    /// Get the current noise keypair (for current epoch)
    /// - Returns: The cached keypair for current epoch
    /// - Throws: PaykitRingError.noKeypairCached if no keypair is available
    public func getCurrentKeypair() throws -> X25519Keypair {
        let deviceId = keyManager.getDeviceId()
        let epoch = keyManager.getCurrentEpoch()
        return try getCachedKeypair(deviceId: deviceId, epoch: epoch)
    }
    
    /// Check if we have a cached keypair for the current epoch
    public var hasCurrentKeypair: Bool {
        return keyManager.hasNoiseKeypair
    }
    
    /// Get or refresh X25519 keypair with automatic cache miss recovery
    ///
    /// If the keypair is cached, returns it immediately.
    /// If not cached, automatically requests new setup from Ring.
    ///
    /// - Parameters:
    ///   - deviceId: The device ID used for derivation context
    ///   - epoch: The epoch for this keypair
    /// - Returns: The keypair (either cached or freshly retrieved)
    /// - Throws: PubkyRingError if Ring request fails
    public func getOrRefreshKeypair(deviceId: String, epoch: UInt32) async throws -> X25519Keypair {
        // Try cache first
        if let cached = try? getCachedKeypair(deviceId: deviceId, epoch: epoch) {
            return cached
        }
        
        // Cache miss - request new setup from Ring
        Logger.warn("Keypair cache miss for epoch \(epoch), requesting from Ring", context: "PubkyRingIntegration")
        let result = try await PubkyRingBridge.shared.requestPaykitSetup()
        
        // The bridge callback handler will have cached the result
        // Try retrieving again
        if let cached = try? getCachedKeypair(deviceId: deviceId, epoch: epoch) {
            return cached
        }
        
        // Still not available - this shouldn't happen
        throw PaykitRingError.noKeypairCached(
            "Failed to refresh keypair from Ring for epoch \(epoch)"
        )
    }
    
    /// Get the current keypair with automatic refresh on cache miss
    /// - Returns: The cached or refreshed keypair for current epoch
    /// - Throws: PubkyRingError if Ring request fails
    public func getCurrentKeypairOrRefresh() async throws -> X25519Keypair {
        let deviceId = keyManager.getDeviceId()
        let epoch = keyManager.getCurrentEpoch()
        return try await getOrRefreshKeypair(deviceId: deviceId, epoch: epoch)
    }
    
    /// Cache a keypair received from Pubky Ring
    /// Called by PubkyRingBridge when receiving keypairs via callback
    public func cacheKeypair(_ keypair: X25519Keypair, deviceId: String, epoch: UInt32) throws {
        // Store in KeyManager (primary cache)
        try keyManager.cacheNoiseKeypair(keypair, epoch: epoch)
        
        // Also store secret in NoiseKeyCache for backward compatibility
        if let secretBytes = Data(hex: keypair.secretKeyHex) {
            noiseKeyCache.setKey(secretBytes, deviceId: deviceId, epoch: epoch)
        }
    }
}

enum PaykitRingError: LocalizedError {
    case noIdentity(String)
    case noKeypairCached(String)
    case derivationFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .noIdentity(let msg):
            return msg
        case .noKeypairCached(let msg):
            return msg
        case .derivationFailed(let msg):
            return "Failed to derive X25519 keypair: \(msg)"
        }
    }
}
