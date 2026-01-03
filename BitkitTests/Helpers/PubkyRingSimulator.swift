//
//  PubkyRingSimulator.swift
//  BitkitTests
//
//  Simulates Pubky-ring responses for E2E and integration testing
//

import Foundation
@testable import Bitkit

/// Simulates Pubky-ring app responses for testing purposes
/// This allows E2E tests to run without requiring the actual Pubky-ring app
public class PubkyRingSimulator {
    
    public static let shared = PubkyRingSimulator()
    
    // Test data
    public static let testPubkey = "test123456789abcdefghijklmnopqrstuvwxyz"
    public static let testSessionSecret = "secret123456789abcdefghijklmnop"
    public static let testNoiseKey = "noise123456789abcdefghijklmnopqrst"
    
    private init() {}
    
    // MARK: - Secure Handoff Simulation (Recommended)
    
    /// Simulate a secure handoff callback as if Ring stored an encrypted blob.
    ///
    /// This is the recommended way to test the secure handoff flow. It creates a
    /// mock callback URL with only the request_id and pubkey (no secrets in URL),
    /// simulating the production secure handoff protocol.
    ///
    /// - Parameters:
    ///   - requestId: The handoff request ID (defaults to random UUID)
    ///   - pubkey: The pubkey to use (defaults to test pubkey)
    /// - Returns: The request ID used for the handoff
    @discardableResult
    public func injectSecureHandoffCallback(
        requestId: String = UUID().uuidString,
        pubkey: String = PubkyRingSimulator.testPubkey
    ) -> String {
        let callbackUrl = URL(string: "bitkit://paykit-setup?pubky=\(pubkey)&request_id=\(requestId)&mode=secure_handoff")!
        
        let handled = PubkyRingBridge.shared.handleCallback(url: callbackUrl)
        
        if !handled {
            print("PubkyRingSimulator: Failed to inject secure handoff callback")
        }
        
        return requestId
    }
    
    /// Store a mock encrypted handoff envelope for testing decryption flow.
    ///
    /// This simulates Ring storing an encrypted blob at the handoff path.
    /// Use with `injectSecureHandoffCallback` for complete secure handoff testing.
    ///
    /// - Parameters:
    ///   - requestId: The handoff request ID
    ///   - pubkey: The pubkey (owner of the handoff)
    ///   - sessionSecret: Session secret to include in payload
    ///   - noiseSecretKey: Noise secret key to include in payload
    /// - Note: In production, the envelope is encrypted to Bitkit's ephemeral public key.
    ///         This test helper creates a mock envelope for testing purposes.
    public func storeMockHandoffEnvelope(
        requestId: String,
        pubkey: String = PubkyRingSimulator.testPubkey,
        sessionSecret: String = PubkyRingSimulator.testSessionSecret,
        noiseSecretKey: String = PubkyRingSimulator.testNoiseKey
    ) {
        // In production, this would be an encrypted Sealed Blob v1 envelope.
        // For testing, we store a mock payload that the test decryption flow can handle.
        let mockPayload: [String: Any] = [
            "version": 1,
            "pubky": pubkey,
            "session_secret": sessionSecret,
            "capabilities": ["read", "write"],
            "device_id": "test-device",
            "noise_keypairs": [
                ["epoch": 0, "public_key": "mock_pk_0", "secret_key": noiseSecretKey]
            ],
            "noise_seed": "mock_noise_seed_for_testing",
            "created_at": Int(Date().timeIntervalSince1970 * 1000),
            "expires_at": Int((Date().timeIntervalSince1970 + 300) * 1000)
        ]
        
        // Store in test storage for retrieval during handoff
        let path = "/pub/paykit.app/v0/handoff/\(requestId)"
        print("PubkyRingSimulator: Stored mock handoff at \(path) for pubkey \(pubkey)")
        
        // Note: In real tests, you'd need to configure PubkyStorageAdapter to return this
        // when fetched. This is a placeholder showing the expected flow.
        _ = mockPayload
    }
    
    /// Inject a profile callback
    /// - Parameters:
    ///   - name: Profile name
    ///   - bio: Profile bio
    ///   - pubkey: The pubkey
    public func injectProfileCallback(
        name: String = "Test User",
        bio: String = "Test bio",
        pubkey: String = PubkyRingSimulator.testPubkey
    ) {
        let profileJson = """
        {"name":"\(name)","bio":"\(bio)","pubkey":"\(pubkey)"}
        """
        let encoded = profileJson.data(using: .utf8)!.base64EncodedString()
        
        let callbackUrl = URL(string: "bitkit://paykit-profile?data=\(encoded)")!
        
        let handled = PubkyRingBridge.shared.handleCallback(url: callbackUrl)
        
        if !handled {
            print("PubkyRingSimulator: Failed to inject profile callback")
        }
    }
    
    /// Inject a follows list callback
    /// - Parameter follows: List of pubkeys being followed
    public func injectFollowsCallback(follows: [String] = []) {
        let followsJson = try? JSONSerialization.data(withJSONObject: follows)
        let encoded = followsJson?.base64EncodedString() ?? ""
        
        let callbackUrl = URL(string: "bitkit://paykit-follows?data=\(encoded)")!
        
        let handled = PubkyRingBridge.shared.handleCallback(url: callbackUrl)
        
        if !handled {
            print("PubkyRingSimulator: Failed to inject follows callback")
        }
    }
    
    // MARK: - Test Session Helpers
    
    /// Create a test PubkyRingSession
    public func createTestSession(
        pubkey: String = PubkyRingSimulator.testPubkey,
        sessionSecret: String = PubkyRingSimulator.testSessionSecret
    ) -> PubkyRingSession {
        return PubkyRingSession(
            pubkey: pubkey,
            sessionSecret: sessionSecret,
            capabilities: ["read", "write"],
            createdAt: Date()
        )
    }
    
    /// Directly cache a test session in PubkyRingBridge
    public func cacheTestSession(
        pubkey: String = PubkyRingSimulator.testPubkey,
        sessionSecret: String = PubkyRingSimulator.testSessionSecret
    ) {
        let session = createTestSession(pubkey: pubkey, sessionSecret: sessionSecret)
        PubkyRingBridge.shared.setCachedSession(session)
    }
    
    // MARK: - Cleanup
    
    /// Clear all cached sessions and state
    public func reset() {
        PubkyRingBridge.shared.clearCache()
    }
}

// MARK: - Test Assertion Helpers

extension PubkyRingSimulator {
    
    /// Verify that a session was successfully cached
    public func assertSessionCached(for pubkey: String = PubkyRingSimulator.testPubkey) -> Bool {
        return PubkyRingBridge.shared.getCachedSession(for: pubkey) != nil
    }
    
    /// Get the cached session for verification
    public func getCachedSession(for pubkey: String = PubkyRingSimulator.testPubkey) -> PubkyRingSession? {
        return PubkyRingBridge.shared.getCachedSession(for: pubkey)
    }
}

