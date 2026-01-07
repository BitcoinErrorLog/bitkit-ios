//
//  PaymentRequest.swift
//  Bitkit
//
//  PaymentRequest model for payment requests
//

import Foundation

/// A payment request stored in persistent storage (distinct from PaykitMobile.PaymentRequest)
public struct BitkitPaymentRequest: Identifiable, Codable, Hashable {
    public let id: String
    public let fromPubkey: String
    public let toPubkey: String
    public let amountSats: Int64
    public let currency: String
    public let methodId: String
    public let description: String
    public let createdAt: Date
    public let expiresAt: Date?
    public var status: PaymentRequestStatus
    public let direction: RequestDirection
    
    public init(
        id: String,
        fromPubkey: String,
        toPubkey: String,
        amountSats: Int64,
        currency: String,
        methodId: String,
        description: String,
        createdAt: Date,
        expiresAt: Date?,
        status: PaymentRequestStatus,
        direction: RequestDirection
    ) {
        self.id = id
        self.fromPubkey = fromPubkey
        self.toPubkey = toPubkey
        self.amountSats = amountSats
        self.currency = currency
        self.methodId = methodId
        self.description = description
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.status = status
        self.direction = direction
    }
    
    /// Display name for the counterparty
    public var counterpartyName: String {
        let key = direction == .incoming ? fromPubkey : toPubkey
        if key.count > 12 {
            return String(key.prefix(6)) + "..." + String(key.suffix(4))
        }
        return key
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    public static func == (lhs: BitkitPaymentRequest, rhs: BitkitPaymentRequest) -> Bool {
        lhs.id == rhs.id
    }
}

/// Status of a payment request
public enum PaymentRequestStatus: String, Codable, CaseIterable {
    case pending = "Pending"
    case accepted = "Accepted"
    case declined = "Declined"
    case expired = "Expired"
    case paid = "Paid"
}

/// Direction of the request (incoming = someone is requesting from you)
public enum RequestDirection: String, Codable {
    case incoming  // Someone is requesting payment from you
    case outgoing  // You are requesting payment from someone
}
