//
//  PubkySDKService.swift
//  Bitkit
//
//  Service for Pubky homeserver operations using Paykit transport infrastructure.
//  Provides profile/follows fetching and session management.
//

import Foundation

// MARK: - PubkySDKService

/// Service for Pubky homeserver operations using Paykit transport infrastructure.
/// Uses PubkyStorageAdapter for actual storage operations.
public final class PubkySDKService {
    
    // MARK: - Singleton
    
    public static let shared = PubkySDKService()
    
    // MARK: - Properties
    
    private let keychainStorage = PaykitKeychainStorage.shared
    private var legacySessionCache: [String: LegacyPubkySession] = [:]
    private let lock = NSLock()
    
    // MARK: - Configuration
    
    /// Current homeserver URL (resolved from pubkey to actual URL)
    public private(set) var homeserver: String = PubkyConfig.homeserverBaseURL()
    
    /// Profile cache to avoid repeated fetches
    private var profileCache: [String: CachedProfile] = [:]
    private let profileCacheTTL: TimeInterval = 300 // 5 minutes
    
    /// Follows cache
    private var followsCache: [String: CachedFollows] = [:]
    private let followsCacheTTL: TimeInterval = 300 // 5 minutes
    
    // MARK: - Initialization
    
    private init() {
        Logger.info("PubkySDKService initialized", context: "PubkySDKService")
    }
    
    // MARK: - Public API
    
    /// Configure the service with a homeserver base URL
    public func configure(homeserver: String? = nil) {
        self.homeserver = homeserver ?? PubkyConfig.homeserverBaseURL()
        Logger.info("PubkySDKService configured with homeserver: \(self.homeserver)", context: "PubkySDKService")
    }
    
    /// Set a session from Pubky-ring callback
    public func setSession(_ session: LegacyPubkySession) {
        lock.lock()
        defer { lock.unlock() }
        
        legacySessionCache[session.pubkey] = session
        persistSession(session)
        
        Logger.info("Session set for pubkey: \(session.pubkey.prefix(12))...", context: "PubkySDKService")
    }
    
    /// Get cached session for a pubkey
    public func getSession(for pubkey: String) -> LegacyPubkySession? {
        lock.lock()
        defer { lock.unlock() }
        return legacySessionCache[pubkey]
    }
    
