//
//  E2ETestConfig.swift
//  BitkitUITests
//
//  Configuration for real E2E testing against production homeserver
//

import Foundation

/// Configuration for real E2E testing against production homeserver
public struct E2ETestConfig {
    
    // MARK: - Known Test Pubkeys
    
    /// iOS AI Tester pubkey (z-base-32)
    /// Decrypted from: credentials/ios-ai-tester-backup-2026-01-01_12-16-19.pkarr (password: tester)
    public static let iosTestPubkey = "n3pfudgxncn8i1e6icuq7umoczemjuyi6xdfrfczk3o8ej3e55my"
    
    /// Android AI Tester pubkey (z-base-32)
    /// Decrypted from: credentials/android-ai-tester-backup-2026-01-01_12-18-17.pkarr (password: tester)
    public static let androidTestPubkey = "tjtigrhbiinfwwh8nwwgbq4b17t71uqesshsd7zp37zt3huwmwyo"
    
    // MARK: - Environment Variables
    
    /// Test pubkey (z-base-32 encoded)
    /// Set via E2E_TEST_PUBKEY environment variable, defaults to iOS test pubkey
    public static var testPubkey: String {
        ProcessInfo.processInfo.environment["E2E_TEST_PUBKEY"] ?? iosTestPubkey
    }
    
    /// Secondary test pubkey for follow/contact tests
    /// Set via E2E_SECONDARY_PUBKEY environment variable, defaults to Android test pubkey
    public static var secondaryTestPubkey: String {
        ProcessInfo.processInfo.environment["E2E_SECONDARY_PUBKEY"] ?? androidTestPubkey
    }
    
    /// Unique run ID for test isolation
    /// Auto-generated if not provided via E2E_RUN_ID environment variable
    public static var runId: String {
        if let envRunId = ProcessInfo.processInfo.environment["E2E_RUN_ID"], !envRunId.isEmpty {
            return envRunId
        }
        return String(UUID().uuidString.prefix(8)).lowercased()
    }
    
    // MARK: - Homeserver Configuration
    
    /// Production homeserver pubkey (z-base-32)
    public static let productionHomeserverPubkey = "8um71us3fyw6h8wbcxb5ar3rwusy1a6u49956ikzojg3gcwd1dty"
    
    /// Staging homeserver pubkey (z-base-32)
    public static let stagingHomeserverPubkey = "ufibwbmed6jeq9k4p583go95wofakh9fwpp4k734trq79pd9u1uy"
    
    /// Production homeserver URL
    public static let productionHomeserverURL = "https://homeserver.pubky.app"
    
    /// Staging homeserver URL
    public static let stagingHomeserverURL = "https://staging.homeserver.pubky.app"
    
    // MARK: - Computed Properties
    
    /// Whether real E2E mode is enabled (vs simulation)
    /// Always true now that we have default test pubkeys
    public static var isRealE2E: Bool {
        true
    }
    
    /// Whether a secondary pubkey is available for follow tests
    /// Always true now that we have default test pubkeys
    public static var hasSecondaryPubkey: Bool {
        true
    }
    
    /// Whether using custom environment variable pubkeys (vs defaults)
    public static var isUsingCustomPubkeys: Bool {
        ProcessInfo.processInfo.environment["E2E_TEST_PUBKEY"] != nil
    }
    
    /// Test profile name with run isolation
    /// Includes run ID to ensure each test run creates unique data
    public static var testProfileName: String {
        "E2E Test [\(runId)]"
    }
    
    /// Test profile bio
    public static var testProfileBio: String {
        "Automated E2E test profile - \(Date())"
    }
    
    // MARK: - Timeouts
    
    /// Default timeout for UI elements to appear
    public static let defaultUITimeout: TimeInterval = 15
    
    /// Timeout for network operations (profile fetch, publish)
    public static let networkTimeout: TimeInterval = 30
    
    /// Timeout for Pubky-ring session establishment
    public static let sessionTimeout: TimeInterval = 60
    
    /// Short delay for UI settling
    public static let uiSettleDelay: TimeInterval = 1
    
    /// Delay after publishing to allow homeserver to persist
    public static let publishSettleDelay: TimeInterval = 2
    
    // MARK: - App Identifiers
    
    /// Pubky-ring bundle identifier
    public static let pubkyRingBundleId = "app.pubky.ring"
    
    /// Bitkit bundle identifier
    public static let bitkitBundleId = "to.bitkit.app"
    
    // MARK: - URL Schemes
    
    /// Pubky-ring URL scheme
    public static let pubkyRingScheme = "pubkyring"
    
    /// Bitkit URL scheme
    public static let bitkitScheme = "bitkit"
    
    // MARK: - Helper Methods
    
    /// Get the paykit-connect URL for requesting a session from Pubky-ring
    /// - Parameter deviceId: Device identifier for noise key derivation
    /// - Returns: URL to open Pubky-ring with session request
    public static func paykitConnectURL(deviceId: String) -> URL? {
        let callbackUrl = "\(bitkitScheme)://paykit-setup"
        let urlString = "\(pubkyRingScheme)://paykit-connect?deviceId=\(deviceId)&callback=\(callbackUrl)"
        return URL(string: urlString)
    }
    
    /// Description of current configuration for logging
    public static var configurationDescription: String {
        """
        E2E Test Configuration:
        - Real E2E: \(isRealE2E)
        - Using Custom Pubkeys: \(isUsingCustomPubkeys)
        - Test Pubkey: \(testPubkey.prefix(16))...
        - Secondary Pubkey: \(secondaryTestPubkey.prefix(16))...
        - Run ID: \(runId)
        - Profile Name: \(testProfileName)
        """
    }
}

