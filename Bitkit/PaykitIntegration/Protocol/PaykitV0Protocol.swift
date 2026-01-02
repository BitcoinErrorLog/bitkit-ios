//
//  PaykitV0Protocol.swift
//  Bitkit
//
//  Canonical Paykit v0 protocol conventions.
//
//  This file provides the single source of truth for:
//  - Pubkey normalization and scope hashing
//  - Storage path construction
//  - AAD (Additional Authenticated Data) formats for Sealed Blob v1
//
//  All implementations must match paykit-lib/src/protocol exactly.
//

import Foundation
import CryptoKit

/// Canonical Paykit v0 protocol conventions.
///
/// This struct provides static methods for:
/// - Pubkey normalization and scope hashing
/// - Storage path construction
/// - AAD (Additional Authenticated Data) formats for Sealed Blob v1
///
/// All implementations must match `paykit-lib/src/protocol` exactly.
public struct PaykitV0Protocol {
    
    // MARK: - Constants
    
    /// Protocol version string.
    public static let protocolVersion = "v0"
    
    /// Base path prefix for all Paykit v0 data.
    public static let paykitV0Prefix = "/pub/paykit.app/v0"
    
    /// Path suffix for payment requests directory.
    public static let requestsSubpath = "requests"
    
    /// Path suffix for subscription proposals directory.
    public static let subscriptionProposalsSubpath = "subscriptions/proposals"
    
    /// Path for Noise endpoint.
    public static let noiseEndpointSubpath = "noise"
    
    /// Path suffix for secure handoff directory.
    public static let handoffSubpath = "handoff"
    
    /// AAD prefix for all Paykit v0 sealed blobs.
    public static let aadPrefix = "paykit:v0"
    
    /// Purpose label for payment requests.
    public static let purposeRequest = "request"
    
    /// Purpose label for subscription proposals.
    public static let purposeSubscriptionProposal = "subscription_proposal"
    
    /// Purpose label for secure handoff payloads.
    public static let purposeHandoff = "handoff"
    
    /// Valid characters in z-base-32 encoding (lowercase only).
    private static let z32Alphabet: Set<Character> = Set("ybndrfg8ejkmcpqxot1uwisza345h769")
    
    /// Expected length of a z-base-32 encoded Ed25519 public key (256 bits / 5 bits per char).
    private static let z32PubkeyLength = 52
    
    // MARK: - Errors
    
    public enum ProtocolError: Error, LocalizedError {
        case invalidPubkeyLength(actual: Int, expected: Int)
        case invalidZ32Character(Character)
        
        public var errorDescription: String? {
            switch self {
            case .invalidPubkeyLength(let actual, let expected):
                return "z32 pubkey must be \(expected) chars, got \(actual)"
            case .invalidZ32Character(let char):
                return "invalid z32 character: '\(char)'"
            }
        }
    }
    
    // MARK: - Scope Derivation
    
    /// Normalize a z-base-32 pubkey string.
    ///
    /// Performs:
    /// 1. Trim whitespace
    /// 2. Strip `pk:` prefix if present
    /// 3. Lowercase
    /// 4. Validate length (52 chars) and alphabet
    ///
    /// - Parameter pubkey: The pubkey string to normalize
    /// - Returns: The normalized pubkey (52 lowercase z32 chars)
    /// - Throws: ProtocolError if the pubkey is malformed
    public static func normalizePubkeyZ32(_ pubkey: String) throws -> String {
        let trimmed = pubkey.trimmingCharacters(in: .whitespaces)
        
        // Strip pk: prefix if present
        let withoutPrefix = trimmed.hasPrefix("pk:") ? String(trimmed.dropFirst(3)) : trimmed
        
        // Lowercase
        let lowercased = withoutPrefix.lowercased()
        
        // Validate length
        guard lowercased.count == z32PubkeyLength else {
            throw ProtocolError.invalidPubkeyLength(actual: lowercased.count, expected: z32PubkeyLength)
        }
        
        // Validate alphabet
        for char in lowercased {
            guard z32Alphabet.contains(char) else {
                throw ProtocolError.invalidZ32Character(char)
            }
        }
        
        return lowercased
    }
    
