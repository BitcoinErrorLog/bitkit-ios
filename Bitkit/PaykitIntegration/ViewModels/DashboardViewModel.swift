//
//  DashboardViewModel.swift
//  Bitkit
//
//  ViewModel for Paykit Dashboard
//

import Foundation
import SwiftUI

@MainActor
class DashboardViewModel: ObservableObject {
    @Published var recentReceipts: [PaymentReceipt] = []
    @Published var contactCount: Int = 0
    @Published var totalSent: UInt64 = 0
    @Published var totalReceived: UInt64 = 0
    @Published var pendingCount: Int = 0
    @Published var isLoading = true
    
    @Published var hasPaymentMethods: Bool = false
    @Published var hasPublishedMethods: Bool = false
    @Published var autoPayEnabled: Bool = false
    @Published var activeSubscriptions: Int = 0
    @Published var pendingRequests: Int = 0
    @Published var publishedMethodsCount: Int = 0
    @Published var sessionCount: Int = 0
    @Published private(set) var activeSession: PubkyRingSession?
    
    /// Whether the current session is active (not expired)
    var isSessionActive: Bool {
        guard let session = activeSession else { return false }
        return !session.isExpired
    }
    
    /// Session status for UI display
    var sessionStatus: SessionStatus {
        guard let session = activeSession else { return .noSession }
        return session.isExpired ? .expired : .active
    }
    
    private let receiptStorage: ReceiptStorage
    private let contactStorage: ContactStorage
    private let autoPayStorage: AutoPayStorage
    private let subscriptionStorage: SubscriptionStorage
    private let paymentRequestStorage: PaymentRequestStorage
    
    private let identityName: String
    
    init(identityName: String? = nil) {
        // Use the current pubkey for storage key to match SubscriptionsViewModel behavior
        self.identityName = identityName ?? PaykitKeyManager.shared.getCurrentPublicKeyZ32() ?? "default"
        self.receiptStorage = ReceiptStorage(identityName: self.identityName)
        self.contactStorage = ContactStorage(identityName: self.identityName)
        self.autoPayStorage = AutoPayStorage(identityName: self.identityName)
        self.subscriptionStorage = SubscriptionStorage(identityName: self.identityName)
        self.paymentRequestStorage = PaymentRequestStorage(identityName: self.identityName)
    }
    
    func loadDashboard() {
        isLoading = true
        
        // Load recent receipts
        recentReceipts = receiptStorage.recentReceipts(limit: 5)
        
        // Load stats from local storage first
        contactCount = contactStorage.listContacts().count
        totalSent = receiptStorage.totalSent()
        totalReceived = receiptStorage.totalReceived()
        pendingCount = receiptStorage.pendingCount()
        
        // Load Auto-Pay status
        let autoPaySettings = autoPayStorage.getSettings()
        autoPayEnabled = autoPaySettings.isEnabled
        
        // Load Subscriptions count
        activeSubscriptions = subscriptionStorage.activeSubscriptions().count
        
        // Load Payment Requests count
        pendingRequests = paymentRequestStorage.pendingCount()
        
        // Load Session count and active session
        let sessions = PubkyRingBridge.shared.getAllSessions()
        sessionCount = sessions.count
        activeSession = sessions.first(where: { !$0.isExpired }) ?? sessions.first
        
        isLoading = false
        
        // Sync contacts from Pubky follows in background (updates contactCount when done)
        Task {
            await syncContactsFromFollows()
        }
    }
    
    /// Sync contacts from Pubky follows and update contact count
    private func syncContactsFromFollows() async {
        do {
            let follows = try await DirectoryService.shared.discoverContactsFromFollows()
            
            // Convert and persist locally
            var followContacts: [Contact] = []
            for discovered in follows {
                let existing = contactStorage.getContact(id: discovered.pubkey)
                let contact = Contact(
                    publicKeyZ32: discovered.pubkey,
                    name: discovered.name ?? existing?.name ?? "",
                    notes: existing?.notes
                )
                followContacts.append(contact)
            }
            
            try contactStorage.importContacts(followContacts)
            
            // Update UI
            await MainActor.run {
                self.contactCount = followContacts.count
            }
        } catch {
            Logger.debug("Failed to sync contacts from follows: \(error)", context: "DashboardVM")
            // Keep the local storage count as fallback
        }
    }
    
    var isSetupComplete: Bool {
        contactCount > 0 && hasPaymentMethods && hasPublishedMethods
    }
    
    var setupProgress: Int {
        var completed = 1 // Identity is always created at this point
        if contactCount > 0 { completed += 1 }
        if hasPaymentMethods { completed += 1 }
        if hasPublishedMethods { completed += 1 }
        return (completed * 100) / 4
    }
}

/// Session status for UI display
enum SessionStatus {
    case active
    case expired
    case noSession
    
    var displayText: String {
        switch self {
        case .active: return "Session Active"
        case .expired: return "Session Expired"
        case .noSession: return "No Session"
        }
    }
    
    var accessibilityId: String {
        displayText
    }
    
    var color: Color {
        switch self {
        case .active: return .green
        case .expired: return .orange
        case .noSession: return .gray
        }
    }
}

