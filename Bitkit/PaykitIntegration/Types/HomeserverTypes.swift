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
    
    /// Cache of resolved URLs with expiry
    private var cache: [HomeserverPubkey: (url: HomeserverURL, expires: Date)] = [:]
    
    /// Known homeserver mappings (pubkey → URL)
    private var knownHomeservers: [String: String] = [:]
    
    private init() {
        loadDefaultMappings()
    }
    
    /// Load default homeserver mappings
    private func loadDefaultMappings() {
        // Production homeserver (Synonym mainnet)
        knownHomeservers["8um71us3fyw6h8wbcxb5ar3rwusy1a6u49956ikzojg3gcwd1dty"] = "https://homeserver.pubky.app"
        
        // Staging homeserver (Synonym staging)  
        knownHomeservers["ufibwbmed6jeq9k4p583go95wofakh9fwpp4k734trq79pd9u1uy"] = "https://staging.homeserver.pubky.app"
        
        // Add more known homeservers here as needed
    }
    
    /// Add a custom homeserver mapping
    public func addMapping(pubkey: HomeserverPubkey, url: HomeserverURL) {
        knownHomeservers[pubkey.value] = url.value
        // Invalidate cache for this pubkey
        cache.removeValue(forKey: pubkey)
    }
    
    /// Resolve a homeserver pubkey to its URL.
    ///
    /// Resolution order:
    /// 1. Check override (for testing)
    /// 2. Check cache
    /// 3. Check known mappings
    /// 4. Fall back to default
    ///
    /// - Parameter pubkey: The homeserver's pubkey
    /// - Returns: The resolved URL
    public func resolve(pubkey: HomeserverPubkey) -> HomeserverURL {
        // 1. Check for override (testing/development)
        if let override = overrideURL {
            return override
        }
        
        // 2. Check cache
        if let cached = cache[pubkey], cached.expires > Date() {
            return cached.url
        }
        
        // 3. Check known mappings
        if let urlString = knownHomeservers[pubkey.value] {
            let url = HomeserverURL(urlString)
            // Cache for 1 hour
            cache[pubkey] = (url, Date().addingTimeInterval(3600))
            return url
        }
        
        // 4. Fall back to default
        // TODO: Implement DNS-based resolution via _pubky.<pubkey>
        let defaultURL = PubkyConfig.defaultHomeserverURL
        cache[pubkey] = (defaultURL, Date().addingTimeInterval(3600))
        return defaultURL
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
    
    /// Clear the resolution cache
    public func clearCache() {
        cache.removeAll()
    }
}