    /// Check if we have an active session
    public var hasActiveSession: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !legacySessionCache.isEmpty
    }
    
    /// Get the current active session (first available)
    public var activeSession: LegacyPubkySession? {
        lock.lock()
        defer { lock.unlock() }
        return legacySessionCache.values.first
    }
    
    // MARK: - Cache Management
    
    /// Invalidate the cached profile for a specific pubkey
    public func invalidateProfileCache(for pubkey: String) {
        profileCache.removeValue(forKey: pubkey)
        Logger.debug("Invalidated profile cache for \(pubkey.prefix(12))...", context: "PubkySDKService")
    }
    
    // MARK: - Profile Operations
    
    /// Fetch a user's profile from their homeserver
    public func fetchProfile(pubkey: String, app: String = "pubky.app", forceRefresh: Bool = false) async throws -> SDKProfile {
        // Check cache first (skip if force refresh)
        if !forceRefresh, let cached = profileCache[pubkey], !cached.isExpired(ttl: profileCacheTTL) {
            Logger.debug("Profile cache hit for \(pubkey.prefix(12))...", context: "PubkySDKService")
            return cached.profile
        }
        
        let profilePath = "/pub/\(app)/profile.json"
        let pubkyStorage = PubkyStorageAdapter.shared
        let adapter = PubkyUnauthenticatedStorageAdapter(homeserverBaseURL: homeserver)
        
        guard let data = try await pubkyStorage.readFile(path: profilePath, adapter: adapter, ownerPubkey: pubkey) else {
            throw PubkySDKError.notFound
        }
        
        let profile = try JSONDecoder().decode(SDKProfile.self, from: data)
        
        // Cache the result
        profileCache[pubkey] = CachedProfile(profile: profile, fetchedAt: Date())
        
        Logger.info("Fetched profile for \(pubkey.prefix(12))...: \(profile.name ?? "unnamed")", context: "PubkySDKService")
        return profile
    }
    
    /// Fetch a user's follows list from their homeserver
    public func fetchFollows(pubkey: String, app: String = "pubky.app") async throws -> [String] {
        // Check cache first
        if let cached = followsCache[pubkey], !cached.isExpired(ttl: followsCacheTTL) {
            Logger.debug("Follows cache hit for \(pubkey.prefix(12))...", context: "PubkySDKService")
            return cached.follows
        }
        
        let followsPath = "/pub/\(app)/follows/"
        let pubkyStorage = PubkyStorageAdapter.shared
        let adapter = PubkyUnauthenticatedStorageAdapter(homeserverBaseURL: homeserver)
        
        let follows = try await pubkyStorage.listDirectory(path: followsPath, adapter: adapter, ownerPubkey: pubkey)
        
        // Cache the result
        followsCache[pubkey] = CachedFollows(follows: follows, fetchedAt: Date())
        
        Logger.info("Fetched \(follows.count) follows for \(pubkey.prefix(12))...", context: "PubkySDKService")
        return follows
    }
    
    // MARK: - Session Persistence
    
    /// Restore sessions from keychain
    public func restoreSessions() {
        let keys = keychainStorage.listKeys(withPrefix: "pubky.session.")
        
        for key in keys {
            do {
                guard let data = keychainStorage.get(key: key) else { continue }
                let session = try JSONDecoder().decode(LegacyPubkySession.self, from: data)
                
                // Check if session is expired
                if let expiresAt = session.expiresAt, expiresAt < Date() {
                    Logger.info("Session expired for \(session.pubkey.prefix(12))..., removing", context: "PubkySDKService")
                    keychainStorage.deleteQuietly(key: key)
                    continue
                }
                
                legacySessionCache[session.pubkey] = session
                Logger.info("Restored session for \(session.pubkey.prefix(12))...", context: "PubkySDKService")
            } catch {
                Logger.error("Failed to restore session from \(key): \(error)", context: "PubkySDKService")
            }
        }
        
        Logger.info("Restored \(legacySessionCache.count) sessions from keychain", context: "PubkySDKService")
    }
    
    /// Clear all sessions
    public func clearAllSessions() {
        let keys = keychainStorage.listKeys(withPrefix: "pubky.session.")
        for key in keys {
            keychainStorage.deleteQuietly(key: key)
        }
        legacySessionCache.removeAll()
        
        Logger.info("Cleared all sessions", context: "PubkySDKService")
    }
    
    /// Sign out a specific pubkey
    public func signout(pubkey: String) {
        keychainStorage.deleteQuietly(key: "pubky.session.\(pubkey)")
        lock.lock()
        legacySessionCache.removeValue(forKey: pubkey)
        lock.unlock()
        
        Logger.info("Signed out \(pubkey.prefix(12))... (local cache only)", context: "PubkySDKService")
    }
    
    /// Clear caches
    public func clearCaches() {
        profileCache.removeAll()
        followsCache.removeAll()
        Logger.debug("Cleared profile and follows caches", context: "PubkySDKService")
    }
    
    // MARK: - Generic Data Access
    
    /// Fetch raw data from a Pubky URI.
    ///
    /// - Parameter uri: Full Pubky URI (e.g., "pubky://pubkey/path/to/file")
    /// - Returns: Raw data if found, nil otherwise
    public func getData(_ uri: String) async throws -> Data? {
        // Parse URI: pubky://{pubkey}/{path}
        guard uri.hasPrefix("pubky://") else {
            throw PubkySDKError.invalidInput("Invalid Pubky URI: \(uri)")
        }
        
        let withoutScheme = String(uri.dropFirst(8)) // Remove "pubky://"
        guard let firstSlash = withoutScheme.firstIndex(of: "/") else {
            throw PubkySDKError.invalidInput("Invalid Pubky URI format: \(uri)")
        }
        
        let pubkey = String(withoutScheme[..<firstSlash])
        let path = String(withoutScheme[firstSlash...])
        
        let pubkyStorage = PubkyStorageAdapter.shared
        let adapter = PubkyUnauthenticatedStorageAdapter(homeserverBaseURL: homeserver)
        
        return try await pubkyStorage.readFile(path: path, adapter: adapter, ownerPubkey: pubkey)
    }
    
    // MARK: - Session Refresh
    
    /// Refresh a single session by pubkey.
    ///
    /// Note: This requires the session to still be valid or have a refresh mechanism.
    /// In practice, Pubky-ring handles session management, so this is mostly a placeholder.
    public func refreshSession(pubkey: String) async throws {
        guard let session = getSession(for: pubkey) else {
            throw PubkySDKError.noSession
        }
        
        // Check if session has expiration
        if let expiresAt = session.expiresAt, expiresAt > Date() {
            // Session still valid, nothing to do
            Logger.debug("Session for \(pubkey.prefix(12))... still valid until \(expiresAt)", context: "PubkySDKService")
            return
        }
        
        // Session expired or expiring - we'd need to re-authenticate via Pubky-ring
        // For now, just log this. In production, you'd trigger a re-auth flow.
        Logger.warn("Session for \(pubkey.prefix(12))... needs refresh - user action required", context: "PubkySDKService")
    }
    
    /// Refresh all sessions that are expiring soon.
    ///
    /// - Parameter bufferSeconds: Refresh sessions expiring within this many seconds (default 600 = 10 minutes)
    public func refreshExpiringSessions(bufferSeconds: TimeInterval = 600) async throws {
        let now = Date()
        let threshold = now.addingTimeInterval(bufferSeconds)
        
        lock.lock()
        let expiringSessions = legacySessionCache.values.filter { session in
            guard let expiresAt = session.expiresAt else { return false }
            return expiresAt < threshold
        }
        lock.unlock()
        
        for session in expiringSessions {
            do {
                try await refreshSession(pubkey: session.pubkey)
            } catch {
                Logger.error("Failed to refresh session for \(session.pubkey.prefix(12))...: \(error)", context: "PubkySDKService")
            }
        }
        
        Logger.info("Checked \(expiringSessions.count) expiring sessions", context: "PubkySDKService")
    }
    
    // MARK: - Private Helpers
    
    private func persistSession(_ session: LegacyPubkySession) {
        do {
            let data = try JSONEncoder().encode(session)
            keychainStorage.set(key: "pubky.session.\(session.pubkey)", value: data)
            Logger.debug("Persisted session for \(session.pubkey.prefix(12))...", context: "PubkySDKService")
        } catch {
            Logger.error("Failed to persist session: \(error)", context: "PubkySDKService")
        }
    }
}

