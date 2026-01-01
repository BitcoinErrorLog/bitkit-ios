//
//  NoisePaymentViewModel.swift
//  Bitkit
//
//  ViewModel for Noise payment flows with real Pubky-ring integration
//

import Foundation
import SwiftUI

@MainActor
class NoisePaymentViewModel: ObservableObject {
    @Published var isConnecting = false
    @Published var isConnected = false
    @Published var isListening = false
    @Published var isSessionActive = false
    @Published var hasNoiseKey = false
    @Published var currentUserPubkey: String?
    @Published var paymentRequest: NoisePaymentRequest?
    @Published var paymentResponse: NoisePaymentResponse?
    @Published var errorMessage: String?
    
    private let noisePaymentService = NoisePaymentService.shared
    private let pubkyRingBridge = PubkyRingBridge.shared
    
    var noiseKeyStatus: String {
        hasNoiseKey ? "Active" : "Not configured"
    }
    
    var activeChannelsStatus: String {
        isConnected ? "1 active" : "None"
    }
    
    func checkSessionStatus() {
        if let pubkey = PaykitKeyManager.shared.getCurrentPublicKeyZ32(),
           let session = pubkyRingBridge.getCachedSession(for: pubkey) {
            isSessionActive = true
            currentUserPubkey = pubkey
            hasNoiseKey = true
        } else {
            isSessionActive = false
            currentUserPubkey = PaykitKeyManager.shared.getCurrentPublicKeyZ32()
            hasNoiseKey = PaykitKeyManager.shared.getCurrentPublicKeyZ32() != nil
        }
    }
    
    func refreshSession() {
        checkSessionStatus()
    }
    
    func handleSessionAuthenticated(_ session: PubkyRingSession) {
        // Session is already cached by PubkyRingBridge
        // Configure DirectoryService with the session for authenticated writes
        DirectoryService.shared.configureWithPubkySession(session)
        checkSessionStatus()
    }
    
    func isValidRecipient(_ pubkey: String) -> Bool {
        // z-base32 pubkeys are 52 characters
        let trimmed = pubkey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count == 52 && trimmed.allSatisfy { c in
            "ybndrfg8ejkmcpqxot1uwisza345h769".contains(c.lowercased())
        }
    }
    
    func sendPayment(_ request: NoisePaymentRequest) async {
        isConnecting = true
        errorMessage = nil
        
        do {
            let response = try await noisePaymentService.sendPaymentRequest(request)
            paymentResponse = response
            isConnected = true
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isConnecting = false
    }
    
    func receivePayment() async {
        guard isSessionActive else {
            errorMessage = "Please authenticate with Pubky-ring first"
            return
        }
        
        isListening = true
        isConnecting = true
        errorMessage = nil
        
        do {
            if let request = try await noisePaymentService.receivePaymentRequest() {
                paymentRequest = request
                isConnected = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isConnecting = false
    }
    
    func stopListening() {
        isListening = false
        // NoisePaymentService doesn't have stopListening - it's stateless
    }
    
    func acceptIncomingRequest() async {
        guard let request = paymentRequest else { return }
        
        isConnecting = true
        errorMessage = nil
        
        do {
            // Construct paykit: URI for proper payment routing
            let paykitUri = "paykit:\(request.payeePubkey)"
            let amountSats = UInt64(request.amount ?? "0") ?? 0
            
            let paymentService = PaykitPaymentService.shared
            let result = try await paymentService.pay(
                to: paykitUri,
                amountSats: amountSats,
                peerPubkey: request.payeePubkey
            )
            
            if result.success {
                Logger.info("NoisePaymentViewModel: Payment accepted successfully, receipt: \(result.receipt.id)", context: "NoisePaymentViewModel")
                paymentRequest = nil
                paymentResponse = NoisePaymentResponse(
                    success: true,
                    receiptId: result.receipt.id,
                    confirmedAt: Date(),
                    errorCode: nil,
                    errorMessage: nil
                )
            } else {
                let errorMsg = result.error?.localizedDescription ?? "Payment failed"
                Logger.error("NoisePaymentViewModel: Payment failed: \(errorMsg)", context: "NoisePaymentViewModel")
                errorMessage = errorMsg
            }
        } catch {
            Logger.error("NoisePaymentViewModel: Payment acceptance failed: \(error)", context: "NoisePaymentViewModel")
            errorMessage = error.localizedDescription
        }
        
        isConnecting = false
    }
    
    func declineIncomingRequest() async {
        guard paymentRequest != nil else { return }
        
        // Decline by simply clearing the request
        paymentRequest = nil
    }
}

