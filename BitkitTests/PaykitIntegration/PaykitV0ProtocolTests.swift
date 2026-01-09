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
    
    // All-zeros pubkey (52 y's) for ContextId tests
    private let allZerosPubkey = "yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy"
    
    // MARK: - Normalization Tests
    
    func testNormalizePubkeyZ32_stripsPrefix() throws {
        let input = "pk:YBNDRFG8EJKMCPQXOT1UWISZA345H769YBNDRFG8EJKMCPQXOT1U"
        let result = try PaykitV0Protocol.normalizePubkeyZ32(input)
        XCTAssertEqual(result, "ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u")
    }
    
    func testNormalizePubkeyZ32_stripsPubkyUriPrefix() throws {
        let input = "pubky://ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u"
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
    
    // MARK: - ContextId Tests (Sealed Blob v2)
    
    func testContextId_isSymmetric() throws {
        let ctxAB = try PaykitV0Protocol.contextId(testPubkey1, testPubkey2)
        let ctxBA = try PaykitV0Protocol.contextId(testPubkey2, testPubkey1)
        XCTAssertEqual(ctxAB, ctxBA)
    }
    
    func testContextId_produces64CharHex() throws {
        let ctx = try PaykitV0Protocol.contextId(testPubkey1, testPubkey2)
        XCTAssertEqual(ctx.count, 64)
        XCTAssertTrue(ctx.allSatisfy { $0.isHexDigit })
    }
    
    func testContextId_isDeterministic() throws {
        let ctx1 = try PaykitV0Protocol.contextId(testPubkey1, testPubkey2)
        let ctx2 = try PaykitV0Protocol.contextId(testPubkey1, testPubkey2)
        XCTAssertEqual(ctx1, ctx2)
    }
    
    func testContextId_differsForDifferentPeerPairs() throws {
        let ctx1 = try PaykitV0Protocol.contextId(testPubkey1, testPubkey2)
        let ctx2 = try PaykitV0Protocol.contextId(testPubkey1, allZerosPubkey)
        XCTAssertNotEqual(ctx1, ctx2)
    }
    
    func testContextId_normalizesPkPrefix() throws {
        let ctxNormal = try PaykitV0Protocol.contextId(testPubkey1, testPubkey2)
        let ctxWithPrefix = try PaykitV0Protocol.contextId("pk:\(testPubkey1)", "pk:\(testPubkey2)")
        XCTAssertEqual(ctxNormal, ctxWithPrefix)
    }
    
    func testContextId_normalizesPubkyUriPrefix() throws {
        let ctxNormal = try PaykitV0Protocol.contextId(testPubkey1, testPubkey2)
        let ctxWithUri = try PaykitV0Protocol.contextId("pubky://\(testPubkey1)", "pubky://\(testPubkey2)")
        XCTAssertEqual(ctxNormal, ctxWithUri)
    }
    
    // MARK: - Legacy Scope Tests (Deprecated but still functional)
    
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
    
    // MARK: - Path Tests (ContextId-based)
    
    func testPaymentRequestPath_hasCorrectFormat() throws {
        let path = try PaykitV0Protocol.paymentRequestPath(
            senderPubkeyZ32: testPubkey1,
            recipientPubkeyZ32: testPubkey2,
            requestId: "req-123"
        )
        XCTAssertTrue(path.hasPrefix("/pub/paykit.app/v0/requests/"))
        XCTAssertTrue(path.hasSuffix("/req-123"))
        let parts = path.split(separator: "/")
        XCTAssertEqual(parts.count, 6)
        XCTAssertEqual(parts[4].count, 64) // contextId is 64 hex chars
    }
    
    func testPaymentRequestPath_isSymmetric() throws {
        let path1 = try PaykitV0Protocol.paymentRequestPath(
            senderPubkeyZ32: testPubkey1,
            recipientPubkeyZ32: testPubkey2,
            requestId: "req-123"
        )
        let path2 = try PaykitV0Protocol.paymentRequestPath(
            senderPubkeyZ32: testPubkey2,
            recipientPubkeyZ32: testPubkey1,
            requestId: "req-123"
        )
        XCTAssertEqual(path1, path2)
    }
    
    func testPaymentRequestsDir_hasCorrectFormat() throws {
        let dir = try PaykitV0Protocol.paymentRequestsDir(
            senderPubkeyZ32: testPubkey1,
            recipientPubkeyZ32: testPubkey2
        )
        XCTAssertTrue(dir.hasPrefix("/pub/paykit.app/v0/requests/"))
        XCTAssertTrue(dir.hasSuffix("/"))
    }
    
    func testSubscriptionProposalPath_hasCorrectFormat() throws {
        let path = try PaykitV0Protocol.subscriptionProposalPath(
            providerPubkeyZ32: testPubkey1,
            subscriberPubkeyZ32: testPubkey2,
            proposalId: "prop-456"
        )
        XCTAssertTrue(path.hasPrefix("/pub/paykit.app/v0/subscriptions/proposals/"))
        XCTAssertTrue(path.hasSuffix("/prop-456"))
        let parts = path.split(separator: "/")
        XCTAssertEqual(parts.count, 7)
        XCTAssertEqual(parts[5].count, 64) // contextId is 64 hex chars
    }
    
    func testSubscriptionProposalsDir_hasCorrectFormat() throws {
        let dir = try PaykitV0Protocol.subscriptionProposalsDir(
            providerPubkeyZ32: testPubkey1,
            subscriberPubkeyZ32: testPubkey2
        )
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
    
    func testAckPath_hasCorrectFormat() throws {
        let path = try PaykitV0Protocol.ackPath(
            objectType: "request",
            senderPubkeyZ32: testPubkey1,
            recipientPubkeyZ32: testPubkey2,
            msgId: "msg-123"
        )
        XCTAssertTrue(path.hasPrefix("/pub/paykit.app/v0/acks/request/"))
        XCTAssertTrue(path.hasSuffix("/msg-123"))
        let parts = path.split(separator: "/")
        XCTAssertEqual(parts.count, 7)
        XCTAssertEqual(parts[5].count, 64) // contextId is 64 hex chars
    }
    
    func testAckPath_isSymmetric() throws {
        let path1 = try PaykitV0Protocol.ackPath(
            objectType: "request",
            senderPubkeyZ32: testPubkey1,
            recipientPubkeyZ32: testPubkey2,
            msgId: "msg-123"
        )
        let path2 = try PaykitV0Protocol.ackPath(
            objectType: "request",
            senderPubkeyZ32: testPubkey2,
            recipientPubkeyZ32: testPubkey1,
            msgId: "msg-123"
        )
        XCTAssertEqual(path1, path2)
    }
    
    // MARK: - AAD Tests (Owner-bound for Sealed Blob v2)
    
    func testPaymentRequestAad_hasCorrectFormat() throws {
        let aad = try PaykitV0Protocol.paymentRequestAad(
            ownerPubkeyZ32: testPubkey1,
            senderPubkeyZ32: testPubkey1,
            recipientPubkeyZ32: testPubkey2,
            requestId: "req-123"
        )
        XCTAssertTrue(aad.hasPrefix("paykit:v0:request:"))
        XCTAssertTrue(aad.contains(testPubkey1)) // owner
        XCTAssertTrue(aad.contains("/pub/paykit.app/v0/requests/"))
        XCTAssertTrue(aad.hasSuffix(":req-123"))
    }
    
    func testSubscriptionProposalAad_hasCorrectFormat() throws {
        let aad = try PaykitV0Protocol.subscriptionProposalAad(
            ownerPubkeyZ32: testPubkey1,
            providerPubkeyZ32: testPubkey1,
            subscriberPubkeyZ32: testPubkey2,
            proposalId: "prop-456"
        )
        XCTAssertTrue(aad.hasPrefix("paykit:v0:subscription_proposal:"))
        XCTAssertTrue(aad.contains(testPubkey1)) // owner
        XCTAssertTrue(aad.contains("/pub/paykit.app/v0/subscriptions/proposals/"))
        XCTAssertTrue(aad.hasSuffix(":prop-456"))
    }
    
    func testSecureHandoffAad_hasCorrectFormat() throws {
        let aad = try PaykitV0Protocol.secureHandoffAad(ownerPubkeyZ32: testPubkey1, requestId: "handoff-789")
        XCTAssertTrue(aad.hasPrefix("paykit:v0:handoff:"))
        XCTAssertTrue(aad.contains(testPubkey1))
        XCTAssertTrue(aad.contains("/pub/paykit.app/v0/handoff/handoff-789"))
        XCTAssertTrue(aad.hasSuffix(":handoff-789"))
    }
    
    func testAckAad_hasCorrectFormat() throws {
        let aad = try PaykitV0Protocol.ackAad(
            objectType: "request",
            ackWriterPubkeyZ32: testPubkey2,
            senderPubkeyZ32: testPubkey1,
            recipientPubkeyZ32: testPubkey2,
            msgId: "msg-123"
        )
        XCTAssertTrue(aad.hasPrefix("paykit:v0:ack_request:"))
        XCTAssertTrue(aad.contains(testPubkey2)) // ACK writer
        XCTAssertTrue(aad.contains("/pub/paykit.app/v0/acks/request/"))
        XCTAssertTrue(aad.hasSuffix(":msg-123"))
    }
    
    func testRelaySessionAad_hasCorrectFormat() {
        let aad = PaykitV0Protocol.relaySessionAad(requestId: "abc123")
        XCTAssertEqual(aad, "paykit:v0:relay:session:abc123")
    }
    
    func testAad_isDeterministic() throws {
        let aad1 = try PaykitV0Protocol.paymentRequestAad(
            ownerPubkeyZ32: testPubkey1,
            senderPubkeyZ32: testPubkey1,
            recipientPubkeyZ32: testPubkey2,
            requestId: "req-123"
        )
        let aad2 = try PaykitV0Protocol.paymentRequestAad(
            ownerPubkeyZ32: testPubkey1,
            senderPubkeyZ32: testPubkey1,
            recipientPubkeyZ32: testPubkey2,
            requestId: "req-123"
        )
        XCTAssertEqual(aad1, aad2)
    }
    
    func testAad_differsForDifferentIds() throws {
        let aad1 = try PaykitV0Protocol.paymentRequestAad(
            ownerPubkeyZ32: testPubkey1,
            senderPubkeyZ32: testPubkey1,
            recipientPubkeyZ32: testPubkey2,
            requestId: "req-123"
        )
        let aad2 = try PaykitV0Protocol.paymentRequestAad(
            ownerPubkeyZ32: testPubkey1,
            senderPubkeyZ32: testPubkey1,
            recipientPubkeyZ32: testPubkey2,
            requestId: "req-456"
        )
        XCTAssertNotEqual(aad1, aad2)
    }
    
    func testAad_differsForDifferentOwners() throws {
        let aad1 = try PaykitV0Protocol.paymentRequestAad(
            ownerPubkeyZ32: testPubkey1,
            senderPubkeyZ32: testPubkey1,
            recipientPubkeyZ32: testPubkey2,
            requestId: "req-123"
        )
        let aad2 = try PaykitV0Protocol.paymentRequestAad(
            ownerPubkeyZ32: testPubkey2,
            senderPubkeyZ32: testPubkey1,
            recipientPubkeyZ32: testPubkey2,
            requestId: "req-123"
        )
        XCTAssertNotEqual(aad1, aad2)
    }
    
    func testAad_differsForDifferentRecipients() throws {
        let aad1 = try PaykitV0Protocol.paymentRequestAad(
            ownerPubkeyZ32: testPubkey1,
            senderPubkeyZ32: testPubkey1,
            recipientPubkeyZ32: testPubkey2,
            requestId: "req-123"
        )
        let aad2 = try PaykitV0Protocol.paymentRequestAad(
            ownerPubkeyZ32: testPubkey1,
            senderPubkeyZ32: testPubkey1,
            recipientPubkeyZ32: allZerosPubkey,
            requestId: "req-123"
        )
        XCTAssertNotEqual(aad1, aad2)
    }
}
