//
//  KeyManager.swift
//  Bitkit
//
//  Manages Ed25519 identity keys and X25519 device keys for Paykit
//  Uses Bitkit's Keychain for secure storage
//

import Foundation
// PaykitMobile types are available from FFI/PaykitMobile.swift

/// Manages Ed25519 identity keys and X25519 device keys for Paykit
public final class PaykitKeyManager {
    
    public static let shared = PaykitKeyManager()
    
    private let keychain: PaykitKeychainStorage
    
    private enum Keys {
        static let secretKey = "paykit.identity.secret"
        static let publicKey = "paykit.identity.public"
        static let publicKeyZ32 = "paykit.identity.public.z32"
        static let deviceId = "paykit.device.id"
        static let epoch = "paykit.device.epoch"
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
    
    /// Get or create Ed25519 identity
    public func getOrCreateIdentity() async throws -> Ed25519Keypair {
        if let secretData = try? keychain.retrieve(key: Keys.secretKey),
           let secretHex = String(data: secretData, encoding: .utf8) {
            return try ed25519KeypairFromSecret(secretKeyHex: secretHex)
        }
        return try await generateNewIdentity()
    }
    
    /// Generate a new Ed25519 identity
    public func generateNewIdentity() async throws -> Ed25519Keypair {
        let keypair = try generateEd25519Keypair()
        
        // Store in keychain
        try keychain.store(key: Keys.secretKey, data: keypair.secretKeyHex.data(using: .utf8)!)
        try keychain.store(key: Keys.publicKey, data: keypair.publicKeyHex.data(using: .utf8)!)
        try keychain.store(key: Keys.publicKeyZ32, data: keypair.publicKeyZ32.data(using: .utf8)!)
        
        return keypair
    }
    
    /// Get current public key in z-base32 format
    public func getCurrentPublicKeyZ32() -> String? {
        guard let data = try? keychain.retrieve(key: Keys.publicKeyZ32),
              let pubkey = String(data: data, encoding: .utf8) else {
            return nil
        }
        return pubkey
    }
    
    /// Get current secret key hex
    public func getSecretKeyHex() -> String? {
        guard let data = try? keychain.retrieve(key: Keys.secretKey),
              let secret = String(data: data, encoding: .utf8) else {
            return nil
        }
        return secret
    }
    
    /// Get secret key as bytes
    public func getSecretKeyBytes() -> Data? {
        guard let hex = getSecretKeyHex() else { return nil }
        return Data(hex: hex)
    }
    
    /// Derive X25519 keypair for Noise protocol
    public func deriveNoiseKeypair(epoch: UInt32? = nil) async throws -> X25519Keypair {
        guard let secretHex = getSecretKeyHex() else {
            throw PaykitKeyError.noIdentity
        }
        let deviceIdValue = self.deviceId
        let epochValue = epoch ?? currentEpoch
        
        return try deriveX25519Keypair(
            ed25519SecretHex: secretHex,
            deviceId: deviceIdValue,
            epoch: epochValue
        )
    }
    
    /// Get device ID
    public func getDeviceId() -> String {
        return deviceId
    }
    
    /// Get current epoch
    public func getCurrentEpoch() -> UInt32 {
        return currentEpoch
    }
    
    /// Rotate keys by incrementing epoch
    public func rotateKeys() async throws {
        let newEpoch = currentEpoch + 1
        try keychain.store(key: Keys.epoch, data: String(newEpoch).data(using: .utf8)!)
    }
    
    /// Set current epoch
    public func setCurrentEpoch(_ epoch: UInt32) {
        try? keychain.store(key: Keys.epoch, data: String(epoch).data(using: .utf8)!)
    }
    
    /// Set current public key (z32 format) - used when receiving from Pubky-ring callback
    public func setCurrentPublicKey(z32 pubkey: String) {
        try? keychain.store(key: Keys.publicKeyZ32, data: pubkey.data(using: .utf8)!)
    }
    
    /// Delete identity
    public func deleteIdentity() throws {
        try? keychain.delete(key: Keys.secretKey)
        try? keychain.delete(key: Keys.publicKey)
        try? keychain.delete(key: Keys.publicKeyZ32)
    }
    
    /// Clear all identity and device keys
    public func clearAllKeys() {
        Logger.info("Clearing all Paykit keys", context: "KeyManager")
        
        // Delete all paykit-related keys using bulk delete (handles both namespaces)
        keychain.deleteAllWithPrefix("paykit.")
        
        Logger.info("Cleared all Paykit keys from keychain", context: "KeyManager")
    }
    
    /// Clear cached noise keypairs for all epochs
    public func clearNoiseKeyCache() {
        Logger.info("Clearing noise keypair cache", context: "KeyManager")
        keychain.deleteAllWithPrefix("paykit.noise.")
    }
    
    // MARK: - Noise Keypair Cache
    
    private enum NoiseKeypairKeys {
        static func secretKey(epoch: UInt32) -> String { "paykit.noise.\(epoch).secret" }
        static func publicKey(epoch: UInt32) -> String { "paykit.noise.\(epoch).public" }
    }
    
    /// Get cached noise keypair for current or specified epoch
    public func getCachedNoiseKeypair(epoch: UInt32? = nil) -> CachedNoiseKeypair? {
        let epochValue = epoch ?? currentEpoch
        
        guard let secretData = try? keychain.retrieve(key: NoiseKeypairKeys.secretKey(epoch: epochValue)),
              let publicData = try? keychain.retrieve(key: NoiseKeypairKeys.publicKey(epoch: epochValue)) else {
            return nil
        }
        
        // Data is stored as 32-byte binary, convert to hex strings for the keypair struct
        let secretKey = secretData.hex
        let publicKey = publicData.hex
        
        return CachedNoiseKeypair(secretKey: secretKey, publicKey: publicKey, epoch: epochValue)
    }
    
    /// Cache noise keypair for an epoch
    public func cacheNoiseKeypair(_ keypair: CachedNoiseKeypair) {
        // CRITICAL: keypair keys are hex strings (64 chars). Decode to 32-byte binary data.
        let secretData = keypair.secretKey.hexaData
        let publicData = keypair.publicKey.hexaData
        
        guard secretData.count == 32, publicData.count == 32 else {
            Logger.warn("Invalid noise keypair lengths: secret=\(secretData.count), public=\(publicData.count)", context: "KeyManager")
            return
        }
        
        try? keychain.store(key: NoiseKeypairKeys.secretKey(epoch: keypair.epoch), data: secretData)
        try? keychain.store(key: NoiseKeypairKeys.publicKey(epoch: keypair.epoch), data: publicData)
    }
    
    // MARK: - Private
    
    private func generateNewDeviceId() -> String {
        return UUID().uuidString
    }
}

enum PaykitKeyError: LocalizedError {
    case noIdentity
    
    var errorDescription: String? {
        switch self {
        case .noIdentity:
            return "No identity configured. Please set up your identity first."
        }
    }
}

/// Cached X25519 noise keypair
public struct CachedNoiseKeypair {
    public let secretKey: String // Hex-encoded
    public let publicKey: String // Hex-encoded
    public let epoch: UInt32
    
    public init(secretKey: String, publicKey: String, epoch: UInt32) {
        self.secretKey = secretKey
        self.publicKey = publicKey
        self.epoch = epoch
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
