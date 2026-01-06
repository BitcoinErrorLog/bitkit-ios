//
//  SubscriptionStorage.swift
//  Bitkit
//
//  Persistent storage for subscriptions, proposals, and payment history using Keychain.
//

import Foundation

/// Manages persistent storage of subscriptions, proposals, and payment history
public class SubscriptionStorage {
    
    /// Shared singleton instance - use this to ensure caching works correctly
    public static let shared = SubscriptionStorage()
    
    private let keychain: PaykitKeychainStorage
    private let identityName: String
    
    // In-memory caches
    private var subscriptionsCache: [BitkitSubscription]?
    private var proposalsCache: [SubscriptionProposal]?
    private var paymentsCache: [SubscriptionPayment]?
    private var sentProposalsCache: [SentProposal]?
    
    private var subscriptionsKey: String { "paykit.subscriptions.\(identityName)" }
    private var proposalsKey: String { "paykit.proposals.\(identityName)" }
    private var paymentsKey: String { "paykit.payments.\(identityName)" }
    private var sentProposalsKey: String { "paykit.sent_proposals.\(identityName)" }
    private var seenProposalIdsKey: String { "paykit.proposals.seen.\(identityName)" }
    private var declinedProposalIdsKey: String { "paykit.proposals.declined.\(identityName)" }
    
    // Additional caches for seen/declined IDs
    private var seenProposalIdsCache: Set<String>?
    private var declinedProposalIdsCache: Set<String>?
    
    public init(identityName: String? = nil, keychain: PaykitKeychainStorage = PaykitKeychainStorage()) {
        self.identityName = identityName ?? PaykitKeyManager.shared.getCurrentPublicKeyZ32() ?? "default"
        self.keychain = keychain
    }
    
    // MARK: - Subscriptions CRUD
    
    public func listSubscriptions() -> [BitkitSubscription] {
        if let cached = subscriptionsCache {
            return cached
        }
        
        do {
            guard let data = try keychain.retrieve(key: subscriptionsKey) else {
                return []
            }
            let subscriptions = try JSONDecoder().decode([BitkitSubscription].self, from: data)
            subscriptionsCache = subscriptions
            return subscriptions
        } catch {
            Logger.error("Failed to load subscriptions: \(error)", context: "SubscriptionStorage")
            return []
        }
    }
    
    public func getSubscription(id: String) -> BitkitSubscription? {
        return listSubscriptions().first { $0.id == id }
    }
    
    public func saveSubscription(_ subscription: BitkitSubscription) throws {
        var subscriptions = listSubscriptions()
        
        if let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) {
            subscriptions[index] = subscription
        } else {
            subscriptions.append(subscription)
        }
        
