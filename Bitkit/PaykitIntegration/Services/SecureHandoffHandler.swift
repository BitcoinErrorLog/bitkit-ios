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
public struct SecureHandoffPayload: Codable {
    public let version: Int
    public let pubky: String
    public let sessionSecret: String
    public let capabilities: [String]
    public let deviceId: String
    public let noiseKeypairs: [NoiseKeypairPayload]
    public let createdAt: Int64
    public let expiresAt: Int64
    
    enum CodingKeys: String, CodingKey {
        case version, pubky, capabilities
        case sessionSecret = "session_secret"
        case deviceId = "device_id"
        case noiseKeypairs = "noise_keypairs"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }
    
    public init(
        version: Int,
        pubky: String,
        sessionSecret: String,
        capabilities: [String],
        deviceId: String,
        noiseKeypairs: [NoiseKeypairPayload],
        createdAt: Int64,
        expiresAt: Int64
    ) {
        self.version = version
        self.pubky = pubky
        self.sessionSecret = sessionSecret
        self.capabilities = capabilities
        self.deviceId = deviceId
        self.noiseKeypairs = noiseKeypairs
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
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
    
    public init(
        session: PubkyRingSession,
        deviceId: String,
        noiseKeypair0: NoiseKeypair?,
        noiseKeypair1: NoiseKeypair?
    ) {
        self.session = session
        self.deviceId = deviceId
        self.noiseKeypair0 = noiseKeypair0
        self.noiseKeypair1 = noiseKeypair1
    }
}

// MARK: - Errors

public enum SecureHandoffError: Error, LocalizedError, Equatable {
    case payloadNotFound
    case payloadExpired
    case invalidPayload
    case deletionFailed
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
        case .networkError(let message):
            return "Network error: \(message)"
        }
    }
    
    public static func == (lhs: SecureHandoffError, rhs: SecureHandoffError) -> Bool {
        switch (lhs, rhs) {
        case (.payloadNotFound, .payloadNotFound),
             (.payloadExpired, .payloadExpired),
             (.invalidPayload, .invalidPayload),
             (.deletionFailed, .deletionFailed):
            return true
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
    
    private init() {}
    
    /// Fetch and process secure handoff payload from homeserver
    ///
    /// - Parameters:
    ///   - pubkey: The pubkey that owns the handoff payload
    ///   - requestId: The unique request ID for the handoff (256-bit random)
    /// - Returns: PaykitSetupResult containing session and noise keypairs
    /// - Throws: SecureHandoffError if fetch or processing fails
    public func fetchAndProcessPayload(
        pubkey: String,
        requestId: String
    ) async throws -> PaykitSetupResult {
        Logger.info("Fetching secure handoff payload for \(pubkey.prefix(12))...", context: "SecureHandoffHandler")
        
        // 1. Fetch payload from homeserver
        let payload = try await fetchHandoffPayload(pubkey: pubkey, requestId: requestId)
        
        // 2. Validate expiration
        try validatePayload(payload)
        
        // 3. Build result
        let result = buildSetupResult(from: payload)
        
        // 4. Cache session and noise keys
        try cacheAndPersistResult(result, deviceId: payload.deviceId)
        
        // 5. Schedule payload deletion (cleanup)
        Task {
            await deletePayloadQuietly(pubkey: pubkey, requestId: requestId, sessionSecret: result.session.sessionSecret)
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
    
    private func fetchHandoffPayload(pubkey: String, requestId: String) async throws -> SecureHandoffPayload {
        let handoffPath = "/pub/paykit.app/v0/handoff/\(requestId)"
        
        Logger.debug("Fetching handoff from path: \(handoffPath)", context: "SecureHandoffHandler")
        
        let adapter = PubkyUnauthenticatedStorageAdapter(
            homeserverBaseURL: PubkyConfig.homeserverBaseURL()
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
        
        do {
            let payload = try JSONDecoder().decode(SecureHandoffPayload.self, from: payloadData)
            Logger.debug("Successfully decoded handoff payload v\(payload.version)", context: "SecureHandoffHandler")
            return payload
        } catch {
            Logger.error("Failed to decode handoff payload: \(error)", context: "SecureHandoffHandler")
            throw SecureHandoffError.invalidPayload
        }
    }
    
    private func buildSetupResult(from payload: SecureHandoffPayload) -> PaykitSetupResult {
        let session = PubkyRingSession(
            pubkey: payload.pubky,
            sessionSecret: payload.sessionSecret,
            capabilities: payload.capabilities,
            createdAt: Date(timeIntervalSince1970: TimeInterval(payload.createdAt) / 1000),
            expiresAt: nil
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
            "Built setup result: session=\(payload.pubky.prefix(12))..., keypairs=[\(keypair0 != nil ? "0" : ""), \(keypair1 != nil ? "1" : "")]",
            context: "SecureHandoffHandler"
        )
        
        return PaykitSetupResult(
            session: session,
            deviceId: payload.deviceId,
            noiseKeypair0: keypair0,
            noiseKeypair1: keypair1
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
    }
    
    private func persistKeypair(_ keypair: NoiseKeypair, deviceId: String, epoch: UInt32) {
        guard let secretKeyData = keypair.secretKey.data(using: .utf8) else {
            Logger.warn("Failed to encode secret key for epoch \(epoch)", context: "SecureHandoffHandler")
            return
        }
        
        noiseKeyCache.setKey(secretKeyData, deviceId: deviceId, epoch: epoch)
        Logger.debug("Persisted noise keypair for epoch \(epoch)", context: "SecureHandoffHandler")
    }
    
    private func deletePayloadQuietly(pubkey: String, requestId: String, sessionSecret: String) async {
        let handoffPath = "/pub/paykit.app/v0/handoff/\(requestId)"
        
        do {
            let adapter = PubkyAuthenticatedStorageAdapter(
                sessionId: sessionSecret,
                homeserverBaseURL: PubkyConfig.homeserverBaseURL()
            )
            
            try await PubkyStorageAdapter.shared.deleteFile(path: handoffPath, adapter: adapter)
            Logger.info("Deleted secure handoff payload: \(requestId.prefix(16))...", context: "SecureHandoffHandler")
        } catch {
            Logger.warn("Failed to delete handoff payload: \(error.localizedDescription)", context: "SecureHandoffHandler")
        }
    }
}

