//
//  SubscriptionBackgroundService.swift
//  Bitkit
//
//  Background service for subscription monitoring using BGTaskScheduler.
//  Checks for due subscriptions and processes auto-pay.
//

import BackgroundTasks
import Foundation
import UserNotifications

/// Manages background subscription checking and auto-pay execution
public class SubscriptionBackgroundService {
    
    public static let shared = SubscriptionBackgroundService()
    
    /// Background task identifier - must be registered in Info.plist
    public static let taskIdentifier = "to.bitkit.subscriptions.check"
    
    /// Minimum interval between background checks (15 minutes)
    private let minimumCheckInterval: TimeInterval = 15 * 60
    
    /// Hours before due to send notification (default 24 hours)
    private let notifyBeforeHours: Int = 24
    
    /// Retry configuration for failed payments
    private let maxRetries: Int = 3
    private let initialRetryDelay: TimeInterval = 5.0  // 5 seconds
    private let maxRetryDelay: TimeInterval = 60.0     // 1 minute max
    
    private let subscriptionStorage: SubscriptionStorage
    private let autoPayStorage: AutoPayStorage
    private let autoPayEvaluator: AutoPayEvaluatorService
    
    private init(identityName: String = "default") {
        self.subscriptionStorage = SubscriptionStorage(identityName: identityName)
        self.autoPayStorage = AutoPayStorage(identityName: identityName)
        self.autoPayEvaluator = AutoPayEvaluatorService(identityName: identityName)
    }
    
    // MARK: - Registration
    
