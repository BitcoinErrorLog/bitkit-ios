//
//  SubscriptionsViewModel.swift
//  Bitkit
//
//  ViewModel for Subscriptions management with proposals, payment history, and spending limits
//

import Foundation
import SwiftUI

@MainActor
class SubscriptionsViewModel: ObservableObject {
    @Published var subscriptions: [BitkitSubscription] = []
    @Published var proposals: [SubscriptionProposal] = []
    @Published var sentProposals: [SentProposal] = []
    @Published var paymentHistory: [SubscriptionPayment] = []
    @Published var isLoading = false
    @Published var isLoadingSentProposals = false
    @Published var showingAddSubscription = false
    
    // Sending proposal state
    @Published var isSending = false
    @Published var sendSuccess = false
    @Published var sendError: String?
    
    // Spending limit tracking
    @Published var totalSpentThisMonth: Int64 = 0
    @Published var monthlySpendingLimit: Int64 = 1000000 // 1M sats default
    
    var remainingSpendingLimit: Int64 {
        max(0, monthlySpendingLimit - totalSpentThisMonth)
    }
    
    private let subscriptionStorage: SubscriptionStorage
    private let directoryService: DirectoryService
    private let identityName: String
    
    init(identityName: String? = nil, directoryService: DirectoryService = .shared) {
        // Use the current pubkey for storage key to match PaykitPollingService behavior
        self.identityName = identityName ?? PaykitKeyManager.shared.getCurrentPublicKeyZ32() ?? "default"
        self.subscriptionStorage = SubscriptionStorage(identityName: self.identityName)
        self.directoryService = directoryService
    }
    
    func loadSubscriptions() {
        isLoading = true
        subscriptions = subscriptionStorage.listSubscriptions()
        calculateSpending()
        isLoading = false
    }
    
    func loadProposals() {
        // Invalidate cache to ensure we get fresh data after polling
        subscriptionStorage.invalidateCache()
        proposals = subscriptionStorage.pendingProposals()
    }
    
    func loadPaymentHistory() {
        paymentHistory = subscriptionStorage.listPayments()
    }
    
    func loadSentProposals() {
        isLoadingSentProposals = true
        sentProposals = subscriptionStorage.listSentProposals()
        isLoadingSentProposals = false
    }
    
    /// Discover proposals from network by polling known peers.
    @Published var isDiscovering = false
    @Published var discoveryResult: String?
    
    func discoverProposals() async {
        isDiscovering = true
        discoveryResult = nil
        
        // Check if we have an identity
        guard let myPubkey = PaykitKeyManager.shared.getCurrentPublicKeyZ32() else {
            discoveryResult = "No identity configured"
            isDiscovering = false
            return
        }
        
        Logger.info("=== DISCOVERY START ===", context: "SubscriptionsVM")
        Logger.info("My full pubkey: \(myPubkey)", context: "SubscriptionsVM")
        
        // Check follows
        do {
            let follows = try await directoryService.fetchFollows()
            if follows.isEmpty {
                discoveryResult = "No follows. My pk: \(myPubkey.prefix(12))..."
                isDiscovering = false
                return
            }
            
            // Log discovery context (ContextId is symmetric so we compute per-peer)
            Logger.info("My pubkey: \(myPubkey.prefix(12))..., will check ContextId paths for each follow", context: "SubscriptionsVM")
            Logger.info("Follows (peers to check): \(follows)", context: "SubscriptionsVM")
            
            discoveryResult = "Polling \(follows.count) peers..."
            
            await PaykitPollingService.shared.pollNow()
            loadProposals()
            
            if proposals.isEmpty {
                // Show debug info - check if noise key is missing
                let firstFollow = follows.first ?? "none"
                let noiseKeypair = PaykitKeyManager.shared.getCachedNoiseKeypair()
                let hasNoiseKey = noiseKeypair != nil
                if !hasNoiseKey {
                    discoveryResult = "⚠️ No Noise key!\nReconnect to Pubky Ring to get crypto keys.\nFollow: \(firstFollow.prefix(20))..."
                } else {
                    discoveryResult = "0 proposals found.\nNoise ✓ epoch \(noiseKeypair?.epoch ?? 0)\n\(follows.count) follows checked"
                }
            } else {
                discoveryResult = "Found \(proposals.count) proposals!"
            }
        } catch {
            discoveryResult = "Error: \(error.localizedDescription)"
        }
        
        isDiscovering = false
    }
    
