//
//  HomeserverTypes.swift
//  Bitkit
//
//  Type-safe wrappers for Pubky homeserver identifiers.
//  Prevents confusion between pubkeys and URLs.
//

import Foundation

// MARK: - HomeserverPubkey

/// Type-safe wrapper for a homeserver's z32 public key
public struct HomeserverPubkey: Equatable, Hashable, Codable {
    /// The raw z32 pubkey value (without pk: prefix)
    public let value: String
    
    public init(_ value: String) {
        // Strip pk: prefix if present
        if value.hasPrefix("pk:") {
            self.value = String(value.dropFirst(3))
        } else {
            self.value = value
        }
    }
    
    /// The pubkey with pk: prefix
    public var withPrefix: String {
        return "pk:\(value)"
    }
    
    /// Validate that this looks like a valid z32 pubkey (52 chars, lowercase alphanumeric)
    public var isValid: Bool {
        value.count == 52 && value.allSatisfy { $0.isLetter || $0.isNumber }
    }
}

extension HomeserverPubkey: CustomStringConvertible {
    public var description: String {
        return value
    }
}

// MARK: - HomeserverURL

/// Type-safe wrapper for a homeserver's HTTPS URL
public struct HomeserverURL: Equatable, Hashable, Codable {
    /// The raw URL string (must be HTTPS)
    public let value: String
    
    public init(_ value: String) {
        self.value = value
    }
    
    /// Validate that this is a valid HTTPS URL
    public var isValid: Bool {
        guard let url = URL(string: value) else { return false }
        return url.scheme == "https" && url.host != nil
    }
    
    /// Construct a full URL for accessing a user's data on this homeserver
    /// - Parameters:
    ///   - owner: The owner's pubkey
    ///   - path: The path within their storage (should start with /)
    /// - Returns: Full URL for the resource, or nil if construction fails
    public func urlForPath(owner: OwnerPubkey, path: String) -> URL? {
        // Unauthenticated reads use /pubky<ownerPubkey><path> format
        let urlString = "\(value)/pubky\(owner.value)\(path)"
        return URL(string: urlString)
    }
    
    /// Construct a URL for authenticated writes (no pubky prefix needed)
    /// - Parameter path: The path for the write operation
    /// - Returns: Full URL for the authenticated write
    public func urlForAuthenticatedPath(_ path: String) -> URL? {
        let urlString = "\(value)\(path)"
        return URL(string: urlString)
    }
}

extension HomeserverURL: CustomStringConvertible {
    public var description: String {
        return value
    }
}

// MARK: - OwnerPubkey

/// Type-safe wrapper for an owner's z32 public key
public struct OwnerPubkey: Equatable, Hashable, Codable {
    /// The raw z32 pubkey value (without pk: prefix)
    public let value: String
    
    public init(_ value: String) {
        // Strip pk: prefix if present
        if value.hasPrefix("pk:") {
            self.value = String(value.dropFirst(3))
        } else {
            self.value = value
        }
    }
    
    /// The pubkey with pk: prefix
    public var withPrefix: String {
        return "pk:\(value)"
    }
    
    /// Validate that this looks like a valid z32 pubkey
    public var isValid: Bool {
        value.count == 52 && value.allSatisfy { $0.isLetter || $0.isNumber }
    }
}

extension OwnerPubkey: CustomStringConvertible {
    public var description: String {
        return value
    }
}

// MARK: - SessionSecret

/// Type-safe wrapper for a session secret that redacts when printed
public struct SessionSecret: Equatable, Codable {
    /// The raw hex value of the session secret
    public let hexValue: String
    
    public init(_ hexValue: String) {
        self.hexValue = hexValue
    }
    
    /// Convert to raw bytes if valid hex
    public var bytes: Data? {
        guard hexValue.count % 2 == 0 else { return nil }
        var data = Data()
        var index = hexValue.startIndex
        while index < hexValue.endIndex {
            let nextIndex = hexValue.index(index, offsetBy: 2)
            guard let byte = UInt8(hexValue[index..<nextIndex], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }
        return data
    }
}

extension SessionSecret: CustomStringConvertible {
    /// Always redacts the actual value for security
    public var description: String {
        return "SessionSecret(***)"
    }
}

extension SessionSecret: CustomDebugStringConvertible {
    /// Always redacts the actual value for security
    public var debugDescription: String {
        return "SessionSecret(***)"
    }
}

// MARK: - Known Homeserver Defaults

/// Default homeserver pubkeys and URLs
public enum HomeserverDefaults {
    /// Production homeserver pubkey (Synonym mainnet)
    public static let productionPubkey = HomeserverPubkey("8um71us3fyw6h8wbcxb5ar3rwusy1a6u49956ikzojg3gcwd1dty")
    
    /// Staging homeserver pubkey (Synonym staging)
    public static let stagingPubkey = HomeserverPubkey("ufibwbmed6jeq9k4p583go95wofakh9fwpp4k734trq79pd9u1uy")
    
    /// Production homeserver URL
    public static let productionURL = HomeserverURL("https://homeserver.pubky.app")
    
    /// Staging homeserver URL
    public static let stagingURL = HomeserverURL("https://staging.homeserver.pubky.app")
    
    /// Default pubkey to use
    public static let defaultPubkey = productionPubkey
    
    /// Default URL to use
    public static let defaultURL = productionURL
}

