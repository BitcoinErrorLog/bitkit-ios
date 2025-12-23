//
//  PushRelayService.swift
//  Bitkit
//
//  Private push relay service client for secure wake notifications.
//  Replaces public push token publishing with server-side token storage.
//

import Foundation
import CryptoKit

// MARK: - PushRelayService

/// Client for the private push relay service.
///
/// The push relay service stores push tokens server-side (never publicly)
/// and forwards authorized wake notifications to APNs/FCM.
///
/// Benefits over public publishing:
/// - Tokens never exposed publicly (no DoS via spam)
/// - Rate limiting at relay level
/// - Sender authentication required
public final class PushRelayService {
    
    public static let shared = PushRelayService()
    
    // MARK: - Configuration
    
    /// Relay service base URL
    public var baseURL: String {
        if let envURL = ProcessInfo.processInfo.environment["PUSH_RELAY_URL"] {
            return envURL
        }
        #if DEBUG
        return "https://push-staging.paykit.app/v1"
        #else
        return "https://push.paykit.app/v1"
        #endif
    }
    
    /// Whether to fall back to homeserver discovery during migration
    public var fallbackToHomeserver: Bool {
        ProcessInfo.processInfo.environment["PUSH_RELAY_FALLBACK"] == "true"
    }
    
    /// Whether push relay is enabled
    public var isEnabled: Bool {
        ProcessInfo.processInfo.environment["PUSH_RELAY_ENABLED"] != "false"
    }
    
    // MARK: - State
    
    private var currentRelayId: String?
    private var registrationExpiresAt: Date?
    
    private let keyManager = PaykitKeyManager.shared
    private let urlSession: URLSession
    
    // MARK: - Types
    
    public enum WakeType: String, Codable {
        case noiseConnect = "noise_connect"
        case paymentReceived = "payment_received"
        case channelUpdate = "channel_update"
    }
    
    public struct RegistrationResponse: Codable {
        let status: String
        let relayId: String
        let expiresAt: Int64
        
        enum CodingKeys: String, CodingKey {
            case status
            case relayId = "relay_id"
            case expiresAt = "expires_at"
        }
    }
    
    public struct WakeResponse: Codable {
        let status: String
        let wakeId: String?
        
        enum CodingKeys: String, CodingKey {
            case status
            case wakeId = "wake_id"
        }
    }
    
    public enum PushRelayError: LocalizedError {
        case notConfigured
        case invalidSignature
        case rateLimited(retryAfter: Int)
        case recipientNotFound
        case networkError(Error)
        case serverError(String)
        case disabled
        
        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Push relay not configured - missing pubkey"
            case .invalidSignature:
                return "Invalid signature for relay request"
            case .rateLimited(let retryAfter):
                return "Rate limited, retry after \(retryAfter) seconds"
            case .recipientNotFound:
                return "Recipient not registered for push notifications"
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            case .serverError(let message):
                return "Server error: \(message)"
            case .disabled:
                return "Push relay is disabled"
            }
        }
    }
    
    // MARK: - Initialization
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.urlSession = URLSession(configuration: config)
    }
    
    // MARK: - Registration
    
    /// Register device for push notifications via relay.
    ///
    /// - Parameters:
    ///   - token: APNs device token (hex encoded)
    ///   - capabilities: Notification types to receive
    /// - Returns: Registration response with relay ID and expiry
    public func register(
        token: String,
        capabilities: [String] = ["wake", "payment_received"]
    ) async throws -> RegistrationResponse {
        guard isEnabled else {
            throw PushRelayError.disabled
        }
        
        guard let pubkey = keyManager.getCurrentPublicKeyZ32() else {
            throw PushRelayError.notConfigured
        }
        
        let body: [String: Any] = [
            "platform": "ios",
            "token": token,
            "capabilities": capabilities,
            "device_id": keyManager.getDeviceId()
        ]
        
        let response: RegistrationResponse = try await makeAuthenticatedRequest(
            method: "POST",
            path: "/register",
            body: body,
            pubkey: pubkey
        )
        
        currentRelayId = response.relayId
        registrationExpiresAt = Date(timeIntervalSince1970: Double(response.expiresAt))
        
        Logger.info("Registered with push relay, expires: \(registrationExpiresAt!)", context: "PushRelayService")
        
        return response
    }
    
    /// Unregister from push relay.
    public func unregister() async throws {
        guard isEnabled else { return }
        
        guard let pubkey = keyManager.getCurrentPublicKeyZ32() else {
            throw PushRelayError.notConfigured
        }
        
        let body: [String: Any] = [
            "device_id": keyManager.getDeviceId()
        ]
        
        let _: EmptyResponse = try await makeAuthenticatedRequest(
            method: "DELETE",
            path: "/register",
            body: body,
            pubkey: pubkey
        )
        
        currentRelayId = nil
        registrationExpiresAt = nil
        
        Logger.info("Unregistered from push relay", context: "PushRelayService")
    }
    
    /// Check if registration needs renewal (within 7 days of expiry).
    public var needsRenewal: Bool {
        guard let expiresAt = registrationExpiresAt else { return true }
        let renewalThreshold = expiresAt.addingTimeInterval(-7 * 24 * 60 * 60)
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
        guard isEnabled else {
            throw PushRelayError.disabled
        }
        
        guard let senderPubkey = keyManager.getCurrentPublicKeyZ32() else {
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
        
        Logger.debug("Wake sent to \(recipientPubkey.prefix(12))..., status: \(response.status)", context: "PushRelayService")
        
        return response
    }
    
    // MARK: - Private Helpers
    
    private struct EmptyResponse: Codable {}
    
    private func makeAuthenticatedRequest<T: Codable>(
        method: String,
        path: String,
        body: [String: Any],
        pubkey: String
    ) async throws -> T {
        let url = URL(string: baseURL + path)!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Serialize body
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        
        // Add authentication headers
        let timestamp = Int64(Date().timeIntervalSince1970)
        let bodyHash = SHA256.hash(data: bodyData).compactMap { String(format: "%02x", $0) }.joined()
        let message = "\(method):\(path):\(timestamp):\(bodyHash)"
        
        // Sign with Ed25519 (would use PaykitKeyManager's signing capability)
        // For now, using a placeholder - actual implementation would use Ring's signing
        let signature = try signMessage(message, pubkey: pubkey)
        
        request.setValue(signature, forHTTPHeaderField: "X-Pubky-Signature")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-Pubky-Timestamp")
        request.setValue(pubkey, forHTTPHeaderField: "X-Pubky-Pubkey")
        
        // Make request
        let (data, response) = try await urlSession.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PushRelayError.networkError(URLError(.badServerResponse))
        }
        
        switch httpResponse.statusCode {
        case 200, 201:
            let decoder = JSONDecoder()
            return try decoder.decode(T.self, from: data)
            
        case 401:
            throw PushRelayError.invalidSignature
            
        case 404:
            throw PushRelayError.recipientNotFound
            
        case 429:
            let retryAfter = Int(httpResponse.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60
            throw PushRelayError.rateLimited(retryAfter: retryAfter)
            
        default:
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw PushRelayError.serverError(errorMessage)
        }
    }
    
    private func signMessage(_ message: String, pubkey: String) async throws -> String {
        // Request Ed25519 signature from Pubky Ring
        // Ring holds the secret key and performs the signing
        return try await PubkyRingBridge.shared.requestSignature(message: message)
    }
    
    private func generateNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