    private func calculateSpending() {
        let calendar = Calendar.current
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))!
        
        totalSpentThisMonth = paymentHistory
            .filter { $0.paidAt >= startOfMonth && $0.status == .completed }
            .reduce(0) { $0 + $1.amountSats }
    }
    
    func addSubscription(_ subscription: BitkitSubscription) throws {
        try subscriptionStorage.saveSubscription(subscription)
        loadSubscriptions()
    }
    
    func updateSubscription(_ subscription: BitkitSubscription) throws {
        try subscriptionStorage.saveSubscription(subscription)
        loadSubscriptions()
    }
    
    func deleteSubscription(_ subscription: BitkitSubscription) throws {
        try subscriptionStorage.deleteSubscription(id: subscription.id)
        loadSubscriptions()
    }
    
    func toggleActive(_ subscription: BitkitSubscription) throws {
        try subscriptionStorage.toggleActive(id: subscription.id)
        loadSubscriptions()
    }
    
    func recordPayment(_ subscription: BitkitSubscription) throws {
        try subscriptionStorage.recordPayment(subscriptionId: subscription.id)
        loadSubscriptions()
        loadPaymentHistory()
    }
    
    // MARK: - Proposals
    
    func acceptProposal(_ proposal: SubscriptionProposal) throws {
        let subscription = BitkitSubscription(
            providerName: proposal.providerName,
            providerPubkey: proposal.providerPubkey,
            amountSats: UInt64(proposal.amountSats),
            currency: proposal.currency,
            frequency: proposal.frequency,
            description: proposal.description,
            methodId: proposal.methodId
        )
        
        try subscriptionStorage.saveSubscription(subscription)
        try subscriptionStorage.deleteProposal(id: proposal.id)
        loadSubscriptions()
        loadProposals()
    }
    
    func declineProposal(_ proposal: SubscriptionProposal) throws {
        // Mark as declined locally (no remote delete in provider-storage model)
        try subscriptionStorage.markProposalAsDeclined(id: proposal.id)
        loadProposals()
    }
    
    /// Dismiss a received proposal locally (remove from pending list).
    func dismissProposal(_ proposal: SubscriptionProposal) throws {
        try subscriptionStorage.deleteProposal(id: proposal.id)
        loadProposals()
    }
    
    // MARK: - Sent Proposals Management
    
    /// Cancel a sent proposal (delete from homeserver and local storage).
    ///
    /// As the provider, we can delete proposals we've sent.
    @Published var isDeletingSentProposal = false
    @Published var deleteSentProposalError: String?
    
    func cancelSentProposal(_ proposal: SentProposal) async {
        isDeletingSentProposal = true
        deleteSentProposalError = nil
        
        do {
            // Delete from homeserver
            try await directoryService.deleteSubscriptionProposal(
                proposalId: proposal.id,
                subscriberPubkey: proposal.recipientPubkey
            )
            
            // Delete from local storage
            try subscriptionStorage.deleteSentProposal(id: proposal.id)
            
            // Reload the list
            loadSentProposals()
            Logger.info("Cancelled sent proposal: \(proposal.id)", context: "SubscriptionsVM")
        } catch {
            deleteSentProposalError = error.localizedDescription
            Logger.error("Failed to cancel sent proposal: \(error)", context: "SubscriptionsVM")
        }
        
        isDeletingSentProposal = false
    }
    
    /// Clean up orphaned proposals from the homeserver.
    ///
    /// This finds proposals that exist on the homeserver but aren't tracked locally
    /// (e.g., from previous sessions or failed deletions) and deletes them.
    ///
    /// - Returns: Number of orphaned proposals deleted
    @discardableResult
    func cleanupOrphanedProposals() async -> Int {
        Logger.info("Starting orphaned proposal cleanup", context: "SubscriptionsVM")
        
        // Get all sent proposals and group tracked IDs by recipient
        // This prevents cross-recipient false matches where proposal IDs could theoretically collide
        let sentProposals = subscriptionStorage.listSentProposals()
        let trackedIdsByRecipient = Dictionary(grouping: sentProposals, by: { $0.recipientPubkey })
            .mapValues { Set($0.map { $0.id }) }
        
        var totalDeleted = 0
        
        for (recipientPubkey, trackedIds) in trackedIdsByRecipient {
            do {
                // List all proposals on homeserver for this recipient
                let homeserverProposals = try await directoryService.listProposalsOnHomeserver(subscriberPubkey: recipientPubkey)
                
                // Find orphaned proposals (on homeserver but not tracked locally for THIS recipient)
                let orphanedIds = homeserverProposals.filter { !trackedIds.contains($0) }
                
                if !orphanedIds.isEmpty {
                    Logger.info("Found \(orphanedIds.count) orphaned proposals for \(recipientPubkey.prefix(12))...", context: "SubscriptionsVM")
                    let deleted = await directoryService.deleteProposalsBatch(proposalIds: orphanedIds, subscriberPubkey: recipientPubkey)
                    totalDeleted += deleted
                }
            } catch {
                Logger.warn("Failed to check proposals for \(recipientPubkey.prefix(12))...: \(error)", context: "SubscriptionsVM")
            }
        }
        
        Logger.info("Cleanup complete: deleted \(totalDeleted) orphaned proposals", context: "SubscriptionsVM")
        return totalDeleted
    }
    
    // MARK: - Send Proposal
    
    /// Send a subscription proposal to a subscriber.
    ///
    /// This encrypts the proposal and publishes it to our homeserver storage
    /// for the subscriber to discover and accept.
    ///
    /// - Parameters:
    ///   - recipientPubkey: The z32 pubkey of the subscriber
    ///   - amountSats: Amount in satoshis per payment
    ///   - frequency: Payment frequency (daily, weekly, monthly, yearly)
    ///   - description: Optional description
    func sendSubscriptionProposal(
        recipientPubkey: String,
        amountSats: Int64,
        frequency: String,
        description: String?
    ) async {
        isSending = true
        sendSuccess = false
        sendError = nil
        
        guard PaykitKeyManager.shared.getCurrentPublicKeyZ32() != nil else {
            sendError = "No identity configured"
            isSending = false
            return
        }
        
        let proposal = SubscriptionProposal(
            providerName: "",
            providerPubkey: "", // Will be set by DirectoryService from our identity
            amountSats: amountSats,
            currency: "SAT",
            frequency: frequency,
            description: description ?? "",
            methodId: "lightning"
        )
        
        do {
            let trimmedRecipient = recipientPubkey.trimmingCharacters(in: .whitespaces)
            try await directoryService.publishSubscriptionProposal(proposal, subscriberPubkey: trimmedRecipient)
            
            // Save sent proposal locally for tracking
            let sentProposal = SentProposal(
                id: proposal.id,
                recipientPubkey: trimmedRecipient,
                amountSats: amountSats,
                frequency: frequency,
                description: description,
                createdAt: Date(),
                status: .pending
            )
            try? subscriptionStorage.saveSentProposal(sentProposal)
            loadSentProposals()
            
            sendSuccess = true
            isSending = false
        } catch {
            sendError = error.localizedDescription
            isSending = false
        }
    }
    
    /// Clear the send error
    func clearSendError() {
        sendError = nil
    }
    
    /// Reset send state after successful send
    func resetSendState() {
        sendSuccess = false
        sendError = nil
    }
    
    // MARK: - Spending Limits
    
    func updateSpendingLimit(_ subscription: BitkitSubscription, limit: SubscriptionSpendingLimit?) throws {
        var updated = subscription
        updated.spendingLimit = limit
        try subscriptionStorage.saveSubscription(updated)
        loadSubscriptions()
    }
    
    func setMonthlySpendingLimit(_ amount: Int64) {
        monthlySpendingLimit = amount
        // Persist this to UserDefaults or dedicated storage
        UserDefaults.standard.set(amount, forKey: "paykit_monthly_spending_limit")
    }
    
    var activeSubscriptions: [BitkitSubscription] {
        subscriptionStorage.activeSubscriptions()
    }
}

