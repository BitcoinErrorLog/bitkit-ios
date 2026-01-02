import XCTest
@testable import Bitkit

/// Cross-platform test vectors for PaykitV0Protocol.
///
/// These test vectors MUST match the corresponding tests in:
/// - Rust: `paykit-lib/src/protocol/scope.rs` (cross_platform_scope_vectors)
/// - Android: `PaykitV0ProtocolTest.kt`
final class PaykitV0ProtocolTests: XCTestCase {
    
    // MARK: - Test Vectors (must match Rust and Kotlin)
    
    // Vector 1: test pubkey (all z32 chars)
    private let testPubkey1 = "ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u"
    private let expectedScope1 = "55340b54f918470e1f025a80bb3347934fad3f57189eef303d620e65468cde80"
    
    // Vector 2: default homeserver pubkey
    private let testPubkey2 = "8pinxxgqs41n4aididenw5apqp1urfmzdztr8jt4abrkdn435ewo"
    private let expectedScope2 = "04dc3323da61313c6f5404cf7921af2432ef867afe6cc4c32553858b8ac07f12"
    
    // MARK: - Normalization Tests
    
    func testNormalizePubkeyZ32_stripsPrefix() throws {
        let input = "pk:YBNDRFG8EJKMCPQXOT1UWISZA345H769YBNDRFG8EJKMCPQXOT1U"
        let result = try PaykitV0Protocol.normalizePubkeyZ32(input)
        XCTAssertEqual(result, "ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u")
    }
    
    func testNormalizePubkeyZ32_alreadyNormalized() throws {
        let result = try PaykitV0Protocol.normalizePubkeyZ32(testPubkey1)
        XCTAssertEqual(result, testPubkey1)
    }
    
    func testNormalizePubkeyZ32_trimsWhitespace() throws {
        let input = "  pk:ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u  "
        let result = try PaykitV0Protocol.normalizePubkeyZ32(input)
        XCTAssertEqual(result, "ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u")
    }
    
    func testNormalizePubkeyZ32_rejectsWrongLength() {
        XCTAssertThrowsError(try PaykitV0Protocol.normalizePubkeyZ32("tooshort"))
    }
    
    func testNormalizePubkeyZ32_rejectsInvalidChars() {
        // 'l' and 'v' are not in z32 alphabet
        XCTAssertThrowsError(try PaykitV0Protocol.normalizePubkeyZ32("lbndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u"))
    }
    
    // MARK: - Scope Tests (cross-platform vectors)
    
    func testRecipientScope_vector1() throws {
        let scope = try PaykitV0Protocol.recipientScope(testPubkey1)
        XCTAssertEqual(scope, expectedScope1, "Scope for vector 1 must match Rust/Kotlin")
    }
    
    func testRecipientScope_vector2() throws {
        let scope = try PaykitV0Protocol.recipientScope(testPubkey2)
        XCTAssertEqual(scope, expectedScope2, "Scope for vector 2 must match Rust/Kotlin")
    }
    
    func testRecipientScope_deterministic() throws {
        let scope1 = try PaykitV0Protocol.recipientScope(testPubkey1)
        let scope2 = try PaykitV0Protocol.recipientScope(testPubkey1)
        XCTAssertEqual(scope1, scope2)
        XCTAssertEqual(scope1.count, 64) // 256 bits = 64 hex chars
    }
    
    func testRecipientScope_differsForDifferentPubkeys() throws {
        let scope1 = try PaykitV0Protocol.recipientScope(testPubkey1)
        let scope2 = try PaykitV0Protocol.recipientScope(testPubkey2)
        XCTAssertNotEqual(scope1, scope2)
    }
    
    func testSubscriberScope_isAliasForRecipientScope() throws {
        let rScope = try PaykitV0Protocol.recipientScope(testPubkey1)
        let sScope = try PaykitV0Protocol.subscriberScope(testPubkey1)
        XCTAssertEqual(rScope, sScope)
    }
    
    // MARK: - Path Tests
    
    func testPaymentRequestPath_hasCorrectFormat() throws {
        let path = try PaykitV0Protocol.paymentRequestPath(recipientPubkeyZ32: testPubkey1, requestId: "req-123")
        XCTAssertTrue(path.hasPrefix("/pub/paykit.app/v0/requests/"))
        XCTAssertTrue(path.hasSuffix("/req-123"))
        let parts = path.split(separator: "/")
        XCTAssertEqual(parts.count, 6)
        XCTAssertEqual(parts[4].count, 64) // scope is 64 hex chars
    }
    
    func testPaymentRequestsDir_hasCorrectFormat() throws {
        let dir = try PaykitV0Protocol.paymentRequestsDir(recipientPubkeyZ32: testPubkey1)
        XCTAssertTrue(dir.hasPrefix("/pub/paykit.app/v0/requests/"))
        XCTAssertTrue(dir.hasSuffix("/"))
    }
    