// MARK: - Supporting Types

/// Profile data from Pubky homeserver
public struct SDKProfile: Codable {
    public let name: String?
    public let bio: String?
    public let image: String?
    public let links: [SDKProfileLink]?
    
    public init(name: String? = nil, bio: String? = nil, image: String? = nil, links: [SDKProfileLink]? = nil) {
        self.name = name
        self.bio = bio
        self.image = image
        self.links = links
    }
}

/// Profile link
public struct SDKProfileLink: Codable {
    public let title: String
    public let url: String
    
    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

/// Legacy session for compatibility
public struct LegacyPubkySession: Codable {
    public let pubkey: String
    public let sessionSecret: String
    public let capabilities: [String]
    public let expiresAt: Date?
    
    public init(pubkey: String, sessionSecret: String, capabilities: [String], expiresAt: Date? = nil) {
        self.pubkey = pubkey
        self.sessionSecret = sessionSecret
        self.capabilities = capabilities
        self.expiresAt = expiresAt
    }
}

/// Cached profile
struct CachedProfile {
    let profile: SDKProfile
    let fetchedAt: Date
    
    func isExpired(ttl: TimeInterval) -> Bool {
        Date().timeIntervalSince(fetchedAt) > ttl
    }
}

/// Cached follows
struct CachedFollows {
    let follows: [String]
    let fetchedAt: Date
    
    func isExpired(ttl: TimeInterval) -> Bool {
        Date().timeIntervalSince(fetchedAt) > ttl
    }
}

// MARK: - PubkySDKError

public enum PubkySDKError: Error, LocalizedError {
    case notConfigured
    case notFound
    case noSession
    case invalidInput(String)
    case networkError(String)
    
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "PubkySDKService is not configured"
        case .notFound:
            return "Resource not found"
        case .noSession:
            return "No active session - authenticate with Pubky-ring first"
        case .invalidInput(let message):
            return "Invalid input: \(message)"
        case .networkError(let message):
            return "Network error: \(message)"
        }
    }
}
