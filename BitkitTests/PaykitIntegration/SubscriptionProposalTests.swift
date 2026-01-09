// SubscriptionProposalTests.swift
// BitkitTests
//
// Unit tests for subscription proposal send/receive flow

import XCTest
@testable import Bitkit

final class SubscriptionProposalTests: XCTestCase {

    // MARK: - DirectoryService.publishSubscriptionProposal Tests

    func testPublishSubscriptionProposalThrowsWhenNotConfigured() async throws {
        // Given - directory service without authenticated adapter
        let unconfiguredService = DirectoryService()
        let proposal = SubscriptionProposal(
            providerName: "Test Provider",
            providerPubkey: "ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u",
            amountSats: 1000,
            currency: "SAT",
            frequency: "monthly",
            description: "Test subscription"
        )
        
        // When/Then - should throw notConfigured error
        do {
            try await unconfiguredService.publishSubscriptionProposal(
                proposal,
                subscriberPubkey: "ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u"
            )
            XCTFail("Expected error to be thrown")
        } catch let error as DirectoryError {
            if case .notConfigured = error {
                // Expected
            } else {
                XCTFail("Expected notConfigured error, got: \(error)")
            }
        }
    }

    // MARK: - SubscriptionProposal Model Tests

    func testSubscriptionProposalInitialization() {
        let proposal = SubscriptionProposal(
            providerName: "Alice's Services",
            providerPubkey: "ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u",
            amountSats: 5000,
            currency: "SAT",
            frequency: "weekly",
            description: "Weekly newsletter"
        )
        
        XCTAssertFalse(proposal.id.isEmpty)
        XCTAssertEqual(proposal.providerName, "Alice's Services")
        XCTAssertEqual(proposal.providerPubkey, "ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u")
        XCTAssertEqual(proposal.amountSats, 5000)
        XCTAssertEqual(proposal.currency, "SAT")
        XCTAssertEqual(proposal.frequency, "weekly")
        XCTAssertEqual(proposal.description, "Weekly newsletter")
        XCTAssertEqual(proposal.methodId, "lightning")
    }

    func testSubscriptionProposalWithCustomId() {
        let customId = "custom-proposal-123"
        let proposal = SubscriptionProposal(
            id: customId,
            providerName: "Bob",
            providerPubkey: "ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u",
            amountSats: 1000,
            frequency: "monthly"
        )
        
        XCTAssertEqual(proposal.id, customId)
    }

    // MARK: - PaykitV0Protocol Subscription Path Tests

    func testSubscriptionProposalPathGeneration() throws {
        let providerPubkey = "8pinxxgqs41n4aididenw5apqp1urfmzdztr8jt4abrkdn435ewo"
        let subscriberPubkey = "ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u"
        let proposalId = "test-proposal-id"
        
        let path = try PaykitV0Protocol.subscriptionProposalPath(
            providerPubkeyZ32: providerPubkey,
            subscriberPubkeyZ32: subscriberPubkey,
            proposalId: proposalId
        )
        
        XCTAssertTrue(path.hasPrefix("/pub/paykit.app/v0/subscriptions/proposals/"))
        XCTAssertTrue(path.hasSuffix("/\(proposalId)"))
    }

    func testSubscriptionProposalAadGeneration() throws {
        let providerPubkey = "8pinxxgqs41n4aididenw5apqp1urfmzdztr8jt4abrkdn435ewo"
        let subscriberPubkey = "ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u"
        let proposalId = "test-proposal-id"
        
        let aad = try PaykitV0Protocol.subscriptionProposalAad(
            ownerPubkeyZ32: providerPubkey,
            providerPubkeyZ32: providerPubkey,
            subscriberPubkeyZ32: subscriberPubkey,
            proposalId: proposalId
        )
        
        XCTAssertTrue(aad.hasPrefix("paykit:v0:subscription_proposal:"))
        XCTAssertTrue(aad.contains(proposalId))
        XCTAssertTrue(aad.contains(providerPubkey)) // owner
    }

    func testSubscriptionProposalsDirGeneration() throws {
        let providerPubkey = "8pinxxgqs41n4aididenw5apqp1urfmzdztr8jt4abrkdn435ewo"
        let subscriberPubkey = "ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u"
        
        let dir = try PaykitV0Protocol.subscriptionProposalsDir(
            providerPubkeyZ32: providerPubkey,
            subscriberPubkeyZ32: subscriberPubkey
        )
        
        XCTAssertTrue(dir.hasPrefix("/pub/paykit.app/v0/subscriptions/proposals/"))
        XCTAssertTrue(dir.hasSuffix("/"))
    }

    // MARK: - DirectoryError.encryptionFailed Tests

    func testDirectoryErrorEncryptionFailedDescription() {
        let error = DirectoryError.encryptionFailed("No noise endpoint")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("Encryption failed"))
        XCTAssertTrue(error.errorDescription!.contains("No noise endpoint"))
    }

    // MARK: - SubscriptionsViewModel State Tests

    @MainActor
    func testSubscriptionsViewModelInitialState() {
        let viewModel = SubscriptionsViewModel()
        
        XCTAssertFalse(viewModel.isSending)
        XCTAssertFalse(viewModel.sendSuccess)
        XCTAssertNil(viewModel.sendError)
    }

    @MainActor
    func testSubscriptionsViewModelClearSendError() {
        let viewModel = SubscriptionsViewModel()
        
        // Simulate an error state (we can't set it directly, but can test the method exists)
        viewModel.clearSendError()
        
        XCTAssertNil(viewModel.sendError)
    }

    @MainActor
    func testSubscriptionsViewModelResetSendState() {
        let viewModel = SubscriptionsViewModel()
        
        viewModel.resetSendState()
        
        XCTAssertFalse(viewModel.sendSuccess)
        XCTAssertNil(viewModel.sendError)
    }

    // MARK: - DiscoveredSubscriptionProposal Tests

    func testDiscoveredSubscriptionProposalInitialization() {
        let proposal = DiscoveredSubscriptionProposal(
            subscriptionId: "disc-123",
            providerPubkey: "ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u",
            amountSats: 2000,
            description: "Monthly premium",
            frequency: "monthly",
            createdAt: Date()
        )
        
        XCTAssertEqual(proposal.subscriptionId, "disc-123")
        XCTAssertEqual(proposal.amountSats, 2000)
        XCTAssertEqual(proposal.frequency, "monthly")
        XCTAssertEqual(proposal.description, "Monthly premium")
    }

    // MARK: - Scope Hash Tests

    func testSubscriberScopeMatchesRecipientScope() throws {
        let pubkey = "ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u"
        
        let subscriberScope = try PaykitV0Protocol.subscriberScope(pubkey)
        let recipientScope = try PaykitV0Protocol.recipientScope(pubkey)
        
        XCTAssertEqual(subscriberScope, recipientScope)
        XCTAssertEqual(subscriberScope.count, 64) // SHA-256 hex = 64 chars
    }

    // MARK: - Purpose Constants Tests

    func testPurposeSubscriptionProposalConstant() {
        XCTAssertEqual(PaykitV0Protocol.purposeSubscriptionProposal, "subscription_proposal")
    }

    func testSubscriptionProposalsSubpathConstant() {
        XCTAssertEqual(PaykitV0Protocol.subscriptionProposalsSubpath, "subscriptions/proposals")
    }
}

