//
//  E2ETestOrchestrator.swift
//  BitkitUITests
//
//  Orchestrates cross-app E2E testing with Pubky-ring
//

import XCTest

/// Orchestrates cross-app E2E testing with Pubky-ring
class E2ETestOrchestrator {
    
    // MARK: - Properties
    
    private let app: XCUIApplication
    private let timeout: TimeInterval
    
    // MARK: - Initialization
    
    init(app: XCUIApplication, timeout: TimeInterval = E2ETestConfig.sessionTimeout) {
        self.app = app
        self.timeout = timeout
    }
    
    // MARK: - Session Management
    
    /// Ensure a valid session exists, requesting from Pubky-ring if needed
    /// - Throws: E2ETestError if session cannot be established
    func ensureSessionEstablished() throws {
        // Check if session already active
        if isSessionActive() {
            print("E2E: Session already active, skipping connection")
            return
        }
        
        // Request session from Pubky-ring
        try requestSessionFromPubkyRing()
        
        // Wait for session to be established
        let sessionActive = app.staticTexts["Session Active"]
        XCTAssertTrue(
            sessionActive.waitForExistence(timeout: timeout),
            "Session should be established after Pubky-ring callback"
        )
    }
    
    /// Check if a session is currently active in the UI
    /// - Returns: True if session is active
    func isSessionActive() -> Bool {
        navigateToPaykitSettings()
        Thread.sleep(forTimeInterval: E2ETestConfig.uiSettleDelay)
        return app.staticTexts["Session Active"].exists
    }
    
    /// Request session from Pubky-ring via URL scheme
    /// - Throws: E2ETestError.pubkyRingNotInstalled if Pubky-ring is not available
    func requestSessionFromPubkyRing() throws {
        guard isPubkyRingInstalled() else {
            throw E2ETestError.pubkyRingNotInstalled
        }
        
        let deviceId = getDeviceId()
        guard let url = E2ETestConfig.paykitConnectURL(deviceId: deviceId) else {
            throw E2ETestError.invalidURL
        }
        
        print("E2E: Opening Pubky-ring with URL: \(url)")
        app.open(url)
        
        // Wait for app to regain focus after Pubky-ring processes
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        
        // Wait for callback to be processed
        Thread.sleep(forTimeInterval: E2ETestConfig.uiSettleDelay)
    }
    
    /// Get a consistent device ID for testing
    private func getDeviceId() -> String {
        return "e2e-test-device-\(E2ETestConfig.runId)"
    }
    
    // MARK: - Navigation Helpers
    
    /// Navigate to Paykit settings section
    func navigateToPaykitSettings() {
        // Try tab bar first
        let settingsTab = app.tabBars.buttons["Settings"]
        if settingsTab.waitForExistence(timeout: 3) {
            settingsTab.tap()
        }
        
        // Look for Paykit cell in settings
        let paykitCell = app.cells["Paykit"]
        if paykitCell.waitForExistence(timeout: 5) {
            paykitCell.tap()
        }
    }
    
    /// Navigate to profile edit screen
    func navigateToProfileEdit() {
        navigateToPaykitSettings()
        Thread.sleep(forTimeInterval: E2ETestConfig.uiSettleDelay)
        
        let editButton = app.buttons["Edit Profile"]
        if editButton.waitForExistence(timeout: 5) {
            editButton.tap()
        }
    }
    
    /// Navigate to contacts/follows screen
    func navigateToContacts() {
        navigateToPaykitSettings()
        Thread.sleep(forTimeInterval: E2ETestConfig.uiSettleDelay)
        
        let contactsButton = app.buttons["Contacts"]
        if contactsButton.waitForExistence(timeout: 5) {
            contactsButton.tap()
        }
    }
    
    /// Navigate to the main activity/dashboard
    func navigateToDashboard() {
        let dashboardTab = app.tabBars.buttons["Wallet"]
        if dashboardTab.exists {
            dashboardTab.tap()
        }
    }
    
