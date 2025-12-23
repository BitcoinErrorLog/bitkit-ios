//
//  KeyManager.swift
//  Bitkit
//
//  Manages device identity and X25519 noise keys for Paykit
//  Ed25519 master keys are owned by Pubky Ring - Bitkit only caches derived keys
//

import Foundation
// PaykitMobile types are available from FFI/PaykitMobile.swift

/// Manages device identity and X25519 noise keys for Paykit
/// 
/// SECURITY: Ed25519 master keys are owned exclusively by Pubky Ring.
/// Bitkit only stores:
/// - Public key (z-base32) for identification
/// - Device ID for key derivation context
/// - Epoch for key rotation
/// - Cached X25519 noise keypairs (derived by Ring)
public final class PaykitKeyManager {
    
    public static let shared = PaykitKeyManager()
    
    private let keychain: PaykitKeychainStorage
    
    private enum Keys {
        static let publicKeyZ32 = "paykit.identity.public.z32"
        static let deviceId = "paykit.device.id"
        static let epoch = "paykit.device.epoch"
        static let noiseKeypairPrefix = "paykit.noise.keypair."
    }
    
    private var deviceId: String {
        if let existing = try? keychain.retrieve(key: Keys.deviceId) {
            return String(data: existing, encoding: .utf8) ?? generateNewDeviceId()
        }
        let newId = generateNewDeviceId()
        try? keychain.store(key: Keys.deviceId, data: newId.data(using: .utf8)!)
        return newId
    }
    
    private var currentEpoch: UInt32 {
        if let epochData = try? keychain.retrieve(key: Keys.epoch),
           let epochStr = String(data: epochData, encoding: .utf8),
           let epoch = UInt32(epochStr) {
            return epoch
        }
        return 0
    }
    
    private init() {
        self.keychain = PaykitKeychainStorage()
    }
    
    // MARK: - Public Key (from Ring)
    
    /// Store public key received from Pubky Ring
    public func storePublicKey(pubkeyZ32: String) throws {
        try keychain.store(key: Keys.publicKeyZ32, data: pubkeyZ32.data(using: .utf8)!)
    }
    
    /// Get current public key in z-base32 format
    public func getCurrentPublicKeyZ32() -> String? {
        guard let data = try? keychain.retrieve(key: Keys.publicKeyZ32),
              let pubkey = String(data: data, encoding: .utf8) else {
            return nil
        }
        return pubkey
    }
    
    /// Check if we have an identity configured
    public var hasIdentity: Bool {
        return getCurrentPublicKeyZ32() != nil
    }
    
    // MARK: - Device Management
    
    /// Get device ID (used for key derivation context)
    public func getDeviceId() -> String {
        return deviceId
    }
    
    /// Get current epoch (used for key rotation)
    public func getCurrentEpoch() -> UInt32 {
        return currentEpoch
    }
    
    /// Set current epoch to a specific value
    /// Used for key rotation when switching to a pre-cached epoch
    public func setCurrentEpoch(_ epoch: UInt32) {
        try? keychain.store(key: Keys.epoch, data: String(epoch).data(using: .utf8)!)
    }
    
    /// Rotate keys by incrementing epoch
    public func rotateKeys() throws {
        let newEpoch = currentEpoch + 1
        try keychain.store(key: Keys.epoch, data: String(newEpoch).data(using: .utf8)!)
    }
    
    // MARK: - X25519 Noise Keypair Caching
    
    /// Cache an X25519 noise keypair received from Pubky Ring
    /// - Parameters:
    ///   - keypair: The X25519 keypair from Ring
    ///   - epoch: The epoch this keypair was derived for
    public func cacheNoiseKeypair(_ keypair: X25519Keypair, epoch: UInt32) throws {
        let key = noiseKeypairKey(epoch: epoch)
        let data = try encodeKeypair(keypair)
        try keychain.store(key: key, data: data)
    }
    
    /// Get cached X25519 noise keypair for a given epoch
    /// - Parameter epoch: The epoch to retrieve keypair for (defaults to current)
    /// - Returns: The cached keypair, or nil if not cached
    public func getCachedNoiseKeypair(epoch: UInt32? = nil) -> X25519Keypair? {
        let epochValue = epoch ?? currentEpoch
        let key = noiseKeypairKey(epoch: epochValue)
        guard let data = try? keychain.retrieve(key: key) else {
            return nil
        }
        return try? decodeKeypair(data)
    }
    
    /// Check if we have a cached noise keypair for the current epoch
    public var hasNoiseKeypair: Bool {
        return getCachedNoiseKeypair() != nil
    }
    
    // MARK: - Cleanup
    
    /// Delete all Paykit identity data
    public func deleteIdentity() throws {
        try? keychain.delete(key: Keys.publicKeyZ32)
        // Clean up noise keypairs for epochs 0-10 (reasonable range)
        for epoch in 0..<10 {
            try? keychain.delete(key: noiseKeypairKey(epoch: UInt32(epoch)))
        }
    }
    
    // MARK: - Private
    
    private func generateNewDeviceId() -> String {
        return UUID().uuidString
    }
    
    private func noiseKeypairKey(epoch: UInt32) -> String {
        return "\(Keys.noiseKeypairPrefix)\(deviceId).\(epoch)"
    }
    
    private func encodeKeypair(_ keypair: X25519Keypair) throws -> Data {
        // Store as JSON for simplicity
        let dict: [String: String] = [
            "publicKeyHex": keypair.publicKeyHex,
            "secretKeyHex": keypair.secretKeyHex
        ]
        return try JSONSerialization.data(withJSONObject: dict)
    }
    
    private func decodeKeypair(_ data: Data) throws -> X25519Keypair {
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let publicKeyHex = dict["publicKeyHex"],
              let secretKeyHex = dict["secretKeyHex"] else {
            throw PaykitKeyError.invalidKeypairData
        }
        return X25519Keypair(publicKeyHex: publicKeyHex, secretKeyHex: secretKeyHex)
    }
}

enum PaykitKeyError: LocalizedError {
    case noIdentity
    case noNoiseKeypair
    case invalidKeypairData
    
    var errorDescription: String? {
        switch self {
        case .noIdentity:
            return "No identity configured. Please connect to Pubky Ring first."
        case .noNoiseKeypair:
            return "No noise keypair available. Please reconnect to Pubky Ring."
        case .invalidKeypairData:
            return "Failed to decode cached keypair data."
        }
    }
}

// Helper extension for Data hex conversion
extension Data {
    init?(hex: String) {
        let len = hex.count / 2
        var data = Data(capacity: len)
        var i = hex.startIndex
        for _ in 0..<len {
            let j = hex.index(i, offsetBy: 2)
            let bytes = hex[i..<j]
            if var num = UInt8(bytes, radix: 16) {
                data.append(&num, count: 1)
            } else {
                return nil
            }
            i = j
        }
        self = data
    }
}
