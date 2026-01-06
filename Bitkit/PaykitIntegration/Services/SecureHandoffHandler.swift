//
//  SecureHandoffHandler.swift
//  Bitkit
//
//  Handles secure handoff payload fetching and processing for cross-device authentication.
//  When Pubky-ring uses secure handoff mode, it stores the session and noise keys on the
//  homeserver at an unguessable path. This handler fetches and processes that payload.
//

import Foundation

// MARK: - Data Models

/// Payload structure stored on homeserver by Pubky-ring during secure handoff
/// NOTE: This is the DECRYPTED payload. On homeserver, it's encrypted using Sealed Blob v1.
public struct SecureHandoffPayload: Codable {
    public let version: Int
    public let pubky: String
    public let sessionSecret: String
    public let capabilities: [String]
    public let deviceId: String
    public let noiseKeypairs: [NoiseKeypairPayload]
    /// Noise seed for local epoch derivation (so Bitkit doesn't need to re-call Ring)
    public let noiseSeed: String?
    public let createdAt: Int64
    public let expiresAt: Int64
    /// The homeserver URL this session was created for (optional, from Pubky Ring)
    public let homeserverUrl: String?
    
    enum CodingKeys: String, CodingKey {
        case version, pubky, capabilities
        case sessionSecret = "session_secret"
        case deviceId = "device_id"
        case noiseKeypairs = "noise_keypairs"
        case noiseSeed = "noise_seed"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case homeserverUrl = "homeserver_url"
    }
    
    public init(
        version: Int,
        pubky: String,
        sessionSecret: String,
        capabilities: [String],
        deviceId: String,
        noiseKeypairs: [NoiseKeypairPayload],
        noiseSeed: String? = nil,
        createdAt: Int64,
        expiresAt: Int64,
        homeserverUrl: String? = nil
    ) {
        self.version = version
        self.pubky = pubky
        self.sessionSecret = sessionSecret
        self.capabilities = capabilities
        self.deviceId = deviceId
        self.noiseKeypairs = noiseKeypairs
        self.noiseSeed = noiseSeed
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.homeserverUrl = homeserverUrl
    }
}

/// Sealed Blob v1 envelope structure (encrypted handoff data)
public struct SealedBlobEnvelope: Codable {
    public let v: Int
    public let epk: String
    public let nonce: String
    public let ct: String
    public let kid: String?
    public let purpose: String?
}

/// Noise keypair payload from handoff
public struct NoiseKeypairPayload: Codable {
    public let epoch: Int
    public let publicKey: String
    public let secretKey: String
    
    enum CodingKeys: String, CodingKey {
        case epoch
        case publicKey = "public_key"
        case secretKey = "secret_key"
    }
    
    public init(epoch: Int, publicKey: String, secretKey: String) {
        self.epoch = epoch
        self.publicKey = publicKey
        self.secretKey = secretKey
    }
}

/// Result of processing a secure handoff payload
public struct PaykitSetupResult {
    public let session: PubkyRingSession
    public let deviceId: String
    public let noiseKeypair0: NoiseKeypair?
    public let noiseKeypair1: NoiseKeypair?
    /// Noise seed for local epoch derivation (so Bitkit doesn't need to re-call Ring)
    public let noiseSeed: String?
    
    public init(
        session: PubkyRingSession,
        deviceId: String,
        noiseKeypair0: NoiseKeypair?,
        noiseKeypair1: NoiseKeypair?,
        noiseSeed: String? = nil
    ) {
        self.session = session
        self.deviceId = deviceId
        self.noiseKeypair0 = noiseKeypair0
        self.noiseKeypair1 = noiseKeypair1
        self.noiseSeed = noiseSeed
    }
}

// MARK: - Errors

public enum SecureHandoffError: Error, LocalizedError, Equatable {
    case payloadNotFound
    case payloadExpired
    case invalidPayload
    case deletionFailed
    case decryptionFailed(String)
    case missingEphemeralKey
    case networkError(String)
    
