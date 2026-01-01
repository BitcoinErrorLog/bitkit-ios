// DirectoryServiceTests.swift
// BitkitTests
//
// Unit tests for DirectoryService

import XCTest
@testable import Bitkit

final class DirectoryServiceTests: XCTestCase {

    var directoryService: DirectoryService!

    override func setUp() {
        super.setUp()
        directoryService = DirectoryService.shared
    }

    override func tearDown() {
        directoryService = nil
        super.tearDown()
    }

    // MARK: - Payment Method Discovery Tests

    func testDiscoverPaymentMethodsThrowsWhenNotConfigured() async throws {
        // Given - directory service without PaykitClient configured
        let unconfiguredService = DirectoryService()
        
        // When/Then - should throw notConfigured error
        do {
            _ = try await unconfiguredService.discoverPaymentMethods(for: "pk:unknown123")
            XCTFail("Expected error to be thrown")
        } catch let error as DirectoryError {
            if case .notConfigured = error {
                // Expected
            } else {
                XCTFail("Expected notConfigured error")
            }
        }
    }

    func testDiscoverNoiseEndpointReturnsNilWhenNotConfigured() async throws {
        // Given - directory service without PaykitClient configured
        let unconfiguredService = DirectoryService()
        
        // When/Then - should throw notConfigured error
        do {
            _ = try await unconfiguredService.discoverNoiseEndpoint(for: "pk:unknown456")
            XCTFail("Expected error to be thrown")
        } catch let error as DirectoryError {
            if case .notConfigured = error {
                // Expected
            } else {
                XCTFail("Expected notConfigured error")
            }
        }
    }

    // MARK: - Endpoint Publishing Tests

    func testPublishNoiseEndpointThrowsWhenNotConfigured() async throws {
        // Given - directory service without authenticated transport
        let unconfiguredService = DirectoryService()
        
        // When/Then - should throw notConfigured error
        do {
            try await unconfiguredService.publishNoiseEndpoint(
                host: "localhost",
                port: 8080,
                noisePubkey: "pk:test123"
            )
            XCTFail("Expected error to be thrown")
        } catch let error as DirectoryError {
            if case .notConfigured = error {
                // Expected
            } else {
                XCTFail("Expected notConfigured error")
            }
        }
    }

    func testRemoveNoiseEndpointThrowsWhenNotConfigured() async throws {
        // Given - directory service without authenticated transport
        let unconfiguredService = DirectoryService()
        
        // When/Then - should throw notConfigured error
        do {
            try await unconfiguredService.removeNoiseEndpoint()
            XCTFail("Expected error to be thrown")
        } catch let error as DirectoryError {
            if case .notConfigured = error {
                // Expected
            } else {
                XCTFail("Expected notConfigured error")
            }
        }
    }

    // MARK: - Payment Method Publishing Tests
    
    func testPublishPaymentMethodThrowsWhenNotConfigured() async throws {
        // Given - directory service without authenticated transport
        let unconfiguredService = DirectoryService()
        
        // When/Then - should throw notConfigured error
        do {
            try await unconfiguredService.publishPaymentMethod(
                methodId: "lightning",
                endpoint: "lnurl1dp68gurn8ghj7um9..."
            )
            XCTFail("Expected error to be thrown")
        } catch let error as DirectoryError {
            if case .notConfigured = error {
                // Expected
            } else {
                XCTFail("Expected notConfigured error")
            }
        }
    }
    
    func testRemovePaymentMethodThrowsWhenNotConfigured() async throws {
        // Given - directory service without authenticated transport
        let unconfiguredService = DirectoryService()
        
        // When/Then - should throw notConfigured error
        do {
            try await unconfiguredService.removePaymentMethod(methodId: "lightning")
            XCTFail("Expected error to be thrown")
        } catch let error as DirectoryError {
            if case .notConfigured = error {
                // Expected
            } else {
                XCTFail("Expected notConfigured error")
            }
        }
    }

    // MARK: - Directory Error Tests

