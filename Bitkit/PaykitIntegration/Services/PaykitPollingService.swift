//
//  PaykitPollingService.swift
//  Bitkit
//
//  Service for periodically polling the Pubky directory for pending payment requests.
//  Uses BGAppRefreshTask for background polling when app is suspended.
//

import BackgroundTasks
import Foundation
import UserNotifications

/// Service for discovering pending payment requests from the Pubky directory.
///
/// This service periodically polls for:
/// - Incoming payment requests
/// - Subscription proposals
/// - Pending approvals
///
/// When a new request is found, it can:
/// 1. Trigger a local notification to the user
/// 2. Evaluate auto-pay rules and execute payment if approved
/// 3. Queue the request for manual review
public final class PaykitPollingService {
    
    // MARK: - Singleton
    
    public static let shared = PaykitPollingService()
    
    // MARK: - Constants
    
    /// Background task identifier - must be registered in Info.plist
    public static let taskIdentifier = "to.bitkit.paykit.polling"
    
    /// Minimum interval between polls (15 minutes - iOS minimum)
    private let minimumPollInterval: TimeInterval = 15 * 60
    
    /// Foreground poll interval (5 minutes)
    private let foregroundPollInterval: TimeInterval = 5 * 60
    
    // MARK: - State
    
    /// Currently polling
    private var isPolling = false
    
    /// Timer for foreground polling
    private var foregroundTimer: Timer?
    
    /// Last poll timestamp
    private var lastPollTime: Date?
    
    /// Discovered request IDs (to avoid duplicate notifications)
    private var seenRequestIds: Set<String> = []
    
    // MARK: - Dependencies
    
    private let directoryService: DirectoryService
    
    // MARK: - Initialization
    
    private init() {
        self.directoryService = DirectoryService.shared
    }
    
    // MARK: - Public API
    