    /// Compute the scope hash for a pubkey.
    ///
    /// `scope = hex(sha256(utf8(normalized_pubkey_z32)))`
    ///
    /// The scope is used as a per-recipient directory name in storage paths.
    ///
    /// - Parameter pubkeyZ32: A z-base-32 encoded pubkey (will be normalized)
    /// - Returns: Lowercase hex string (64 chars) representing the SHA-256 hash
    /// - Throws: ProtocolError if the pubkey is malformed
    public static func recipientScope(_ pubkeyZ32: String) throws -> String {
        let normalized = try normalizePubkeyZ32(pubkeyZ32)
        return computeScopeHash(normalized)
    }
    
    /// Alias for `recipientScope` - used for subscription proposals.
    ///
    /// Semantically identical, but named for clarity when dealing with subscriptions.
    public static func subscriberScope(_ pubkeyZ32: String) throws -> String {
        try recipientScope(pubkeyZ32)
    }
    
    /// Internal: compute SHA-256 hash and return as lowercase hex.
    private static func computeScopeHash(_ normalizedPubkey: String) -> String {
        let data = Data(normalizedPubkey.utf8)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    
    // MARK: - Path Builders
    
    /// Build the storage path for a payment request.
    ///
    /// Path format: `/pub/paykit.app/v0/requests/{recipient_scope}/{request_id}`
    ///
    /// This path is used on the **sender's** storage to store an encrypted
    /// payment request addressed to the recipient.
    ///
    /// - Parameters:
    ///   - recipientPubkeyZ32: The recipient's z-base-32 encoded pubkey
    ///   - requestId: Unique identifier for this request
    /// - Returns: The full storage path (without the `pubky://owner` prefix)
    public static func paymentRequestPath(recipientPubkeyZ32: String, requestId: String) throws -> String {
        let scope = try recipientScope(recipientPubkeyZ32)
        return "\(paykitV0Prefix)/\(requestsSubpath)/\(scope)/\(requestId)"
    }
    
    /// Build the directory path for listing payment requests for a recipient.
    ///
    /// Path format: `/pub/paykit.app/v0/requests/{recipient_scope}/`
    ///
    /// Used when polling a contact's storage to discover pending requests.
    ///
    /// - Parameter recipientPubkeyZ32: The recipient's z-base-32 encoded pubkey
    /// - Returns: The directory path (with trailing slash for listing)
    public static func paymentRequestsDir(recipientPubkeyZ32: String) throws -> String {
        let scope = try recipientScope(recipientPubkeyZ32)
        return "\(paykitV0Prefix)/\(requestsSubpath)/\(scope)/"
    }
    
    /// Build the storage path for a subscription proposal.
    ///
    /// Path format: `/pub/paykit.app/v0/subscriptions/proposals/{subscriber_scope}/{proposal_id}`
    ///
    /// This path is used on the **provider's** storage to store an encrypted
    /// subscription proposal addressed to the subscriber.
    ///
    /// - Parameters:
    ///   - subscriberPubkeyZ32: The subscriber's z-base-32 encoded pubkey
    ///   - proposalId: Unique identifier for this proposal
    /// - Returns: The full storage path (without the `pubky://owner` prefix)
    public static func subscriptionProposalPath(subscriberPubkeyZ32: String, proposalId: String) throws -> String {
        let scope = try subscriberScope(subscriberPubkeyZ32)
        return "\(paykitV0Prefix)/\(subscriptionProposalsSubpath)/\(scope)/\(proposalId)"
    }
    
    /// Build the directory path for listing subscription proposals for a subscriber.
    ///
    /// Path format: `/pub/paykit.app/v0/subscriptions/proposals/{subscriber_scope}/`
    ///
    /// Used when polling a provider's storage to discover pending proposals.
    ///
    /// - Parameter subscriberPubkeyZ32: The subscriber's z-base-32 encoded pubkey
    /// - Returns: The directory path (with trailing slash for listing)
    public static func subscriptionProposalsDir(subscriberPubkeyZ32: String) throws -> String {
        let scope = try subscriberScope(subscriberPubkeyZ32)
        return "\(paykitV0Prefix)/\(subscriptionProposalsSubpath)/\(scope)/"
    }
    
    /// Build the storage path for a Noise endpoint.
    ///
    /// Path format: `/pub/paykit.app/v0/noise`
    ///
    /// This is a fixed path on the user's own storage.
    public static func noiseEndpointPath() -> String {
        "\(paykitV0Prefix)/\(noiseEndpointSubpath)"
    }
    
    /// Build the storage path for a secure handoff payload.
    ///
    /// Path format: `/pub/paykit.app/v0/handoff/{request_id}`
    ///
    /// - Parameter requestId: Unique identifier for this handoff request
    /// - Returns: The full storage path
    public static func secureHandoffPath(requestId: String) -> String {
        "\(paykitV0Prefix)/\(handoffSubpath)/\(requestId)"
    }
    
    // MARK: - AAD Builders
    
    /// Build AAD for a payment request.
    ///
    /// Format: `paykit:v0:request:{path}:{request_id}`
    ///
    /// - Parameters:
    ///   - recipientPubkeyZ32: The recipient's z-base-32 encoded pubkey
    ///   - requestId: Unique identifier for this request
    /// - Returns: The AAD string to use with Sealed Blob v1 encryption
    public static func paymentRequestAad(recipientPubkeyZ32: String, requestId: String) throws -> String {
        let path = try paymentRequestPath(recipientPubkeyZ32: recipientPubkeyZ32, requestId: requestId)
        return "\(aadPrefix):\(purposeRequest):\(path):\(requestId)"
    }
    
    /// Build AAD for a subscription proposal.
    ///
    /// Format: `paykit:v0:subscription_proposal:{path}:{proposal_id}`
    ///
    /// - Parameters:
    ///   - subscriberPubkeyZ32: The subscriber's z-base-32 encoded pubkey
    ///   - proposalId: Unique identifier for this proposal
    /// - Returns: The AAD string to use with Sealed Blob v1 encryption
    public static func subscriptionProposalAad(subscriberPubkeyZ32: String, proposalId: String) throws -> String {
        let path = try subscriptionProposalPath(subscriberPubkeyZ32: subscriberPubkeyZ32, proposalId: proposalId)
        return "\(aadPrefix):\(purposeSubscriptionProposal):\(path):\(proposalId)"
    }
    
    /// Build AAD for a secure handoff payload.
    ///
    /// Format: `paykit:v0:handoff:{owner_pubkey}:{path}:{request_id}`
    ///
    /// - Parameters:
    ///   - ownerPubkeyZ32: The Ring user's z-base-32 encoded pubkey
    ///   - requestId: Unique identifier for this handoff
    /// - Returns: The AAD string to use with Sealed Blob v1 encryption
    public static func secureHandoffAad(ownerPubkeyZ32: String, requestId: String) -> String {
        let path = secureHandoffPath(requestId: requestId)
        return "\(aadPrefix):\(purposeHandoff):\(ownerPubkeyZ32):\(path):\(requestId)"
    }
    
    /// Build AAD for a cross-device relay session payload.
    ///
    /// Format: `paykit:v0:relay:session:{request_id}`
    ///
    /// - Parameter requestId: Unique identifier for this relay session request
    /// - Returns: The AAD string to use with Sealed Blob v1 encryption
    public static func relaySessionAad(requestId: String) -> String {
        "\(aadPrefix):relay:session:\(requestId)"
    }
    
    /// Build AAD from explicit path and ID.
    ///
    /// Format: `paykit:v0:{purpose}:{path}:{id}`
    ///
    /// - Parameters:
    ///   - purpose: The object type (use constants like `purposeRequest`)
    ///   - path: The full storage path
    ///   - id: The object identifier
    public static func buildAad(purpose: String, path: String, id: String) -> String {
        "\(aadPrefix):\(purpose):\(path):\(id)"
    }
}