// MARK: - Models

public struct SubscriptionProposal: Identifiable, Codable {
    public let id: String
    let providerName: String
    let providerPubkey: String
    let amountSats: Int64
    let currency: String
    let frequency: String
    let description: String
    let methodId: String
    let maxPayments: Int?
    let startDate: Date?
    let createdAt: Date
    
    init(
        id: String = UUID().uuidString,
        providerName: String,
        providerPubkey: String,
        amountSats: Int64,
        currency: String = "SAT",
        frequency: String,
        description: String = "",
        methodId: String = "lightning",
        maxPayments: Int? = nil,
        startDate: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.providerName = providerName
        self.providerPubkey = providerPubkey
        self.amountSats = amountSats
        self.currency = currency
        self.frequency = frequency
        self.description = description
        self.methodId = methodId
        self.maxPayments = maxPayments
        self.startDate = startDate
        self.createdAt = createdAt
    }
}

public struct SubscriptionPayment: Identifiable, Codable {
    public let id: String
    let subscriptionId: String
    let subscriptionName: String
    let amountSats: Int64
    let paidAt: Date
    let status: SubscriptionPaymentStatus
    let txId: String?
    let preimage: String?
    
    init(
        id: String = UUID().uuidString,
        subscriptionId: String,
        subscriptionName: String,
        amountSats: Int64,
        paidAt: Date = Date(),
        status: SubscriptionPaymentStatus = .completed,
        txId: String? = nil,
        preimage: String? = nil
    ) {
        self.id = id
        self.subscriptionId = subscriptionId
        self.subscriptionName = subscriptionName
        self.amountSats = amountSats
        self.paidAt = paidAt
        self.status = status
        self.txId = txId
        self.preimage = preimage
    }
}

enum SubscriptionPaymentStatus: String, Codable {
    case pending = "Pending"
    case completed = "Completed"
    case failed = "Failed"
}

public struct SubscriptionSpendingLimit: Codable {
    public let maxAmount: Int64
    public let period: SpendingLimitPeriod
    public var usedAmount: Int64
    public let requireConfirmation: Bool
    
    init(maxAmount: Int64, period: SpendingLimitPeriod, usedAmount: Int64 = 0, requireConfirmation: Bool = false) {
        self.maxAmount = maxAmount
        self.period = period
        self.usedAmount = usedAmount
        self.requireConfirmation = requireConfirmation
    }
}

public enum SpendingLimitPeriod: String, Codable {
    case daily = "day"
    case weekly = "week"
    case monthly = "month"
}
