//
//  HomeserverResolver.swift
//  Bitkit
//
//  Centralized pubkey-to-URL resolution for Pubky homeservers.
//  Mirrors the Android implementation for cross-platform parity.
//

import Foundation

// MARK: - HomeserverResolver

/// Centralized resolver for converting homeserver pubkeys to URLs.
/// Provides caching, known mappings, and override support for testing.
public final class HomeserverResolver {
    
    // MARK: - Singleton
    
    public static let shared = HomeserverResolver()
    
    // MARK: - Properties
    
    /// Override URL for testing/development - when set, all resolutions return this URL
    public var overrideURL: HomeserverURL?
    
    /// Cache of resolved URLs with expiry timestamps
    private var cache: [HomeserverPubkey: (url: HomeserverURL, expiresAt: Date)] = [:]
    
    /// Known homeserver mappings (pubkey -> URL)
    private var knownHomeservers: [String: String] = [:]
    
    /// Cache TTL in seconds
    private let cacheTTL: TimeInterval = 3600 // 1 hour
    
    /// Lock for thread-safe access
    private let lock = NSLock()
    
    // MARK: - Initialization
    
    private init() {
        loadDefaultMappings()
    }
    
    // MARK: - Default Mappings
    
    /// Load default homeserver mappings
    private func loadDefaultMappings() {
        // Production homeserver (Synonym mainnet)
        knownHomeservers[HomeserverDefaults.productionPubkey.value] = HomeserverDefaults.productionURL.value
        
        // Staging homeserver (Synonym staging)
        knownHomeservers[HomeserverDefaults.stagingPubkey.value] = HomeserverDefaults.stagingURL.value
    }
    
    // MARK: - Public API
    
    /// Add a custom homeserver mapping
    /// - Parameters:
    ///   - pubkey: The homeserver's pubkey
    ///   - url: The homeserver's URL
    public func addMapping(pubkey: HomeserverPubkey, url: HomeserverURL) {
        lock.lock()
        defer { lock.unlock() }
        
        knownHomeservers[pubkey.value] = url.value
        cache.removeValue(forKey: pubkey)
    }
    
    /// Remove a custom homeserver mapping
    /// - Parameter pubkey: The homeserver's pubkey to remove
    public func removeMapping(pubkey: HomeserverPubkey) {
        lock.lock()
        defer { lock.unlock() }
        
        knownHomeservers.removeValue(forKey: pubkey.value)
        cache.removeValue(forKey: pubkey)
    }
    
    /// Clear all cached resolutions
    public func clearCache() {
        lock.lock()
        defer { lock.unlock() }
        
        cache.removeAll()
    }
    
    /// Resolve a homeserver pubkey to its URL.
    ///
    /// Resolution order:
    /// 1. Check override (for testing)
    /// 2. Check cache (if not expired)
    /// 3. Check known mappings
    /// 4. Fall back to production URL
    ///
    /// - Parameter pubkey: The homeserver's pubkey
    /// - Returns: The resolved URL
    public func resolve(pubkey: HomeserverPubkey) -> HomeserverURL {
        // 1. Check for override (testing/development)
        if let override = overrideURL {
            return override
        }
        
        lock.lock()
        defer { lock.unlock() }
        
        let now = Date()
        
        // 2. Check cache
        if let cached = cache[pubkey], cached.expiresAt > now {
            return cached.url
        }
        
        // 3. Check known mappings
        if let urlString = knownHomeservers[pubkey.value] {
            let url = HomeserverURL(urlString)
            cache[pubkey] = (url: url, expiresAt: now.addingTimeInterval(cacheTTL))
            return url
        }
        
        // 4. Fall back to production URL
        // Future: Implement DNS-based resolution via _pubky.<pubkey>
        let defaultURL = HomeserverDefaults.productionURL
        cache[pubkey] = (url: defaultURL, expiresAt: now.addingTimeInterval(cacheTTL))
        return defaultURL
    }
    
