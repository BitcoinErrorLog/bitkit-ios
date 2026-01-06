import XCTest
@testable import Bitkit

@MainActor
final class NonceStorageTests: XCTestCase {

    private var storage: NonceStorage!
    private var mockDefaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        // Use a unique suite name for each test to isolate test data
        suiteName = "NonceStorageTests-\(UUID())"
        mockDefaults = UserDefaults(suiteName: suiteName)!
        storage = NonceStorage(userDefaults: mockDefaults)
    }

    override func tearDown() {
        // Clean up the test defaults using the actual suite name
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        storage = nil
        mockDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - checkAndMark Tests

    func test_freshNonceIsAccepted() {
        let nonce = "abc123def456abc123def456abc123def456abc123def456abc123def456abcd"
        let expiresAt = Int64(Date().timeIntervalSince1970) + 3600

        let result = storage.checkAndMark(nonce: nonce, expiresAt: expiresAt)

        XCTAssertTrue(result, "Fresh nonce should be accepted")
    }

    func test_duplicateNonceIsRejected() {
        let nonce = "abc123def456abc123def456abc123def456abc123def456abc123def456abcd"
        let expiresAt = Int64(Date().timeIntervalSince1970) + 3600

        // First use - should succeed
        let first = storage.checkAndMark(nonce: nonce, expiresAt: expiresAt)
        XCTAssertTrue(first, "First use should succeed")

        // Second use - should fail (replay attack)
        let second = storage.checkAndMark(nonce: nonce, expiresAt: expiresAt)
        XCTAssertFalse(second, "Duplicate nonce should be rejected")
    }

    func test_differentNoncesAreBothAccepted() {
        let nonce1 = "1111111111111111111111111111111111111111111111111111111111111111"
        let nonce2 = "2222222222222222222222222222222222222222222222222222222222222222"
        let expiresAt = Int64(Date().timeIntervalSince1970) + 3600

        let first = storage.checkAndMark(nonce: nonce1, expiresAt: expiresAt)
        let second = storage.checkAndMark(nonce: nonce2, expiresAt: expiresAt)

        XCTAssertTrue(first, "First nonce should be accepted")
        XCTAssertTrue(second, "Second nonce should be accepted")
    }

    // MARK: - isUsed Tests

    func test_isUsedReturnsTrueForUsedNonce() {
        let nonce = "abc123def456abc123def456abc123def456abc123def456abc123def456abcd"
        let expiresAt = Int64(Date().timeIntervalSince1970) + 3600

        XCTAssertFalse(storage.isUsed(nonce: nonce), "Should not be used initially")

        _ = storage.checkAndMark(nonce: nonce, expiresAt: expiresAt)

        XCTAssertTrue(storage.isUsed(nonce: nonce), "Should be used after marking")
    }

    // MARK: - cleanupExpired Tests

    func test_cleanupExpiredRemovesOldNonces() {
        let now = Int64(Date().timeIntervalSince1970)

        // Add an old nonce (expired 1000 seconds ago)
        let oldNonce = "old_nonce_1111111111111111111111111111111111111111111111111111"
        _ = storage.checkAndMark(nonce: oldNonce, expiresAt: now - 1000)

        // Add a recent nonce (expires in 1000 seconds)
        let recentNonce = "recent_nonce_2222222222222222222222222222222222222222222222222"
        _ = storage.checkAndMark(nonce: recentNonce, expiresAt: now + 1000)

        XCTAssertEqual(storage.count(), 2)

        let removed = storage.cleanupExpired(before: now)

        XCTAssertEqual(removed, 1, "Should remove 1 expired nonce")
        XCTAssertFalse(storage.isUsed(nonce: oldNonce), "Old nonce should be removed")
        XCTAssertTrue(storage.isUsed(nonce: recentNonce), "Recent nonce should remain")
    }

    // MARK: - count Tests

    func test_countReturnsCorrectNumberOfNonces() {
        XCTAssertEqual(storage.count(), 0, "Should start empty")

        let nonce1 = "1111111111111111111111111111111111111111111111111111111111111111"
        let nonce2 = "2222222222222222222222222222222222222222222222222222222222222222"
        let expiresAt = Int64(Date().timeIntervalSince1970) + 3600

        _ = storage.checkAndMark(nonce: nonce1, expiresAt: expiresAt)
        XCTAssertEqual(storage.count(), 1)

        _ = storage.checkAndMark(nonce: nonce2, expiresAt: expiresAt)
        XCTAssertEqual(storage.count(), 2)
    }

    // MARK: - clear Tests

    func test_clearRemovesAllNonces() {
        let nonce1 = "1111111111111111111111111111111111111111111111111111111111111111"
        let nonce2 = "2222222222222222222222222222222222222222222222222222222222222222"
        let expiresAt = Int64(Date().timeIntervalSince1970) + 3600

        _ = storage.checkAndMark(nonce: nonce1, expiresAt: expiresAt)
        _ = storage.checkAndMark(nonce: nonce2, expiresAt: expiresAt)
        XCTAssertEqual(storage.count(), 2)

        storage.clear()

        XCTAssertEqual(storage.count(), 0, "Should be empty after clear")
    }

    // MARK: - Persistence Tests

    func test_noncePersistsAcrossInstances() {
        let nonce = "abc123def456abc123def456abc123def456abc123def456abc123def456abcd"
        let expiresAt = Int64(Date().timeIntervalSince1970) + 3600

        // First instance: mark nonce
        _ = storage.checkAndMark(nonce: nonce, expiresAt: expiresAt)

        // Second instance with same UserDefaults: should see the nonce as used
        let storage2 = NonceStorage(userDefaults: mockDefaults)
        XCTAssertTrue(storage2.isUsed(nonce: nonce), "Nonce should persist across instances")
        XCTAssertFalse(
            storage2.checkAndMark(nonce: nonce, expiresAt: expiresAt),
            "Persisted nonce should be rejected"
        )
    }
}