    /// Go back one screen in navigation
    func goBack() {
        let backButton = app.navigationBars.buttons.firstMatch
        if backButton.exists {
            backButton.tap()
        }
    }
    
    // MARK: - Pubky-ring Detection
    
    /// Check if Pubky-ring app is installed on the device
    /// - Returns: True if Pubky-ring can be launched
    func isPubkyRingInstalled() -> Bool {
        let pubkyRingApp = XCUIApplication(bundleIdentifier: E2ETestConfig.pubkyRingBundleId)
        // Check if the app exists by attempting to get its state
        // This is a workaround since we can't directly check installation
        return pubkyRingApp.exists || canOpenPubkyRingURL()
    }
    
    /// Check if Pubky-ring URL scheme can be opened
    private func canOpenPubkyRingURL() -> Bool {
        guard let url = URL(string: "\(E2ETestConfig.pubkyRingScheme)://ping") else {
            return false
        }
        
        // Store current app state
        let wasInForeground = app.state == .runningForeground
        
        // Try to open the URL
        app.open(url)
        
        // Small delay to allow URL handling
        Thread.sleep(forTimeInterval: 0.5)
        
        // If our app is no longer in foreground, Pubky-ring was launched
        let pubkyRingInstalled = app.state != .runningForeground
        
        // Return to our app if needed
        if pubkyRingInstalled && wasInForeground {
            app.activate()
        }
        
        return pubkyRingInstalled
    }
    
    // MARK: - Wait Helpers
    
    /// Wait for a loading indicator to disappear
    /// - Parameter timeout: Maximum time to wait
    func waitForLoadingToComplete(timeout: TimeInterval = E2ETestConfig.networkTimeout) {
        let loadingIndicator = app.activityIndicators.firstMatch
        if loadingIndicator.exists {
            let disappeared = NSPredicate(format: "exists == false")
            let expectation = XCTNSPredicateExpectation(predicate: disappeared, object: loadingIndicator)
            _ = XCTWaiter.wait(for: [expectation], timeout: timeout)
        }
    }
    
    /// Wait for a specific element to appear
    /// - Parameters:
    ///   - element: The element to wait for
    ///   - timeout: Maximum time to wait
    /// - Returns: True if element appeared within timeout
    @discardableResult
    func waitFor(_ element: XCUIElement, timeout: TimeInterval = E2ETestConfig.defaultUITimeout) -> Bool {
        return element.waitForExistence(timeout: timeout)
    }
    
    // MARK: - Cleanup
    
    /// Reset test data to clean state
    func resetTestData() {
        // Navigate to profile and reset name if it contains our run ID
        navigateToProfileEdit()
        
        let nameField = app.textFields["Display Name"]
        if nameField.waitForExistence(timeout: 5) {
            if let currentValue = nameField.value as? String,
               currentValue.contains(E2ETestConfig.runId) {
                // Reset to default name
                nameField.clearAndTypeText("E2E Test Identity")
                
                let publishButton = app.buttons["Publish to Pubky"]
                if publishButton.exists {
                    publishButton.tap()
                    Thread.sleep(forTimeInterval: E2ETestConfig.publishSettleDelay)
                }
            }
        }
    }
}

// MARK: - Error Types

enum E2ETestError: Error, LocalizedError {
    case pubkyRingNotInstalled
    case sessionNotEstablished
    case profileNotFound
    case invalidURL
    case timeout
    
    var errorDescription: String? {
        switch self {
        case .pubkyRingNotInstalled:
            return "Pubky-ring app is not installed on the test device"
        case .sessionNotEstablished:
            return "Failed to establish session with Pubky-ring"
        case .profileNotFound:
            return "Profile data not found"
        case .invalidURL:
            return "Failed to construct valid URL"
        case .timeout:
            return "Operation timed out"
        }
    }
}

