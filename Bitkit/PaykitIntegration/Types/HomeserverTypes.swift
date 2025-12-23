//
//  HomeserverTypes.swift
//  Bitkit
//
//  Type-safe wrappers for homeserver-related identifiers.
//  Prevents accidental confusion between pubkeys, URLs, and session secrets.
//

import Foundation

// MARK: - HomeserverPubkey

/// A z32-encoded Ed25519 public key identifying a homeserver.
///
/// This is the pubkey of the homeserver operator, NOT a URL.
/// Used for:
/// - Identifying which homeserver a user is registered with
/// - Constructing storage paths
/// - Authenticating homeserver responses
///
/// Example: `pk:8pinxxgqs41n4aididenw5apqp1urfmzdztr8jt4abrkdn435ewo`
public struct HomeserverPubkey: Hashable, Codable, CustomStringConvertible {
    
    /// The raw z32-encoded pubkey string
    public let value: String
    
    /// Create from a z32-encoded pubkey string
    /// - Parameter value: The z32 pubkey (with or without `pk:` prefix)
    public init(_ value: String) {
        // Normalize: remove pk: prefix if present
        if value.hasPrefix("pk:") {
            self.value = String(value.dropFirst(3))
        } else {
            self.value = value
        }
    }
    
    /// Validate the pubkey format
    public var isValid: Bool {
        // z32 pubkeys are 52 characters (256 bits / 5 bits per char)
        value.count == 52 && value.allSatisfy { c in
            "ybndrfg8ejkmcpqxot1uwisza345h769".contains(c)
        }
    }
    
    /// Returns the pubkey with pk: prefix
    public var withPrefix: String {
        "pk:\(value)"
    }
    
    public var description: String {
        "HomeserverPubkey(\(value.prefix(12))...)"
    }
}

// MARK: - HomeserverURL

/// A resolved HTTPS URL for a homeserver's API endpoint.
///
/// This is the actual URL to make HTTP requests to, NOT a pubkey.
/// Resolved from a HomeserverPubkey via DNS or configuration.
///
/// Example: `https://homeserver.pubky.app`
public struct HomeserverURL: Hashable, Codable, CustomStringConvertible {
    
    /// The resolved HTTPS URL string
    public let value: String
    
    /// Create from a URL string
    /// - Parameter value: The HTTPS URL for the homeserver
    public init(_ value: String) {
        // Normalize: ensure https and no trailing slash
        var normalized = value
        if !normalized.hasPrefix("https://") && !normalized.hasPrefix("http://") {
            normalized = "https://\(normalized)"
        }
        if normalized.hasSuffix("/") {
            normalized = String(normalized.dropLast())
        }
        self.value = normalized
    }
    
    /// Validate the URL format
    public var isValid: Bool {
        URL(string: value) != nil && value.hasPrefix("https://")
    }
    
    /// Get the URL object
    public var url: URL? {
        URL(string: value)
    }
    
    /// Construct a full URL for a pubky path
    /// - Parameters:
    ///   - ownerPubkey: The owner's pubkey
    ///   - path: The path within the owner's storage
    /// - Returns: Full URL for the resource
    public func urlForPath(owner ownerPubkey: String, path: String) -> URL? {
        URL(string: "\(value)/\(ownerPubkey)\(path)")
    }
    
    public var description: String {
        "HomeserverURL(\(value))"
    }
}

// MARK: - SessionSecret

/// A session secret token for authenticated homeserver operations.
///
/// This is a sensitive credential - handle with care.
/// Never log or expose in URLs.
public struct SessionSecret: Hashable, CustomStringConvertible {
    
    /// The raw session secret bytes (hex encoded for transport)
    public let hexValue: String
    
    /// Create from hex-encoded secret
    public init(hex: String) {
        self.hexValue = hex
    }
    
    /// Validate the secret format
    public var isValid: Bool {
        // Session secrets are typically 32 bytes = 64 hex chars
        hexValue.count >= 32 && hexValue.allSatisfy { $0.isHexDigit }
    }
    
