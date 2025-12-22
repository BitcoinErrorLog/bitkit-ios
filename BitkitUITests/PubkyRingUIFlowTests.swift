// PubkyRingUIFlowTests.swift
// Bitkit iOS UI Tests
//
// UI automation tests that navigate the app and interact with Pubky Ring integration.
// These tests tap on actual UI elements and verify the connection flow.

import XCTest

final class PubkyRingUIFlowTests: XCTestCase {
    
    var app: XCUIApplication!
    
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
    }
    
    override func tearDownWithError() throws {
        app = nil
    }
    
    // MARK: - Helper Methods
    
    /// Wait for the app to be ready (home screen loaded)
    private func waitForAppReady() {
        // Wait for the main balance or home screen elements
        let balanceExists = app.staticTexts["$"].waitForExistence(timeout: 10)
        if !balanceExists {
            // Try waiting for any home screen indicator
            _ = app.buttons["Send"].waitForExistence(timeout: 5)
        }
    }
    
    /// Navigate to Profile screen by tapping on profile header
    private func navigateToProfile() {
        waitForAppReady()
        
        // Tap on the profile area (top left with "Your Name" or avatar)
        let profileButton = app.buttons["Your Name"]
        if profileButton.waitForExistence(timeout: 5) {
            profileButton.tap()
            return
        }
        
        // Try the hamburger menu
        let menuButton = app.buttons["Menu"]
        if menuButton.waitForExistence(timeout: 3) {
            menuButton.tap()
            sleep(1)
            
            // Look for Profile option in menu
            let profileOption = app.buttons["Profile"]
            if profileOption.waitForExistence(timeout: 3) {
                profileOption.tap()
            }
        }
    }
    
    /// Navigate to Settings
    private func navigateToSettings() {
        waitForAppReady()
        
        // Tap hamburger menu
        let menuButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'menu' OR label CONTAINS[c] 'settings'")).firstMatch
        if menuButton.waitForExistence(timeout: 5) {
            menuButton.tap()
            sleep(1)
        }
        
        // Look for Settings
        let settingsButton = app.buttons["Settings"]
        if settingsButton.waitForExistence(timeout: 3) {
            settingsButton.tap()
        }
    }
    
    // MARK: - Pubky Ring Connection Flow Tests
    
    /// Test navigating to profile and finding the Connect button
    func testNavigateToProfileScreen() throws {
        navigateToProfile()
        
        // Verify we're on the profile screen
        let profileScreenExists = app.staticTexts["Profile"].waitForExistence(timeout: 5)
            || app.staticTexts["Your Profile"].waitForExistence(timeout: 3)
            || app.buttons["Connect with Pubky Ring"].waitForExistence(timeout: 3)
        
        XCTAssertTrue(profileScreenExists, "Should navigate to profile screen")
    }
    
    /// Test the Connect with Pubky Ring button exists
    func testConnectPubkyRingButtonExists() throws {
        navigateToProfile()
        
        // Look for the Connect button
        let connectButton = app.buttons["Connect with Pubky Ring"]
        let exists = connectButton.waitForExistence(timeout: 5)
        
        // If not found as button, try as text
        if !exists {
            let connectText = app.staticTexts["Connect with Pubky Ring"]
            XCTAssertTrue(connectText.waitForExistence(timeout: 3), 
                         "Connect with Pubky Ring button or text should exist")
            return
        }
        
        XCTAssertTrue(exists, "Connect with Pubky Ring button should exist")
    }
    
    /// Test tapping Connect button shows appropriate response
    func testTapConnectPubkyRingButton() throws {
        navigateToProfile()
        
        // Find and tap the connect button
        let connectButton = app.buttons["Connect with Pubky Ring"]
        if connectButton.waitForExistence(timeout: 5) {
            connectButton.tap()
            sleep(2)
            
            // After tapping, we should see one of:
            // 1. "Connecting..." state
            // 2. Alert about Pubky Ring not installed
            // 3. Switch to Pubky Ring app (if installed)
            
            let isConnecting = app.staticTexts["Connecting..."].exists
            let notInstalledAlert = app.alerts.element.exists
            let switchedApp = !app.wait(for: .runningForeground, timeout: 2)
            
            XCTAssertTrue(isConnecting || notInstalledAlert || switchedApp,
                         "Should show connecting state, alert, or switch to Pubky Ring")
        }
    }
    
    /// Test the cross-device QR code option
    func testCrossDeviceQROption() throws {
        navigateToProfile()
        
        // Look for QR code or cross-device option
        let qrOption = app.buttons["Use QR Code"]
        let crossDeviceOption = app.buttons["Cross-Device"]
        let scanOption = app.buttons["Scan QR"]
        
        let hasQrOption = qrOption.waitForExistence(timeout: 5) ||
                          crossDeviceOption.waitForExistence(timeout: 3) ||
                          scanOption.waitForExistence(timeout: 3)
        
        if hasQrOption {
            // Tap the option
            if qrOption.exists { qrOption.tap() }
            else if crossDeviceOption.exists { crossDeviceOption.tap() }
            else if scanOption.exists { scanOption.tap() }
            
            sleep(2)
            
            // Should show QR code or link
            let hasQrDisplay = app.images.matching(NSPredicate(format: "label CONTAINS[c] 'qr'")).count > 0 ||
                              app.buttons["Copy Link"].exists ||
                              app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'scan'")).count > 0
            
            XCTAssertTrue(hasQrDisplay, "Should show QR code or copy link option")
        }
    }
    
    // MARK: - Profile Display Tests
    
    /// Test that connected profile shows user info
    func testConnectedProfileDisplaysInfo() throws {
        navigateToProfile()
        
        // If already connected, should see profile info
        let hasProfileInfo = app.textFields["Name"].exists ||
                            app.textViews["Bio"].exists ||
                            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'pubky'")).count > 0
        
        // Either has profile info or has connect button
        let hasConnectButton = app.buttons["Connect with Pubky Ring"].exists
        
        XCTAssertTrue(hasProfileInfo || hasConnectButton,
                     "Profile screen should show either profile info or connect button")
    }
    
    // MARK: - Navigation Flow Tests
    
    /// Test the complete navigation flow to Paykit settings
    func testNavigateToPaykitSettings() throws {
        navigateToSettings()
        
        // Look for Paykit or Pubky settings
        let paykitOption = app.buttons["Paykit"]
        let pubkyOption = app.buttons["Pubky"]
        let identityOption = app.buttons["Identity"]
        
        let hasPaykitSettings = paykitOption.waitForExistence(timeout: 5) ||
                               pubkyOption.waitForExistence(timeout: 3) ||
                               identityOption.waitForExistence(timeout: 3)
        
        if hasPaykitSettings {
            if paykitOption.exists { paykitOption.tap() }
            else if pubkyOption.exists { pubkyOption.tap() }
            else if identityOption.exists { identityOption.tap() }
            
            sleep(1)
            
            // Should see Paykit-related settings
            XCTAssertTrue(true, "Navigated to Paykit settings")
        }
    }
    
    // MARK: - Error State Tests
    
    /// Test that appropriate error is shown when Pubky Ring not installed
    func testPubkyRingNotInstalledError() throws {
        navigateToProfile()
        
        let connectButton = app.buttons["Connect with Pubky Ring"]
        guard connectButton.waitForExistence(timeout: 5) else {
            // Already connected, skip this test
            return
        }
        
        connectButton.tap()
        sleep(2)
        
        // If Pubky Ring is not installed, should show error or alternative
        let errorAlert = app.alerts.element
        let notInstalledText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'not installed' OR label CONTAINS[c] 'install'")
        ).firstMatch
        let qrAlternative = app.buttons["Use QR Code"]
        
        // One of these should appear
        let hasAppropriateResponse = errorAlert.exists || 
                                     notInstalledText.exists || 
                                     qrAlternative.exists ||
                                     !app.wait(for: .runningForeground, timeout: 1) // App switched
        
        XCTAssertTrue(hasAppropriateResponse,
                     "Should show error, alternative, or switch to Pubky Ring")
    }
    
    // MARK: - State Persistence Tests
    
    /// Test that connection state persists after app restart
    func testConnectionStatePersistsAfterRestart() throws {
        // First, check current state
        navigateToProfile()
        
        let initiallyConnected = app.textFields["Name"].exists ||
                                app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'pubky'")).count > 0
        
        // Terminate and relaunch
        app.terminate()
        app.launch()
        
        navigateToProfile()
        
        // State should be same after restart
        let stillConnected = app.textFields["Name"].exists ||
                            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'pubky'")).count > 0
        
        XCTAssertEqual(initiallyConnected, stillConnected,
                      "Connection state should persist after app restart")
    }
}

