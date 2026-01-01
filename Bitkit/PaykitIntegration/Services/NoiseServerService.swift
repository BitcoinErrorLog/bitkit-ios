//
//  NoiseServerService.swift
//  Bitkit
//
//  Service for handling incoming Noise connections from push wake notifications.
//  When a peer sends a wake notification, this service starts a Noise server
//  to accept the incoming connection.
//

import Foundation
import Network
import UserNotifications

/// Service for handling incoming Noise payment requests.
///
/// When the app is woken by a push notification indicating an incoming Noise connection,
/// this service:
/// 1. Starts a local Noise server
/// 2. Accepts the incoming connection
/// 3. Receives and decrypts the payment request
/// 4. Stores the request for user action
/// 5. Shows a notification
public final class NoiseServerService {
    
    public static let shared = NoiseServerService()
    
    // MARK: - Configuration
    
    private let defaultPort: UInt16 = 9000
    private let serverTimeout: TimeInterval = 30
    
    // MARK: - Dependencies
    
    private let noisePaymentService = NoisePaymentService.shared
    private let paymentRequestStorage = PaymentRequestStorage()
    
    private init() {}
    
    // MARK: - Public API
    
    /// Handle incoming Noise request from push notification.
    ///
    /// - Parameters:
    ///   - fromPubkey: Sender's pubkey from push payload
    ///   - endpointHost: Our endpoint host (optional, for logging)
    ///   - endpointPort: Our endpoint port to listen on
    ///   - noisePubkey: Sender's noise public key (optional)
    public func handleIncomingRequest(
        fromPubkey: String?,
        endpointHost: String?,
        endpointPort: Int,
        noisePubkey: String?
    ) async {
        let shortPubkey = fromPubkey.map { String($0.prefix(12)) } ?? "unknown"
        Logger.info("NoiseServerService: Handling incoming request from \(shortPubkey)...", context: "NoiseServerService")
        
        do {
            try await startServerAndReceive(port: UInt16(endpointPort), expectedFromPubkey: fromPubkey)
        } catch {
            Logger.error("NoiseServerService: Failed to handle request: \(error)", context: "NoiseServerService")
        }
    }
    
    /// Handle a decoded push notification payload.
    ///
    /// - Parameter userInfo: The push notification userInfo dictionary
    public func handlePushNotification(_ userInfo: [AnyHashable: Any]) async {
        guard let type = userInfo["type"] as? String, type == "noise_connect" else {
            Logger.debug("NoiseServerService: Ignoring non-noise push notification", context: "NoiseServerService")
            return
        }
        
        let fromPubkey = userInfo["from_pubkey"] as? String
        let endpointHost = userInfo["endpoint_host"] as? String
        let endpointPort = (userInfo["endpoint_port"] as? Int) ?? Int(defaultPort)
        let noisePubkey = userInfo["noise_pubkey"] as? String
        
        await handleIncomingRequest(
            fromPubkey: fromPubkey,
            endpointHost: endpointHost,
            endpointPort: endpointPort,
            noisePubkey: noisePubkey
        )
    }
    
    // MARK: - Private Implementation
    
    private func startServerAndReceive(port: UInt16, expectedFromPubkey: String?) async throws {
        try await noisePaymentService.startBackgroundServer(port: Int(port)) { [weak self] request in
            await self?.handleReceivedRequest(request, expectedFromPubkey: expectedFromPubkey)
        }
    }
    
    private func handleReceivedRequest(_ noiseRequest: NoisePaymentRequest, expectedFromPubkey: String?) async {
        // Validate sender if expected
        if let expected = expectedFromPubkey, noiseRequest.payerPubkey != expected {
            Logger.warn("NoiseServerService: Received from unexpected pubkey. Expected: \(expected.prefix(12))..., got: \(noiseRequest.payerPubkey.prefix(12))...", context: "NoiseServerService")
        }
        
        // Convert to BitkitPaymentRequest and store
        // For incoming requests: fromPubkey = who sent the request (payee/requester),
        // toPubkey = who should pay (payer = me)
        let request = BitkitPaymentRequest(
            id: noiseRequest.receiptId,
            fromPubkey: noiseRequest.payeePubkey,  // The requester who wants payment
            toPubkey: noiseRequest.payerPubkey,    // Me, who is expected to pay
            amountSats: Int64(noiseRequest.amount ?? "0") ?? 0,
            currency: noiseRequest.currency ?? "BTC",
            methodId: noiseRequest.methodId,
            description: noiseRequest.description ?? "",
            createdAt: Date(timeIntervalSince1970: TimeInterval(noiseRequest.createdAt)),
            expiresAt: nil,
            status: .pending,
            direction: .incoming
        )
        
        do {
            try paymentRequestStorage.addRequest(request)
            Logger.info("NoiseServerService: Stored request \(request.id)", context: "NoiseServerService")
            
            // Show notification
            await showPaymentRequestNotification(request)
        } catch {
            Logger.error("NoiseServerService: Failed to store request: \(error)", context: "NoiseServerService")
        }
    }
    
    private func showPaymentRequestNotification(_ request: BitkitPaymentRequest) async {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("paykit__payment_request_received", comment: "Payment Request Received")
        content.body = String(
            format: NSLocalizedString("paykit__payment_request_body", comment: "Request for %lld sats from %@"),
            request.amountSats,
            formatPubkey(request.fromPubkey)
        )
        content.sound = .default
        content.userInfo = [
            "type": "paykit_noise_request",
            "requestId": request.id
        ]
        
        let notificationRequest = UNNotificationRequest(
            identifier: "noise_request_\(request.id)",
            content: content,
            trigger: nil
        )
        
        do {
            try await UNUserNotificationCenter.current().add(notificationRequest)
            Logger.debug("NoiseServerService: Sent notification for request \(request.id)", context: "NoiseServerService")
        } catch {
            Logger.error("NoiseServerService: Failed to send notification: \(error)", context: "NoiseServerService")
        }
    }
    
    private func formatPubkey(_ pubkey: String) -> String {
        guard pubkey.count > 12 else { return pubkey }
        return "\(pubkey.prefix(6))...\(pubkey.suffix(6))"
    }
}

