//
//  DirectoryService.swift
//  Bitkit
//
//  Directory Service for Noise Endpoint Discovery
//  Uses PaykitClient FFI methods for directory operations
//

import Foundation
// PaykitMobile types are available from FFI/PaykitMobile.swift

// MARK: - Pubky Homeserver Configuration

/// Configuration for Pubky homeserver connections
/// Uses HomeserverResolver for centralized pubkey-to-URL resolution
public struct PubkyConfig {
    /// Production homeserver pubkey (Synonym mainnet)
    public static let productionHomeserverPubkey = HomeserverDefaults.productionPubkey.value
    
    /// Staging homeserver pubkey (Synonym staging)
    public static let stagingHomeserverPubkey = HomeserverDefaults.stagingPubkey.value
    
    /// Default homeserver pubkey to use
    public static let defaultHomeserver = productionHomeserverPubkey
    
    /// Pubky app URL for production
    public static let productionAppUrl = "https://pubky.app"
    
    /// Pubky app URL for staging
    public static let stagingAppUrl = "https://staging.pubky.app"
    
    /// Get the homeserver base URL for directory operations
    /// Uses HomeserverResolver for centralized resolution with caching
    public static func homeserverBaseURL(for pubkey: String = defaultHomeserver) -> String {
        return HomeserverResolver.shared.resolve(pubkeyString: pubkey)
    }
}

/// Service for interacting with the Pubky directory
/// Uses PaykitClient FFI methods for directory operations
public final class DirectoryService {
    
    public static let shared = DirectoryService()
    
    private var paykitClient: PaykitClient?
    private var directoryOps: DirectoryOperationsAsync?
    private var unauthenticatedTransport: UnauthenticatedTransportFfi?
    private var authenticatedTransport: AuthenticatedTransportFfi?
    private var authenticatedAdapter: PubkyAuthenticatedStorageAdapter?
    private var homeserverBaseURL: String?
    
    /// Cached profile for the current user (populated by prefetchProfile)
    private var cachedProfile: PubkyProfile?
    private var cachedProfilePubkey: String?
    
    private init() {
        // Create directory operations manager
        directoryOps = try? DirectoryOperationsAsync()
    }
    
    /// Public initializer for creating a new instance
    public convenience init(paykitClient: PaykitClient? = nil) {
        self.init()
        if let client = paykitClient {
            self.paykitClient = client
        }
    }
    
    /// Initialize with PaykitClient
    public func initialize(client: PaykitClient) {
        self.paykitClient = client
    }
    
    /// Configure Pubky transport for directory operations
    /// - Parameter homeserverBaseURL: The homeserver base URL (defaults to resolved PubkyConfig URL)
    public func configurePubkyTransport(homeserverBaseURL: String? = nil) {
        self.homeserverBaseURL = homeserverBaseURL ?? PubkyConfig.homeserverBaseURL()
        let adapter = PubkyUnauthenticatedStorageAdapter(homeserverBaseURL: self.homeserverBaseURL)
        unauthenticatedTransport = UnauthenticatedTransportFfi.fromCallback(callback: adapter)
    }
    
    /// Configure authenticated transport with session
    /// - Parameters:
    ///   - sessionId: The session secret from Pubky-ring
    ///   - ownerPubkey: The owner's public key
    ///   - homeserverBaseURL: The homeserver base URL (defaults to resolved PubkyConfig URL)
    public func configureAuthenticatedTransport(sessionId: String, ownerPubkey: String, homeserverBaseURL: String? = nil) {
        self.homeserverBaseURL = homeserverBaseURL ?? PubkyConfig.homeserverBaseURL()
        
        // Store adapter for write operations
        authenticatedAdapter = PubkyAuthenticatedStorageAdapter(
            sessionSecret: sessionId,
            ownerPubkey: ownerPubkey,
            homeserverBaseURL: self.homeserverBaseURL
        )
        
        // Configure transport for FFI operations
        authenticatedTransport = AuthenticatedTransportFfi.fromCallback(
            callback: authenticatedAdapter!,
            ownerPubkey: ownerPubkey
        )
        
        // Also rebuild unauthenticated transport with new URL to prevent stale cached transport
        let unauthAdapter = PubkyUnauthenticatedStorageAdapter(homeserverBaseURL: self.homeserverBaseURL)
        unauthenticatedTransport = UnauthenticatedTransportFfi.fromCallback(callback: unauthAdapter)
    }
    
    /// Configure transport using a Pubky session from Pubky-ring
    public func configureWithPubkySession(_ session: PubkyRingSession) {
        // Clear cached profile when session changes
        clearProfileCache()
        
        // Use session's homeserver URL if provided, otherwise fall back to default
        homeserverBaseURL = session.homeserverURL ?? PubkyConfig.homeserverBaseURL()
        
        // Store authenticated adapter for write operations (uses session cookie)
        authenticatedAdapter = PubkyAuthenticatedStorageAdapter(
            sessionSecret: session.sessionSecret,
            ownerPubkey: session.pubkey,
            homeserverBaseURL: homeserverBaseURL
        )
        
        // Configure authenticated transport for FFI operations
        authenticatedTransport = AuthenticatedTransportFfi.fromCallback(
            callback: authenticatedAdapter!,
            ownerPubkey: session.pubkey
        )
        
        // Also configure unauthenticated transport for read operations
        let unauthAdapter = PubkyUnauthenticatedStorageAdapter(homeserverBaseURL: homeserverBaseURL)
        unauthenticatedTransport = UnauthenticatedTransportFfi.fromCallback(callback: unauthAdapter)
        
        Logger.info("Configured DirectoryService with Pubky session for \(session.pubkey) on \(homeserverBaseURL ?? "default")", context: "DirectoryService")
        
        // Pre-fetch profile after session is configured
        Task {
            await prefetchProfile()
        }
    }
    