        try persistSubscriptions(subscriptions)
    }
    
    public func deleteSubscription(id: String) throws {
        var subscriptions = listSubscriptions()
        subscriptions.removeAll { $0.id == id }
        try persistSubscriptions(subscriptions)
    }
    
    public func toggleActive(id: String) throws {
        var subscriptions = listSubscriptions()
        guard let index = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        subscriptions[index].isActive.toggle()
        try persistSubscriptions(subscriptions)
    }
    
    public func recordPayment(subscriptionId: String) throws {
        try recordPayment(subscriptionId: subscriptionId, paymentHash: nil, preimage: nil, feeSats: nil)
    }
    
    public func recordPayment(
        subscriptionId: String,
        paymentHash: String?,
        preimage: String?,
        feeSats: UInt64?
    ) throws {
        var subscriptions = listSubscriptions()
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionId }) else { return }
        
        let subscription = subscriptions[index]
        subscriptions[index].recordPayment(paymentHash: paymentHash, preimage: preimage, feeSats: feeSats)
        
        // Also record to payment history
        let payment = SubscriptionPayment(
            subscriptionId: subscriptionId,
            subscriptionName: subscription.providerName,
            amountSats: Int64(subscription.amountSats),
            status: .completed,
            preimage: preimage
        )
        try savePayment(payment)
        
        try persistSubscriptions(subscriptions)
    }
    
    public func activeSubscriptions() -> [BitkitSubscription] {
        listSubscriptions().filter { $0.isActive }
    }
    
    // MARK: - Proposals CRUD
    
    /// Invalidate all in-memory caches to force reload from keychain
    public func invalidateCache() {
        subscriptionsCache = nil
        proposalsCache = nil
        paymentsCache = nil
        sentProposalsCache = nil
        seenProposalIdsCache = nil
        declinedProposalIdsCache = nil
    }
    
    public func listProposals() -> [SubscriptionProposal] {
        if let cached = proposalsCache {
            return cached
        }
        
        do {
            guard let data = try keychain.retrieve(key: proposalsKey) else {
                return []
            }
            let proposals = try JSONDecoder().decode([SubscriptionProposal].self, from: data)
            proposalsCache = proposals
            return proposals
        } catch {
            Logger.error("Failed to load proposals: \(error)", context: "SubscriptionStorage")
            return []
        }
    }
    
    public func saveProposal(_ proposal: SubscriptionProposal) throws {
        var proposals = listProposals()
        
        if let index = proposals.firstIndex(where: { $0.id == proposal.id }) {
            proposals[index] = proposal
        } else {
            proposals.append(proposal)
        }
        
        try persistProposals(proposals)
    }
    
    public func deleteProposal(id: String) throws {
        var proposals = listProposals()
        proposals.removeAll { $0.id == id }
        try persistProposals(proposals)
    }
    
    /// Get pending proposals (not declined)
    public func pendingProposals() -> [SubscriptionProposal] {
        let declined = getDeclinedProposalIds()
        return listProposals().filter { !declined.contains($0.id) }
    }
    
    // MARK: - Seen IDs (for deduplication)
    
    /// Check if a proposal has been seen (notified about)
    public func hasSeenProposal(id: String) -> Bool {
        return getSeenProposalIds().contains(id)
    }
    
    /// Mark a proposal as seen (prevents duplicate notifications)
    public func markProposalAsSeen(id: String) throws {
        var seen = getSeenProposalIds()
        seen.insert(id)
        try persistSeenProposalIds(seen)
    }
    
    /// Mark a proposal as declined (hides from inbox)
    public func markProposalAsDeclined(id: String) throws {
        var declined = getDeclinedProposalIds()
        declined.insert(id)
        try persistDeclinedProposalIds(declined)
    }
    
    private func getSeenProposalIds() -> Set<String> {
        if let cached = seenProposalIdsCache {
            return cached
        }
        
        do {
            guard let data = try keychain.retrieve(key: seenProposalIdsKey) else {
                return []
            }
            let ids = try JSONDecoder().decode(Set<String>.self, from: data)
            seenProposalIdsCache = ids
            return ids
        } catch {
            Logger.error("Failed to load seen proposal IDs: \(error)", context: "SubscriptionStorage")
            return []
        }
    }
    
    private func getDeclinedProposalIds() -> Set<String> {
        if let cached = declinedProposalIdsCache {
            return cached
        }
        
        do {
            guard let data = try keychain.retrieve(key: declinedProposalIdsKey) else {
                return []
            }
            let ids = try JSONDecoder().decode(Set<String>.self, from: data)
            declinedProposalIdsCache = ids
            return ids
        } catch {
            Logger.error("Failed to load declined proposal IDs: \(error)", context: "SubscriptionStorage")
            return []
        }
    }
    
    private func persistSeenProposalIds(_ ids: Set<String>) throws {
        let data = try JSONEncoder().encode(ids)
        try keychain.store(key: seenProposalIdsKey, data: data)
        seenProposalIdsCache = ids
    }
    
    private func persistDeclinedProposalIds(_ ids: Set<String>) throws {
        let data = try JSONEncoder().encode(ids)
        try keychain.store(key: declinedProposalIdsKey, data: data)
        declinedProposalIdsCache = ids
    }
    
    // MARK: - Payment History CRUD
    
    public func listPayments() -> [SubscriptionPayment] {
        if let cached = paymentsCache {
            return cached
        }
        
        do {
            guard let data = try keychain.retrieve(key: paymentsKey) else {
                return []
            }
            let payments = try JSONDecoder().decode([SubscriptionPayment].self, from: data)
            paymentsCache = payments
            return payments.sorted { $0.paidAt > $1.paidAt }
        } catch {
            Logger.error("Failed to load payments: \(error)", context: "SubscriptionStorage")
            return []
        }
    }
    
    public func savePayment(_ payment: SubscriptionPayment) throws {
        var payments = listPayments()
        payments.append(payment)
        try persistPayments(payments)
    }
    
    public func getPayments(forSubscription subscriptionId: String) -> [SubscriptionPayment] {
        listPayments().filter { $0.subscriptionId == subscriptionId }
    }
    
    // MARK: - Sent Proposals CRUD
    
    public func listSentProposals() -> [SentProposal] {
        if let cached = sentProposalsCache {
            return cached
        }
        
        do {
            guard let data = try keychain.retrieve(key: sentProposalsKey) else {
                return []
            }
            let proposals = try JSONDecoder().decode([SentProposal].self, from: data)
            sentProposalsCache = proposals
            return proposals.sorted { $0.createdAt > $1.createdAt }
        } catch {
            Logger.error("Failed to load sent proposals: \(error)", context: "SubscriptionStorage")
            return []
        }
    }
    
    public func saveSentProposal(_ proposal: SentProposal) throws {
        var proposals = listSentProposals()
        
        if let index = proposals.firstIndex(where: { $0.id == proposal.id }) {
            proposals[index] = proposal
        } else {
            proposals.append(proposal)
        }
        
        try persistSentProposals(proposals)
    }
    
    public func updateSentProposalStatus(id: String, status: SentProposalStatus) throws {
        var proposals = listSentProposals()
        guard let index = proposals.firstIndex(where: { $0.id == id }) else { return }
        proposals[index].status = status
        try persistSentProposals(proposals)
    }
    
    public func deleteSentProposal(id: String) throws {
        var proposals = listSentProposals()
        proposals.removeAll { $0.id == id }
        try persistSentProposals(proposals)
    }
    
    // MARK: - Clear All
    
    public func clearAll() throws {
        // Clear in-memory caches
        subscriptionsCache = nil
        proposalsCache = nil
        paymentsCache = nil
        sentProposalsCache = nil
        
        // Delete from keychain
        try? keychain.delete(key: subscriptionsKey)
        try? keychain.delete(key: proposalsKey)
        try? keychain.delete(key: paymentsKey)
        try? keychain.delete(key: sentProposalsKey)
        try? keychain.delete(key: seenProposalIdsKey)
        try? keychain.delete(key: declinedProposalIdsKey)
        
        Logger.info("SubscriptionStorage: Cleared all data for \(identityName.prefix(12))...", context: "SubscriptionStorage")
    }
    
    // MARK: - Private Persistence
    
    private func persistSubscriptions(_ subscriptions: [BitkitSubscription]) throws {
        let data = try JSONEncoder().encode(subscriptions)
        try keychain.store(key: subscriptionsKey, data: data)
        subscriptionsCache = subscriptions
    }
    
    private func persistProposals(_ proposals: [SubscriptionProposal]) throws {
        let data = try JSONEncoder().encode(proposals)
        try keychain.store(key: proposalsKey, data: data)
        proposalsCache = proposals
    }
    
    private func persistPayments(_ payments: [SubscriptionPayment]) throws {
        let data = try JSONEncoder().encode(payments)
        try keychain.store(key: paymentsKey, data: data)
        paymentsCache = payments
    }
    
    private func persistSentProposals(_ proposals: [SentProposal]) throws {
        let data = try JSONEncoder().encode(proposals)
        try keychain.store(key: sentProposalsKey, data: data)
        sentProposalsCache = proposals
    }
}

// MARK: - Sent Proposal Model

public struct SentProposal: Identifiable, Codable {
    public let id: String
    public let recipientPubkey: String
    public let amountSats: Int64
    public let frequency: String
    public let description: String?
    public let createdAt: Date
    public var status: SentProposalStatus
    
    public init(
        id: String = UUID().uuidString,
        recipientPubkey: String,
        amountSats: Int64,
        frequency: String,
        description: String? = nil,
        createdAt: Date = Date(),
        status: SentProposalStatus = .pending
    ) {
        self.id = id
        self.recipientPubkey = recipientPubkey
        self.amountSats = amountSats
        self.frequency = frequency
        self.description = description
        self.createdAt = createdAt
        self.status = status
    }
}

public enum SentProposalStatus: String, Codable {
    case pending
    case accepted
    case declined
}
