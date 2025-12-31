//
//  AutoPayEvaluatorService.swift
//  Bitkit
//
//  Non-MainActor auto-pay evaluation service for background and worker contexts.
//  Extracted from AutoPayViewModel for use in SubscriptionBackgroundService.
//

import Foundation

/// Auto-pay evaluator service for background contexts.
///
/// This service encapsulates auto-pay evaluation logic without MainActor constraints,
/// making it suitable for use in BGTaskScheduler handlers and other background contexts.
///
/// ## Biometric Policy for Background Payments
///
/// Background payments (e.g., subscription auto-renewals) cannot use biometric
/// authentication because there is no user interface to present the prompt.
///
/// **Policy:**
/// - Payments requiring biometric auth (`.needsBiometric`) are treated as `.needsApproval`
/// - A local notification is sent to prompt the user to open the app
/// - The payment is deferred until the user manually approves it
///
/// **Configuration:**
/// - Set `AutoPaySettings.biometricForLarge` to control the threshold
/// - For fully automatic background payments, ensure amounts are below this threshold
/// - Or disable `biometricForLarge` to skip biometric requirements entirely
public final class AutoPayEvaluatorService {
    
    // MARK: - Properties
    
    private let autoPayStorage: AutoPayStorage
    private let identityName: String
    
    // MARK: - Initialization
    
    public init(identityName: String = "default") {
        self.identityName = identityName
        self.autoPayStorage = AutoPayStorage(identityName: identityName)
    }
    
    // MARK: - Evaluation
    
    /// Evaluate if a payment should be auto-approved.
    ///
    /// This method is thread-safe and can be called from any context (including background tasks).
    ///
    /// - Parameters:
    ///   - peerPubkey: The peer's public key.
    ///   - peerName: The peer's display name.
    ///   - amount: Payment amount in satoshis.
    ///   - methodId: The payment method identifier.
    ///   - isSubscription: Whether this is a subscription payment.
    /// - Returns: The evaluation result.
    public func evaluate(
        peerPubkey: String,
        peerName: String,
        amount: Int64,
        methodId: String,
        isSubscription: Bool = false
    ) -> AutopayEvaluationResult {
        let settings = autoPayStorage.getSettings()
        let peerLimits = autoPayStorage.getPeerLimits()
        let rules = autoPayStorage.getRules()
        
        // Check if autopay is enabled
        guard settings.isEnabled else {
            return .denied(reason: "Auto-pay is disabled")
        }
        
        // Check per-payment limit
        if amount > settings.maxPerPayment {
            if settings.confirmHighValue {
                return .needsApproval
            }
            return .denied(reason: "Exceeds max per payment")
        }
        
        // Check global daily limit
        let spentToday = calculateSpentToday()
        if spentToday + amount > settings.globalDailyLimit {
            return .denied(reason: "Would exceed daily limit")
        }
        
        // Check if first payment to peer requires confirmation
        let isNewPeer = !peerLimits.contains { $0.peerPubkey == peerPubkey }
        if isNewPeer && settings.confirmFirstPayment {
            return .needsApproval
        }
        
        // Check subscription confirmation requirement
        if isSubscription && settings.confirmSubscriptions {
            return .needsApproval
        }
        
        // Check biometric for large amounts
        // Note: Background payments cannot show biometric prompts
        if settings.biometricForLarge && amount > 100_000 {
            return .needsBiometric
        }
        
        // Check peer-specific limit
        if let peerLimit = peerLimits.first(where: { $0.peerPubkey == peerPubkey }) {
            var mutableLimit = peerLimit
            mutableLimit.resetIfNeeded()
            
            // Update storage if reset occurred
            if mutableLimit.spentSats != peerLimit.spentSats {
                try? autoPayStorage.savePeerLimit(mutableLimit)
            }
            
            if mutableLimit.spentSats + amount > mutableLimit.limitSats {
                return .denied(reason: "Would exceed peer limit")
            }
        }
        
        // Check auto-pay rules
        for rule in rules where rule.isEnabled {
            if rule.matches(amount: amount, method: methodId, peer: peerPubkey) {
                return .approved(ruleId: rule.id, ruleName: rule.name)
            }
        }
        
        return .needsApproval
    }
    
    /// Evaluate for background context, treating biometric requirement as needs approval.
    ///
    /// This method should be used in background tasks where biometric prompts are not possible.
    ///
    /// - Parameters:
    ///   - peerPubkey: The peer's public key.
    ///   - peerName: The peer's display name.
    ///   - amount: Payment amount in satoshis.
    ///   - methodId: The payment method identifier.
    ///   - isSubscription: Whether this is a subscription payment.
    /// - Returns: The evaluation result (never returns `.needsBiometric`).
    public func evaluateForBackground(
        peerPubkey: String,
        peerName: String,
        amount: Int64,
        methodId: String,
        isSubscription: Bool = false
    ) -> AutopayEvaluationResult {
        let result = evaluate(
            peerPubkey: peerPubkey,
            peerName: peerName,
            amount: amount,
            methodId: methodId,
            isSubscription: isSubscription
        )
        
        // Convert biometric requirement to needs approval for background contexts
        if case .needsBiometric = result {
            return .needsApproval
        }
        
        return result
    }
    
    // MARK: - Helpers
    
    private func calculateSpentToday() -> Int64 {
        let history = autoPayStorage.getHistory()
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        
        return history
            .filter { $0.timestamp >= startOfDay && $0.wasApproved }
            .reduce(0) { $0 + $1.amount }
    }
    
    /// Record a payment in the auto-pay history.
    ///
    /// - Parameters:
    ///   - peerPubkey: The peer's public key.
    ///   - peerName: The peer's display name.
    ///   - amount: Payment amount in satoshis.
    ///   - approved: Whether the payment was approved.
    ///   - reason: Optional reason for the result.
    public func recordPayment(
        peerPubkey: String,
        peerName: String,
        amount: Int64,
        approved: Bool,
        reason: String = ""
    ) {
        let entry = AutoPayHistoryEntry(
            peerPubkey: peerPubkey,
            peerName: peerName,
            amount: amount,
            wasApproved: approved,
            reason: reason
        )
        
        try? autoPayStorage.saveHistoryEntry(entry)
    }
}