    /// Discover noise endpoints for a recipient.
    ///
    /// Tries FFI-based discovery first, then falls back to direct HTTP if FFI fails.
    /// This fallback is necessary because iOS simulators may have pkarr DNS resolution issues.
    public func discoverNoiseEndpoint(for recipientPubkey: String) async throws -> NoiseEndpointInfo? {
        guard paykitClient != nil else {
            throw DirectoryError.notConfigured
        }
        
        let transport = unauthenticatedTransport ?? {
            let adapter = PubkyUnauthenticatedStorageAdapter(homeserverBaseURL: homeserverBaseURL)
            let transport = UnauthenticatedTransportFfi.fromCallback(callback: adapter)
            unauthenticatedTransport = transport
            return transport
        }()
        
        // Try FFI first
        do {
            if let result = try Bitkit.discoverNoiseEndpoint(transport: transport, recipientPubkey: recipientPubkey) {
                return result
            }
        } catch {
            Logger.debug("FFI discoverNoiseEndpoint failed for \(recipientPubkey.prefix(12))...: \(error)", context: "DirectoryService")
        }
        
        // Fallback: direct HTTP to homeserver (bypasses pkarr DNS issues in simulators)
        return await discoverNoiseEndpointViaHTTP(recipientPubkey)
    }
    
    /// HTTP fallback for discovering Noise endpoints.
    ///
    /// Directly queries the homeserver at `/pub/paykit.app/v0/noise` with the pubky-host header.
    /// This bypasses pkarr DNS resolution which may fail in iOS simulators.
    private func discoverNoiseEndpointViaHTTP(_ recipientPubkey: String) async -> NoiseEndpointInfo? {
        let effectiveHomeserverURL = homeserverBaseURL ?? PubkyConfig.homeserverBaseURL()
        let noisePath = PaykitV0Protocol.noiseEndpointPath()
        
        Logger.debug("Fetching Noise endpoint via HTTP: \(effectiveHomeserverURL)\(noisePath) for \(recipientPubkey.prefix(12))...", context: "DirectoryService")
        
        guard let url = URL(string: "\(effectiveHomeserverURL)\(noisePath)") else {
            Logger.error("Invalid URL for Noise endpoint discovery", context: "DirectoryService")
            return nil
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(recipientPubkey, forHTTPHeaderField: "pubky-host")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                Logger.error("Invalid HTTP response for Noise endpoint discovery", context: "DirectoryService")
                return nil
            }
            
            if httpResponse.statusCode == 404 {
                Logger.debug("No Noise endpoint found for \(recipientPubkey.prefix(12))... via HTTP", context: "DirectoryService")
                return nil
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                Logger.error("HTTP \(httpResponse.statusCode) for Noise endpoint discovery", context: "DirectoryService")
                return nil
            }
            
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                Logger.error("Invalid JSON for Noise endpoint", context: "DirectoryService")
                return nil
            }
            
            let host = json["host"] as? String ?? ""
            let port = json["port"] as? Int ?? 0
            let pubkey = json["pubkey"] as? String ?? ""
            let metadata = json["metadata"] as? String
            
            if pubkey.isEmpty {
                Logger.warn("Noise endpoint for \(recipientPubkey.prefix(12))... has no pubkey", context: "DirectoryService")
                return nil
            }
            
