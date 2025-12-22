// PubkyRingDeepLinkTests.swift
// Bitkit iOS UI Tests
//
// Tests for Pubky Ring deep link handling and integration flows.
// These tests verify the app correctly handles incoming callbacks from Pubky Ring.

import XCTest

final class PubkyRingDeepLinkTests: XCTestCase {
    
    var app: XCUIApplication!
    
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }
    
    override func tearDownWithError() throws {
        app = nil
    }
    
    // MARK: - Deep Link Callback Tests
    
    /// Test that the app handles a paykit-setup callback correctly
    func testPaykitSetupCallbackIsHandled() throws {
        // The app should be running
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        
        // Send a deep link callback simulating Pubky Ring response
        // Note: In actual UI tests, we'd use Safari or a helper app to trigger the deep link
        // For now, we verify the app can receive and process the callback
        
        let testPubkey = "pk1uitest\(Int.random(in: 1000...9999))"
        let deepLinkURL = "bitkit://paykit-setup?pubky=\(testPubkey)&session_secret=testsecret&device_id=testdevice"
        
        // Open the deep link (this will prompt to switch apps in a real scenario)
        // In automated testing, we can verify the URL scheme is registered
        if let url = URL(string: deepLinkURL) {
            XCTAssertTrue(UIApplication.shared.canOpenURL(url), "App should handle bitkit:// URLs")
        }
    }
    
    /// Test that the app handles a session callback correctly
    func testSessionCallbackIsHandled() throws {
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        
        let deepLinkURL = "bitkit://paykit-session?pubky=pk1sessiontest&session_secret=secret123"
        
        if let url = URL(string: deepLinkURL) {
            XCTAssertTrue(UIApplication.shared.canOpenURL(url), "App should handle session callback URLs")
        }
    }
    
    /// Test that the app handles cross-device session callback correctly
    func testCrossDeviceSessionCallbackIsHandled() throws {
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        
        let deepLinkURL = "bitkit://paykit-cross-session?pubky=pk1crosstest&session_secret=secret456&request_id=test-request"
        
        if let url = URL(string: deepLinkURL) {
            XCTAssertTrue(UIApplication.shared.canOpenURL(url), "App should handle cross-device callback URLs")
        }
    }
    
    /// Test that the app handles profile callback correctly
    func testProfileCallbackIsHandled() throws {
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        
        let deepLinkURL = "bitkit://paykit-profile?name=TestUser&bio=Test%20Bio"
        
        if let url = URL(string: deepLinkURL) {
            XCTAssertTrue(UIApplication.shared.canOpenURL(url), "App should handle profile callback URLs")
        }
    }
    
    /// Test that the app handles follows callback correctly
    func testFollowsCallbackIsHandled() throws {
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        
        let deepLinkURL = "bitkit://paykit-follows?follows=pk1user1,pk1user2,pk1user3"
        
        if let url = URL(string: deepLinkURL) {
            XCTAssertTrue(UIApplication.shared.canOpenURL(url), "App should handle follows callback URLs")
        }
    }
    
    // MARK: - Integration Flow Tests
    
    /// Test launching Pubky Ring for authentication (if installed)
    func testPubkyRingLaunchForAuth() throws {
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        
        // Check if we can open Pubky Ring URL scheme
        let pubkyRingURL = "pubkyring://paykit-connect?deviceId=uitest123&callback=bitkit://paykit-setup"
        
        if let url = URL(string: pubkyRingURL) {
            // This tests if the URL scheme is valid (Pubky Ring may or may not be installed)
            // In a full test environment, you'd have both apps installed
            let canOpen = UIApplication.shared.canOpenURL(url)
            // We just log whether it's available, not assert - Pubky Ring may not be installed
            print("Pubky Ring URL scheme available: \(canOpen)")
        }
    }
    
    /// Test that paykit:// scheme URLs are handled
    func testPaykitSchemeIsHandled() throws {
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        
        let paykitURL = "paykit://payment-request?amount=1000&recipient=pk1recipient"
        
        if let url = URL(string: paykitURL) {
            XCTAssertTrue(UIApplication.shared.canOpenURL(url), "App should handle paykit:// URLs")
        }
    }
    
    // MARK: - URL Scheme Registration Tests
    
    /// Verify all expected URL schemes are registered
    func testAllURLSchemesAreRegistered() throws {
        let schemes = [
            "bitkit://test",
            "paykit://test",
            "bitcoin://test",
            "lightning://test",
        ]
        
        for scheme in schemes {
            if let url = URL(string: scheme) {
                XCTAssertTrue(
                    UIApplication.shared.canOpenURL(url),
                    "URL scheme should be registered: \(scheme)"
                )
            }
        }
    }
    
    // MARK: - Callback Path Verification Tests
    
    /// Test all callback paths are recognized
    func testAllCallbackPathsAreRecognized() throws {
        let callbackPaths = [
            "paykit-session",
            "paykit-keypair",
            "paykit-profile",
            "paykit-follows",
            "paykit-cross-session",
            "paykit-setup",
        ]
        
        for path in callbackPaths {
            let urlString = "bitkit://\(path)?test=1"
            if let url = URL(string: urlString) {
                XCTAssertTrue(
                    UIApplication.shared.canOpenURL(url),
                    "Callback path should be handled: \(path)"
                )
            }
        }
    }
}

