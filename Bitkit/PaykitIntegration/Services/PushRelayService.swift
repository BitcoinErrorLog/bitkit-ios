//
//  PushRelayService.swift
//  Bitkit
//
//  Client for the private push relay service.
//  Handles secure registration and sending of wake notifications.
//
//  The push relay service stores push tokens server-side (never publicly)
//  and forwards authorized wake notifications to APNs.
//
//  Benefits over public publishing:
//  - Tokens never exposed publicly (no DoS via spam)
//  - Rate limiting at relay level
//  - Sender authentication required
//

import Foundation
import CryptoKit

public final class PushRelayService {
    
    public static let shared = PushRelayService()
    
    // MARK: - Constants
    
    private static let productionURL = "https://push.paykit.app/v1"
    private static let stagingURL = "https://push-staging.paykit.app/v1"
    
    private static func getBaseUrl() -> String {
        if let envUrl = ProcessInfo.processInfo.environment["PUSH_RELAY_URL"] {
            return envUrl
        }
        #if DEBUG
        return stagingURL
        #else
        return productionURL
        #endif
    }
    
    private static func isEnabled() -> Bool {
        return ProcessInfo.processInfo.environment["PUSH_RELAY_ENABLED"] != "false"
    }
    
    // MARK: - Types
    
    public enum WakeType: String, Codable {
        case noiseConnect = "noise_connect"
        case paymentReceived = "payment_received"
        case channelUpdate = "channel_update"
        case paymentRequest = "payment_request"
        case subscriptionDue = "subscription_due"
    }
    
    public struct RegistrationResponse: Codable {
        public let status: String
        public let relayId: String
        public let expiresAt: Int64
        
        enum CodingKeys: String, CodingKey {
            case status
            case relayId = "relay_id"
            case expiresAt = "expires_at"
        }
    }
    
    public struct WakeResponse: Codable {
        public let status: String
        public let wakeId: String?
        
        enum CodingKeys: String, CodingKey {
            case status
            case wakeId = "wake_id"
        }
    }
    
