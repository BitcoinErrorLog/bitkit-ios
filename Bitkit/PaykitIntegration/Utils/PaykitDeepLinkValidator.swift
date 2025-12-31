//
//  PaykitDeepLinkValidator.swift
//  Bitkit
//
//  Validates Paykit deep links for security and correctness.
//

import Foundation

/// Validates Paykit deep links before processing.
///
/// Ensures deep links have:
/// - Valid scheme (paykit:// or bitkit://)
/// - Valid host (payment-request for bitkit://)
/// - Required parameters present and non-empty
/// - Parameters within expected format/length constraints
public enum PaykitDeepLinkValidator {
    
    // MARK: - Validation Result
    
    public enum ValidationResult {
        case valid(requestId: String, fromPubkey: String)
        case invalid(reason: String)
    }
    
    // MARK: - Constants
    
    /// Maximum length for requestId parameter (UUID format is 36 chars)
    private static let maxRequestIdLength = 64
    
    /// Maximum length for pubkey parameter (z-base32 encoded pubkeys)
    private static let maxPubkeyLength = 256
    
    /// Allowed schemes for Paykit deep links
    private static let allowedSchemes: Set<String> = ["paykit", "bitkit"]
    
    /// Valid host for bitkit:// scheme
    private static let bitkitPaymentHost = "payment-request"
    
    // MARK: - Validation
    
    /// Validate a Paykit deep link URL.
    ///
    /// Valid formats:
    /// - `paykit://payment-request?requestId=xxx&from=yyy`
    /// - `bitkit://payment-request?requestId=xxx&from=yyy`
    ///
    /// - Parameter url: The URL to validate.
    /// - Returns: Validation result with extracted parameters or reason for failure.
    public static func validate(_ url: URL) -> ValidationResult {
        // Check scheme
        guard let scheme = url.scheme?.lowercased(),
              allowedSchemes.contains(scheme) else {
            return .invalid(reason: "Invalid URL scheme")
        }
        
        // For bitkit:// scheme, host must be "payment-request"
        if scheme == "bitkit" {
            guard url.host?.lowercased() == bitkitPaymentHost else {
                return .invalid(reason: "Invalid payment request host")
            }
        }
        
        // Parse query parameters
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return .invalid(reason: "Cannot parse URL components")
        }
        
        // Extract required parameters
        let requestId = queryItems.first(where: { $0.name == "requestId" })?.value?.trimmingCharacters(in: .whitespaces)
        let fromPubkey = queryItems.first(where: { $0.name == "from" })?.value?.trimmingCharacters(in: .whitespaces)
        
        // Validate requestId
        guard let requestId, !requestId.isEmpty else {
            return .invalid(reason: "Missing or empty requestId parameter")
        }
        
        if requestId.count > maxRequestIdLength {
            return .invalid(reason: "requestId exceeds maximum length")
        }
        
        // Basic format check - requestId should be alphanumeric with dashes/underscores
        let requestIdPattern = "^[a-zA-Z0-9_-]+$"
        guard requestId.range(of: requestIdPattern, options: .regularExpression) != nil else {
            return .invalid(reason: "requestId contains invalid characters")
        }
        
        // Validate fromPubkey
        guard let fromPubkey, !fromPubkey.isEmpty else {
            return .invalid(reason: "Missing or empty from parameter")
        }
        
        if fromPubkey.count > maxPubkeyLength {
            return .invalid(reason: "from parameter exceeds maximum length")
        }
        
        // Basic format check - pubkey should be alphanumeric (z-base32)
        let pubkeyPattern = "^[a-zA-Z0-9]+$"
        guard fromPubkey.range(of: pubkeyPattern, options: .regularExpression) != nil else {
            return .invalid(reason: "from parameter contains invalid characters")
        }
        
        return .valid(requestId: requestId, fromPubkey: fromPubkey)
    }
    
    /// Check if a URL is a valid Paykit payment request deep link.
    ///
    /// - Parameter url: The URL to check.
    /// - Returns: True if valid, false otherwise.
    public static func isValidPaykitDeepLink(_ url: URL) -> Bool {
        if case .valid = validate(url) {
            return true
        }
        return false
    }
    
    /// Check if a URL has a Paykit scheme (paykit:// or bitkit://payment-request)
    ///
    /// - Parameter url: The URL to check.
    /// - Returns: True if this is a Paykit URL, false otherwise.
    public static func isPaykitURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        
        if scheme == "paykit" {
            return true
        }
        
        if scheme == "bitkit" && url.host?.lowercased() == bitkitPaymentHost {
            return true
        }
        
        return false
    }
}