    func testDirectoryErrorDescriptions() {
        let notConfigured = DirectoryError.notConfigured
        XCTAssertNotNil(notConfigured.errorDescription)
        XCTAssertTrue(notConfigured.errorDescription!.contains("not configured"))
        
        let networkError = DirectoryError.networkError("timeout")
        XCTAssertTrue(networkError.errorDescription!.contains("Network error"))
        
        let parseError = DirectoryError.parseError("invalid json")
        XCTAssertTrue(parseError.errorDescription!.contains("Parse error"))
        
        let notFound = DirectoryError.notFound("endpoint")
        XCTAssertTrue(notFound.errorDescription!.contains("Not found"))
        
        let publishFailed = DirectoryError.publishFailed("server error")
        XCTAssertTrue(publishFailed.errorDescription!.contains("Publish failed"))
    }
    
    // MARK: - DirectoryDiscoveredContact Tests
    
    func testDirectoryDiscoveredContactIdentifiable() {
        let contact = DirectoryDiscoveredContact(
            pubkey: "pk:abc123",
            name: "Alice",
            hasPaymentMethods: true,
            supportedMethods: ["lightning", "onchain"]
        )
        
        XCTAssertEqual(contact.id, "pk:abc123")
        XCTAssertEqual(contact.pubkey, "pk:abc123")
        XCTAssertEqual(contact.name, "Alice")
        XCTAssertTrue(contact.hasPaymentMethods)
        XCTAssertEqual(contact.supportedMethods.count, 2)
    }
    
    func testDirectoryDiscoveredContactWithNilName() {
        let contact = DirectoryDiscoveredContact(
            pubkey: "pk:xyz789",
            name: nil,
            hasPaymentMethods: false,
            supportedMethods: []
        )
        
        XCTAssertNil(contact.name)
        XCTAssertFalse(contact.hasPaymentMethods)
        XCTAssertTrue(contact.supportedMethods.isEmpty)
    }
    
    // MARK: - Profile Operations Tests
    
    func testPublishProfileThrowsWhenNotConfigured() async throws {
        // Given - directory service without authenticated adapter
        let unconfiguredService = DirectoryService()
        let profile = PubkyProfile(name: "Test User", bio: "Test bio")
        
        // When/Then - should throw notConfigured error
        do {
            try await unconfiguredService.publishProfile(profile)
            XCTFail("Expected error to be thrown")
        } catch let error as DirectoryError {
            if case .notConfigured = error {
                // Expected
            } else {
                XCTFail("Expected notConfigured error, got: \(error)")
            }
        }
    }
    
    // MARK: - Follows Operations Tests
    
    func testAddFollowThrowsWhenNotConfigured() async throws {
        // Given - directory service without authenticated adapter
        let unconfiguredService = DirectoryService()
        
        // When/Then - should throw notConfigured error
        do {
            try await unconfiguredService.addFollow(pubkey: "pk:testfollow123")
            XCTFail("Expected error to be thrown")
        } catch let error as DirectoryError {
            if case .notConfigured = error {
                // Expected
            } else {
                XCTFail("Expected notConfigured error, got: \(error)")
            }
        }
    }
    
    func testRemoveFollowThrowsWhenNotConfigured() async throws {
        // Given - directory service without authenticated adapter
        let unconfiguredService = DirectoryService()
        
        // When/Then - should throw notConfigured error
        do {
            try await unconfiguredService.removeFollow(pubkey: "pk:testfollow123")
            XCTFail("Expected error to be thrown")
        } catch let error as DirectoryError {
            if case .notConfigured = error {
                // Expected
            } else {
                XCTFail("Expected notConfigured error, got: \(error)")
            }
        }
    }
    
    // MARK: - PubkyConfig Tests
    
    func testPubkyConfigHomeserverBaseURL() {
        // Test that homeserverBaseURL returns the production URL for default pubkey
        let url = PubkyConfig.homeserverBaseURL()
        XCTAssertEqual(url, "https://homeserver.pubky.app")
    }
    
