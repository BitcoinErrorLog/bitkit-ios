// PubkyRingBridgeTests.swift
// Bitkit iOS Tests
//
// Tests for PubkyRingBridge including cross-device authentication.

import XCTest
@testable import Bitkit

final class PubkyRingBridgeTests: XCTestCase {
    
    var bridge: PubkyRingBridge!
    
    override func setUp() {
        super.setUp()
        bridge = PubkyRingBridge.shared
        bridge.clearCache()
    }
    
    override func tearDown() {
        bridge.clearCache()
        super.tearDown()
    }
    
    // MARK: - Cross-Device Request Generation Tests
    
    func testGenerateCrossDeviceRequestCreatesValidRequest() {
        let request = bridge.generateCrossDeviceRequest()
        
        XCTAssertFalse(request.requestId.isEmpty, "Request ID should not be empty")
        XCTAssertFalse(request.isExpired, "New request should not be expired")
        XCTAssertTrue(request.timeRemaining > 0, "Time remaining should be positive")
        XCTAssertNotNil(request.qrCodeImage, "QR code image should be generated")
    }
    
    func testGenerateCrossDeviceRequestURLContainsRequiredParameters() {
        let request = bridge.generateCrossDeviceRequest()
        let urlString = request.url.absoluteString
        
        XCTAssertTrue(urlString.contains("request_id="), "URL should contain request_id")
        XCTAssertTrue(urlString.contains("callback_scheme=bitkit"), "URL should contain callback_scheme")
        XCTAssertTrue(urlString.contains("app_name=Bitkit"), "URL should contain app_name")
        XCTAssertTrue(urlString.contains("relay_url="), "URL should contain relay_url")
    }
    
    func testGenerateCrossDeviceRequestExpiresAfterFiveMinutes() {
        let request = bridge.generateCrossDeviceRequest()
        let expectedExpiry = Date().addingTimeInterval(300)
        
        // Allow 1 second tolerance
        XCTAssertEqual(request.expiresAt.timeIntervalSince1970, expectedExpiry.timeIntervalSince1970, accuracy: 1.0)
    }
    
    func testMultipleCrossDeviceRequestsHaveUniqueIds() {
        let request1 = bridge.generateCrossDeviceRequest()
        let request2 = bridge.generateCrossDeviceRequest()
        
        XCTAssertNotEqual(request1.requestId, request2.requestId, "Each request should have unique ID")
    }
    
    // MARK: - Authentication Status Tests
    
    func testAuthenticationStatusReturnsCorrectValue() {
        // Note: On simulator, Pubky-ring won't be installed
        let status = bridge.authenticationStatus
        
        // Status should be one of the valid values
        XCTAssertTrue(status == .pubkyRingAvailable || status == .crossDeviceOnly)
    }
    
    func testCanAuthenticateAlwaysReturnsTrue() {
        // Cross-device auth is always available as fallback
        XCTAssertTrue(bridge.canAuthenticate)
    }
    
    func testRecommendedAuthMethodReflectsInstallStatus() {
        let method = bridge.recommendedAuthMethod
        
        // Should be one of the valid methods
        switch method {
        case .sameDevice, .crossDevice, .manual:
            break // All valid
        }
    }
    
    // MARK: - Callback Handling Tests
    
    func testHandleCallbackIgnoresNonBitkitScheme() {
        let url = URL(string: "https://example.com/paykit-session?pubky=test")!
        
        let handled = bridge.handleCallback(url: url)
        
        XCTAssertFalse(handled, "Should not handle non-bitkit scheme")
    }
    
    func testHandleCallbackIgnoresUnknownPath() {
        let url = URL(string: "bitkit://unknown-path?pubky=test")!
        
        let handled = bridge.handleCallback(url: url)
        
        XCTAssertFalse(handled, "Should not handle unknown path")
    }
    
    func testHandleUnknownSessionPathReturnsFalse() {
        // Legacy paykit-session path is no longer supported
        let pubkey = "z6mktest1234567890"
        let secret = "test_secret_12345"
        let url = URL(string: "bitkit://paykit-session?pubky=\(pubkey)&session_secret=\(secret)")!
        
        // Should return false for unknown path
        let handled = bridge.handleCallback(url: url)
        XCTAssertFalse(handled, "Legacy paykit-session path should not be handled")
        
        // Session should NOT be cached
        let cached = bridge.getCachedSession(for: pubkey)
        XCTAssertNil(cached, "Session should not be cached for unknown path")
    }
    
    func testHandlePaykitSetupCallbackReturnsTrueForValidUrl() {
        // paykit-setup requires secure_handoff mode with request_id
        // Without those params, it should still return true (callback was recognized)
        // but will resume with error
        let pubkey = "z6mktest1234567890"
        let secret = "test_secret_12345"
        let deviceId = "test_device_123"
        let url = URL(string: "bitkit://paykit-setup?pubky=\(pubkey)&session_secret=\(secret)&device_id=\(deviceId)")!
        
        let handled = bridge.handleCallback(url: url)
        
        // Should return true because the path was recognized
        XCTAssertTrue(handled, "paykit-setup path should be recognized")
        
        // Session will NOT be cached because secure_handoff params are missing
        let cached = bridge.getCachedSession(for: pubkey)
        XCTAssertNil(cached, "Session should not be cached without secure handoff params")
    }
    