    /// Resolve a homeserver pubkey string to its URL string.
    /// Convenience method that accepts and returns raw strings.
    ///
    /// - Parameter pubkeyString: The homeserver's pubkey as a string
    /// - Returns: The resolved URL as a string
    public func resolve(pubkeyString: String) -> String {
        return resolve(pubkey: HomeserverPubkey(pubkeyString)).value
    }
    
    /// Construct a full URL for accessing a user's data on a homeserver.
    ///
    /// - Parameters:
    ///   - owner: The owner's pubkey
    ///   - path: The path within their storage
    ///   - homeserver: Optional specific homeserver (defaults to owner's homeserver via production)
    /// - Returns: Full URL string for the resource
    public func urlFor(owner: OwnerPubkey, path: String, homeserver: HomeserverPubkey? = nil) -> String {
        let resolvedURL = resolve(pubkey: homeserver ?? HomeserverDefaults.defaultPubkey)
        // Unauthenticated reads use /pubky<ownerPubkey><path> format
        return "\(resolvedURL.value)/pubky\(owner.value)\(path)"
    }
    
    /// Construct a full URL for authenticated writes.
    ///
    /// - Parameters:
    ///   - path: The path for the write operation
    ///   - homeserver: Optional specific homeserver (defaults to production)
    /// - Returns: Full URL string for the authenticated write
    public func urlForAuthenticatedPath(_ path: String, homeserver: HomeserverPubkey? = nil) -> String {
        let resolvedURL = resolve(pubkey: homeserver ?? HomeserverDefaults.defaultPubkey)
        return "\(resolvedURL.value)\(path)"
    }
    
    // MARK: - Async DNS Resolution
    
    /// Resolve a homeserver pubkey with DNS lookup fallback.
    ///
    /// This async version tries DNS TXT record lookup at _pubky.{pubkey}
    /// before falling back to the default homeserver.
    ///
    /// - Parameter pubkey: The homeserver's pubkey
    /// - Returns: The resolved URL
    public func resolveWithDNS(pubkey: HomeserverPubkey) async -> HomeserverURL {
        // 1. Check for override (testing/development)
        if let override = overrideURL {
            return override
        }
        
        let now = Date()
        
        // 2. Check cache
        lock.lock()
        if let cached = cache[pubkey], cached.expiresAt > now {
            lock.unlock()
            return cached.url
        }
        
        // 3. Check known mappings
        if let urlString = knownHomeservers[pubkey.value] {
            let url = HomeserverURL(urlString)
            cache[pubkey] = (url: url, expiresAt: now.addingTimeInterval(cacheTTL))
            lock.unlock()
            return url
        }
        lock.unlock()
        
        // 4. Try DNS-based resolution
        if let dnsResolved = await resolveViaDNS(pubkey: pubkey.value) {
            lock.lock()
            cache[pubkey] = (url: dnsResolved, expiresAt: now.addingTimeInterval(cacheTTL))
            lock.unlock()
            return dnsResolved
        }
        
        // 5. Fall back to production URL
        let defaultURL = HomeserverDefaults.productionURL
        lock.lock()
        cache[pubkey] = (url: defaultURL, expiresAt: now.addingTimeInterval(cacheTTL))
        lock.unlock()
        return defaultURL
    }
    
    /// Resolve homeserver via DNS TXT record at _pubky.{pubkey}
    ///
    /// Uses CFHost for DNS queries. Returns nil if DNS lookup fails.
    private func resolveViaDNS(pubkey: String) async -> HomeserverURL? {
        let dnsName = "_pubky.\(pubkey)"
        
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                // Use CFHost for DNS queries
                guard let hostRef = CFHostCreateWithName(nil, dnsName as CFString).takeRetainedValue() as CFHost? else {
                    continuation.resume(returning: nil)
                    return
                }
                
                var resolved = DarwinBoolean(false)
                CFHostStartInfoResolution(hostRef, .addresses, nil)
                
                // Try to get TXT records (requires custom implementation or fallback)
                // For now, this is a placeholder that returns nil
                // Full DNS TXT implementation requires lower-level APIs
                continuation.resume(returning: nil)
            }
        }
    }
}