    /// Register the background task with BGTaskScheduler
    /// Call this in AppDelegate.didFinishLaunchingWithOptions
    public func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            self?.handleSubscriptionCheck(task: task as! BGProcessingTask)
        }
        
        Logger.info("SubscriptionBackgroundService: Registered background task", context: "SubscriptionBackgroundService")
    }
    
    /// Schedule the next background task
    public func scheduleBackgroundTask() {
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: minimumCheckInterval)
        
        do {
            try BGTaskScheduler.shared.submit(request)
            Logger.info("SubscriptionBackgroundService: Scheduled background task for \(request.earliestBeginDate?.description ?? "unknown")", context: "SubscriptionBackgroundService")
            
            // Verify scheduling
            verifyBackgroundTaskScheduled()
        } catch {
            Logger.error("SubscriptionBackgroundService: Failed to schedule background task: \(error)", context: "SubscriptionBackgroundService")
        }
    }
    
    /// Verify that background task is scheduled
    private func verifyBackgroundTaskScheduled() {
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            let hasSubscriptionTask = requests.contains { $0.identifier == Self.taskIdentifier }
            if hasSubscriptionTask {
                Logger.debug("SubscriptionBackgroundService: Background task verified as scheduled", context: "SubscriptionBackgroundService")
            } else {
                Logger.warn("SubscriptionBackgroundService: Background task not found in pending requests", context: "SubscriptionBackgroundService")
            }
        }
    }
    
    // MARK: - Background Task Handling
    
    private func handleSubscriptionCheck(task: BGProcessingTask) {
        Logger.info("SubscriptionBackgroundService: Starting subscription check", context: "SubscriptionBackgroundService")
        
        // Schedule next task before processing
        scheduleBackgroundTask()
        
        // Create a task to handle the background processing
        let processingTask = Task {
            do {
                // Check for due subscriptions
                let dueSubscriptions = try await checkDueSubscriptions()
                
                // Process each due subscription
                for subscription in dueSubscriptions {
                    try await processSubscriptionPayment(subscription)
                }
                
                // Schedule notifications for upcoming payments
                await scheduleUpcomingPaymentNotifications()
                
                task.setTaskCompleted(success: true)
            } catch {
                Logger.error("SubscriptionBackgroundService: Background task failed: \(error)", context: "SubscriptionBackgroundService")
                task.setTaskCompleted(success: false)
            }
        }
        
        // Handle task expiration
        task.expirationHandler = {
            processingTask.cancel()
            Logger.info("SubscriptionBackgroundService: Task expired", context: "SubscriptionBackgroundService")
        }
    }
    
    // MARK: - Subscription Checking
    
    /// Check for subscriptions that are due for payment
    public func checkDueSubscriptions() async throws -> [BitkitSubscription] {
        let activeSubscriptions = subscriptionStorage.activeSubscriptions()
        let now = Date()
        
        let dueSubscriptions = activeSubscriptions.filter { subscription in
            guard let nextPaymentAt = subscription.nextPaymentAt else { return false }
            return nextPaymentAt <= now
        }
        
        Logger.info("SubscriptionBackgroundService: Found \(dueSubscriptions.count) due subscriptions", context: "SubscriptionBackgroundService")
        
        return dueSubscriptions
    }
    
    /// Get subscriptions due within the next N hours (for notifications)
    public func getUpcomingSubscriptions(withinHours hours: Int = 24) -> [BitkitSubscription] {
        let activeSubscriptions = subscriptionStorage.activeSubscriptions()
        let now = Date()
        let futureDate = Calendar.current.date(byAdding: .hour, value: hours, to: now) ?? now
        
        return activeSubscriptions.filter { subscription in
            guard let nextPaymentAt = subscription.nextPaymentAt else { return false }
            return nextPaymentAt > now && nextPaymentAt <= futureDate
        }
    }
    
    // MARK: - Payment Processing
    
    /// Process a single subscription payment
    private func processSubscriptionPayment(_ subscription: BitkitSubscription) async throws {
        Logger.info("SubscriptionBackgroundService: Processing payment for subscription \(subscription.id)", context: "SubscriptionBackgroundService")
        
        // Wait for node to be ready
        guard try await waitForNodeReady(timeout: 30) else {
            Logger.error("SubscriptionBackgroundService: Node not ready for subscription payment", context: "SubscriptionBackgroundService")
            await sendPaymentFailedNotification(subscription: subscription, reason: "Wallet not ready")
            return
        }
        
        // Evaluate auto-pay using dedicated evaluator service (non-MainActor safe)
        let result = autoPayEvaluator.evaluateForBackground(
            peerPubkey: subscription.providerPubkey,
            peerName: subscription.providerName,
            amount: Int64(subscription.amountSats),
            methodId: "lightning",
            isSubscription: true
        )
        
        switch result {
        case .approved(let ruleId, let ruleName):
            Logger.info("SubscriptionBackgroundService: Auto-pay approved by rule: \(ruleName ?? ruleId)", context: "SubscriptionBackgroundService")
            try await executePaymentWithRetry(subscription)
            
            // Record successful auto-pay
            autoPayEvaluator.recordPayment(
                peerPubkey: subscription.providerPubkey,
                peerName: subscription.providerName,
                amount: Int64(subscription.amountSats),
                approved: true,
                reason: "Auto-approved by rule: \(ruleName ?? ruleId)"
            )
            
        case .denied(let reason):
            Logger.info("SubscriptionBackgroundService: Auto-pay denied: \(reason)", context: "SubscriptionBackgroundService")
            await sendPaymentNeedsApprovalNotification(subscription: subscription, reason: reason)
            
        case .needsApproval:
            Logger.info("SubscriptionBackgroundService: Payment needs manual approval", context: "SubscriptionBackgroundService")
            await sendPaymentNeedsApprovalNotification(subscription: subscription, reason: "Manual approval required")
            
        case .needsBiometric:
            // This case shouldn't occur when using evaluateForBackground(), but handle it safely
            Logger.info("SubscriptionBackgroundService: Biometric required, deferring to foreground", context: "SubscriptionBackgroundService")
            await sendPaymentNeedsApprovalNotification(subscription: subscription, reason: "Biometric authentication required")
        }
    }
    
    /// Execute payment with exponential backoff retry logic.
    ///
    /// Retry strategy:
    /// - Initial delay: 5 seconds
    /// - Exponential backoff: delay doubles each retry (5s, 10s, 20s)
    /// - Maximum delay capped at 60 seconds
    /// - Maximum retries: 3
    private func executePaymentWithRetry(_ subscription: BitkitSubscription) async throws {
        var lastError: Error?
        var currentDelay = initialRetryDelay
        
        for attempt in 1...maxRetries {
            do {
                try await executePayment(subscription)
                return // Success
            } catch {
                lastError = error
                
                if attempt < maxRetries {
                    Logger.warn(
                        "SubscriptionBackgroundService: Payment attempt \(attempt)/\(maxRetries) failed: \(error.localizedDescription), retrying in \(currentDelay)s",
                        context: "SubscriptionBackgroundService"
                    )
                    
                    // Wait with exponential backoff
                    try? await Task.sleep(nanoseconds: UInt64(currentDelay * 1_000_000_000))
                    
                    // Double the delay for next retry, capped at max
                    currentDelay = min(currentDelay * 2, maxRetryDelay)
                } else {
                    Logger.error(
                        "SubscriptionBackgroundService: All \(maxRetries) payment attempts failed for subscription \(subscription.id)",
                        context: "SubscriptionBackgroundService"
                    )
                }
            }
        }
        
        // All retries exhausted
        if let error = lastError {
            await sendPaymentFailedNotification(subscription: subscription, reason: error.localizedDescription)
            throw error
        }
    }
    
    /// Execute the actual payment for a subscription
    private func executePayment(_ subscription: BitkitSubscription) async throws {
        // Initialize Paykit if needed
        guard await PaykitIntegrationHelper.setupAsync() else {
            throw SubscriptionError.paykitNotReady
        }
        
        // Create payment request for the subscription
        // Use the subscription's payment method (invoice or pubkey)
        let paymentService = PaykitPaymentService.shared
        
        do {
            // Determine the payment recipient from subscription
            let recipient: String
            if let invoice = subscription.lastInvoice, !invoice.isEmpty {
                // Use the last invoice if available
                recipient = invoice
            } else {
                // Fall back to Paykit URI using provider pubkey
                recipient = "paykit:\(subscription.providerPubkey)"
            }
            
            // Execute payment with spending limit enforcement
            let result = try await paymentService.pay(
                to: recipient,
                amountSats: subscription.amountSats,
                peerPubkey: subscription.providerPubkey
            )
            
            if result.success {
                // Record the payment with receipt information
                try subscriptionStorage.recordPayment(
                    subscriptionId: subscription.id,
                    paymentHash: result.receipt.paymentHash,
                    preimage: result.receipt.preimage,
                    feeSats: result.receipt.feeSats
                )
                
                // Send success notification
                await sendPaymentSuccessNotification(subscription: subscription)
                
                Logger.info("SubscriptionBackgroundService: Payment executed successfully for subscription \(subscription.id), receipt: \(result.receipt.id)", context: "SubscriptionBackgroundService")
            } else {
                let errorMessage = result.error?.localizedDescription ?? "Unknown error"
                Logger.error("SubscriptionBackgroundService: Payment failed: \(errorMessage)", context: "SubscriptionBackgroundService")
                await sendPaymentFailedNotification(subscription: subscription, reason: errorMessage)
                throw SubscriptionError.paymentFailed(errorMessage)
            }
        } catch let error as PaykitPaymentError {
            Logger.error("SubscriptionBackgroundService: Payment execution failed: \(error.localizedDescription)", context: "SubscriptionBackgroundService")
            await sendPaymentFailedNotification(subscription: subscription, reason: error.userMessage)
            throw error
        } catch {
            Logger.error("SubscriptionBackgroundService: Payment execution failed: \(error)", context: "SubscriptionBackgroundService")
            await sendPaymentFailedNotification(subscription: subscription, reason: error.localizedDescription)
            throw error
        }
    }
    
    /// Wait for the Lightning node to be ready
    private func waitForNodeReady(timeout: TimeInterval) async throws -> Bool {
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < timeout {
            // Check if node is available via LightningService
            if LightningService.shared.node != nil {
                return true
            }
            
            // Wait a bit before checking again
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }
        
        return false
    }
    
    // MARK: - Notifications
    
    /// Schedule notifications for upcoming subscription payments
    public func scheduleUpcomingPaymentNotifications() async {
        let upcomingSubscriptions = getUpcomingSubscriptions(withinHours: notifyBeforeHours)
        
        for subscription in upcomingSubscriptions {
            await schedulePaymentDueNotification(subscription: subscription)
        }
    }
    
    private func schedulePaymentDueNotification(subscription: BitkitSubscription) async {
        guard let nextPaymentAt = subscription.nextPaymentAt else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "Subscription Payment Due"
        content.body = "\(subscription.providerName): ₿ \(subscription.amountSats) sats"
        content.sound = .default
        content.userInfo = [
            "type": "paykitSubscriptionDue",
            "subscriptionId": subscription.id
        ]
        
        // Schedule for 1 hour before due
        let notifyDate = Calendar.current.date(byAdding: .hour, value: -1, to: nextPaymentAt) ?? nextPaymentAt
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: notifyDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        
        let request = UNNotificationRequest(
            identifier: "subscription-due-\(subscription.id)",
            content: content,
            trigger: trigger
        )
        
        do {
            try await UNUserNotificationCenter.current().add(request)
            Logger.debug("SubscriptionBackgroundService: Scheduled notification for subscription \(subscription.id)", context: "SubscriptionBackgroundService")
        } catch {
            Logger.error("SubscriptionBackgroundService: Failed to schedule notification: \(error)", context: "SubscriptionBackgroundService")
        }
    }
    
    private func sendPaymentSuccessNotification(subscription: BitkitSubscription) async {
        let content = UNMutableNotificationContent()
        content.title = "Subscription Payment Sent"
        content.body = "\(subscription.providerName): ₿ \(subscription.amountSats) sats"
        content.sound = .default
        content.userInfo = [
            "type": "paykitAutoPayExecuted",
            "subscriptionId": subscription.id,
            "amount": subscription.amountSats
        ]
        
        let request = UNNotificationRequest(
            identifier: "subscription-paid-\(subscription.id)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Logger.error("SubscriptionBackgroundService: Failed to send success notification: \(error)", context: "SubscriptionBackgroundService")
        }
    }
    
    private func sendPaymentFailedNotification(subscription: BitkitSubscription, reason: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Subscription Payment Failed"
        content.body = "\(subscription.providerName): \(reason)"
        content.sound = .default
        content.userInfo = [
            "type": "paykitSubscriptionFailed",
            "subscriptionId": subscription.id,
            "reason": reason
        ]
        
        let request = UNNotificationRequest(
            identifier: "subscription-failed-\(subscription.id)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Logger.error("SubscriptionBackgroundService: Failed to send failure notification: \(error)", context: "SubscriptionBackgroundService")
        }
    }
    
    private func sendPaymentNeedsApprovalNotification(subscription: BitkitSubscription, reason: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Subscription Payment Pending"
        content.body = "\(subscription.providerName) requires approval: ₿ \(subscription.amountSats) sats"
        content.sound = .default
        content.userInfo = [
            "type": "paykitSubscriptionDue",
            "subscriptionId": subscription.id,
            "reason": reason
        ]
        
        let request = UNNotificationRequest(
            identifier: "subscription-approval-\(subscription.id)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Logger.error("SubscriptionBackgroundService: Failed to send approval notification: \(error)", context: "SubscriptionBackgroundService")
        }
    }
}

// MARK: - Errors

enum SubscriptionError: Error, LocalizedError {
    case paykitNotReady
    case nodeNotReady
    case paymentFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .paykitNotReady:
            return "Paykit is not ready"
        case .nodeNotReady:
            return "Lightning node is not ready"
        case .paymentFailed(let reason):
            return "Payment failed: \(reason)"
        }
    }
}