            Logger.debug("Discovered Noise endpoint for \(recipientPubkey.prefix(12))... via HTTP: \(host):\(port)", context: "DirectoryService")
            return NoiseEndpointInfo(
                recipientPubkey: recipientPubkey,
                host: host,
                port: UInt16(port),
                serverNoisePubkey: pubkey,
                metadata: metadata
            )
        } catch {
            Logger.error("Failed to discover Noise endpoint via HTTP for \(recipientPubkey.prefix(12))...: \(error)", context: "DirectoryService")
            return nil
        }
    }
    
    /// Publish our noise endpoint
    public func publishNoiseEndpoint(host: String, port: UInt16, noisePubkey: String, metadata: String? = nil) async throws {
        guard paykitClient != nil, let transport = authenticatedTransport else {
            throw DirectoryError.notConfigured
        }
        
        do {
            try Bitkit.publishNoiseEndpoint(transport: transport, host: host, port: port, noisePubkey: noisePubkey, metadata: metadata)
            Logger.info("Published Noise endpoint: \(host):\(port)", context: "DirectoryService")
        } catch {
            Logger.error("Failed to publish Noise endpoint: \(error)", context: "DirectoryService")
            throw DirectoryError.publishFailed(error.localizedDescription)
        }
    }
    
    /// Remove noise endpoint from directory
    public func removeNoiseEndpoint() async throws {
        guard paykitClient != nil, let transport = authenticatedTransport else {
            throw DirectoryError.notConfigured
        }
        
        do {
            try Bitkit.removeNoiseEndpoint(transport: transport)
            Logger.info("Removed Noise endpoint", context: "DirectoryService")
        } catch {
            Logger.error("Failed to remove Noise endpoint: \(error)", context: "DirectoryService")
            throw DirectoryError.publishFailed(error.localizedDescription)
        }
    }
    
    /// Discover payment methods for a pubkey
    public func discoverPaymentMethods(for pubkey: String) async throws -> [PaymentMethod] {
        guard paykitClient != nil, let ops = directoryOps else {
            throw DirectoryError.notConfigured
        }
        
        let transport = unauthenticatedTransport ?? {
            let adapter = PubkyUnauthenticatedStorageAdapter(homeserverBaseURL: homeserverBaseURL)
            let transport = UnauthenticatedTransportFfi.fromCallback(callback: adapter)
            unauthenticatedTransport = transport
            return transport
        }()
        
        do {
            return try ops.fetchSupportedPayments(transport: transport, ownerPubkey: pubkey)
        } catch {
            Logger.error("Failed to discover payment methods for \(pubkey): \(error)", context: "DirectoryService")
            return []
        }
    }
    
    /// Publish a payment method to the directory
    public func publishPaymentMethod(methodId: String, endpoint: String) async throws {
        guard paykitClient != nil, let transport = authenticatedTransport, let ops = directoryOps else {
            throw DirectoryError.notConfigured
        }
        
        do {
            try ops.publishPaymentEndpoint(transport: transport, methodId: methodId, endpointData: endpoint)
            Logger.info("Published payment method: \(methodId)", context: "DirectoryService")
        } catch {
            Logger.error("Failed to publish payment method \(methodId): \(error)", context: "DirectoryService")
            throw DirectoryError.publishFailed(error.localizedDescription)
        }
    }
    
    /// Remove a payment method from the directory
    public func removePaymentMethod(methodId: String) async throws {
        guard paykitClient != nil, let transport = authenticatedTransport, let ops = directoryOps else {
            throw DirectoryError.notConfigured
        }
        
        do {
            try ops.removePaymentEndpoint(transport: transport, methodId: methodId)
            Logger.info("Removed payment method: \(methodId)", context: "DirectoryService")
        } catch {
            Logger.error("Failed to remove payment method \(methodId): \(error)", context: "DirectoryService")
            throw DirectoryError.publishFailed(error.localizedDescription)
        }
    }
    
    // MARK: - Profile Operations
    
    /// Fetch profile for a pubkey from Pubky directory
    /// Uses PubkySDKService first, falls back to direct FFI if unavailable
    public func fetchProfile(for pubkey: String) async throws -> PubkyProfile? {
        // Try PubkySDKService first (preferred, direct homeserver access)
        do {
            let sdkProfile = try await PubkySDKService.shared.fetchProfile(pubkey: pubkey)
            // Convert to local PubkyProfile type
            return PubkyProfile(
                name: sdkProfile.name,
                bio: sdkProfile.bio,
                avatar: sdkProfile.image,
                links: sdkProfile.links?.map { PubkyProfileLink(title: $0.title, url: $0.url) }
            )
        } catch {
            Logger.debug("PubkySDKService profile fetch failed: \(error)", context: "DirectoryService")
        }
        
        // Try PubkyRingBridge if Pubky-ring is installed (user interaction required)
        if PubkyRingBridge.shared.isPubkyRingInstalled {
            do {
                if let profile = try await PubkyRingBridge.shared.requestProfile(pubkey: pubkey) {
                    Logger.debug("Got profile from Pubky-ring", context: "DirectoryService")
                    return profile
                }
            } catch {
                Logger.debug("PubkyRingBridge profile fetch failed: \(error)", context: "DirectoryService")
            }
        }
        
        // Fallback to direct FFI
        return try await fetchProfileViaFFI(for: pubkey)
    }
    
    /// Fetch profile using direct FFI (fallback)
    private func fetchProfileViaFFI(for pubkey: String) async throws -> PubkyProfile? {
        let storageAdapter = PubkyUnauthenticatedStorageAdapter(homeserverBaseURL: homeserverBaseURL ?? PubkyConfig.homeserverBaseURL())
        
        let profilePath = "/pub/pubky.app/profile.json"
        let pubkyStorage = PubkyStorageAdapter.shared
        
        do {
            if let data = try await pubkyStorage.readFile(path: profilePath, adapter: storageAdapter, ownerPubkey: pubkey) {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return PubkyProfile(
                        name: json["name"] as? String,
                        bio: json["bio"] as? String,
                        avatar: json["avatar"] as? String,
                        links: (json["links"] as? [[String: String]])?.compactMap { dict in
                            guard let title = dict["title"], let url = dict["url"] else { return nil }
                            return PubkyProfileLink(title: title, url: url)
                        }
                    )
                }
            }
            return nil
        } catch {
            Logger.error("Failed to fetch profile for \(pubkey): \(error)", context: "DirectoryService")
            return nil
        }
    }
    
    /// Pre-fetch and cache the current user's profile after session configuration
    public func prefetchProfile() async {
        guard let ownerPubkey = PaykitKeyManager.shared.getCurrentPublicKeyZ32() else {
            Logger.debug("Cannot prefetch profile: no current pubkey", context: "DirectoryService")
            return
        }
        
        do {
            if let profile = try await fetchProfile(for: ownerPubkey) {
                cachedProfile = profile
                cachedProfilePubkey = ownerPubkey
                Logger.info("Prefetched profile for \(ownerPubkey.prefix(12))...: \(profile.name ?? "unnamed")", context: "DirectoryService")
            }
        } catch {
            Logger.debug("Failed to prefetch profile: \(error)", context: "DirectoryService")
        }
    }
    
    /// Get profile from cache if available, otherwise fetch from network
    public func getOrFetchProfile(pubkey: String) async throws -> PubkyProfile? {
        // Return cached profile if it matches the requested pubkey
        if let cached = cachedProfile, cachedProfilePubkey == pubkey {
            Logger.debug("Returning cached profile for \(pubkey.prefix(12))...", context: "DirectoryService")
            return cached
        }
        
        // Fetch from network
        let profile = try await fetchProfile(for: pubkey)
        
        // Cache if it's for the current user
        if pubkey == PaykitKeyManager.shared.getCurrentPublicKeyZ32() {
            cachedProfile = profile
            cachedProfilePubkey = pubkey
        }
        
        return profile
    }
    
    /// Clear the cached profile (call when session changes)
    public func clearProfileCache() {
        cachedProfile = nil
        cachedProfilePubkey = nil
    }
    
    /// Publish profile to Pubky directory
    public func publishProfile(_ profile: PubkyProfile) async throws {
        guard let adapter = authenticatedAdapter else {
            throw DirectoryError.notConfigured
        }
        
        let pubkyStorage = PubkyStorageAdapter.shared
        let profilePath = "/pub/pubky.app/profile.json"
        
        var profileDict: [String: Any] = [:]
        if let name = profile.name { profileDict["name"] = name }
        if let bio = profile.bio { profileDict["bio"] = bio }
        if let avatar = profile.avatar { profileDict["avatar"] = avatar }
        if let links = profile.links {
            profileDict["links"] = links.map { ["title": $0.title, "url": $0.url] }
        }
        
        let data = try JSONSerialization.data(withJSONObject: profileDict)
        try await pubkyStorage.writeFile(path: profilePath, data: data, adapter: adapter)
        Logger.info("Published profile to Pubky directory", context: "DirectoryService")
    }
    
    // MARK: - Follows Operations
    
    /// Fetch list of pubkeys user follows
    /// Uses PubkySDKService first, falls back to direct FFI if unavailable
    public func fetchFollows() async throws -> [String] {
        guard let ownerPubkey = PaykitKeyManager.shared.getCurrentPublicKeyZ32() else {
            return []
        }
        
        // Try PubkySDKService first (preferred, direct homeserver access)
        do {
            return try await PubkySDKService.shared.fetchFollows(pubkey: ownerPubkey)
        } catch {
            Logger.debug("PubkySDKService follows fetch failed: \(error)", context: "DirectoryService")
        }
        
        // Try PubkyRingBridge if Pubky-ring is installed (user interaction required)
        if PubkyRingBridge.shared.isPubkyRingInstalled {
            do {
                let follows = try await PubkyRingBridge.shared.requestFollows()
                if !follows.isEmpty {
                    Logger.debug("Got \(follows.count) follows from Pubky-ring", context: "DirectoryService")
                    return follows
                }
            } catch {
                Logger.debug("PubkyRingBridge follows fetch failed: \(error)", context: "DirectoryService")
            }
        }
        
        // Fallback to direct FFI
        return try await fetchFollowsViaFFI(ownerPubkey: ownerPubkey)
    }
    
    /// Fetch follows using direct FFI (fallback)
    private func fetchFollowsViaFFI(ownerPubkey: String) async throws -> [String] {
        let storageAdapter = PubkyUnauthenticatedStorageAdapter(homeserverBaseURL: homeserverBaseURL ?? PubkyConfig.homeserverBaseURL())
        
        let pubkyStorage = PubkyStorageAdapter.shared
        let followsPath = "/pub/pubky.app/follows/"
        
        return try await pubkyStorage.listDirectory(path: followsPath, adapter: storageAdapter, ownerPubkey: ownerPubkey)
    }
    
    /// Add a follow to the Pubky directory
    public func addFollow(pubkey: String) async throws {
        guard let adapter = authenticatedAdapter else {
            throw DirectoryError.notConfigured
        }
        
        let pubkyStorage = PubkyStorageAdapter.shared
        let followPath = "/pub/pubky.app/follows/\(pubkey)"
        let data = "{}".data(using: .utf8)!
        
        try await pubkyStorage.writeFile(path: followPath, data: data, adapter: adapter)
        Logger.info("Added follow: \(pubkey)", context: "DirectoryService")
    }
    
    /// Remove a follow from the Pubky directory
    public func removeFollow(pubkey: String) async throws {
        guard let adapter = authenticatedAdapter else {
            throw DirectoryError.notConfigured
        }
        
        let pubkyStorage = PubkyStorageAdapter.shared
        let followPath = "/pub/pubky.app/follows/\(pubkey)"
        
        try await pubkyStorage.deleteFile(path: followPath, adapter: adapter)
        Logger.info("Removed follow: \(pubkey)", context: "DirectoryService")
    }
    
    /// Discover contacts from Pubky follows directory
    /// Fetches profiles for each followed pubkey to populate names
    public func discoverContactsFromFollows() async throws -> [DirectoryDiscoveredContact] {
        guard let ownerPubkey = PaykitKeyManager.shared.getCurrentPublicKeyZ32() else {
            return []
        }
        
        // Create unauthenticated adapter for reading follows
        let unauthAdapter = PubkyUnauthenticatedStorageAdapter(homeserverBaseURL: homeserverBaseURL)
        let pubkyStorage = PubkyStorageAdapter.shared
        
        // Fetch follows list from Pubky
        let followsPath = "/pub/pubky.app/follows/"
        let followsList = try await pubkyStorage.listDirectory(path: followsPath, adapter: unauthAdapter, ownerPubkey: ownerPubkey)
        
        var discovered: [DirectoryDiscoveredContact] = []
        
        for followPubkey in followsList {
            // Fetch profile for this follow to get their name
            var profileName: String?
            do {
                if let profile = try await fetchProfile(for: followPubkey) {
                    profileName = profile.name
                }
            } catch {
                Logger.debug("Failed to fetch profile for follow \(followPubkey.prefix(12))...: \(error)", context: "DirectoryService")
            }
            
            // Check if this follow has payment methods
            var paymentMethods: [PaymentMethod] = []
            var hasPaymentMethods = false
            do {
                paymentMethods = try await discoverPaymentMethods(for: followPubkey)
                hasPaymentMethods = !paymentMethods.isEmpty
            } catch {
                Logger.debug("Failed to discover payment methods for \(followPubkey.prefix(12))...: \(error)", context: "DirectoryService")
            }
            
            // Include all follows, not just those with payment methods
            discovered.append(
                DirectoryDiscoveredContact(
                    pubkey: followPubkey,
                    name: profileName,
                    hasPaymentMethods: hasPaymentMethods,
                    supportedMethods: paymentMethods.map { $0.methodId }
                )
            )
        }
        
        return discovered
    }
    
    // MARK: - Payment Request Operations
    
    /// Fetch a payment request from a sender's Pubky storage.
    ///
    /// Retrieves and decrypts from: `pubky://{senderPubkey}/pub/paykit.app/v0/requests/{scope}/{requestId}`
    ///
    /// SECURITY: Decrypts using our Noise secret key and canonical AAD.
    ///
    /// - Parameters:
    ///   - requestId: The payment request ID
    ///   - senderPubkey: The pubkey of the request sender
    ///   - recipientPubkey: The recipient's pubkey (our pubkey, used for scope computation)
    /// - Returns: The payment request if found, nil otherwise
    public func fetchPaymentRequest(requestId: String, senderPubkey: String, recipientPubkey: String? = nil) async throws -> BitkitPaymentRequest? {
        let recipient = recipientPubkey ?? PaykitKeyManager.shared.getCurrentPublicKeyZ32() ?? ""
        
        // Use canonical v0 path (scope-based)
        guard let path = try? PaykitV0Protocol.paymentRequestPath(recipientPubkeyZ32: recipient, requestId: requestId) else {
            Logger.error("Failed to compute canonical path for payment request", context: "DirectoryService")
            return nil
        }
        let pubkyUri = "pubky://\(senderPubkey)\(path)"
        
        Logger.debug("Fetching payment request from: \(pubkyUri)", context: "DirectoryService")
        
        do {
            guard let envelopeData = try await PubkySDKService.shared.getData(pubkyUri) else {
                Logger.debug("Payment request \(requestId) not found at \(senderPubkey.prefix(12))...", context: "DirectoryService")
                return nil
            }
            
            guard let envelopeJson = String(data: envelopeData, encoding: .utf8) else {
                return nil
            }
            
            // Check if this is an encrypted sealed blob
            guard isSealedBlob(json: envelopeJson) else {
                Logger.error("Payment request is not encrypted (sealed blob required)", context: "DirectoryService")
                return nil
            }
            
            // Get our Noise secret key for decryption
            guard let noiseKeypair = PaykitKeyManager.shared.getCachedNoiseKeypair(),
                  let myNoiseSk = Data(hex: noiseKeypair.secretKey) else {
                Logger.error("No Noise keypair available for decryption", context: "DirectoryService")
                return nil
            }
            
            let aad = try PaykitV0Protocol.paymentRequestAad(recipientPubkeyZ32: recipient, requestId: requestId)
            
            let plaintextData = try sealedBlobDecrypt(
                recipientSk: myNoiseSk,
                envelopeJson: envelopeJson,
                aad: aad
            )
            
            guard let json = try JSONSerialization.jsonObject(with: plaintextData) as? [String: Any] else {
                return nil
            }
            
            let createdAtTimestamp = (json["created_at"] as? Int64) ?? Int64(Date().timeIntervalSince1970)
            let expiresAtTimestamp = json["expires_at"] as? Int64
            
            return BitkitPaymentRequest(
                id: requestId,
                fromPubkey: json["from_pubkey"] as? String ?? senderPubkey,
                toPubkey: json["to_pubkey"] as? String ?? recipient,
                amountSats: (json["amount_sats"] as? Int64) ?? 0,
                currency: json["currency"] as? String ?? "BTC",
                methodId: json["method_id"] as? String ?? "lightning",
                description: json["description"] as? String ?? "",
                createdAt: Date(timeIntervalSince1970: TimeInterval(createdAtTimestamp)),
                expiresAt: expiresAtTimestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                status: .pending,
                direction: .incoming
            )
        } catch {
            Logger.error("Failed to fetch payment request \(requestId): \(error)", context: "DirectoryService")
            return nil
        }
    }
    
    /// Remove a payment request from OUR storage.
    ///
    /// NOTE: In the sender-storage model, only the sender can delete their stored requests.
    ///
    /// - Parameters:
    ///   - requestId: The payment request ID to remove
    ///   - recipientPubkey: The recipient pubkey (used for scope computation)
    public func removePaymentRequest(requestId: String, recipientPubkey: String) async throws {
        guard let adapter = authenticatedAdapter else {
            throw DirectoryError.notConfigured
        }
        
        let path = try PaykitV0Protocol.paymentRequestPath(recipientPubkeyZ32: recipientPubkey, requestId: requestId)
        let pubkyStorage = PubkyStorageAdapter.shared
        
        try await pubkyStorage.deleteFile(path: path, adapter: adapter)
        Logger.info("Removed payment request: \(requestId)", context: "DirectoryService")
    }
    
    // MARK: - Pending Requests Discovery
    
    /// Discover pending payment requests from a peer's storage.
    ///
    /// In the v0 sender-storage model, recipients poll known peers and list
    /// their `.../{my_scope}/` directory to discover pending requests.
    ///
    /// - Parameters:
    ///   - peerPubkey: The pubkey of the peer whose storage to poll
    ///   - myPubkey: Our pubkey (used for scope computation)
    /// - Returns: List of discovered requests addressed to us
    public func discoverPendingRequestsFromPeer(peerPubkey: String, myPubkey: String) async throws -> [DiscoveredRequest] {
        let unauthAdapter = PubkyUnauthenticatedStorageAdapter(homeserverBaseURL: homeserverBaseURL)
        let pubkyStorage = PubkyStorageAdapter.shared
        
        let myScope = try PaykitV0Protocol.recipientScope(myPubkey)
        let requestsPath = "\(PaykitV0Protocol.paykitV0Prefix)/\(PaykitV0Protocol.requestsSubpath)/\(myScope)/"
        
        do {
            let requestFiles = try await pubkyStorage.listDirectory(path: requestsPath, adapter: unauthAdapter, ownerPubkey: peerPubkey)
            
            var requests: [DiscoveredRequest] = []
            for requestId in requestFiles {
                if let request = await decryptAndParsePaymentRequest(requestId: requestId, path: requestsPath + requestId, adapter: unauthAdapter, peerPubkey: peerPubkey, myPubkey: myPubkey) {
                    requests.append(request)
                }
            }
            return requests
        } catch {
            Logger.error("Failed to discover requests from \(peerPubkey): \(error)", context: "DirectoryService")
            return []
        }
    }
    
    /// Discover subscription proposals from a peer's storage.
    ///
    /// In the v0 provider-storage model, subscribers poll known providers and list
    /// their `.../{my_scope}/` directory to discover pending proposals.
    ///
    /// - Parameters:
    ///   - peerPubkey: The pubkey of the peer (provider) whose storage to poll
    ///   - myPubkey: Our pubkey (used for scope computation)
    /// - Returns: List of discovered proposals addressed to us
    public func discoverSubscriptionProposalsFromPeer(peerPubkey: String, myPubkey: String) async throws -> [DiscoveredSubscriptionProposal] {
        let unauthAdapter = PubkyUnauthenticatedStorageAdapter(homeserverBaseURL: homeserverBaseURL)
        let pubkyStorage = PubkyStorageAdapter.shared
        
        let myScope = try PaykitV0Protocol.subscriberScope(myPubkey)
        let proposalsPath = "\(PaykitV0Protocol.paykitV0Prefix)/\(PaykitV0Protocol.subscriptionProposalsSubpath)/\(myScope)/"
        
        do {
            let proposalFiles = try await pubkyStorage.listDirectory(path: proposalsPath, adapter: unauthAdapter, ownerPubkey: peerPubkey)
            
            var proposals: [DiscoveredSubscriptionProposal] = []
            for proposalId in proposalFiles {
                if let proposal = await decryptAndParseSubscriptionProposal(proposalId: proposalId, path: proposalsPath + proposalId, adapter: unauthAdapter, peerPubkey: peerPubkey, myPubkey: myPubkey) {
                    proposals.append(proposal)
                }
            }
            return proposals
        } catch {
            Logger.error("Failed to discover proposals from \(peerPubkey): \(error)", context: "DirectoryService")
            return []
        }
    }
    
    /// Decrypt and parse a payment request from an encrypted sealed blob.
    private func decryptAndParsePaymentRequest(requestId: String, path: String, adapter: PubkyUnauthenticatedStorageAdapter, peerPubkey: String, myPubkey: String) async -> DiscoveredRequest? {
        let pubkyStorage = PubkyStorageAdapter.shared
        
        do {
            guard let data = try await pubkyStorage.readFile(path: path, adapter: adapter, ownerPubkey: peerPubkey) else {
                return nil
            }
            
            guard let envelopeJson = String(data: data, encoding: .utf8),
                  isSealedBlob(json: envelopeJson) else {
                Logger.error("Payment request \(requestId) is not encrypted (sealed blob required)", context: "DirectoryService")
                return nil
            }
            
            // Get our Noise secret key for decryption
            guard let noiseKeypair = PaykitKeyManager.shared.getCachedNoiseKeypair(),
                  let myNoiseSk = Data(hex: noiseKeypair.secretKey) else {
                Logger.error("No Noise keypair available for decryption", context: "DirectoryService")
                return nil
            }
            
            let aad = try PaykitV0Protocol.paymentRequestAad(recipientPubkeyZ32: myPubkey, requestId: requestId)
            
            let plaintextData = try sealedBlobDecrypt(
                recipientSk: myNoiseSk,
                envelopeJson: envelopeJson,
                aad: aad
            )
            
            guard let json = try JSONSerialization.jsonObject(with: plaintextData) as? [String: Any] else {
                return nil
            }
            
            return DiscoveredRequest(
                requestId: requestId,
                type: .paymentRequest,
                fromPubkey: json["from_pubkey"] as? String ?? "",
                amountSats: (json["amount_sats"] as? Int64) ?? 0,
                description: json["description"] as? String,
                createdAt: Date(timeIntervalSince1970: TimeInterval((json["created_at"] as? Int64) ?? Int64(Date().timeIntervalSince1970))),
                frequency: nil
            )
        } catch {
            Logger.error("Failed to decrypt/parse payment request \(requestId): \(error)", context: "DirectoryService")
            return nil
        }
    }
    
    /// Decrypt and parse a subscription proposal from an encrypted sealed blob.
    ///
    /// SECURITY: Only encrypted Sealed Blob v1 format is accepted.
    /// Uses canonical AAD format: `paykit:v0:subscription_proposal:{path}:{proposalId}`
    private func decryptAndParseSubscriptionProposal(proposalId: String, path: String, adapter: PubkyUnauthenticatedStorageAdapter, peerPubkey: String, myPubkey: String) async -> DiscoveredSubscriptionProposal? {
        let pubkyStorage = PubkyStorageAdapter.shared
        
        do {
            guard let data = try await pubkyStorage.readFile(path: path, adapter: adapter, ownerPubkey: peerPubkey) else {
                return nil
            }
            
            guard let envelopeString = String(data: data, encoding: .utf8) else {
                return nil
            }
            
            // SECURITY: Only accept encrypted sealed blobs
            guard isSealedBlob(json: envelopeString) else {
                Logger.error("Subscription proposal \(proposalId) is not encrypted (sealed blob required)", context: "DirectoryService")
                return nil
            }
            
            // Get our noise secret key for decryption
            guard let noiseKeypair = PaykitKeyManager.shared.getCachedNoiseKeypair(),
                  let myNoiseSk = Data(hex: noiseKeypair.secretKey) else {
                Logger.error("No Noise keypair available for decryption", context: "DirectoryService")
                return nil
            }
            
            // Build canonical AAD
            let aad = try PaykitV0Protocol.subscriptionProposalAad(subscriberPubkeyZ32: myPubkey, proposalId: proposalId)
            
            // Decrypt the sealed blob
            let plaintextData = try sealedBlobDecrypt(
                recipientSk: myNoiseSk,
                envelopeJson: envelopeString,
                aad: aad
            )
            
            guard let json = try JSONSerialization.jsonObject(with: plaintextData) as? [String: Any] else {
                Logger.error("Failed to parse decrypted proposal JSON", context: "DirectoryService")
                return nil
            }
            
            let providerPubkey = json["provider_pubkey"] as? String ?? ""
            
            // SECURITY: Verify provider identity binding
            // The provider_pubkey in the proposal must match the peer we're polling
            if !providerPubkey.isEmpty {
                let normalizedExpected = try PaykitV0Protocol.normalizePubkeyZ32(peerPubkey)
                let normalizedActual = try PaykitV0Protocol.normalizePubkeyZ32(providerPubkey)
                if normalizedExpected != normalizedActual {
                    Logger.error("Provider identity mismatch for proposal \(proposalId): expected \(normalizedExpected), got \(normalizedActual)", context: "DirectoryService")
                    return nil
                }
            }
            
            return DiscoveredSubscriptionProposal(
                subscriptionId: proposalId,
                providerPubkey: providerPubkey,
                amountSats: (json["amount_sats"] as? Int64) ?? 0,
                description: json["description"] as? String,
                frequency: json["frequency"] as? String ?? "monthly",
                createdAt: Date(timeIntervalSince1970: TimeInterval((json["created_at"] as? Int64) ?? Int64(Date().timeIntervalSince1970)))
            )
        } catch {
            Logger.error("Failed to parse/decrypt subscription proposal \(proposalId): \(error)", context: "DirectoryService")
            return nil
        }
    }
    
    // MARK: - Subscription Proposal Publishing
    
    /// Publish a subscription proposal to our storage for the subscriber to discover.
    ///
    /// The proposal is stored ENCRYPTED at the canonical v0 path:
    /// `/pub/paykit.app/v0/subscriptions/proposals/{subscriber_scope}/{proposalId}`
    ///
    /// SECURITY: Proposals are encrypted using Sealed Blob v1 to subscriber's Noise public key.
    /// Uses canonical AAD format: `paykit:v0:subscription_proposal:{path}:{proposalId}`
    ///
    /// - Parameters:
    ///   - proposal: The subscription proposal to publish
    ///   - subscriberPubkey: The z32 pubkey of the subscriber
    /// - Throws: DirectoryError.notConfigured if session is not configured
    /// - Throws: DirectoryError.publishFailed if the publish operation fails
    /// - Throws: DirectoryError.encryptionFailed if encryption fails (e.g., subscriber has no Noise endpoint)
    public func publishSubscriptionProposal(_ proposal: SubscriptionProposal, subscriberPubkey: String) async throws {
        guard let adapter = authenticatedAdapter else {
            throw DirectoryError.notConfigured
        }
        
        // Get our identity pubkey (provider)
        guard let providerPubkey = PaykitKeyManager.shared.getCurrentPublicKeyZ32() else {
            throw DirectoryError.notConfigured
        }
        
        // Use canonical v0 path (scope-based)
        let proposalPath = try PaykitV0Protocol.subscriptionProposalPath(subscriberPubkeyZ32: subscriberPubkey, proposalId: proposal.id)
        
        // Build proposal JSON
        var proposalDict: [String: Any] = [
            "provider_pubkey": providerPubkey,
            "amount_sats": proposal.amountSats,
            "currency": proposal.currency,
            "frequency": proposal.frequency,
            "method_id": proposal.methodId,
            "created_at": Int64(proposal.createdAt.timeIntervalSince1970)
        ]
        if !proposal.providerName.isEmpty {
            proposalDict["provider_name"] = proposal.providerName
        }
        if !proposal.description.isEmpty {
            proposalDict["description"] = proposal.description
        }
        
        let proposalData = try JSONSerialization.data(withJSONObject: proposalDict)
        
        // Discover subscriber's Noise endpoint to get their public key for encryption
        guard let subscriberNoiseEndpoint = try await discoverNoiseEndpoint(for: subscriberPubkey) else {
            throw DirectoryError.encryptionFailed("Subscriber has no Noise endpoint published")
        }
        
        // Get subscriber's Noise public key as bytes
        guard let subscriberNoisePkBytes = Data(hex: subscriberNoiseEndpoint.serverNoisePubkey) else {
            throw DirectoryError.encryptionFailed("Invalid subscriber Noise public key format")
        }
        
        // Build canonical AAD
        let aad = try PaykitV0Protocol.subscriptionProposalAad(subscriberPubkeyZ32: subscriberPubkey, proposalId: proposal.id)
        
        // Encrypt proposal using Sealed Blob v1 with canonical AAD
        let encryptedEnvelope: String
        do {
            encryptedEnvelope = try sealedBlobEncrypt(
                recipientPk: subscriberNoisePkBytes,
                plaintext: proposalData,
                aad: aad,
                purpose: PaykitV0Protocol.purposeSubscriptionProposal
            )
        } catch {
            Logger.error("Failed to encrypt subscription proposal: \(error)", context: "DirectoryService")
            throw DirectoryError.encryptionFailed("Encryption failed: \(error.localizedDescription)")
        }
        
        // Publish to homeserver
        let result = adapter.put(path: proposalPath, content: encryptedEnvelope)
        if !result.success {
            Logger.error("Failed to publish subscription proposal: \(result.error ?? "Unknown")", context: "DirectoryService")
            throw DirectoryError.publishFailed(result.error ?? "Unknown error")
        }
        
        Logger.info("Published encrypted subscription proposal \(proposal.id) to \(subscriberPubkey.prefix(12))...", context: "DirectoryService")
    }
}