    public var errorDescription: String? {
        switch self {
        case .payloadNotFound:
            return "Handoff payload not found on homeserver"
        case .payloadExpired:
            return "Handoff payload has expired"
        case .invalidPayload:
            return "Invalid handoff payload format"
        case .deletionFailed:
            return "Failed to delete handoff payload"
        case .decryptionFailed(let message):
            return "Decryption failed: \(message)"
        case .missingEphemeralKey:
            return "Ephemeral key not found - cannot decrypt handoff"
        case .networkError(let message):
            return "Network error: \(message)"
        }
    }
    
    public static func == (lhs: SecureHandoffError, rhs: SecureHandoffError) -> Bool {
        switch (lhs, rhs) {
        case (.payloadNotFound, .payloadNotFound),
             (.payloadExpired, .payloadExpired),
             (.invalidPayload, .invalidPayload),
             (.deletionFailed, .deletionFailed),
             (.missingEphemeralKey, .missingEphemeralKey):
            return true
        case (.decryptionFailed(let a), .decryptionFailed(let b)):
            return a == b
        case (.networkError(let a), .networkError(let b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - Handler

/// Handles secure handoff payload fetching and processing for cross-device authentication
public final class SecureHandoffHandler {
    
    public static let shared = SecureHandoffHandler()
    
    private let noiseKeyCache = NoiseKeyCache.shared
    private let keychainStorage = PaykitKeychainStorage()
    
    /// Keychain key for storing ephemeral secret key during handoff
    private let ephemeralKeyKeychainKey = "paykit.ephemeral_handoff_key"
    
    private init() {}
    
    /// Store ephemeral secret key for handoff decryption
    ///
    /// Called before initiating the Ring request. The secret key is stored temporarily
    /// and deleted after successful decryption.
    ///
    /// - Parameter secretKey: Ephemeral X25519 secret key as hex string (64 chars = 32 bytes)
    public func storeEphemeralKey(_ secretKey: String) {
        // CRITICAL: secretKey is a hex string (64 chars). Decode to 32-byte binary data.
        let data = secretKey.hexaData
        guard data.count == 32 else {
            Logger.warn("Invalid ephemeral key length \(data.count), expected 32", context: "SecureHandoffHandler")
            return
        }
        keychainStorage.set(key: ephemeralKeyKeychainKey, value: data)
        Logger.debug("Stored ephemeral handoff key (\(data.count) bytes)", context: "SecureHandoffHandler")
    }
    
    /// Get stored ephemeral secret key as hex string
    private func getEphemeralKey() -> String? {
        guard let data = keychainStorage.get(key: ephemeralKeyKeychainKey) else {
            return nil
        }
        // Data is stored as 32-byte binary, convert back to hex string
        return data.hex
    }
    
    /// Clear ephemeral secret key (zeroize after use)
    private func clearEphemeralKey() {
        keychainStorage.deleteQuietly(key: ephemeralKeyKeychainKey)
        Logger.debug("Cleared ephemeral handoff key", context: "SecureHandoffHandler")
    }
    
    /// Fetch and process secure handoff payload from homeserver
    ///
    /// - Parameters:
    ///   - pubkey: The pubkey that owns the handoff payload
    ///   - requestId: The unique request ID for the handoff (256-bit random)
    ///   - ephemeralSecretKey: Optional ephemeral secret key for decryption (if not provided, uses stored key)
    /// - Returns: PaykitSetupResult containing session and noise keypairs
    /// - Throws: SecureHandoffError if fetch or processing fails
    public func fetchAndProcessPayload(
        pubkey: String,
        requestId: String,
        ephemeralSecretKey: String? = nil,
        homeserverPubkey: String? = nil
    ) async throws -> PaykitSetupResult {
        Logger.info("Fetching secure handoff payload for \(pubkey.prefix(12))...", context: "SecureHandoffHandler")
        
        // Resolve homeserver URL upfront - we'll need it for both fetching AND for the session
        let resolvedHomeserverURL = PubkyConfig.homeserverBaseURL(for: homeserverPubkey ?? PubkyConfig.defaultHomeserver)
        Logger.debug("Resolved homeserver URL: \(resolvedHomeserverURL)", context: "SecureHandoffHandler")
        
        // Get ephemeral key (from parameter or stored)
        let secretKey = ephemeralSecretKey ?? getEphemeralKey()
        
        // 1. Fetch encrypted envelope from homeserver
        let payload = try await fetchHandoffPayload(
            pubkey: pubkey,
            requestId: requestId,
            ephemeralSecretKey: secretKey,
            homeserverPubkey: homeserverPubkey
        )
        
        // 2. Clear ephemeral key now that we've decrypted
        if ephemeralSecretKey == nil {
            clearEphemeralKey()
        }
        
        // 3. Validate expiration
        try validatePayload(payload)
        
        // 4. Build result - use resolved homeserver URL (payload.homeserverUrl might be nil)
        let result = buildSetupResult(from: payload, homeserverURL: resolvedHomeserverURL)
        
        // 5. Cache session and noise keys
        try cacheAndPersistResult(result, deviceId: payload.deviceId)
        
        // 6. Schedule payload deletion (cleanup)
        Task {
            await deletePayloadQuietly(pubkey: pubkey, requestId: requestId, sessionSecret: result.session.sessionSecret)
        }
        
        // 7. Verify Ring published the Noise endpoint (non-blocking diagnostic)
        Task {
            let noisePublished = await verifyNoiseEndpointPublished(pubkey: pubkey)
            if !noisePublished {
                Logger.warn(
                    "Noise endpoint was not published by Ring - encrypted payment channels may not work",
                    context: "SecureHandoffHandler"
                )
            }
        }
        
        Logger.info("Secure handoff completed for \(pubkey.prefix(12))...", context: "SecureHandoffHandler")
        return result
    }
    
    /// Validate that a payload has not expired
    /// - Throws: SecureHandoffError.payloadExpired if expired
    public func validatePayload(_ payload: SecureHandoffPayload) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if now > payload.expiresAt {
            Logger.warn("Handoff payload expired: now=\(now), expiresAt=\(payload.expiresAt)", context: "SecureHandoffHandler")
            throw SecureHandoffError.payloadExpired
        }
    }
    
    // MARK: - Private Methods
    
    private func fetchHandoffPayload(
        pubkey: String,
        requestId: String,
        ephemeralSecretKey: String?,
        homeserverPubkey: String? = nil
    ) async throws -> SecureHandoffPayload {
        let handoffPath = "/pub/paykit.app/v0/handoff/\(requestId)"
        
        // Resolve homeserver URL - use provided pubkey or fall back to default
        // The homeserver pubkey is passed from Ring's callback for iOS compatibility
        let homeserverURL = PubkyConfig.homeserverBaseURL(for: homeserverPubkey ?? PubkyConfig.defaultHomeserver)
        Logger.debug("Fetching handoff from \(homeserverURL)\(handoffPath) for pubkey \(pubkey.prefix(16))...", context: "SecureHandoffHandler")
        
        let adapter = PubkyUnauthenticatedStorageAdapter(
            homeserverBaseURL: homeserverURL
        )
        
        let data = try await PubkyStorageAdapter.shared.readFile(
            path: handoffPath,
            adapter: adapter,
            ownerPubkey: pubkey
        )
        
        guard let payloadData = data else {
            Logger.warn("Handoff payload not found for request \(requestId.prefix(16))...", context: "SecureHandoffHandler")
            throw SecureHandoffError.payloadNotFound
        }
        
        // SECURITY: Require encrypted sealed blob - no plaintext fallback
        guard let envelopeString = String(data: payloadData, encoding: .utf8),
              isSealedBlob(envelopeString) else {
            Logger.error("Handoff payload is not an encrypted sealed blob - rejecting", context: "SecureHandoffHandler")
            throw SecureHandoffError.invalidPayload
        }
        
        Logger.debug("Detected encrypted sealed blob envelope", context: "SecureHandoffHandler")
        return try await decryptHandoffEnvelope(
            envelopeJson: envelopeString,
            pubkey: pubkey,
            requestId: requestId,
            ephemeralSecretKey: ephemeralSecretKey
        )
    }
    
    /// Decrypt sealed blob envelope using ephemeral secret key
    private func decryptHandoffEnvelope(
        envelopeJson: String,
        pubkey: String,
        requestId: String,
        ephemeralSecretKey: String?
    ) async throws -> SecureHandoffPayload {
        guard let secretKey = ephemeralSecretKey else {
            Logger.error("Ephemeral key required for decryption but not found", context: "SecureHandoffHandler")
            throw SecureHandoffError.missingEphemeralKey
        }
        
        // Build AAD following Paykit v0 protocol: paykit:v0:handoff:{pubkey}:{path}:{requestId}
        let storagePath = "/pub/paykit.app/v0/handoff/\(requestId)"
        let aad = "paykit:v0:handoff:\(pubkey):\(storagePath):\(requestId)"
        
        do {
            // Convert secret key from hex to Data
            guard let secretKeyData = Data(hexString: secretKey) else {
                throw SecureHandoffError.decryptionFailed("Invalid secret key hex")
            }
            
            // Decrypt using pubky-noise sealed blob
            let plaintextData = try sealedBlobDecrypt(
                recipientSk: secretKeyData,
                envelopeJson: envelopeJson,
                aad: aad
            )
            
            // Decode decrypted JSON
            let payload = try JSONDecoder().decode(SecureHandoffPayload.self, from: plaintextData)
            Logger.info("Successfully decrypted handoff payload v\(payload.version)", context: "SecureHandoffHandler")
            return payload
        } catch let error as SecureHandoffError {
            throw error
        } catch {
            Logger.error("Sealed blob decryption failed: \(error)", context: "SecureHandoffHandler")
            throw SecureHandoffError.decryptionFailed(error.localizedDescription)
        }
    }
    
    /// Check if JSON looks like a sealed blob envelope
    private func isSealedBlob(_ json: String) -> Bool {
        json.contains("\"v\":1") || json.contains("\"v\": 1")
    }
    
    private func buildSetupResult(from payload: SecureHandoffPayload, homeserverURL: String) -> PaykitSetupResult {
        let session = PubkyRingSession(
            pubkey: payload.pubky,
            sessionSecret: payload.sessionSecret,
            capabilities: payload.capabilities,
            createdAt: Date(timeIntervalSince1970: TimeInterval(payload.createdAt) / 1000),
            expiresAt: nil,
            homeserverURL: homeserverURL  // Use resolved URL instead of potentially nil payload value
        )
        
        var keypair0: NoiseKeypair?
        var keypair1: NoiseKeypair?
        
        for kp in payload.noiseKeypairs {
            let keypair = NoiseKeypair(
                publicKey: kp.publicKey,
                secretKey: kp.secretKey,
                deviceId: payload.deviceId,
                epoch: UInt64(kp.epoch)
            )
            
            switch kp.epoch {
            case 0:
                keypair0 = keypair
            case 1:
                keypair1 = keypair
            default:
                Logger.debug("Ignoring keypair for epoch \(kp.epoch)", context: "SecureHandoffHandler")
            }
        }
        
        Logger.info(
            "Built setup result: session=\(payload.pubky.prefix(12))..., keypairs=[\(keypair0 != nil ? "0" : ""), \(keypair1 != nil ? "1" : "")], noiseSeed=\(payload.noiseSeed != nil)",
            context: "SecureHandoffHandler"
        )
        
        return PaykitSetupResult(
            session: session,
            deviceId: payload.deviceId,
            noiseKeypair0: keypair0,
            noiseKeypair1: keypair1,
            noiseSeed: payload.noiseSeed
        )
    }
    
    private func cacheAndPersistResult(_ result: PaykitSetupResult, deviceId: String) throws {
        // Persist noise keypairs
        if let keypair0 = result.noiseKeypair0 {
            persistKeypair(keypair0, deviceId: deviceId, epoch: 0)
        }
        
        if let keypair1 = result.noiseKeypair1 {
            persistKeypair(keypair1, deviceId: deviceId, epoch: 1)
        }
        
        // Persist noise seed for future epoch derivation
        if let noiseSeed = result.noiseSeed {
            persistNoiseSeed(noiseSeed, deviceId: deviceId)
        }
    }
    
    private func persistNoiseSeed(_ noiseSeed: String, deviceId: String) {
        let key = "paykit.noise_seed.\(deviceId)"
        if let data = noiseSeed.data(using: .utf8) {
            keychainStorage.set(key: key, value: data)
            Logger.debug("Persisted noise seed for device \(deviceId.prefix(8))...", context: "SecureHandoffHandler")
        }
    }
    
    /// Get stored noise seed for a device
    public func getNoiseSeed(deviceId: String) -> String? {
        let key = "paykit.noise_seed.\(deviceId)"
        guard let data = keychainStorage.get(key: key) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
    
    private func persistKeypair(_ keypair: NoiseKeypair, deviceId: String, epoch: UInt32) {
        // CRITICAL: keypair.secretKey is a hex string (64 chars). Decode to 32-byte binary data.
        let secretKeyData = keypair.secretKey.hexaData
        guard secretKeyData.count == 32 else {
            Logger.warn("Invalid secret key length \(secretKeyData.count) for epoch \(epoch), expected 32", context: "SecureHandoffHandler")
            return
        }
        
        // Store in NoiseKeyCache (used by PubkyRingIntegration)
        noiseKeyCache.setKey(secretKeyData, deviceId: deviceId, epoch: epoch)
        
        // Also store in PaykitKeyManager cache (used by NoisePaymentService)
        let cachedKeypair = CachedNoiseKeypair(
            secretKey: keypair.secretKey,
            publicKey: keypair.publicKey,
            epoch: epoch
        )
        PaykitKeyManager.shared.cacheNoiseKeypair(cachedKeypair)
        
        Logger.debug("Persisted noise keypair for epoch \(epoch)", context: "SecureHandoffHandler")
    }
    
    private func deletePayloadQuietly(pubkey: String, requestId: String, sessionSecret: String) async {
        let handoffPath = "/pub/paykit.app/v0/handoff/\(requestId)"
        
        do {
            let adapter = PubkyAuthenticatedStorageAdapter(
                sessionSecret: sessionSecret,
                ownerPubkey: pubkey,
                homeserverBaseURL: PubkyConfig.homeserverBaseURL()
            )
            
            try await PubkyStorageAdapter.shared.deleteFile(path: handoffPath, adapter: adapter)
            Logger.info("Deleted secure handoff payload: \(requestId.prefix(16))...", context: "SecureHandoffHandler")
        } catch {
            Logger.warn("Failed to delete handoff payload: \(error.localizedDescription)", context: "SecureHandoffHandler")
        }
    }
    
    // MARK: - Noise Endpoint Verification
    
    /// Verify that Ring published the Noise endpoint during handoff.
    ///
    /// Ring v2 publishes the Noise endpoint using SDK put() which signs with Ed25519.
    /// This verification uses DirectoryService.discoverNoiseEndpoint() to actually parse
    /// the endpoint with the same logic that Bitkit will use later, ensuring schema compatibility.
    ///
    /// - Parameter pubkey: The user's pubkey in z32 format
    /// - Returns: True if the Noise endpoint is discoverable and parseable, false otherwise
    public func verifyNoiseEndpointPublished(pubkey: String) async -> Bool {
        Logger.debug("Verifying Noise endpoint via DirectoryService for \(pubkey.prefix(12))...", context: "SecureHandoffHandler")
        
        do {
            // Use DirectoryService to parse the endpoint - validates schema matches PaykitMobile FFI
            if let endpoint = try await DirectoryService.shared.discoverNoiseEndpoint(for: pubkey) {
                Logger.info(
                    "Verified Noise endpoint for \(pubkey.prefix(12))...: host=\(endpoint.host), port=\(endpoint.port)",
                    context: "SecureHandoffHandler"
                )
                return true
            }
            
            Logger.warn(
                "Noise endpoint not found or invalid schema for \(pubkey.prefix(12))... - Ring may not have published it correctly",
                context: "SecureHandoffHandler"
            )
            return false
        } catch {
            Logger.warn("Error verifying Noise endpoint: \(error.localizedDescription)", context: "SecureHandoffHandler")
            return false
        }
    }
}

// MARK: - Data Extension for Hex

private extension Data {
    init?(hexString: String) {
        let hex = hexString.replacingOccurrences(of: " ", with: "")
        guard hex.count % 2 == 0 else { return nil }
        
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        
        self = data
    }
}