    public enum PushRelayError: LocalizedError {
        case notConfigured
        case invalidSignature
        case rateLimited(retryAfterSeconds: Int)
        case recipientNotFound
        case networkError(Error)
        case serverError(String)
        case disabled
        case signingFailed(String)
        
        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Push relay not configured - missing pubkey"
            case .invalidSignature:
                return "Invalid signature for relay request"
            case .rateLimited(let seconds):
                return "Rate limited, retry after \(seconds) seconds"
            case .recipientNotFound:
                return "Recipient not registered for push notifications"
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            case .serverError(let message):
                return "Server error: \(message)"
            case .disabled:
                return "Push relay is disabled"
            case .signingFailed(let message):
                return "Failed to sign message: \(message)"
            }
        }
    }
    
    // MARK: - State
    
    private var currentRelayId: String?
    private var registrationExpiresAt: Date?
    private let urlSession = URLSession.shared
    
    private init() {}
    
    // MARK: - Registration
    
    /// Register device for push notifications via relay.
    ///
    /// - Parameters:
    ///   - token: APNs device token (hex-encoded)
    ///   - capabilities: Notification types to receive
    /// - Returns: Registration response with relay ID and expiry
    public func register(
        token: String,
        capabilities: [String] = ["wake", "payment_received"]
    ) async throws -> RegistrationResponse {
        guard Self.isEnabled() else {
            throw PushRelayError.disabled
        }
        
        guard let pubkey = PaykitKeyManager.shared.getCurrentPublicKeyZ32() else {
            throw PushRelayError.notConfigured
        }
        
        let body: [String: Any] = [
            "platform": "ios",
            "token": token,
            "capabilities": capabilities,
            "device_id": PubkyRingBridge.shared.deviceId
        ]
        
        let response: RegistrationResponse = try await makeAuthenticatedRequest(
            method: "POST",
            path: "/register",
            body: body,
            pubkey: pubkey
        )
        
        currentRelayId = response.relayId
        registrationExpiresAt = Date(timeIntervalSince1970: TimeInterval(response.expiresAt))
        
        Logger.info("PushRelayService: Registered with relay, expires: \(response.expiresAt)", context: "PushRelayService")
        
        return response
    }
    
    /// Unregister from push relay.
    public func unregister() async throws {
        guard Self.isEnabled() else { return }
        
        guard let pubkey = PaykitKeyManager.shared.getCurrentPublicKeyZ32() else {
            throw PushRelayError.notConfigured
        }
        
        let body: [String: Any] = [
            "device_id": PubkyRingBridge.shared.deviceId
        ]
        
        let _: [String: String] = try await makeAuthenticatedRequest(
            method: "DELETE",
            path: "/register",
            body: body,
            pubkey: pubkey
        )
        
        currentRelayId = nil
        registrationExpiresAt = nil
        
        Logger.info("PushRelayService: Unregistered from relay", context: "PushRelayService")
    }
    
    /// Check if registration needs renewal (within 7 days of expiry).
    public var needsRenewal: Bool {
        guard let expiresAt = registrationExpiresAt else { return true }
        let renewalThreshold = expiresAt.addingTimeInterval(-7 * 24 * 60 * 60) // 7 days before expiry
        return Date() > renewalThreshold
    }
    
    // MARK: - Wake Notifications
    
    /// Send a wake notification to a recipient.
    ///
    /// - Parameters:
    ///   - recipientPubkey: The recipient's z32 pubkey
    ///   - wakeType: Type of wake notification
    ///   - payload: Optional encrypted payload
    /// - Returns: Wake response with status
    public func wake(
        recipientPubkey: String,
        wakeType: WakeType,
        payload: Data? = nil
    ) async throws -> WakeResponse {
        guard Self.isEnabled() else {
            throw PushRelayError.disabled
        }
        
        guard let senderPubkey = PaykitKeyManager.shared.getCurrentPublicKeyZ32() else {
            throw PushRelayError.notConfigured
        }
        
        var body: [String: Any] = [
            "recipient_pubkey": recipientPubkey,
            "wake_type": wakeType.rawValue,
            "sender_pubkey": senderPubkey,
            "nonce": generateNonce()
        ]
        
        if let payload = payload {
            body["payload"] = payload.base64EncodedString()
        }
        
        let response: WakeResponse = try await makeAuthenticatedRequest(
            method: "POST",
            path: "/wake",
            body: body,
            pubkey: senderPubkey
        )
        
        let shortPubkey = String(recipientPubkey.prefix(12))
        Logger.debug("PushRelayService: Wake sent to \(shortPubkey)..., status: \(response.status)", context: "PushRelayService")
        
        return response
    }
    
    // MARK: - Private Helpers
    
    private func makeAuthenticatedRequest<T: Decodable>(
        method: String,
        path: String,
        body: [String: Any],
        pubkey: String
    ) async throws -> T {
        let urlString = Self.getBaseUrl() + path
        guard let url = URL(string: urlString) else {
            throw PushRelayError.serverError("Invalid URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        
        // Serialize body
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        
        // Add authentication headers
        let timestamp = Int64(Date().timeIntervalSince1970)
        let bodyHash = sha256Hex(bodyData)
        let message = "\(method):\(path):\(timestamp):\(bodyHash)"
        
        // Sign with Ed25519 via Pubky Ring (Ring holds secret key)
        let signature = try await signMessage(message, pubkey: pubkey)
        
        request.setValue(signature, forHTTPHeaderField: "X-Pubky-Signature")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-Pubky-Timestamp")
        request.setValue(pubkey, forHTTPHeaderField: "X-Pubky-Pubkey")
        
        // Send request
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw PushRelayError.networkError(error)
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PushRelayError.serverError("Invalid response")
        }
        
        // Handle response
        switch httpResponse.statusCode {
        case 200, 201:
            return try JSONDecoder().decode(T.self, from: data)
        case 401:
            throw PushRelayError.invalidSignature
        case 404:
            throw PushRelayError.recipientNotFound
        case 429:
            let retryAfter = Int(httpResponse.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60
            throw PushRelayError.rateLimited(retryAfterSeconds: retryAfter)
        default:
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw PushRelayError.serverError(errorBody)
        }
    }
    
    private func signMessage(_ message: String, pubkey: String) async throws -> String {
        // Request Ed25519 signature from Pubky Ring
        // Ring holds the secret key and performs the signing
        do {
            return try await PubkyRingBridge.shared.requestSignature(message: message)
        } catch {
            throw PushRelayError.signingFailed(error.localizedDescription)
        }
    }
    
    private func sha256Hex(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    private func generateNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

