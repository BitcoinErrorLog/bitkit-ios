//
//  PaykitV0Protocol.swift
//  Bitkit
//
//  Canonical Paykit v0 protocol conventions.
//
//  This file provides the single source of truth for:
//  - Pubkey normalization and ContextId derivation
//  - Storage path construction (using symmetric ContextId)
//  - AAD (Additional Authenticated Data) formats for Sealed Blob v2
//
//  All implementations must match paykit-lib/src/protocol exactly.
//

import Foundation
import CryptoKit

/// Canonical Paykit v0 protocol conventions.
///
/// This struct provides static methods for:
/// - Pubkey normalization and ContextId derivation
/// - Storage path construction (using symmetric ContextId)
/// - AAD (Additional Authenticated Data) formats for Sealed Blob v2
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
    
    /// Path suffix for ACKs directory.
    public static let acksSubpath = "acks"
    
    /// AAD prefix for all Paykit v0 sealed blobs.
    public static let aadPrefix = "paykit:v0"
    
    /// Purpose label for payment requests.
    public static let purposeRequest = "request"
    
    /// Purpose label for subscription proposals.
    public static let purposeSubscriptionProposal = "subscription_proposal"
    
    /// Purpose label for secure handoff payloads.
    public static let purposeHandoff = "handoff"
    
    /// Purpose label for ACKs.
    public static let purposeAck = "ack"
    
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
    
    // MARK: - Pubkey Normalization
    
    /// Normalize a z-base-32 pubkey string.
    ///
    /// Performs:
    /// 1. Trim whitespace
    /// 2. Strip `pubky://` prefix if present
    /// 3. Strip `pk:` prefix if present
    /// 4. Lowercase
    /// 5. Validate length (52 chars) and alphabet
    ///
    /// - Parameter pubkey: The pubkey string to normalize
    /// - Returns: The normalized pubkey (52 lowercase z32 chars)
    /// - Throws: ProtocolError if the pubkey is malformed
    public static func normalizePubkeyZ32(_ pubkey: String) throws -> String {
        var result = pubkey.trimmingCharacters(in: .whitespaces)
        
        // Strip pubky:// prefix if present
        if result.hasPrefix("pubky://") {
            result = String(result.dropFirst(8))
        }
        
        // Strip pk: prefix if present
        if result.hasPrefix("pk:") {
            result = String(result.dropFirst(3))
        }
        
        // Lowercase
        result = result.lowercased()
        
        // Validate length
        guard result.count == z32PubkeyLength else {
            throw ProtocolError.invalidPubkeyLength(actual: result.count, expected: z32PubkeyLength)
        }
        
        // Validate alphabet
        for char in result {
            guard z32Alphabet.contains(char) else {
                throw ProtocolError.invalidZ32Character(char)
            }
        }
        
        return result
    }
    
    // MARK: - ContextId Derivation (Sealed Blob v2)
    
    /// Compute the ContextId for a peer pair.
    ///
    /// `ContextId = hex(sha256("paykit:v0:context:" + first_z32 + ":" + second_z32))`
    ///
    /// Where `first_z32 <= second_z32` lexicographically (symmetric).
    ///
    /// - Parameters:
    ///   - pubkeyAZ32: First peer's z-base-32 encoded pubkey
    ///   - pubkeyBZ32: Second peer's z-base-32 encoded pubkey
    /// - Returns: Lowercase hex string (64 chars) representing the ContextId
    /// - Throws: ProtocolError if either pubkey is malformed
    public static func contextId(_ pubkeyAZ32: String, _ pubkeyBZ32: String) throws -> String {
        let normA = try normalizePubkeyZ32(pubkeyAZ32)
        let normB = try normalizePubkeyZ32(pubkeyBZ32)
        
        let (first, second) = normA <= normB ? (normA, normB) : (normB, normA)
        
        let preimage = "paykit:v0:context:\(first):\(second)"
        let data = Data(preimage.utf8)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    
    // MARK: - Legacy Scope Derivation (Deprecated)
    
    /// Compute the scope hash for a pubkey.
    ///
    /// `scope = hex(sha256(utf8(normalized_pubkey_z32)))`
    ///
    /// - Note: Deprecated in favor of ContextId-based paths. Use `contextId(_:_:)` instead.
    ///
    /// - Parameter pubkeyZ32: A z-base-32 encoded pubkey (will be normalized)
    /// - Returns: Lowercase hex string (64 chars) representing the SHA-256 hash
    /// - Throws: ProtocolError if the pubkey is malformed
    @available(*, deprecated, message: "Use contextId(_:_:) for Sealed Blob v2 paths")
    public static func recipientScope(_ pubkeyZ32: String) throws -> String {
        let normalized = try normalizePubkeyZ32(pubkeyZ32)
        return computeScopeHash(normalized)
    }
    
    /// Alias for `recipientScope` - used for subscription proposals.
    ///
    /// - Note: Deprecated in favor of ContextId-based paths. Use `contextId(_:_:)` instead.
    @available(*, deprecated, message: "Use contextId(_:_:) for Sealed Blob v2 paths")
    public static func subscriberScope(_ pubkeyZ32: String) throws -> String {
        try recipientScope(pubkeyZ32)
    }
    
    /// Internal: compute SHA-256 hash and return as lowercase hex.
    private static func computeScopeHash(_ normalizedPubkey: String) -> String {
        let data = Data(normalizedPubkey.utf8)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    
    // MARK: - Path Builders (ContextId-based)
    
    /// Build the storage path for a payment request.
    ///
    /// Path format: `/pub/paykit.app/v0/requests/{context_id}/{request_id}`
    ///
    /// Uses symmetric ContextId for sender-recipient pair.
    ///
    /// - Parameters:
    ///   - senderPubkeyZ32: The sender's z-base-32 encoded pubkey
    ///   - recipientPubkeyZ32: The recipient's z-base-32 encoded pubkey
    ///   - requestId: Unique identifier for this request
    /// - Returns: The full storage path (without the `pubky://owner` prefix)
    public static func paymentRequestPath(
        senderPubkeyZ32: String,
        recipientPubkeyZ32: String,
        requestId: String
    ) throws -> String {
        let ctxId = try contextId(senderPubkeyZ32, recipientPubkeyZ32)
        return "\(paykitV0Prefix)/\(requestsSubpath)/\(ctxId)/\(requestId)"
    }
    
    /// Build the directory path for listing payment requests.
    ///
    /// Path format: `/pub/paykit.app/v0/requests/{context_id}/`
    ///
    /// - Parameters:
    ///   - senderPubkeyZ32: The sender's z-base-32 encoded pubkey
    ///   - recipientPubkeyZ32: The recipient's z-base-32 encoded pubkey
    /// - Returns: The directory path (with trailing slash for listing)
    public static func paymentRequestsDir(
        senderPubkeyZ32: String,
        recipientPubkeyZ32: String
    ) throws -> String {
        let ctxId = try contextId(senderPubkeyZ32, recipientPubkeyZ32)
        return "\(paykitV0Prefix)/\(requestsSubpath)/\(ctxId)/"
    }
    
    /// Build the storage path for a subscription proposal.
    ///
    /// Path format: `/pub/paykit.app/v0/subscriptions/proposals/{context_id}/{proposal_id}`
    ///
    /// Uses symmetric ContextId for provider-subscriber pair.
    ///
    /// - Parameters:
    ///   - providerPubkeyZ32: The provider's z-base-32 encoded pubkey
    ///   - subscriberPubkeyZ32: The subscriber's z-base-32 encoded pubkey
    ///   - proposalId: Unique identifier for this proposal
    /// - Returns: The full storage path (without the `pubky://owner` prefix)
    public static func subscriptionProposalPath(
        providerPubkeyZ32: String,
        subscriberPubkeyZ32: String,
        proposalId: String
    ) throws -> String {
        let ctxId = try contextId(providerPubkeyZ32, subscriberPubkeyZ32)
        return "\(paykitV0Prefix)/\(subscriptionProposalsSubpath)/\(ctxId)/\(proposalId)"
    }
    
    /// Build the directory path for listing subscription proposals.
    ///
    /// Path format: `/pub/paykit.app/v0/subscriptions/proposals/{context_id}/`
    ///
    /// - Parameters:
    ///   - providerPubkeyZ32: The provider's z-base-32 encoded pubkey
    ///   - subscriberPubkeyZ32: The subscriber's z-base-32 encoded pubkey
    /// - Returns: The directory path (with trailing slash for listing)
    public static func subscriptionProposalsDir(
        providerPubkeyZ32: String,
        subscriberPubkeyZ32: String
    ) throws -> String {
        let ctxId = try contextId(providerPubkeyZ32, subscriberPubkeyZ32)
        return "\(paykitV0Prefix)/\(subscriptionProposalsSubpath)/\(ctxId)/"
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
    
    /// Build the storage path for an ACK.
    ///
    /// Path format: `/pub/paykit.app/v0/acks/{object_type}/{context_id}/{msg_id}`
    ///
    /// - Parameters:
    ///   - objectType: The type being ACKed (e.g., "request", "proposal")
    ///   - senderPubkeyZ32: The original sender's pubkey
    ///   - recipientPubkeyZ32: The original recipient's pubkey
    ///   - msgId: The original message ID being ACKed
    /// - Returns: The full storage path
    public static func ackPath(
        objectType: String,
        senderPubkeyZ32: String,
        recipientPubkeyZ32: String,
        msgId: String
    ) throws -> String {
        let ctxId = try contextId(senderPubkeyZ32, recipientPubkeyZ32)
        return "\(paykitV0Prefix)/\(acksSubpath)/\(objectType)/\(ctxId)/\(msgId)"
    }
    
    // MARK: - AAD Builders (Owner-bound for Sealed Blob v2)
    
    /// Build AAD for a payment request.
    ///
    /// Format: `paykit:v0:request:{owner}:{path}:{request_id}`
    ///
    /// - Parameters:
    ///   - ownerPubkeyZ32: The storage owner's z-base-32 encoded pubkey
    ///   - senderPubkeyZ32: The sender's z-base-32 encoded pubkey
    ///   - recipientPubkeyZ32: The recipient's z-base-32 encoded pubkey
    ///   - requestId: Unique identifier for this request
    /// - Returns: The AAD string to use with Sealed Blob v2 encryption
    public static func paymentRequestAad(
        ownerPubkeyZ32: String,
        senderPubkeyZ32: String,
        recipientPubkeyZ32: String,
        requestId: String
    ) throws -> String {
        let owner = try normalizePubkeyZ32(ownerPubkeyZ32)
        let path = try paymentRequestPath(
            senderPubkeyZ32: senderPubkeyZ32,
            recipientPubkeyZ32: recipientPubkeyZ32,
            requestId: requestId
        )
        return "\(aadPrefix):\(purposeRequest):\(owner):\(path):\(requestId)"
    }
    
    /// Build AAD for a subscription proposal.
    ///
    /// Format: `paykit:v0:subscription_proposal:{owner}:{path}:{proposal_id}`
    ///
    /// - Parameters:
    ///   - ownerPubkeyZ32: The storage owner's z-base-32 encoded pubkey
    ///   - providerPubkeyZ32: The provider's z-base-32 encoded pubkey
    ///   - subscriberPubkeyZ32: The subscriber's z-base-32 encoded pubkey
    ///   - proposalId: Unique identifier for this proposal
    /// - Returns: The AAD string to use with Sealed Blob v2 encryption
    public static func subscriptionProposalAad(
        ownerPubkeyZ32: String,
        providerPubkeyZ32: String,
        subscriberPubkeyZ32: String,
        proposalId: String
    ) throws -> String {
        let owner = try normalizePubkeyZ32(ownerPubkeyZ32)
        let path = try subscriptionProposalPath(
            providerPubkeyZ32: providerPubkeyZ32,
            subscriberPubkeyZ32: subscriberPubkeyZ32,
            proposalId: proposalId
        )
        return "\(aadPrefix):\(purposeSubscriptionProposal):\(owner):\(path):\(proposalId)"
    }
    
    /// Build AAD for a secure handoff payload.
    ///
    /// Format: `paykit:v0:handoff:{owner_pubkey}:{path}:{request_id}`
    ///
    /// - Parameters:
    ///   - ownerPubkeyZ32: The Ring user's z-base-32 encoded pubkey
    ///   - requestId: Unique identifier for this handoff
    /// - Returns: The AAD string to use with Sealed Blob v2 encryption
    public static func secureHandoffAad(ownerPubkeyZ32: String, requestId: String) throws -> String {
        let owner = try normalizePubkeyZ32(ownerPubkeyZ32)
        let path = secureHandoffPath(requestId: requestId)
        return "\(aadPrefix):\(purposeHandoff):\(owner):\(path):\(requestId)"
    }
    
    /// Build AAD for an ACK.
    ///
    /// Format: `paykit:v0:ack_{object_type}:{ack_writer}:{path}:{msg_id}`
    ///
    /// - Parameters:
    ///   - objectType: The type being ACKed (e.g., "request", "proposal")
    ///   - ackWriterPubkeyZ32: The pubkey of the entity writing the ACK
    ///   - senderPubkeyZ32: The original sender's pubkey
    ///   - recipientPubkeyZ32: The original recipient's pubkey
    ///   - msgId: The original message ID being ACKed
    /// - Returns: The AAD string to use with Sealed Blob v2 encryption
    public static func ackAad(
        objectType: String,
        ackWriterPubkeyZ32: String,
        senderPubkeyZ32: String,
        recipientPubkeyZ32: String,
        msgId: String
    ) throws -> String {
        let ackWriter = try normalizePubkeyZ32(ackWriterPubkeyZ32)
        let path = try ackPath(
            objectType: objectType,
            senderPubkeyZ32: senderPubkeyZ32,
            recipientPubkeyZ32: recipientPubkeyZ32,
            msgId: msgId
        )
        return "\(aadPrefix):ack_\(objectType):\(ackWriter):\(path):\(msgId)"
    }
    
    /// Build AAD for a cross-device relay session payload.
    ///
    /// Format: `paykit:v0:relay:session:{request_id}`
    ///
    /// - Parameter requestId: Unique identifier for this relay session request
    /// - Returns: The AAD string to use with Sealed Blob encryption
    public static func relaySessionAad(requestId: String) -> String {
        "\(aadPrefix):relay:session:\(requestId)"
    }
}
