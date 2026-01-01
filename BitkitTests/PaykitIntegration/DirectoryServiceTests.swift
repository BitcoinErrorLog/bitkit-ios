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
}
