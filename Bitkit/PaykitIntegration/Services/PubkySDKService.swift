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
    
    /// Current homeserver URL
    public private(set) var homeserver: String = PubkyConfig.defaultHomeserver
    
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
    
    /// Configure the service with a homeserver
    public func configure(homeserver: String? = nil) {
        self.homeserver = homeserver ?? PubkyConfig.defaultHomeserver
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
    
    // MARK: - Profile Operations
    
    /// Fetch a user's profile from their homeserver
    public func fetchProfile(pubkey: String, app: String = "pubky.app") async throws -> SDKProfile {
        // Check cache first
        if let cached = profileCache[pubkey], !cached.isExpired(ttl: profileCacheTTL) {
            Logger.debug("Profile cache hit for \(pubkey.prefix(12))...", context: "PubkySDKService")
            return cached.profile
        }
        
        let profilePath = "/pub/\(app)/profile.json"
        let pubkyStorage = PubkyStorageAdapter.shared
        let adapter = PubkyUnauthenticatedStorageAdapter(homeserverBaseURL: homeserver)
        let transport = UnauthenticatedTransportFfi.fromCallback(callback: adapter)
        
        guard let data = try await pubkyStorage.readFile(path: profilePath, adapter: transport, ownerPubkey: pubkey) else {
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