    func testPubkyConfigHomeserverBaseURLWithStagingPubkey() {
        // Test that staging pubkey maps to staging URL
        let url = PubkyConfig.homeserverBaseURL(for: PubkyConfig.stagingHomeserverPubkey)
        XCTAssertEqual(url, "https://staging.homeserver.pubky.app")
    }
    
    func testPubkyConfigHomeserverBaseURLWithUnknownPubkey() {
        // Test that unknown pubkeys fall back to production URL
        let customPubkey = "unknownpubkey123456789"
        let url = PubkyConfig.homeserverBaseURL(for: customPubkey)
        XCTAssertEqual(url, "https://homeserver.pubky.app")
    }
    
    // MARK: - PubkyProfile Tests
    
    func testPubkyProfileInitialization() {
        let links = [
            PubkyProfileLink(title: "Website", url: "https://example.com"),
            PubkyProfileLink(title: "Twitter", url: "https://twitter.com/test")
        ]
        
        let profile = PubkyProfile(
            name: "Test User",
            bio: "This is a test bio",
            avatar: "https://example.com/avatar.png",
            links: links
        )
        
        XCTAssertEqual(profile.name, "Test User")
        XCTAssertEqual(profile.bio, "This is a test bio")
        XCTAssertEqual(profile.avatar, "https://example.com/avatar.png")
        XCTAssertEqual(profile.links?.count, 2)
        XCTAssertEqual(profile.links?.first?.title, "Website")
    }
    
    func testPubkyProfileWithOptionalFields() {
        let profile = PubkyProfile()
        
        XCTAssertNil(profile.name)
        XCTAssertNil(profile.bio)
        XCTAssertNil(profile.avatar)
        XCTAssertNil(profile.links)
    }
    
    // MARK: - SecureHandoffHandler Tests
    
    func testSecureHandoffPayloadDecoding() throws {
        let json = """
        {
            "version": 1,
            "pubky": "8um71us3fyw6h8wbcxb5ar3rwusy1a6u49956ikzojg3gcwd1dty",
            "session_secret": "abc123def456",
            "capabilities": ["read", "write"],
            "device_id": "test-device-id",
            "noise_keypairs": [
                {"epoch": 0, "public_key": "pk0_hex", "secret_key": "sk0_hex"},
                {"epoch": 1, "public_key": "pk1_hex", "secret_key": "sk1_hex"}
            ],
            "created_at": 1704067200000,
            "expires_at": 1704067500000
        }
        """.data(using: .utf8)!
        
        let payload = try JSONDecoder().decode(SecureHandoffPayload.self, from: json)
        
        XCTAssertEqual(payload.version, 1)
        XCTAssertEqual(payload.pubky, "8um71us3fyw6h8wbcxb5ar3rwusy1a6u49956ikzojg3gcwd1dty")
        XCTAssertEqual(payload.sessionSecret, "abc123def456")
        XCTAssertEqual(payload.capabilities, ["read", "write"])
        XCTAssertEqual(payload.deviceId, "test-device-id")
        XCTAssertEqual(payload.noiseKeypairs.count, 2)
        XCTAssertEqual(payload.noiseKeypairs[0].epoch, 0)
        XCTAssertEqual(payload.noiseKeypairs[0].publicKey, "pk0_hex")
        XCTAssertEqual(payload.noiseKeypairs[0].secretKey, "sk0_hex")
        XCTAssertEqual(payload.noiseKeypairs[1].epoch, 1)
        XCTAssertEqual(payload.createdAt, 1704067200000)
        XCTAssertEqual(payload.expiresAt, 1704067500000)
    }
    
    func testSecureHandoffPayloadDecodingWithMinimalKeypairs() throws {
        let json = """
        {
            "version": 1,
            "pubky": "testpubky123",
            "session_secret": "secret",
            "capabilities": [],
            "device_id": "device",
            "noise_keypairs": [
                {"epoch": 0, "public_key": "pk", "secret_key": "sk"}
            ],
            "created_at": 0,
            "expires_at": 9999999999999
        }
        """.data(using: .utf8)!
        
        let payload = try JSONDecoder().decode(SecureHandoffPayload.self, from: json)
        
        XCTAssertEqual(payload.noiseKeypairs.count, 1)
        XCTAssertTrue(payload.capabilities.isEmpty)
    }
    