    /// Register background task with the system.
    /// Call this from AppDelegate's didFinishLaunchingWithOptions.
    public func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: PaykitPollingService.taskIdentifier,
            using: nil
        ) { task in
            self.handleBackgroundPoll(task: task as! BGAppRefreshTask)
        }
        Logger.info("PaykitPollingService: Registered background task", context: "PaykitPollingService")
    }
    
    /// Verify that background task is scheduled
    private func verifyBackgroundTaskScheduled() {
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            let hasPollingTask = requests.contains { $0.identifier == Self.taskIdentifier }
            if hasPollingTask {
                Logger.debug("PaykitPollingService: Background task verified as scheduled", context: "PaykitPollingService")
            } else {
                Logger.warn("PaykitPollingService: Background task not found in pending requests", context: "PaykitPollingService")
            }
        }
    }
    
    /// Schedule a background app refresh task.
    /// Call this when the app enters the background.
    public func scheduleBackgroundPoll() {
        let request = BGAppRefreshTaskRequest(identifier: PaykitPollingService.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: minimumPollInterval)
        
        do {
            try BGTaskScheduler.shared.submit(request)
            Logger.info("PaykitPollingService: Scheduled background poll for \(request.earliestBeginDate?.description ?? "unknown")", context: "PaykitPollingService")
            
            // Verify scheduling
            verifyBackgroundTaskScheduled()
        } catch {
            Logger.error("PaykitPollingService: Failed to schedule background poll: \(error)", context: "PaykitPollingService")
        }
    }
    
    /// Start foreground polling.
    /// Call this when the app enters the foreground.
    public func startForegroundPolling() {
        stopForegroundPolling()
        
        // Poll immediately
        Task {
            await poll()
        }
        
        // Schedule periodic polling
        foregroundTimer = Timer.scheduledTimer(withTimeInterval: foregroundPollInterval, repeats: true) { [weak self] _ in
            Task {
                await self?.poll()
            }
        }
        
        Logger.info("PaykitPollingService: Started foreground polling", context: "PaykitPollingService")
    }
    
    /// Stop foreground polling.
    /// Call this when the app enters the background.
    public func stopForegroundPolling() {
        foregroundTimer?.invalidate()
        foregroundTimer = nil
        Logger.info("PaykitPollingService: Stopped foreground polling", context: "PaykitPollingService")
    }
    
    /// Manually trigger a poll.
    @MainActor
    public func pollNow() async {
        await poll()
    }
    
    // MARK: - Background Task Handler
    
    private func handleBackgroundPoll(task: BGAppRefreshTask) {
        Logger.info("PaykitPollingService: Starting background poll", context: "PaykitPollingService")
        
        // Schedule next poll
        scheduleBackgroundPoll()
        
        // Set expiration handler
        task.expirationHandler = { [weak self] in
            Logger.warn("PaykitPollingService: Background poll expired", context: "PaykitPollingService")
            self?.isPolling = false
            task.setTaskCompleted(success: false)
        }
        
        Task {
            do {
                let newRequests = try await performPoll()
                
                // Persist discovered requests to storage for UI display
                await persistDiscoveredRequests(newRequests)
                
                // Process new requests
                for request in newRequests {
                    await handleNewRequest(request)
                }
                
                Logger.info("PaykitPollingService: Background poll completed, found \(newRequests.count) new requests", context: "PaykitPollingService")
                task.setTaskCompleted(success: true)
            } catch {
                Logger.error("PaykitPollingService: Background poll failed: \(error)", context: "PaykitPollingService")
                task.setTaskCompleted(success: false)
            }
        }
    }
    
    // MARK: - Polling Logic
    
    private func poll() async {
        guard !isPolling else {
            Logger.debug("PaykitPollingService: Already polling, skipping", context: "PaykitPollingService")
            return
        }
        
        isPolling = true
        defer { isPolling = false }
        
        do {
            let newRequests = try await performPoll()
            
            // Persist discovered requests to storage for UI display
            await persistDiscoveredRequests(newRequests)
            
            for request in newRequests {
                await handleNewRequest(request)
            }
            
            lastPollTime = Date()
            Logger.info("PaykitPollingService: Poll completed, found \(newRequests.count) new requests", context: "PaykitPollingService")
        } catch {
            Logger.error("PaykitPollingService: Poll failed: \(error)", context: "PaykitPollingService")
        }
    }
    
    private func performPoll() async throws -> [DiscoveredRequest] {
        var newRequests: [DiscoveredRequest] = []
        
        // Get our pubkey from Paykit
        guard let ownerPubkey = PaykitManager.shared.ownerPubkey else {
            Logger.warn("PaykitPollingService: No owner pubkey configured", context: "PaykitPollingService")
            return []
        }
        
        // Get list of known peers (follows) to poll
        var knownPeers: [String] = []
        do {
            knownPeers = try await directoryService.fetchFollows()
            Logger.info("PaykitPollingService: Found \(knownPeers.count) follows to poll: \(knownPeers.map { String($0.prefix(12)) })", context: "PaykitPollingService")
        } catch {
            Logger.error("PaykitPollingService: Failed to fetch follows for peer polling: \(error)", context: "PaykitPollingService")
        }
        
        // Poll each peer's storage for requests/proposals addressed to us
        for peerPubkey in knownPeers {
            // Discover payment requests from peer's storage
            do {
                let paymentRequests = try await directoryService.discoverPendingRequestsFromPeer(peerPubkey: peerPubkey, myPubkey: ownerPubkey)
                for request in paymentRequests {
                    if !seenRequestIds.contains(request.requestId) {
                        seenRequestIds.insert(request.requestId)
                        newRequests.append(request)
                    }
                }
            } catch {
                Logger.debug("PaykitPollingService: Failed to discover requests from peer \(peerPubkey.prefix(12)): \(error)", context: "PaykitPollingService")
            }
            
            // Discover subscription proposals from peer's storage
            do {
                let proposals = try await directoryService.discoverSubscriptionProposalsFromPeer(peerPubkey: peerPubkey, myPubkey: ownerPubkey)
                for proposal in proposals {
                    let request = DiscoveredRequest(
                        requestId: proposal.subscriptionId,
                        type: .subscriptionProposal,
                        fromPubkey: proposal.providerPubkey,
                        amountSats: proposal.amountSats,
                        description: proposal.description,
                        createdAt: proposal.createdAt,
                        frequency: proposal.frequency
                    )
                    if !seenRequestIds.contains(request.requestId) {
                        seenRequestIds.insert(request.requestId)
                        newRequests.append(request)
                    }
                }
            } catch {
                Logger.debug("PaykitPollingService: Failed to discover proposals from peer \(peerPubkey.prefix(12)): \(error)", context: "PaykitPollingService")
            }
        }
        
        Logger.debug("PaykitPollingService: Discovered \(newRequests.count) new requests from \(knownPeers.count) peers", context: "PaykitPollingService")
        
        return newRequests
    }
    
    private func handleNewRequest(_ request: DiscoveredRequest) async {
        Logger.info("PaykitPollingService: Handling new request \(request.requestId) of type \(request.type)", context: "PaykitPollingService")
        
        switch request.type {
        case .paymentRequest:
            await handlePaymentRequest(request)
        case .subscriptionProposal:
            await handleSubscriptionProposal(request)
        }
    }
    
    private func handlePaymentRequest(_ request: DiscoveredRequest) async {
        // Check auto-pay rules
        let autoPayDecision = await evaluateAutoPay(for: request)
        
        switch autoPayDecision {
        case .approved(let ruleName):
            Logger.info("PaykitPollingService: Auto-pay approved for request \(request.requestId) by rule: \(ruleName ?? "default")", context: "PaykitPollingService")
            
            // Execute payment
            do {
                try await executePayment(for: request)
                await sendPaymentSuccessNotification(for: request)
                // Clean up processed request from directory
                await cleanupProcessedRequest(request)
            } catch {
                Logger.error("PaykitPollingService: Auto-pay failed for request \(request.requestId): \(error)", context: "PaykitPollingService")
                await sendPaymentFailureNotification(for: request, error: error)
            }
            
        case .denied(let reason):
            Logger.info("PaykitPollingService: Auto-pay denied for request \(request.requestId): \(reason)", context: "PaykitPollingService")
            await sendManualApprovalNotification(for: request)
            
        case .needsManualApproval:
            await sendManualApprovalNotification(for: request)
        }
    }
    
    private func handleSubscriptionProposal(_ request: DiscoveredRequest) async {
        let storage = SubscriptionStorage.shared
        
        // Check if already seen (prevents duplicate notifications across restarts)
        if storage.hasSeenProposal(id: request.requestId) {
            Logger.debug("PaykitPollingService: Proposal \(request.requestId) already seen, skipping notification", context: "PaykitPollingService")
            return
        }
        
        // Persist the proposal and mark as seen
        let proposal = SubscriptionProposal(
            id: request.requestId,
            providerName: String(request.fromPubkey.prefix(8)),
            providerPubkey: request.fromPubkey,
            amountSats: request.amountSats,
            currency: "SAT",
            frequency: request.frequency ?? "monthly",
            description: request.description ?? "",
            methodId: "lightning",
            maxPayments: nil,
            startDate: nil,
            createdAt: request.createdAt
        )
        
        do {
            try storage.saveProposal(proposal)
            try storage.markProposalAsSeen(id: request.requestId)
            
            // Only notify for new proposals
            await sendSubscriptionProposalNotification(for: request)
        } catch {
            Logger.error("PaykitPollingService: Failed to persist proposal: \(error)", context: "PaykitPollingService")
        }
    }
    
    // MARK: - Auto-Pay Evaluation
    
    private func evaluateAutoPay(for request: DiscoveredRequest) async -> AutoPayDecision {
        // Check if auto-pay is enabled via AutoPayStorage
        let autoPayStorage = AutoPayStorage.shared
        
        guard autoPayStorage.isEnabled else {
            return .needsManualApproval
        }
        
        // Check spending limits
        do {
            let checkResult = try SpendingLimitManager.shared.wouldExceedLimit(
                peerPubkey: request.fromPubkey,
                amountSats: request.amountSats
            )
            
            if checkResult.wouldExceed {
                return .denied(reason: "Would exceed spending limit")
            }
            
            // Check if peer is in allowed list
            if let rule = autoPayStorage.getRule(for: request.fromPubkey) {
                // If rule has max amount, check against it
                if let maxAmount = rule.maxAmountSats, request.amountSats > maxAmount {
                    return .denied(reason: "Amount exceeds rule limit")
                }
                return .approved(ruleName: rule.name)
            }
            
            return .needsManualApproval
        } catch {
            Logger.error("PaykitPollingService: Auto-pay evaluation failed: \(error)", context: "PaykitPollingService")
            return .needsManualApproval
        }
    }
    
    // MARK: - Persistence
    
    private func persistDiscoveredRequests(_ requests: [DiscoveredRequest]) async {
        guard let ownerPubkey = PaykitManager.shared.ownerPubkey else { return }
        let storage = PaymentRequestStorage()
        
        for request in requests {
            // Only persist payment requests, not subscription proposals
            guard request.type == .paymentRequest else { continue }
            
            let paymentRequest = BitkitPaymentRequest(
                id: request.requestId,
                fromPubkey: request.fromPubkey,
                toPubkey: ownerPubkey,
                amountSats: request.amountSats,
                currency: "BTC",
                methodId: "lightning",
                description: request.description ?? "",
                createdAt: request.createdAt ?? Date(),
                expiresAt: nil,
                status: .pending,
                direction: .incoming
            )
            
            // Don't overwrite if already exists
            if storage.getRequest(id: request.requestId) == nil {
                try? storage.addRequest(paymentRequest)
                Logger.debug("PaykitPollingService: Persisted discovered request \(request.requestId) to storage", context: "PaykitPollingService")
            }
        }
    }
    
    /// Cleanup processed request.
    ///
    /// NOTE: In the v0 sender-storage model, requests are stored on the sender's homeserver.
    /// Recipients cannot delete requests from sender storage. Deduplication is handled locally
    /// via `seenRequestIds` and `PaymentRequestStorage`.
    ///
    /// This method is intentionally a no-op - we only log for diagnostics.
    private func cleanupProcessedRequest(_ request: DiscoveredRequest) async {
        Logger.debug("PaykitPollingService: Request \(request.requestId) processed (no remote delete in sender-storage model)", context: "PaykitPollingService")
    }
    
    // MARK: - Payment Execution
    
    private func executePayment(for request: DiscoveredRequest) async throws {
        // Ensure node is ready
        try await waitForNodeReady()
        
        // Construct paykit: URI for proper payment routing
        let paykitUri = "paykit:\(request.fromPubkey)"
        
        // Execute payment via PaykitPaymentService with spending limit enforcement
        _ = try await PaykitPaymentService.shared.pay(
            to: paykitUri,
            amountSats: UInt64(request.amountSats),
            peerPubkey: request.fromPubkey // Use peer pubkey for spending limit
        )
    }
    
    private func waitForNodeReady() async throws {
        // Wait for LDK node to be ready (node instance exists)
        var attempts = 0
        let maxAttempts = 30  // 30 seconds timeout
        
        while attempts < maxAttempts {
            if LightningService.shared.node != nil {
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
            attempts += 1
        }
        
        throw PaykitPollingError.nodeNotReady
    }
    
    // MARK: - Notifications
    
    private func sendManualApprovalNotification(for request: DiscoveredRequest) async {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("paykit__payment_request_received", comment: "")
        content.body = String(format: NSLocalizedString("paykit__payment_request_body", comment: ""), 
                              formatPubkey(request.fromPubkey), 
                              formatSats(request.amountSats))
        content.sound = .default
        content.userInfo = [
            "type": "paykit_payment_request",
            "requestId": request.requestId
        ]
        
        let notificationRequest = UNNotificationRequest(
            identifier: "paykit_request_\(request.requestId)",
            content: content,
            trigger: nil
        )
        
        do {
            try await UNUserNotificationCenter.current().add(notificationRequest)
            Logger.debug("PaykitPollingService: Sent approval notification for request \(request.requestId)", context: "PaykitPollingService")
        } catch {
            Logger.error("PaykitPollingService: Failed to send notification: \(error)", context: "PaykitPollingService")
        }
    }
    
    private func sendPaymentSuccessNotification(for request: DiscoveredRequest) async {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("paykit__payment_sent_auto", comment: "")
        content.body = String(format: NSLocalizedString("paykit__payment_sent_body", comment: ""), 
                              formatSats(request.amountSats),
                              formatPubkey(request.fromPubkey))
        content.sound = .default
        
        let notificationRequest = UNNotificationRequest(
            identifier: "paykit_success_\(request.requestId)",
            content: content,
            trigger: nil
        )
        
        do {
            try await UNUserNotificationCenter.current().add(notificationRequest)
        } catch {
            Logger.error("PaykitPollingService: Failed to send success notification: \(error)", context: "PaykitPollingService")
        }
    }
    
    private func sendPaymentFailureNotification(for request: DiscoveredRequest, error: Error) async {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("paykit__payment_failed", comment: "")
        content.body = String(format: NSLocalizedString("paykit__payment_failed_body", comment: ""), 
                              formatSats(request.amountSats),
                              error.localizedDescription)
        content.sound = .default
        content.userInfo = [
            "type": "paykit_payment_failed",
            "requestId": request.requestId
        ]
        
        let notificationRequest = UNNotificationRequest(
            identifier: "paykit_failure_\(request.requestId)",
            content: content,
            trigger: nil
        )
        
        do {
            try await UNUserNotificationCenter.current().add(notificationRequest)
        } catch {
            Logger.error("PaykitPollingService: Failed to send failure notification: \(error)", context: "PaykitPollingService")
        }
    }
    
    private func sendSubscriptionProposalNotification(for request: DiscoveredRequest) async {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("paykit__subscription_proposal", comment: "")
        content.body = String(format: NSLocalizedString("paykit__subscription_proposal_body", comment: ""), 
                              formatPubkey(request.fromPubkey),
                              formatSats(request.amountSats))
        content.sound = .default
        content.userInfo = [
            "type": "paykit_subscription_proposal",
            "subscriptionId": request.requestId
        ]
        
        let notificationRequest = UNNotificationRequest(
            identifier: "paykit_sub_\(request.requestId)",
            content: content,
            trigger: nil
        )
        
        do {
            try await UNUserNotificationCenter.current().add(notificationRequest)
        } catch {
            Logger.error("PaykitPollingService: Failed to send subscription notification: \(error)", context: "PaykitPollingService")
        }
    }
    
    // MARK: - Helpers
    
    private func formatPubkey(_ pubkey: String) -> String {
        if pubkey.count > 12 {
            return "\(pubkey.prefix(6))...\(pubkey.suffix(6))"
        }
        return pubkey
    }
    
    private func formatSats(_ sats: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return "\(formatter.string(from: NSNumber(value: sats)) ?? String(sats)) sats"
    }
}

// MARK: - Data Models

/// A discovered payment request or subscription proposal
public struct DiscoveredRequest {
    public let requestId: String
    public let type: DiscoveredRequestType
    public let fromPubkey: String
    public let amountSats: Int64
    public let description: String?
    public let createdAt: Date
    public let frequency: String?
}

public enum DiscoveredRequestType {
    case paymentRequest
    case subscriptionProposal
}

/// Result of auto-pay evaluation
public enum AutoPayDecision {
    case approved(ruleName: String?)
    case denied(reason: String)
    case needsManualApproval
}

/// Subscription proposal discovered from directory
public struct DiscoveredSubscriptionProposal {
    public let subscriptionId: String
    public let providerPubkey: String
    public let amountSats: Int64
    public let description: String?
    public let frequency: String
    public let createdAt: Date
}

// MARK: - Errors

public enum PaykitPollingError: LocalizedError {
    case nodeNotReady
    case paymentFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .nodeNotReady:
            return "Lightning node is not ready"
        case .paymentFailed(let reason):
            return "Payment failed: \(reason)"
        }
    }
}
