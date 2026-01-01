// PubkySDKServiceTests.swift
// BitkitTests
//
// Unit tests for PubkySDKService

import XCTest
@testable import Bitkit

final class PubkySDKServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Clear caches before each test
        PubkySDKService.shared.clearCaches()
    }

    override func tearDown() {
        PubkySDKService.shared.clearCaches()
        super.tearDown()
    }

    // MARK: - Configuration Tests

    func testConfigureWithDefaultHomeserver() {
        // Given - a fresh service

        // When - configure with defaults
        PubkySDKService.shared.configure()

        // Then - should use the resolved homeserver URL
        // Note: We can't directly access the homeserver property, but we verify via the URL pattern
        // The test passes if no error is thrown
    }

    func testConfigureWithCustomHomeserver() {
        // Given - a custom homeserver URL
        let customURL = "https://custom.homeserver.example.com"

        // When - configure with custom URL
        PubkySDKService.shared.configure(homeserver: customURL)

        // Then - should use the custom URL (verified by not throwing)
    }

    // MARK: - Session Management Tests

    func testHasActiveSessionDefaultsFalse() {
        // Given - a fresh service with no sessions
        PubkySDKService.shared.clearAllSessions()

        // When/Then - should have no active session
        XCTAssertFalse(PubkySDKService.shared.hasActiveSession)
    }

    func testActiveSessionReturnsNilWhenNoSessions() {
        // Given - a fresh service with no sessions
        PubkySDKService.shared.clearAllSessions()

        // When/Then - should return nil
        XCTAssertNil(PubkySDKService.shared.activeSession)
    }

    func testSetSessionCachesSession() {
        // Given - a session to set
        let session = LegacyPubkySession(
            pubkey: "testpubkey123",
            sessionSecret: "testsecret456",
            capabilities: ["read", "write"],
            expiresAt: Date().addingTimeInterval(3600)
        )

        // When - set the session
        PubkySDKService.shared.setSession(session)

        // Then - session should be cached
        XCTAssertTrue(PubkySDKService.shared.hasActiveSession)
        XCTAssertNotNil(PubkySDKService.shared.getSession(for: "testpubkey123"))
    }

    func testGetSessionReturnsCorrectSession() {
        // Given - a session set for a specific pubkey
        let session = LegacyPubkySession(
            pubkey: "specificpubkey",
            sessionSecret: "secret123",
            capabilities: [],
            expiresAt: nil
        )
        PubkySDKService.shared.setSession(session)

        // When - retrieve the session
        let retrieved = PubkySDKService.shared.getSession(for: "specificpubkey")

        // Then - should match the original
        XCTAssertEqual(retrieved?.pubkey, "specificpubkey")
        XCTAssertEqual(retrieved?.sessionSecret, "secret123")
    }

    func testSignoutRemovesSession() {
        // Given - a session exists
        let session = LegacyPubkySession(
            pubkey: "signouttest",
            sessionSecret: "secret",
            capabilities: [],
            expiresAt: nil
        )
        PubkySDKService.shared.setSession(session)
        XCTAssertNotNil(PubkySDKService.shared.getSession(for: "signouttest"))

        // When - sign out
        PubkySDKService.shared.signout(pubkey: "signouttest")

        // Then - session should be removed
        XCTAssertNil(PubkySDKService.shared.getSession(for: "signouttest"))
    }

    func testClearAllSessionsRemovesAllSessions() {
        // Given - multiple sessions exist
        let session1 = LegacyPubkySession(pubkey: "user1", sessionSecret: "s1", capabilities: [], expiresAt: nil)
        let session2 = LegacyPubkySession(pubkey: "user2", sessionSecret: "s2", capabilities: [], expiresAt: nil)
        PubkySDKService.shared.setSession(session1)
        PubkySDKService.shared.setSession(session2)
        XCTAssertTrue(PubkySDKService.shared.hasActiveSession)

        // When - clear all sessions
        PubkySDKService.shared.clearAllSessions()

        // Then - no sessions should remain
        XCTAssertFalse(PubkySDKService.shared.hasActiveSession)
        XCTAssertNil(PubkySDKService.shared.getSession(for: "user1"))
        XCTAssertNil(PubkySDKService.shared.getSession(for: "user2"))
    }

    // MARK: - Cache Tests

    func testClearCachesRemovesCachedData() {
        // Given - service with potential cached data

        // When - clear caches
        PubkySDKService.shared.clearCaches()

        // Then - should complete without error
        // (We can't directly verify cache contents, but this ensures no crash)
    }

    // MARK: - SDKProfile Tests

    func testSDKProfileDecodable() throws {
        // Given - JSON data representing a profile
        let json = """
        {
            "name": "Test User",
            "bio": "Hello world",
            "image": "https://example.com/avatar.png",
            "links": [
                {"title": "Website", "url": "https://example.com"}
            ]
        }
        """.data(using: .utf8)!

        // When - decode the profile
        let profile = try JSONDecoder().decode(SDKProfile.self, from: json)

        // Then - should have correct values
        XCTAssertEqual(profile.name, "Test User")
        XCTAssertEqual(profile.bio, "Hello world")
        XCTAssertEqual(profile.image, "https://example.com/avatar.png")
        XCTAssertEqual(profile.links?.count, 1)
        XCTAssertEqual(profile.links?.first?.title, "Website")
    }

    func testSDKProfileDecodableWithOptionalFields() throws {
        // Given - JSON with only required fields
        let json = """
        {}
        """.data(using: .utf8)!

        // When - decode the profile
        let profile = try JSONDecoder().decode(SDKProfile.self, from: json)

        // Then - optional fields should be nil
        XCTAssertNil(profile.name)
        XCTAssertNil(profile.bio)
        XCTAssertNil(profile.image)
        XCTAssertNil(profile.links)
    }

    func testSDKProfileEncodable() throws {
        // Given - a profile object
        let profile = SDKProfile(
            name: "Test",
            bio: "Bio",
            image: "https://img.com/a.png",
            links: [SDKProfileLink(title: "Link", url: "https://link.com")]
        )

        // When - encode to JSON
        let data = try JSONEncoder().encode(profile)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Then - should have correct structure
        XCTAssertEqual(json?["name"] as? String, "Test")
        XCTAssertEqual(json?["bio"] as? String, "Bio")
    }

    // MARK: - LegacyPubkySession Tests

    func testLegacyPubkySessionInitialization() {
        let session = LegacyPubkySession(
            pubkey: "pk123",
            sessionSecret: "secret",
            capabilities: ["read", "write"],
            expiresAt: Date(timeIntervalSince1970: 1700000000)
        )

        XCTAssertEqual(session.pubkey, "pk123")
        XCTAssertEqual(session.sessionSecret, "secret")
        XCTAssertEqual(session.capabilities, ["read", "write"])
        XCTAssertNotNil(session.expiresAt)
    }

    func testLegacyPubkySessionCodable() throws {
        // Given - a session
        let original = LegacyPubkySession(
            pubkey: "codabletest",
            sessionSecret: "secret123",
            capabilities: ["read"],
            expiresAt: Date(timeIntervalSince1970: 1700000000)
        )

        // When - encode and decode
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LegacyPubkySession.self, from: data)

        // Then - should match
        XCTAssertEqual(decoded.pubkey, original.pubkey)
        XCTAssertEqual(decoded.sessionSecret, original.sessionSecret)
        XCTAssertEqual(decoded.capabilities, original.capabilities)
    }

    // MARK: - PubkySDKError Tests

    func testPubkySDKErrorDescriptions() {
        XCTAssertNotNil(PubkySDKError.notConfigured.errorDescription)
        XCTAssertTrue(PubkySDKError.notConfigured.errorDescription!.contains("not configured"))

        XCTAssertNotNil(PubkySDKError.notFound.errorDescription)
        XCTAssertTrue(PubkySDKError.notFound.errorDescription!.contains("not found"))

        XCTAssertNotNil(PubkySDKError.noSession.errorDescription)
        XCTAssertTrue(PubkySDKError.noSession.errorDescription!.contains("session"))

        let inputError = PubkySDKError.invalidInput("bad value")
        XCTAssertTrue(inputError.errorDescription!.contains("bad value"))

        let networkError = PubkySDKError.networkError("timeout")
        XCTAssertTrue(networkError.errorDescription!.contains("timeout"))
    }
}