    func testSecureHandoffPayloadExpirationValidation() throws {
        // Create an expired payload
        let expiredPayload = SecureHandoffPayload(
            version: 1,
            pubky: "testpubky",
            sessionSecret: "secret",
            capabilities: [],
            deviceId: "device",
            noiseKeypairs: [],
            createdAt: 0,
            expiresAt: 1000  // Long expired (1 second after epoch)
        )
        
        XCTAssertThrowsError(try SecureHandoffHandler.shared.validatePayload(expiredPayload)) { error in
            XCTAssertEqual(error as? SecureHandoffError, .payloadExpired)
        }
    }
    
    func testSecureHandoffPayloadValidNotExpired() throws {
        // Create a payload that expires far in the future
        let futureExpiry = Int64(Date().timeIntervalSince1970 * 1000) + 300000 // 5 minutes from now
        
        let validPayload = SecureHandoffPayload(
            version: 1,
            pubky: "testpubky",
            sessionSecret: "secret",
            capabilities: ["read", "write"],
            deviceId: "device",
            noiseKeypairs: [],
            createdAt: Int64(Date().timeIntervalSince1970 * 1000),
            expiresAt: futureExpiry
        )
        
        // Should not throw
        XCTAssertNoThrow(try SecureHandoffHandler.shared.validatePayload(validPayload))
    }
    
    func testNoiseKeypairPayloadDecoding() throws {
        let json = """
        {
            "epoch": 0,
            "public_key": "aabbccdd",
            "secret_key": "11223344"
        }
        """.data(using: .utf8)!
        
        let keypair = try JSONDecoder().decode(NoiseKeypairPayload.self, from: json)
        
        XCTAssertEqual(keypair.epoch, 0)
        XCTAssertEqual(keypair.publicKey, "aabbccdd")
        XCTAssertEqual(keypair.secretKey, "11223344")
    }
    
    func testPaykitSetupResultInitialization() {
        let session = PubkyRingSession(
            pubkey: "testpubky123",
            sessionSecret: "secret456",
            capabilities: ["read"],
            createdAt: Date()
        )
        
        let keypair0 = NoiseKeypair(
            publicKey: "pk0",
            secretKey: "sk0",
            deviceId: "device",
            epoch: 0
        )
        
        let result = PaykitSetupResult(
            session: session,
            deviceId: "device",
            noiseKeypair0: keypair0,
            noiseKeypair1: nil
        )
        
        XCTAssertEqual(result.session.pubkey, "testpubky123")
        XCTAssertEqual(result.deviceId, "device")
        XCTAssertNotNil(result.noiseKeypair0)
        XCTAssertNil(result.noiseKeypair1)
    }
    
    func testSecureHandoffErrorDescriptions() {
        XCTAssertEqual(SecureHandoffError.payloadNotFound.errorDescription, "Handoff payload not found on homeserver")
        XCTAssertEqual(SecureHandoffError.payloadExpired.errorDescription, "Handoff payload has expired")
        XCTAssertEqual(SecureHandoffError.invalidPayload.errorDescription, "Invalid handoff payload format")
        XCTAssertEqual(SecureHandoffError.deletionFailed.errorDescription, "Failed to delete handoff payload")
        XCTAssertEqual(SecureHandoffError.networkError("test").errorDescription, "Network error: test")
    }
    
    func testSecureHandoffErrorEquality() {
        XCTAssertEqual(SecureHandoffError.payloadNotFound, SecureHandoffError.payloadNotFound)
        XCTAssertEqual(SecureHandoffError.payloadExpired, SecureHandoffError.payloadExpired)
        XCTAssertEqual(SecureHandoffError.networkError("a"), SecureHandoffError.networkError("a"))
        XCTAssertNotEqual(SecureHandoffError.networkError("a"), SecureHandoffError.networkError("b"))
        XCTAssertNotEqual(SecureHandoffError.payloadNotFound, SecureHandoffError.payloadExpired)
    }
}