    // MARK: - Cache Management Tests
    
    func testClearCacheRemovesAllSessions() {
        let session1 = PubkyRingSession(
            pubkey: "pubkey1",
            sessionSecret: "secret1",
            capabilities: [],
            createdAt: Date()
        )
        let session2 = PubkyRingSession(
            pubkey: "pubkey2",
            sessionSecret: "secret2",
            capabilities: [],
            createdAt: Date()
        )
        
        bridge.setCachedSession(session1)
        bridge.setCachedSession(session2)
        
        bridge.clearCache()
        
        XCTAssertNil(bridge.getCachedSession(for: "pubkey1"))
        XCTAssertNil(bridge.getCachedSession(for: "pubkey2"))
    }
    
    // MARK: - QR Code Generation Tests
    
    func testQRCodeImageHasCorrectDimensions() {
        let request = bridge.generateCrossDeviceRequest()
        
        guard let image = request.qrCodeImage else {
            XCTFail("QR code image should not be nil")
            return
        }
        
        // QR code should be reasonably sized (scaled up)
        XCTAssertGreaterThan(image.size.width, 100)
        XCTAssertGreaterThan(image.size.height, 100)
    }
    
    // MARK: - Shareable Link Tests
    
    func testGenerateShareableLinkReturnsValidURL() {
        let link = bridge.generateShareableLink()
        
        XCTAssertTrue(link.absoluteString.hasPrefix(PubkyRingBridge.crossDeviceWebUrl))
    }
    
    // MARK: - Error Message Tests
    
    func testPubkyRingErrorUserMessages() {
        XCTAssertFalse(PubkyRingError.appNotInstalled.userMessage.isEmpty)
        XCTAssertFalse(PubkyRingError.timeout.userMessage.isEmpty)
        XCTAssertFalse(PubkyRingError.cancelled.userMessage.isEmpty)
        XCTAssertFalse(PubkyRingError.invalidCallback.userMessage.isEmpty)
        XCTAssertFalse(PubkyRingError.invalidUrl.userMessage.isEmpty)
        XCTAssertFalse(PubkyRingError.failedToOpenApp.userMessage.isEmpty)
        XCTAssertFalse(PubkyRingError.missingParameters.userMessage.isEmpty)
        XCTAssertFalse(PubkyRingError.crossDeviceFailed("test").userMessage.isEmpty)
    }
    
    // MARK: - Cross-Device Request Expiry Tests
    
    func testCrossDeviceRequestIsExpiredProperty() {
        // Create a request with past expiry
        let expiredRequest = CrossDeviceRequest(
            requestId: "test-id",
            url: URL(string: "https://example.com")!,
            qrCodeImage: nil,
            expiresAt: Date().addingTimeInterval(-60) // Expired 1 minute ago
        )
        
        XCTAssertTrue(expiredRequest.isExpired)
        XCTAssertEqual(expiredRequest.timeRemaining, 0)
    }
    
    func testCrossDeviceRequestTimeRemainingCalculation() {
        let futureExpiry = Date().addingTimeInterval(120) // 2 minutes
        let request = CrossDeviceRequest(
            requestId: "test-id",
            url: URL(string: "https://example.com")!,
            qrCodeImage: nil,
            expiresAt: futureExpiry
        )
        
        XCTAssertFalse(request.isExpired)
        XCTAssertTrue(request.timeRemaining > 0)
        XCTAssertLessThanOrEqual(request.timeRemaining, 120)
    }
    
    // MARK: - Session Capability Tests
    
    func testPubkySessionHasCapabilityMethod() {
        let session = PubkyRingSession(
            pubkey: "testpubkey",
            sessionSecret: "testsecret",
            capabilities: ["paykit:read", "paykit:write"],
            createdAt: Date()
        )
        
        XCTAssertTrue(session.hasCapability("paykit:read"))
        XCTAssertTrue(session.hasCapability("paykit:write"))
        XCTAssertFalse(session.hasCapability("paykit:admin"))
    }
    
    // MARK: - Auth Method Enum Tests
    
    func testAuthMethodCases() {
        let methods: [AuthMethod] = [.sameDevice, .crossDevice, .manual]
        XCTAssertEqual(methods.count, 3)
    }
    
    // MARK: - Authentication Status Enum Tests
    
    func testAuthenticationStatusDescriptions() {
        XCTAssertFalse(AuthenticationStatus.pubkyRingAvailable.description.isEmpty)
        XCTAssertFalse(AuthenticationStatus.crossDeviceOnly.description.isEmpty)
    }
}