    func testSubscriptionProposalPath_hasCorrectFormat() throws {
        let path = try PaykitV0Protocol.subscriptionProposalPath(subscriberPubkeyZ32: testPubkey1, proposalId: "prop-456")
        XCTAssertTrue(path.hasPrefix("/pub/paykit.app/v0/subscriptions/proposals/"))
        XCTAssertTrue(path.hasSuffix("/prop-456"))
        let parts = path.split(separator: "/")
        XCTAssertEqual(parts.count, 7)
        XCTAssertEqual(parts[5].count, 64) // scope is 64 hex chars
    }
    
    func testSubscriptionProposalsDir_hasCorrectFormat() throws {
        let dir = try PaykitV0Protocol.subscriptionProposalsDir(subscriberPubkeyZ32: testPubkey1)
        XCTAssertTrue(dir.hasPrefix("/pub/paykit.app/v0/subscriptions/proposals/"))
        XCTAssertTrue(dir.hasSuffix("/"))
    }
    
    func testNoiseEndpointPath_isFixed() {
        let path = PaykitV0Protocol.noiseEndpointPath()
        XCTAssertEqual(path, "/pub/paykit.app/v0/noise")
    }
    
    func testSecureHandoffPath_hasCorrectFormat() {
        let path = PaykitV0Protocol.secureHandoffPath(requestId: "handoff-789")
        XCTAssertEqual(path, "/pub/paykit.app/v0/handoff/handoff-789")
    }
    
    // MARK: - AAD Tests
    
    func testPaymentRequestAad_hasCorrectFormat() throws {
        let aad = try PaykitV0Protocol.paymentRequestAad(recipientPubkeyZ32: testPubkey1, requestId: "req-123")
        XCTAssertTrue(aad.hasPrefix("paykit:v0:request:"))
        XCTAssertTrue(aad.hasSuffix(":req-123"))
    }
    
    func testSubscriptionProposalAad_hasCorrectFormat() throws {
        let aad = try PaykitV0Protocol.subscriptionProposalAad(subscriberPubkeyZ32: testPubkey1, proposalId: "prop-456")
        XCTAssertTrue(aad.hasPrefix("paykit:v0:subscription_proposal:"))
        XCTAssertTrue(aad.hasSuffix(":prop-456"))
    }
    
    func testSecureHandoffAad_hasCorrectFormat() {
        let aad = PaykitV0Protocol.secureHandoffAad(ownerPubkeyZ32: testPubkey1, requestId: "handoff-789")
        XCTAssertTrue(aad.hasPrefix("paykit:v0:handoff:"))
        XCTAssertTrue(aad.contains(testPubkey1))
        XCTAssertTrue(aad.contains("/pub/paykit.app/v0/handoff/handoff-789"))
        XCTAssertTrue(aad.hasSuffix(":handoff-789"))
    }
    
    func testRelaySessionAad_hasCorrectFormat() {
        let aad = PaykitV0Protocol.relaySessionAad(requestId: "abc123")
        XCTAssertEqual(aad, "paykit:v0:relay:session:abc123")
    }
    
    func testBuildAad_producesCorrectFormat() {
        let aad = PaykitV0Protocol.buildAad(purpose: "custom", path: "/some/path", id: "id-123")
        XCTAssertEqual(aad, "paykit:v0:custom:/some/path:id-123")
    }
    
    func testAad_isDeterministic() throws {
        let aad1 = try PaykitV0Protocol.paymentRequestAad(recipientPubkeyZ32: testPubkey1, requestId: "req-123")
        let aad2 = try PaykitV0Protocol.paymentRequestAad(recipientPubkeyZ32: testPubkey1, requestId: "req-123")
        XCTAssertEqual(aad1, aad2)
    }
    
    func testAad_differsForDifferentIds() throws {
        let aad1 = try PaykitV0Protocol.paymentRequestAad(recipientPubkeyZ32: testPubkey1, requestId: "req-123")
        let aad2 = try PaykitV0Protocol.paymentRequestAad(recipientPubkeyZ32: testPubkey1, requestId: "req-456")
        XCTAssertNotEqual(aad1, aad2)
    }
    
    func testAad_differsForDifferentRecipients() throws {
        let aad1 = try PaykitV0Protocol.paymentRequestAad(recipientPubkeyZ32: testPubkey1, requestId: "req-123")
        let aad2 = try PaykitV0Protocol.paymentRequestAad(recipientPubkeyZ32: testPubkey2, requestId: "req-123")
        XCTAssertNotEqual(aad1, aad2)
    }
}