/// Discovered contact from directory with health tracking
public struct DirectoryDiscoveredContact: Identifiable {
    public var id: String { pubkey }
    public let pubkey: String
    public let name: String?
    public let hasPaymentMethods: Bool
    public let supportedMethods: [String]
    public var endpointHealth: [String: Bool]
    public var lastHealthCheckDates: [String: Date]
    
    public init(
        pubkey: String,
        name: String?,
        hasPaymentMethods: Bool,
        supportedMethods: [String],
        endpointHealth: [String: Bool] = [:],
        lastHealthCheckDates: [String: Date] = [:]
    ) {
        self.pubkey = pubkey
        self.name = name
        self.hasPaymentMethods = hasPaymentMethods
        self.supportedMethods = supportedMethods
        
        // Default all endpoints to healthy if not specified
        if endpointHealth.isEmpty {
            var health: [String: Bool] = [:]
            for method in supportedMethods {
                health[method] = true
            }
            self.endpointHealth = health
        } else {
            self.endpointHealth = endpointHealth
        }
        
        self.lastHealthCheckDates = lastHealthCheckDates
    }
}

/// Profile from Pubky directory
public struct PubkyProfile: Codable {
    public let name: String?
    public let bio: String?
    public let avatar: String?
    public let links: [PubkyProfileLink]?
    
    public init(name: String? = nil, bio: String? = nil, avatar: String? = nil, links: [PubkyProfileLink]? = nil) {
        self.name = name
        self.bio = bio
        self.avatar = avatar
        self.links = links
    }
}

public struct PubkyProfileLink: Codable {
    public let title: String
    public let url: String
    
    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

public enum DirectoryError: LocalizedError {
    case notConfigured
    case networkError(String)
    case parseError(String)
    case notFound(String)
    case publishFailed(String)
    case encryptionFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Directory service not configured"
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .parseError(let msg):
            return "Parse error: \(msg)"
        case .notFound(let resource):
            return "Not found: \(resource)"
        case .publishFailed(let msg):
            return "Publish failed: \(msg)"
        case .encryptionFailed(let msg):
            return "Encryption failed: \(msg)"
        }
    }
}