    /// Redacted description for logging
    public var description: String {
        "SessionSecret(***)"
    }
    
    /// Get the raw bytes
    public var bytes: Data? {
        guard hexValue.count % 2 == 0 else { return nil }
        var data = Data(capacity: hexValue.count / 2)
        var index = hexValue.startIndex
        while index < hexValue.endIndex {
            let nextIndex = hexValue.index(index, offsetBy: 2)
            if let byte = UInt8(hexValue[index..<nextIndex], radix: 16) {
                data.append(byte)
            } else {
                return nil
            }
            index = nextIndex
        }
        return data
    }
}

// MARK: - OwnerPubkey

/// A z32-encoded Ed25519 public key identifying a user/owner.
///
/// This is the user's public identity key.
/// Used for:
/// - Identifying the owner of storage paths
/// - Payment addressing
/// - Directory discovery
public struct OwnerPubkey: Hashable, Codable, CustomStringConvertible {
    
    /// The raw z32-encoded pubkey string
    public let value: String
    
    public init(_ value: String) {
        // Normalize: remove pk: prefix if present
        if value.hasPrefix("pk:") {
            self.value = String(value.dropFirst(3))
        } else {
            self.value = value
        }
    }
    
    /// Validate the pubkey format
    public var isValid: Bool {
        value.count == 52 && value.allSatisfy { c in
            "ybndrfg8ejkmcpqxot1uwisza345h769".contains(c)
        }
    }
    
    /// Returns the pubkey with pk: prefix
    public var withPrefix: String {
        "pk:\(value)"
    }
    
    public var description: String {
        "OwnerPubkey(\(value.prefix(12))...)"
    }
}

// MARK: - PubkyConfig Extension

extension PubkyConfig {
    
    /// The default homeserver URL (resolved from pubkey)
    public static var defaultHomeserverURL: HomeserverURL {
        HomeserverURL("https://homeserver.pubky.app")
    }
    
    /// The default homeserver pubkey
    public static var defaultHomeserverPubkey: HomeserverPubkey {
        HomeserverPubkey(defaultHomeserver)
    }
}

// MARK: - HomeserverResolver

/// Centralized homeserver URL resolution.
///
/// Converts pubkeys to URLs and handles configuration.
/// This prevents hardcoded URLs scattered throughout the codebase.
public final class HomeserverResolver {
    
    public static let shared = HomeserverResolver()
    
    /// Override for testing/development
    public var overrideURL: HomeserverURL?
    
    private init() {}
    
    /// Resolve a homeserver pubkey to its URL.
    ///
    /// In production, this would perform DNS-based discovery.
    /// For now, it uses the default homeserver URL.
    ///
    /// - Parameter pubkey: The homeserver's pubkey
    /// - Returns: The resolved URL
    public func resolve(pubkey: HomeserverPubkey) -> HomeserverURL {
        // Check for override (testing/development)
        if let override = overrideURL {
            return override
        }
        
        // TODO: Implement DNS-based resolution
        // For now, all pubkeys resolve to the default homeserver
        return PubkyConfig.defaultHomeserverURL
    }
    
    /// Construct a full URL for accessing a user's data on a homeserver.
    ///
    /// - Parameters:
    ///   - owner: The owner's pubkey
    ///   - path: The path within their storage
    ///   - homeserver: Optional specific homeserver (defaults to owner's homeserver)
    /// - Returns: Full URL for the resource
    public func urlFor(owner: OwnerPubkey, path: String, homeserver: HomeserverPubkey? = nil) -> URL? {
        let resolvedURL = resolve(pubkey: homeserver ?? PubkyConfig.defaultHomeserverPubkey)
        return resolvedURL.urlForPath(owner: owner.value, path: path)
    }
    
    /// The base URL for authenticated operations.
    ///
    /// - Parameter session: The authenticated session
    /// - Returns: Base URL for the session's homeserver
    public func baseURLForSession(_ session: PubkySession) -> HomeserverURL {
        // For now, all sessions use the default homeserver
        // In production, this would be stored with the session
        return PubkyConfig.defaultHomeserverURL
    }
}

