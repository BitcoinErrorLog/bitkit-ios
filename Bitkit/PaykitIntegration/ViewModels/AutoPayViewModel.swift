//
//  AutoPayViewModel.swift
//  Bitkit
//
//  ViewModel for Auto-Pay settings with notification preferences and confirmation toggles
//

import Foundation
import SwiftUI

@MainActor
class AutoPayViewModel: ObservableObject {
    @Published var settings: AutoPaySettings
    @Published var peerLimits: [StoredPeerLimit] = []
    @Published var rules: [StoredAutoPayRule] = []
    @Published var history: [AutoPayHistoryEntry] = []
    @Published var isLoading = false
    
    // Computed spending amounts
    @Published var spentToday: Int64 = 0
    
    private let autoPayStorage: AutoPayStorage
    private let autoPayEvaluator: AutoPayEvaluatorService
    private let identityName: String
    
    init(identityName: String = "default") {
        self.identityName = identityName
        self.autoPayStorage = AutoPayStorage(identityName: identityName)
        self.autoPayEvaluator = AutoPayEvaluatorService(identityName: identityName)
        self.settings = autoPayStorage.getSettings()
    }
    
    func loadSettings() {
        isLoading = true
        settings = autoPayStorage.getSettings()
        peerLimits = autoPayStorage.getPeerLimits()
        rules = autoPayStorage.getRules()
        calculateSpentToday()
        isLoading = false
    }
    
    func loadHistory() {
        history = autoPayStorage.getHistory()
    }
    
    private func calculateSpentToday() {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        
        spentToday = history
            .filter { $0.timestamp >= startOfDay && $0.wasApproved }
            .reduce(0) { $0 + $1.amount }
    }
    
    func saveSettings() throws {
        try autoPayStorage.saveSettings(settings)
    }
    
    func addPeerLimit(_ limit: StoredPeerLimit) throws {
        try autoPayStorage.savePeerLimit(limit)
        loadSettings()
    }
    
    func deletePeerLimit(_ limit: StoredPeerLimit) throws {
        try autoPayStorage.deletePeerLimit(id: limit.id)
        loadSettings()
    }
    
    func addRule(_ rule: StoredAutoPayRule) throws {
        try autoPayStorage.saveRule(rule)
        loadSettings()
    }
    
    func deleteRule(_ rule: StoredAutoPayRule) throws {
        try autoPayStorage.deleteRule(id: rule.id)
        loadSettings()
    }
    
    func recordPayment(peerPubkey: String, peerName: String, amount: Int64, approved: Bool, reason: String = "") {
        // Delegate to the evaluator service for storage
        autoPayEvaluator.recordPayment(
            peerPubkey: peerPubkey,
            peerName: peerName,
            amount: amount,
            approved: approved,
            reason: reason
        )
        
        // Reload local state for UI updates
        loadHistory()
        calculateSpentToday()
    }
    
    /// Evaluate if a payment should be auto-approved.
    ///
    /// Delegates to `AutoPayEvaluatorService` for the actual evaluation logic,
    /// but handles UI-specific side effects like notifications.
    ///
    /// - Parameters:
    ///   - peerPubkey: The peer's public key.
    ///   - peerName: The peer's display name.
    ///   - amount: Payment amount in satoshis.
    ///   - methodId: The payment method identifier.
    ///   - isSubscription: Whether this is a subscription payment.
    /// - Returns: The evaluation result.
    func evaluate(peerPubkey: String, peerName: String, amount: Int64, methodId: String, isSubscription: Bool = false) -> AutopayEvaluationResult {
        // Delegate to the evaluator service for the actual logic
        let result = autoPayEvaluator.evaluate(
            peerPubkey: peerPubkey,
            peerName: peerName,
            amount: amount,
            methodId: methodId,
            isSubscription: isSubscription
        )
        
        // Handle UI-specific side effects based on result
        switch result {
        case .denied(let reason):
            if reason.contains("daily limit") && settings.notifyOnLimitReached {
                sendLimitReachedNotification()
            }
        case .needsApproval:
            let isNewPeer = !peerLimits.contains { $0.peerPubkey == peerPubkey }
            if isNewPeer && settings.notifyOnNewPeer {
                sendNewPeerNotification(peerName: peerName)
            }
        default:
            break
        }
        
        return result
    }
    
    // MARK: - Notifications
    
    private func sendLimitReachedNotification() {
        NotificationCenter.default.post(
            name: Notification.Name("PaykitAutoPayLimitReached"),
            object: nil
        )
    }
    
    private func sendNewPeerNotification(peerName: String) {
        NotificationCenter.default.post(
            name: Notification.Name("PaykitAutoPayNewPeer"),
            object: nil,
            userInfo: ["peerName": peerName]
        )
    }
}

// MARK: - History Entry Model

public struct AutoPayHistoryEntry: Identifiable, Codable {
    public let id: String
    let peerPubkey: String
    let peerName: String
    let amount: Int64
    let wasApproved: Bool
    let reason: String
    let timestamp: Date
    
    init(
        id: String = UUID().uuidString,
        peerPubkey: String,
        peerName: String,
        amount: Int64,
        wasApproved: Bool,
        reason: String = "",
        timestamp: Date = Date()
    ) {
        self.id = id
        self.peerPubkey = peerPubkey
        self.peerName = peerName
        self.amount = amount
        self.wasApproved = wasApproved
        self.reason = reason
        self.timestamp = timestamp
    }
}

