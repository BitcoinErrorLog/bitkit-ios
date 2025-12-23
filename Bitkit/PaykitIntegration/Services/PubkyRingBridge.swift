// PubkyRingBridge.swift
// Bitkit iOS - Paykit Integration
//
// Bridge for communicating with Pubky-ring app via URL schemes.
// Handles session retrieval and noise key derivation requests.
// Supports both same-device and cross-device authentication flows.

import Foundation
import UIKit
import CoreImage
import BitkitCore

// MARK: - PubkyRingBridge

/// Bridge service for communicating with Pubky-ring app via URL schemes.
///
/// Pubky-ring handles:
/// - Session management (sign in/sign up to homeserver)
/// - Key derivation from Ed25519 seed
/// - Profile and follows management
///
/// Communication Flows:
///
/// **Same Device:**
/// 1. Bitkit sends request via URL scheme: `pubkyring://session?callback=bitkit://paykit-session`
/// 2. Pubky-ring prompts user to select a pubky
/// 3. Pubky-ring signs in to homeserver
/// 4. Pubky-ring opens callback URL with data: `bitkit://paykit-session?pubky=...&session_secret=...`
///
/// **Cross Device (QR/Link):**
/// 1. Bitkit generates a session request URL/QR with request_id
/// 2. User scans QR or opens link on device with Pubky-ring
/// 3. Pubky-ring processes request and publishes session to relay/homeserver
/// 4. Bitkit polls relay for session response using request_id
public final class PubkyRingBridge {
    
    // MARK: - Singleton
    
    public static let shared = PubkyRingBridge()
    
    // MARK: - Constants
    
    private let pubkyRingScheme = "pubkyring"
    private let bitkitScheme = "bitkit"
    
    /// Web URL for cross-device authentication
    public static var crossDeviceWebUrl: String {
        if let envUrl = ProcessInfo.processInfo.environment["PUBKY_CROSS_DEVICE_URL"] {
            return envUrl
        }
        return "https://pubky.app/auth"
    }
    
    /// Relay endpoint for cross-device session exchange
    public static var sessionRelayUrl: String {
        if let envUrl = ProcessInfo.processInfo.environment["PUBKY_RELAY_URL"] {
            return envUrl
        }
        // Default production relay
        return "https://relay.pubky.app/sessions"
    }
    
    // Callback paths for different request types
    public struct CallbackPaths {
        public static let session = "paykit-session"
        public static let keypair = "paykit-keypair"
        public static let profile = "paykit-profile"
        public static let follows = "paykit-follows"
        public static let crossDeviceSession = "paykit-cross-session"
        public static let paykitSetup = "paykit-setup"  // Combined session + noise keys
        public static let signatureResult = "signature-result"  // Ed25519 signature result
    }
    
    // MARK: - State
    
    /// Pending session request continuation
    private var pendingSessionContinuation: CheckedContinuation<PubkySession, Error>?
    
    /// Pending keypair request continuation
    private var pendingKeypairContinuation: CheckedContinuation<NoiseKeypair, Error>?
    
    /// Pending paykit setup request continuation (combined session + noise keys)
    private var pendingPaykitSetupContinuation: CheckedContinuation<PaykitSetupResult, Error>?
    
    /// Pending cross-device request ID
    private var pendingCrossDeviceRequestId: String?
    
    /// Cached sessions by pubkey
    private var sessionCache: [String: PubkySession] = [:]
    
    /// Cached keypairs by derivation path
    private var keypairCache: [String: NoiseKeypair] = [:]
    
    /// Keychain storage for persistent session storage
    private let keychainStorage = PaykitKeychainStorage()
    
    /// Device ID for noise key derivation
    private var _deviceId: String?
    
    // MARK: - Initialization
    
    private init() {
        // Load or generate device ID
        _deviceId = loadOrGenerateDeviceId()
    }
    
    // MARK: - Device ID Management
    
    /// Get consistent device ID for noise key derivations
    public var deviceId: String {
        if let id = _deviceId {
            return id
        }
        let id = loadOrGenerateDeviceId()
        _deviceId = id
        return id
    }
    
    private func loadOrGenerateDeviceId() -> String {
        let key = "paykit.device_id"
        
        // Try to load existing
        if let data = keychainStorage.get(key: key),
           let id = String(data: data, encoding: .utf8), !id.isEmpty {
            Logger.debug("Loaded device ID: \(id.prefix(8))...", context: "PubkyRingBridge")
            return id
        }
        
        // Generate new UUID
        let newId = UUID().uuidString.lowercased()
        
        // Persist
        if let data = newId.data(using: .utf8) {
            keychainStorage.set(key: key, value: data)
        }
        
        Logger.info("Generated new device ID: \(newId.prefix(8))...", context: "PubkyRingBridge")
        return newId
    }
    
    /// Reset device ID (for debugging/testing only)
    public func resetDeviceId() {
        keychainStorage.deleteQuietly(key: "paykit.device_id")
        _deviceId = loadOrGenerateDeviceId()
        Logger.info("Device ID reset", context: "PubkyRingBridge")
    }
    
    // MARK: - Public API
    
    /// Check if Pubky-ring app is installed
    public var isPubkyRingInstalled: Bool {
        guard let url = URL(string: "\(pubkyRingScheme)://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }
    
    /// Request a session from Pubky-ring
    ///
    /// Opens Pubky-ring app which will:
    /// 1. Prompt user to select a pubky
    /// 2. Sign in to homeserver
    /// 3. Return session data via callback URL
    ///
    /// - Returns: PubkySession with pubkey, session secret, and capabilities
    /// - Throws: PubkyRingError if request fails or app not installed
    public func requestSession() async throws -> PubkySession {
        guard isPubkyRingInstalled else {
            throw PubkyRingError.appNotInstalled
        }
        
        let callbackUrl = "\(bitkitScheme)://\(CallbackPaths.session)"
        let requestUrl = "\(pubkyRingScheme)://session?callback=\(callbackUrl.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? callbackUrl)"
        
        guard let url = URL(string: requestUrl) else {
            throw PubkyRingError.invalidUrl
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            self.pendingSessionContinuation = continuation
            
            DispatchQueue.main.async {
                UIApplication.shared.open(url) { success in
                    if !success {
                        self.pendingSessionContinuation?.resume(throwing: PubkyRingError.failedToOpenApp)
                        self.pendingSessionContinuation = nil
                    }
                }
            }
        }
    }
    
    /// Request complete Paykit setup from Pubky-ring (session + noise keys in one request)
    ///
    /// This is the preferred method for initial Paykit setup as it:
    /// - Gets everything in a single user interaction
    /// - Ensures noise keys are available even if Ring is later unavailable
    /// - Includes both epoch 0 and epoch 1 keypairs for key rotation
    /// - Always uses secure handoff (no secrets in URL)
    ///
    /// Ring stores secrets on homeserver at an unguessable path and returns only
    /// a request_id. Bitkit fetches the payload and deletes it immediately.
    ///
    /// - Returns: PaykitSetupResult containing session and noise keypairs
    /// - Throws: PubkyRingError if request fails or app not installed
    public func requestPaykitSetup() async throws -> PaykitSetupResult {
        guard isPubkyRingInstalled else {
            throw PubkyRingError.appNotInstalled
        }
        
        let actualDeviceId = self.deviceId
        let callbackUrl = "\(bitkitScheme)://\(CallbackPaths.paykitSetup)"
        let encodedCallback = callbackUrl.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? callbackUrl
        
        let requestUrl = "\(pubkyRingScheme)://paykit-connect?deviceId=\(actualDeviceId)&callback=\(encodedCallback)"
        
        // Ring always uses secure handoff: secrets stored on homeserver at unguessable path,
        // returns only request_id in callback. Bitkit fetches payload and deletes it immediately.
        
        guard let url = URL(string: requestUrl) else {
            throw PubkyRingError.invalidUrl
        }
        
        Logger.info("Requesting Paykit setup from Pubky Ring (secure handoff)", context: "PubkyRingBridge")
        
        let result = try await withCheckedThrowingContinuation { continuation in
            self.pendingPaykitSetupContinuation = continuation
            
            DispatchQueue.main.async {
                UIApplication.shared.open(url) { success in
                    if !success {
                        self.pendingPaykitSetupContinuation?.resume(throwing: PubkyRingError.failedToOpenApp)
                        self.pendingPaykitSetupContinuation = nil
                    }
                }
            }
        }
        
        // Cache session
        sessionCache[result.session.pubkey] = result.session
        
        // Cache and persist noise keypairs
        let noiseKeyCache = NoiseKeyCache.shared
        
        if let keypair0 = result.noiseKeypair0 {
            let cacheKey = "\(keypair0.deviceId):\(keypair0.epoch)"
            keypairCache[cacheKey] = keypair0
            if let secretKeyData = keypair0.secretKey.data(using: .utf8) {
                noiseKeyCache.setKey(secretKeyData, deviceId: keypair0.deviceId, epoch: UInt32(keypair0.epoch))
            }
            Logger.debug("Stored noise keypair for epoch 0", context: "PubkyRingBridge")
        }
        
        if let keypair1 = result.noiseKeypair1 {
            let cacheKey = "\(keypair1.deviceId):\(keypair1.epoch)"
            keypairCache[cacheKey] = keypair1
            if let secretKeyData = keypair1.secretKey.data(using: .utf8) {
                noiseKeyCache.setKey(secretKeyData, deviceId: keypair1.deviceId, epoch: UInt32(keypair1.epoch))
            }
            Logger.debug("Stored noise keypair for epoch 1", context: "PubkyRingBridge")
        }
        
        Logger.info("Paykit setup complete for \(result.session.pubkey.prefix(12))...", context: "PubkyRingBridge")
        
        return result
    }
    
    /// Request a noise keypair derivation from Pubky-ring
    ///
    /// First checks NoiseKeyCache, then requests from Pubky-ring if not found.
    ///
    /// - Parameters:
    ///   - deviceId: Device identifier for key derivation (defaults to stored device ID)
    ///   - epoch: Epoch for key rotation
    /// - Returns: X25519 keypair for Noise protocol
    /// - Throws: PubkyRingError if request fails
    public func requestNoiseKeypair(deviceId: String? = nil, epoch: UInt64) async throws -> NoiseKeypair {
        let actualDeviceId = deviceId ?? self.deviceId
        let cacheKey = "\(actualDeviceId):\(epoch)"
        
        // Check memory cache first
        if let cached = keypairCache[cacheKey] {
            Logger.debug("Noise keypair cache hit for \(cacheKey)", context: "PubkyRingBridge")
            return cached
        }
        
        // Check persistent cache (NoiseKeyCache)
        let noiseKeyCache = NoiseKeyCache.shared
        if let keyData = noiseKeyCache.getKey(deviceId: actualDeviceId, epoch: UInt32(epoch)) {
            // We have the secret key, we need to also have the public key
            // For now, try to reconstruct from stored data
            Logger.debug("Noise keypair found in persistent cache for \(cacheKey)", context: "PubkyRingBridge")
            // The keyData is just the secret key, public key would need to be derived
            // For full support, we'd need to store both - for now request from Pubky-ring
        }
        
        guard isPubkyRingInstalled else {
            throw PubkyRingError.appNotInstalled
        }
        
        let callbackUrl = "\(bitkitScheme)://\(CallbackPaths.keypair)"
        let requestUrl = "\(pubkyRingScheme)://derive-keypair?deviceId=\(actualDeviceId)&epoch=\(epoch)&callback=\(callbackUrl.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? callbackUrl)"
        
        guard let url = URL(string: requestUrl) else {
            throw PubkyRingError.invalidUrl
        }
        
        let keypair = try await withCheckedThrowingContinuation { continuation in
            self.pendingKeypairContinuation = continuation
            
            DispatchQueue.main.async {
                UIApplication.shared.open(url) { success in
                    if !success {
                        self.pendingKeypairContinuation?.resume(throwing: PubkyRingError.failedToOpenApp)
                        self.pendingKeypairContinuation = nil
                    }
                }
            }
        }
        
        // Cache the keypair
        keypairCache[cacheKey] = keypair
        
        // Persist secret key to NoiseKeyCache
        if let secretKeyData = keypair.secretKey.data(using: .utf8) {
            noiseKeyCache.setKey(secretKeyData, deviceId: actualDeviceId, epoch: UInt32(epoch))
        }
        
        return keypair
    }
    
    /// Get cached session for a pubkey
    public func getCachedSession(for pubkey: String) -> PubkySession? {
        sessionCache[pubkey]
    }
    
    /// Clear all cached data
    public func clearCache() {
        sessionCache.removeAll()
        keypairCache.removeAll()
    }
    
    // MARK: - Ed25519 Signing
    
    /// Pending signature request continuation
    private var pendingSignatureContinuation: CheckedContinuation<String, Error>?
    
    /// Request an Ed25519 signature from Pubky-ring
    ///
    /// Ring signs the message with the user's Ed25519 secret key.
    /// Used for authenticating requests to external services (e.g., push relay).
    ///
    /// - Parameter message: The message to sign (UTF-8 string)
    /// - Returns: Hex-encoded Ed25519 signature
    /// - Throws: PubkyRingError if request fails or app not installed
    public func requestSignature(message: String) async throws -> String {
        guard isPubkyRingInstalled else {
            throw PubkyRingError.appNotInstalled
        }
        
        let callbackUrl = "\(bitkitScheme)://\(CallbackPaths.signatureResult)"
        let encodedMessage = message.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? message
        let encodedCallback = callbackUrl.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? callbackUrl
        let requestUrl = "\(pubkyRingScheme)://sign-message?message=\(encodedMessage)&callback=\(encodedCallback)"
        
        guard let url = URL(string: requestUrl) else {
            throw PubkyRingError.invalidUrl
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            pendingSignatureContinuation = continuation
            
            DispatchQueue.main.async {
                UIApplication.shared.open(url) { success in
                    if !success {
                        self.pendingSignatureContinuation?.resume(throwing: PubkyRingError.failedToOpenApp)
                        self.pendingSignatureContinuation = nil
                    }
                }
            }
        }
    }
    
    // MARK: - Profile & Follows Requests
    
    /// Pending profile request continuation
    private var pendingProfileContinuation: CheckedContinuation<DirectoryProfile?, Error>?
    
    /// Pending follows request continuation
    private var pendingFollowsContinuation: CheckedContinuation<[String], Error>?
    
    /// Request a profile from Pubky-ring (which fetches from homeserver)
    ///
    /// - Parameter pubkey: The pubkey of the profile to fetch
    /// - Returns: DirectoryProfile if found, nil otherwise
    /// - Throws: PubkyRingError if request fails
    public func requestProfile(pubkey: String) async throws -> DirectoryProfile? {
        guard isPubkyRingInstalled else {
            throw PubkyRingError.appNotInstalled
        }
        
        let callbackUrl = "\(bitkitScheme)://\(CallbackPaths.profile)"
        let encodedCallback = callbackUrl.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? callbackUrl
        let requestUrl = "\(pubkyRingScheme)://get-profile?pubkey=\(pubkey)&callback=\(encodedCallback)"
        
        guard let url = URL(string: requestUrl) else {
            throw PubkyRingError.invalidUrl
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            self.pendingProfileContinuation = continuation
            
            DispatchQueue.main.async {
                UIApplication.shared.open(url) { success in
                    if !success {
                        self.pendingProfileContinuation?.resume(throwing: PubkyRingError.failedToOpenApp)
                        self.pendingProfileContinuation = nil
                    }
                }
            }
        }
    }
    
    /// Request follows list from Pubky-ring (which fetches from homeserver)
    ///
    /// - Returns: Array of followed pubkeys
    /// - Throws: PubkyRingError if request fails
    public func requestFollows() async throws -> [String] {
        guard isPubkyRingInstalled else {
            throw PubkyRingError.appNotInstalled
        }
        
        let callbackUrl = "\(bitkitScheme)://\(CallbackPaths.follows)"
        let encodedCallback = callbackUrl.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? callbackUrl
        let requestUrl = "\(pubkyRingScheme)://get-follows?callback=\(encodedCallback)"
        
        guard let url = URL(string: requestUrl) else {
            throw PubkyRingError.invalidUrl
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            self.pendingFollowsContinuation = continuation
            
            DispatchQueue.main.async {
                UIApplication.shared.open(url) { success in
                    if !success {
                        self.pendingFollowsContinuation?.resume(throwing: PubkyRingError.failedToOpenApp)
                        self.pendingFollowsContinuation = nil
                    }
                }
            }
        }
    }
    
    // MARK: - Cross-Device Authentication
    
    /// Generate a cross-device session request that can be shared as a link or QR
    ///
    /// This creates a unique request ID and returns both a URL and QR code data
    /// that can be used on another device running Pubky-ring.
    ///
    /// - Returns: CrossDeviceRequest with URL, QR code, and request ID
    public func generateCrossDeviceRequest() -> CrossDeviceRequest {
        let requestId = UUID().uuidString.lowercased()
        pendingCrossDeviceRequestId = requestId
        
        // Build the URL for cross-device auth
        // Format: https://pubky.app/auth?request_id=xxx&callback_scheme=bitkit&app_name=Bitkit
        var components = URLComponents(string: PubkyRingBridge.crossDeviceWebUrl)!
        components.queryItems = [
            URLQueryItem(name: "request_id", value: requestId),
            URLQueryItem(name: "callback_scheme", value: bitkitScheme),
            URLQueryItem(name: "app_name", value: "Bitkit"),
            URLQueryItem(name: "relay_url", value: PubkyRingBridge.sessionRelayUrl)
        ]
        
        let url = components.url!
        let qrImage = generateQRCode(from: url.absoluteString)
        
        return CrossDeviceRequest(
            requestId: requestId,
            url: url,
            qrCodeImage: qrImage,
            expiresAt: Date().addingTimeInterval(300) // 5 minutes
        )
    }
    
    /// Poll for a cross-device session response
    ///
    /// After the user scans the QR or opens the link on another device,
    /// Pubky-ring will publish the session to the relay. This method polls
    /// the relay for the response.
    ///
    /// - Parameters:
    ///   - requestId: The request ID from generateCrossDeviceRequest()
    ///   - timeout: Maximum time to wait (default 5 minutes)
    /// - Returns: PubkySession if successful
    /// - Throws: PubkyRingError on timeout or failure
    public func pollForCrossDeviceSession(requestId: String, timeout: TimeInterval = 300) async throws -> PubkySession {
        let startTime = Date()
        let pollInterval: TimeInterval = 2.0 // Poll every 2 seconds
        
        while Date().timeIntervalSince(startTime) < timeout {
            // Check if session arrived via direct callback
            if let session = sessionCache.values.first(where: { _ in pendingCrossDeviceRequestId == nil }) {
                return session
            }
            
            // Poll relay for session
            if let session = try? await pollRelayForSession(requestId: requestId) {
                sessionCache[session.pubkey] = session
                pendingCrossDeviceRequestId = nil
                return session
            }
            
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        
        pendingCrossDeviceRequestId = nil
        throw PubkyRingError.timeout
    }
    
    /// Import a session manually (for offline/manual cross-device flow)
    ///
    /// Users can manually enter session data if QR/link flow isn't available.
    ///
    /// - Parameters:
    ///   - pubkey: The z-base32 encoded public key
    ///   - sessionSecret: The session secret from Pubky-ring
    ///   - capabilities: Optional list of capabilities
    /// - Returns: Imported PubkySession
    public func importSession(pubkey: String, sessionSecret: String, capabilities: [String] = []) -> PubkySession {
        let session = PubkySession(
            pubkey: pubkey,
            sessionSecret: sessionSecret,
            capabilities: capabilities,
            createdAt: Date()
        )
        sessionCache[pubkey] = session
        return session
    }
    
    /// Generate a shareable link for cross-device auth
    public func generateShareableLink() -> URL {
        let request = generateCrossDeviceRequest()
        return request.url
    }
    
    // MARK: - Private Cross-Device Helpers
    
    private func pollRelayForSession(requestId: String) async throws -> PubkySession? {
        let urlString = "\(PubkyRingBridge.sessionRelayUrl)/\(requestId)"
        guard let url = URL(string: urlString) else { return nil }
        
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse else { return nil }
            
            if httpResponse.statusCode == 404 {
                // Session not yet available
                return nil
            }
            
            if httpResponse.statusCode == 200 {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let session = try decoder.decode(PubkySession.self, from: data)
                return session
            }
            
            return nil
        } catch {
            Logger.debug("Relay poll failed: \(error)", context: "PubkyRingBridge")
            return nil
        }
    }
    
    private func generateQRCode(from string: String) -> UIImage? {
        let data = string.data(using: .utf8)
        
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        
        guard let outputImage = filter.outputImage else { return nil }
        
        // Scale up the QR code for better resolution
        let scale = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = outputImage.transformed(by: scale)
        
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        
        return UIImage(cgImage: cgImage)
    }
    
    // MARK: - Graceful Degradation Helpers
    
    /// Get the current authentication availability status
    public var authenticationStatus: AuthenticationStatus {
        if isPubkyRingInstalled {
            return .pubkyRingAvailable
        } else {
            return .crossDeviceOnly
        }
    }
    
    /// Check if any authentication method is available
    public var canAuthenticate: Bool {
        true // Cross-device is always available as fallback
    }
    
    /// Get recommended authentication method
    public var recommendedAuthMethod: AuthMethod {
        if isPubkyRingInstalled {
            return .sameDevice
        } else {
            return .crossDevice
        }
    }
    
    // MARK: - URL Handling
    
    /// Handle incoming URL callback from Pubky-ring
    ///
    /// Call this from your AppDelegate or SceneDelegate's URL handling method.
    ///
    /// - Parameter url: The callback URL from Pubky-ring
    /// - Returns: True if the URL was handled
    @discardableResult
    public func handleCallback(url: URL) -> Bool {
        guard url.scheme == bitkitScheme else { return false }
        
        let path = url.host ?? url.path
        
        switch path {
        case CallbackPaths.session:
            return handleSessionCallback(url: url)
        case CallbackPaths.keypair:
            return handleKeypairCallback(url: url)
        case CallbackPaths.profile:
            return handleProfileCallback(url: url)
        case CallbackPaths.follows:
            return handleFollowsCallback(url: url)
        case CallbackPaths.crossDeviceSession:
            return handleCrossDeviceSessionCallback(url: url)
        case CallbackPaths.paykitSetup:
            return handlePaykitSetupCallback(url: url)
        case CallbackPaths.signatureResult:
            return handleSignatureCallback(url: url)
        default:
            return false
        }
    }
    
    // MARK: - Private Methods
    
    private func handleSessionCallback(url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            pendingSessionContinuation?.resume(throwing: PubkyRingError.invalidCallback)
            pendingSessionContinuation = nil
            return true
        }
        
        var params: [String: String] = [:]
        for item in queryItems {
            if let value = item.value {
                params[item.name] = value
            }
        }
        
        guard let pubkey = params["pubky"],
              let sessionSecret = params["session_secret"] else {
            pendingSessionContinuation?.resume(throwing: PubkyRingError.missingParameters)
            pendingSessionContinuation = nil
            return true
        }
        
        let capabilities = params["capabilities"]?.components(separatedBy: ",") ?? []
        
        let session = PubkySession(
            pubkey: pubkey,
            sessionSecret: sessionSecret,
            capabilities: capabilities,
            createdAt: Date()
        )
        
        // Cache the session
        sessionCache[pubkey] = session
        
        // Persist to keychain
        persistSession(session)
        
        pendingSessionContinuation?.resume(returning: session)
        pendingSessionContinuation = nil
        
        return true
    }
    
    private func handleKeypairCallback(url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            pendingKeypairContinuation?.resume(throwing: PubkyRingError.invalidCallback)
            pendingKeypairContinuation = nil
            return true
        }
        
        var params: [String: String] = [:]
        for item in queryItems {
            if let value = item.value {
                params[item.name] = value
            }
        }
        
        guard let publicKey = params["public_key"],
              let secretKey = params["secret_key"],
              let deviceId = params["device_id"],
              let epochStr = params["epoch"],
              let epoch = UInt64(epochStr) else {
            pendingKeypairContinuation?.resume(throwing: PubkyRingError.missingParameters)
            pendingKeypairContinuation = nil
            return true
        }
        
        let keypair = NoiseKeypair(
            publicKey: publicKey,
            secretKey: secretKey,
            deviceId: deviceId,
            epoch: epoch
        )
        
        // Cache the keypair in memory
        let cacheKey = "\(deviceId):\(epoch)"
        keypairCache[cacheKey] = keypair
        
        // Persist secret key to NoiseKeyCache
        if let secretKeyData = secretKey.data(using: .utf8) {
            NoiseKeyCache.shared.setKey(secretKeyData, deviceId: deviceId, epoch: UInt32(epoch))
            Logger.debug("Persisted noise keypair to NoiseKeyCache for \(cacheKey)", context: "PubkyRingBridge")
        }
        
        pendingKeypairContinuation?.resume(returning: keypair)
        pendingKeypairContinuation = nil
        
        return true
    }
    
    private func handlePaykitSetupCallback(url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            pendingPaykitSetupContinuation?.resume(throwing: PubkyRingError.invalidCallback)
            pendingPaykitSetupContinuation = nil
            return true
        }
        
        var params: [String: String] = [:]
        for item in queryItems {
            if let value = item.value {
                params[item.name] = value
            }
        }
        
        // Check for secure handoff mode
        if params["mode"] == "secure_handoff" {
            guard let pubkey = params["pubky"],
                  let requestId = params["request_id"] else {
                pendingPaykitSetupContinuation?.resume(throwing: PubkyRingError.missingParameters)
                pendingPaykitSetupContinuation = nil
                return true
            }
            
            // Fetch payload from homeserver asynchronously
            Task {
                do {
                    let result = try await fetchSecureHandoffPayload(pubkey: pubkey, requestId: requestId)
                    pendingPaykitSetupContinuation?.resume(returning: result)
                } catch {
                    pendingPaykitSetupContinuation?.resume(throwing: error)
                }
                pendingPaykitSetupContinuation = nil
            }
            return true
        }
        
        // Legacy mode: secrets in URL
        guard let pubkey = params["pubky"],
              let sessionSecret = params["session_secret"],
              let deviceId = params["device_id"] else {
            pendingPaykitSetupContinuation?.resume(throwing: PubkyRingError.missingParameters)
            pendingPaykitSetupContinuation = nil
            return true
        }
        
        // Parse capabilities
        let capabilities = params["capabilities"]?.split(separator: ",").map(String.init) ?? []
        
        // Create session
        let session = PubkySession(
            pubkey: pubkey,
            sessionSecret: sessionSecret,
            capabilities: capabilities,
            createdAt: Date(),
            expiresAt: nil  // Sessions from paykit-connect don't expire
        )
        
        // Parse noise keypair epoch 0 (optional but expected)
        var keypair0: NoiseKeypair? = nil
        if let publicKey0 = params["noise_public_key_0"],
           let secretKey0 = params["noise_secret_key_0"] {
            keypair0 = NoiseKeypair(
                publicKey: publicKey0,
                secretKey: secretKey0,
                deviceId: deviceId,
                epoch: 0
            )
        }
        
        // Parse noise keypair epoch 1 (optional)
        var keypair1: NoiseKeypair? = nil
        if let publicKey1 = params["noise_public_key_1"],
           let secretKey1 = params["noise_secret_key_1"] {
            keypair1 = NoiseKeypair(
                publicKey: publicKey1,
                secretKey: secretKey1,
                deviceId: deviceId,
                epoch: 1
            )
        }
        
        let result = PaykitSetupResult(
            session: session,
            deviceId: deviceId,
            noiseKeypair0: keypair0,
            noiseKeypair1: keypair1
        )
        
        Logger.info("Paykit setup callback received for \(pubkey.prefix(12))...", context: "PubkyRingBridge")
        
        // Always cache the session directly for robustness
        // This ensures session is available even if called outside of requestPaykitSetup flow
        sessionCache[session.pubkey] = session
        persistSession(session)
        
        // Cache noise keypairs if present
        if let kp0 = keypair0 {
            let cacheKey0 = "\(kp0.deviceId):\(kp0.epoch)"
            keypairCache[cacheKey0] = kp0
            if let secretKeyData = kp0.secretKey.data(using: .utf8) {
                NoiseKeyCache.shared.setKey(secretKeyData, deviceId: kp0.deviceId, epoch: UInt32(kp0.epoch))
            }
        }
        if let kp1 = keypair1 {
            let cacheKey1 = "\(kp1.deviceId):\(kp1.epoch)"
            keypairCache[cacheKey1] = kp1
            if let secretKeyData = kp1.secretKey.data(using: .utf8) {
                NoiseKeyCache.shared.setKey(secretKeyData, deviceId: kp1.deviceId, epoch: UInt32(kp1.epoch))
            }
        }
        
        pendingPaykitSetupContinuation?.resume(returning: result)
        pendingPaykitSetupContinuation = nil
        
        return true
    }
    
    /// Fetch secure handoff payload from homeserver
    private func fetchSecureHandoffPayload(pubkey: String, requestId: String) async throws -> PaykitSetupResult {
        let handoffUri = "pubky://\(pubkey)/pub/paykit.app/v0/handoff/\(requestId)"
        
        Logger.info("Fetching secure handoff payload from \(handoffUri.prefix(50))...", context: "PubkyRingBridge")
        
        // Fetch payload using PubkySDKService
        let data = try await PubkySDKService.shared.publicGet(uri: handoffUri)
        
        // Parse JSON payload
        guard let payload = try? JSONDecoder().decode(SecureHandoffPayload.self, from: data) else {
            throw PubkyRingError.invalidCallback
        }
        
        // Validate payload hasn't expired
        if Date().timeIntervalSince1970 * 1000 > Double(payload.expiresAt) {
            throw PubkyRingError.timeout
        }
        
        // Build session
        let session = PubkySession(
            pubkey: payload.pubky,
            sessionSecret: payload.sessionSecret,
            capabilities: payload.capabilities,
            createdAt: Date(timeIntervalSince1970: Double(payload.createdAt) / 1000),
            expiresAt: nil
        )
        
        // Build noise keypairs
        var keypair0: NoiseKeypair? = nil
        var keypair1: NoiseKeypair? = nil
        
        for kp in payload.noiseKeypairs {
            let keypair = NoiseKeypair(
                publicKey: kp.publicKey,
                secretKey: kp.secretKey,
                deviceId: payload.deviceId,
                epoch: UInt64(kp.epoch)
            )
            
            if kp.epoch == 0 {
                keypair0 = keypair
            } else if kp.epoch == 1 {
                keypair1 = keypair
            }
        }
        
        let result = PaykitSetupResult(
            session: session,
            deviceId: payload.deviceId,
            noiseKeypair0: keypair0,
            noiseKeypair1: keypair1
        )
        
        Logger.info("Secure handoff payload received for \(payload.pubky.prefix(12))...", context: "PubkyRingBridge")
        
        // Cache session and keypairs
        sessionCache[session.pubkey] = session
        persistSession(session)
        
        if let kp0 = keypair0 {
            let cacheKey0 = "\(kp0.deviceId):\(kp0.epoch)"
            keypairCache[cacheKey0] = kp0
            if let secretKeyData = kp0.secretKey.data(using: .utf8) {
                NoiseKeyCache.shared.setKey(secretKeyData, deviceId: kp0.deviceId, epoch: UInt32(kp0.epoch))
            }
        }
        if let kp1 = keypair1 {
            let cacheKey1 = "\(kp1.deviceId):\(kp1.epoch)"
            keypairCache[cacheKey1] = kp1
            if let secretKeyData = kp1.secretKey.data(using: .utf8) {
                NoiseKeyCache.shared.setKey(secretKeyData, deviceId: kp1.deviceId, epoch: UInt32(kp1.epoch))
            }
        }
        
        // Delete handoff file from homeserver to minimize attack window
        Task {
            do {
                let handoffPath = "/pub/paykit.app/v0/handoff/\(requestId)"
                let adapter = PubkyAuthenticatedStorageAdapter(sessionId: session.sessionSecret, homeserverURL: PubkyConfig.defaultHomeserverURL)
                let transport = AuthenticatedTransportFfi.fromCallback(callback: adapter, ownerPubkey: session.pubkey)
                try await PubkyStorageAdapter.shared.deleteFile(path: handoffPath, transport: transport)
                Logger.info("Deleted secure handoff payload: \(requestId)", context: "PubkyRingBridge")
            } catch {
                Logger.warn("Failed to delete handoff payload: \(error)", context: "PubkyRingBridge")
            }
        }
        
        return result
    }
    
    private func handleProfileCallback(url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            pendingProfileContinuation?.resume(returning: nil as DirectoryProfile?)
            pendingProfileContinuation = nil
            return true
        }
        
        var params: [String: String] = [:]
        for item in queryItems {
            if let value = item.value {
                params[item.name] = value
            }
        }
        
        // Check for error response
        if let error = params["error"] {
            Logger.warn("Profile request returned error: \(error)", context: "PubkyRingBridge")
            pendingProfileContinuation?.resume(returning: nil as DirectoryProfile?)
            pendingProfileContinuation = nil
            return true
        }
        
        // Build profile from response using PubkyProfile (DirectoryProfile is typealias)
        let profile: DirectoryProfile = BitkitCore.PubkyProfile(
            name: params["name"]?.removingPercentEncoding,
            bio: params["bio"]?.removingPercentEncoding,
            image: params["avatar"]?.removingPercentEncoding,
            links: [],
            status: params["status"]?.removingPercentEncoding
        )
        
        Logger.debug("Received profile from Pubky-ring: \(profile.name ?? "unknown")", context: "PubkyRingBridge")
        
        pendingProfileContinuation?.resume(returning: profile)
        pendingProfileContinuation = nil
        
        return true
    }
    
    private func handleFollowsCallback(url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            pendingFollowsContinuation?.resume(returning: [])
            pendingFollowsContinuation = nil
            return true
        }
        
        var params: [String: String] = [:]
        for item in queryItems {
            if let value = item.value {
                params[item.name] = value
            }
        }
        
        // Check for error response
        if let error = params["error"] {
            Logger.warn("Follows request returned error: \(error)", context: "PubkyRingBridge")
            pendingFollowsContinuation?.resume(returning: [])
            pendingFollowsContinuation = nil
            return true
        }
        
        // Parse follows list (comma-separated pubkeys)
        let follows = params["follows"]?
            .components(separatedBy: ",")
            .filter { !$0.isEmpty } ?? []
        
        Logger.debug("Received \(follows.count) follows from Pubky-ring", context: "PubkyRingBridge")
        
        pendingFollowsContinuation?.resume(returning: follows)
        pendingFollowsContinuation = nil
        
        return true
    }
    
    private func handleSignatureCallback(url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            pendingSignatureContinuation?.resume(throwing: PubkyRingError.invalidCallback)
            pendingSignatureContinuation = nil
            return true
        }
        
        var params: [String: String] = [:]
        for item in queryItems {
            if let value = item.value {
                params[item.name] = value
            }
        }
        
        // Check for error response
        if let error = params["error"] {
            Logger.warn("Signature request returned error: \(error)", context: "PubkyRingBridge")
            pendingSignatureContinuation?.resume(throwing: PubkyRingError.signatureFailed)
            pendingSignatureContinuation = nil
            return true
        }
        
        // Get signature from response
        guard let signature = params["signature"] else {
            pendingSignatureContinuation?.resume(throwing: PubkyRingError.invalidCallback)
            pendingSignatureContinuation = nil
            return true
        }
        
        Logger.debug("Received Ed25519 signature from Pubky-ring", context: "PubkyRingBridge")
        
        pendingSignatureContinuation?.resume(returning: signature)
        pendingSignatureContinuation = nil
        
        return true
    }
    
    private func handleCrossDeviceSessionCallback(url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return false
        }
        
        var params: [String: String] = [:]
        for item in queryItems {
            if let value = item.value {
                params[item.name] = value
            }
        }
        
        // Verify request ID matches
        if let requestId = params["request_id"], requestId != pendingCrossDeviceRequestId {
            Logger.warn("Cross-device request ID mismatch", context: "PubkyRingBridge")
            return false
        }
        
        guard let pubkey = params["pubky"],
              let sessionSecret = params["session_secret"] else {
            return false
        }
        
        let capabilities = params["capabilities"]?.components(separatedBy: ",") ?? []
        
        let session = PubkySession(
            pubkey: pubkey,
            sessionSecret: sessionSecret,
            capabilities: capabilities,
            createdAt: Date()
        )
        
        // Cache the session
        sessionCache[pubkey] = session
        pendingCrossDeviceRequestId = nil
        
        // Persist to keychain for cross-device sessions too
        persistSession(session)
        
        return true
    }
    
    // MARK: - Session Persistence
    
    /// Persist a session to keychain
    private func persistSession(_ session: PubkySession) {
        do {
            let data = try JSONEncoder().encode(session)
            keychainStorage.set(key: "pubky.session.\(session.pubkey)", value: data)
            Logger.debug("Persisted session for \(session.pubkey.prefix(12))...", context: "PubkyRingBridge")
        } catch {
            Logger.error("Failed to persist session: \(error)", context: "PubkyRingBridge")
        }
    }
    
    /// Restore all sessions from keychain on app launch
    public func restoreSessions() {
        let sessionKeys = keychainStorage.listKeys(withPrefix: "pubky.session.")
        
        for key in sessionKeys {
            do {
                guard let data = keychainStorage.get(key: key) else { continue }
                let session = try JSONDecoder().decode(PubkySession.self, from: data)
                sessionCache[session.pubkey] = session
                Logger.info("Restored session for \(session.pubkey.prefix(12))...", context: "PubkyRingBridge")
            } catch {
                Logger.error("Failed to restore session from \(key): \(error)", context: "PubkyRingBridge")
            }
        }
        
        Logger.info("Restored \(sessionCache.count) sessions from keychain", context: "PubkyRingBridge")
    }
    
    /// Get all cached sessions
    public var cachedSessions: [PubkySession] {
        Array(sessionCache.values)
    }
    
    /// Get all cached sessions
    public func getAllSessions() -> [PubkySession] {
        Array(sessionCache.values)
    }
    
    /// Get count of cached keypairs
    public func getCachedKeypairCount() -> Int {
        keypairCache.count
    }
    
    /// Clear a specific session from cache and keychain
    public func clearSession(pubkey: String) {
        sessionCache.removeValue(forKey: pubkey)
        keychainStorage.deleteQuietly(key: "pubky.session.\(pubkey)")
        Logger.info("Cleared session for \(pubkey.prefix(12))...", context: "PubkyRingBridge")
    }
    
    /// Clear all sessions from cache and keychain
    public func clearAllSessions() {
        for pubkey in sessionCache.keys {
            keychainStorage.deleteQuietly(key: "pubky.session.\(pubkey)")
        }
        sessionCache.removeAll()
        Logger.info("Cleared all sessions", context: "PubkyRingBridge")
    }
    
    /// Set a session directly (for manual or imported sessions)
    public func setCachedSession(_ session: PubkySession) {
        sessionCache[session.pubkey] = session
        persistSession(session)
    }
    
    // MARK: - Backup & Restore
    
    /// Backup data structure for export
    public struct BackupData: Codable {
        public let deviceId: String
        public let sessions: [PubkySession]
        public let noiseKeys: [BackupNoiseKey]
        public let exportedAt: Date
        public let version: Int
        
        public init(deviceId: String, sessions: [PubkySession], noiseKeys: [BackupNoiseKey], exportedAt: Date = Date(), version: Int = 1) {
            self.deviceId = deviceId
            self.sessions = sessions
            self.noiseKeys = noiseKeys
            self.exportedAt = exportedAt
            self.version = version
        }
    }
    
    /// Noise key backup structure
    public struct BackupNoiseKey: Codable {
        public let deviceId: String
        public let epoch: UInt64
        public let secretKey: String
        
        public init(deviceId: String, epoch: UInt64, secretKey: String) {
            self.deviceId = deviceId
            self.epoch = epoch
            self.secretKey = secretKey
        }
    }
    
    /// Export all sessions and noise keys for backup
    ///
    /// - Returns: BackupData containing device ID, sessions, and noise keys
    public func exportBackup() -> BackupData {
        let sessions = Array(sessionCache.values)
        var noiseKeys: [BackupNoiseKey] = []
        
        // Export noise keys from keypair cache
        for (cacheKey, keypair) in keypairCache {
            noiseKeys.append(BackupNoiseKey(
                deviceId: keypair.deviceId,
                epoch: keypair.epoch,
                secretKey: keypair.secretKey
            ))
        }
        
        let backup = BackupData(
            deviceId: deviceId,
            sessions: sessions,
            noiseKeys: noiseKeys
        )
        
        Logger.info("Exported backup with \(sessions.count) sessions and \(noiseKeys.count) noise keys", context: "PubkyRingBridge")
        return backup
    }
    
    /// Export backup as JSON data
    public func exportBackupAsJSON() throws -> Data {
        let backup = exportBackup()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        return try encoder.encode(backup)
    }
    
    /// Import backup data and restore sessions/keys
    ///
    /// - Parameter backup: The backup data to restore
    /// - Parameter overwriteDeviceId: Whether to overwrite the local device ID with the backup's
    public func importBackup(_ backup: BackupData, overwriteDeviceId: Bool = false) {
        // Optionally restore device ID
        if overwriteDeviceId {
            let key = "paykit.device_id"
            if let data = backup.deviceId.data(using: .utf8) {
                keychainStorage.set(key: key, value: data)
                _deviceId = backup.deviceId
                Logger.info("Restored device ID from backup", context: "PubkyRingBridge")
            }
        }
        
        // Restore sessions
        for session in backup.sessions {
            sessionCache[session.pubkey] = session
            persistSession(session)
        }
        
        // Restore noise keys
        let noiseKeyCache = NoiseKeyCache.shared
        for noiseKey in backup.noiseKeys {
            let cacheKey = "\(noiseKey.deviceId):\(noiseKey.epoch)"
            
            // Restore to keypair cache (we only have the secret key, not public)
            // The public key would need to be re-derived from Pubky-ring
            if let secretKeyData = noiseKey.secretKey.data(using: .utf8) {
                noiseKeyCache.setKey(secretKeyData, deviceId: noiseKey.deviceId, epoch: UInt32(noiseKey.epoch))
            }
        }
        
        Logger.info("Imported backup with \(backup.sessions.count) sessions and \(backup.noiseKeys.count) noise keys", context: "PubkyRingBridge")
    }
    
    /// Import backup from JSON data
    public func importBackup(from jsonData: Data, overwriteDeviceId: Bool = false) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(BackupData.self, from: jsonData)
        importBackup(backup, overwriteDeviceId: overwriteDeviceId)
    }
}

// MARK: - Data Models

/// Session data returned from Pubky-ring
public struct PubkySession: Codable {
    public let pubkey: String
    public let sessionSecret: String
    public let capabilities: [String]
    public let createdAt: Date
    public let expiresAt: Date?
    
    /// Initialize with all parameters
    public init(pubkey: String, sessionSecret: String, capabilities: [String], createdAt: Date, expiresAt: Date? = nil) {
        self.pubkey = pubkey
        self.sessionSecret = sessionSecret
        self.capabilities = capabilities
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
    
    /// Check if session has a specific capability
    public func hasCapability(_ capability: String) -> Bool {
        capabilities.contains(capability)
    }
    
    /// Check if session is expired
    public var isExpired: Bool {
        guard let expiresAt = expiresAt else { return false }
        return Date() > expiresAt
    }
}

/// X25519 keypair for Noise protocol
public struct NoiseKeypair: Codable {
    public let publicKey: String
    public let secretKey: String
    public let deviceId: String
    public let epoch: UInt64
}

/// Secure handoff payload structure (stored on homeserver by Ring)
private struct SecureHandoffPayload: Codable {
    let version: Int
    let pubky: String
    let sessionSecret: String
    let capabilities: [String]
    let deviceId: String
    let noiseKeypairs: [SecureHandoffNoiseKeypair]
    let createdAt: Int64
    let expiresAt: Int64
    
    enum CodingKeys: String, CodingKey {
        case version
        case pubky
        case sessionSecret = "session_secret"
        case capabilities
        case deviceId = "device_id"
        case noiseKeypairs = "noise_keypairs"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }
}

private struct SecureHandoffNoiseKeypair: Codable {
    let epoch: Int
    let publicKey: String
    let secretKey: String
    
    enum CodingKeys: String, CodingKey {
        case epoch
        case publicKey = "public_key"
        case secretKey = "secret_key"
    }
}

/// Result from combined Paykit setup request
/// Contains everything needed to operate Paykit: session + noise keys
public struct PaykitSetupResult {
    /// Homeserver session for authenticated storage access
    public let session: PubkySession
    
    /// Device ID used for noise key derivation
    public let deviceId: String
    
    /// X25519 keypair for epoch 0 (current)
    public let noiseKeypair0: NoiseKeypair?
    
    /// X25519 keypair for epoch 1 (for rotation)
    public let noiseKeypair1: NoiseKeypair?
    
    /// Check if noise keys are available
    public var hasNoiseKeys: Bool {
        noiseKeypair0 != nil
    }
}

// MARK: - Errors

public enum PubkyRingError: LocalizedError {
    case appNotInstalled
    case invalidUrl
    case failedToOpenApp
    case invalidCallback
    case missingParameters
    case timeout
    case cancelled
    case signatureFailed
    case crossDeviceFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .appNotInstalled:
            return "Pubky-ring app is not installed"
        case .invalidUrl:
            return "Invalid URL for Pubky-ring request"
        case .failedToOpenApp:
            return "Failed to open Pubky-ring app"
        case .invalidCallback:
            return "Invalid callback from Pubky-ring"
        case .missingParameters:
            return "Missing parameters in Pubky-ring callback"
        case .timeout:
            return "Request to Pubky-ring timed out"
        case .cancelled:
            return "Request was cancelled"
        case .signatureFailed:
            return "Failed to generate signature"
        case .crossDeviceFailed(let reason):
            return "Cross-device authentication failed: \(reason)"
        }
    }
    
    /// User-friendly message for UI display
    public var userMessage: String {
        switch self {
        case .appNotInstalled:
            return "Pubky-ring is not installed on this device. You can use the QR code option to authenticate from another device."
        case .invalidUrl, .invalidCallback, .missingParameters:
            return "Something went wrong. Please try again."
        case .failedToOpenApp:
            return "Could not open Pubky-ring. Please make sure it's installed correctly."
        case .timeout:
            return "The request timed out. Please try again."
        case .cancelled:
            return "Authentication was cancelled."
        case .signatureFailed:
            return "Failed to sign the message. Please try again."
        case .crossDeviceFailed:
            return "Cross-device authentication failed. Please try again."
        }
    }
}

// MARK: - Cross-Device Authentication Models

/// Cross-device session request data
public struct CrossDeviceRequest {
    /// Unique request identifier
    public let requestId: String
    
    /// URL to share or open in browser
    public let url: URL
    
    /// QR code image for scanning
    public let qrCodeImage: UIImage?
    
    /// When this request expires
    public let expiresAt: Date
    
    /// Whether this request has expired
    public var isExpired: Bool {
        Date() > expiresAt
    }
    
    /// Time remaining until expiration
    public var timeRemaining: TimeInterval {
        max(0, expiresAt.timeIntervalSinceNow)
    }
}

/// Authentication method
public enum AuthMethod {
    /// Direct communication with Pubky-ring on same device
    case sameDevice
    
    /// QR code/link for authentication from another device
    case crossDevice
    
    /// Manual session entry
    case manual
}

/// Current authentication availability status
public enum AuthenticationStatus {
    /// Pubky-ring is installed and available
    case pubkyRingAvailable
    
    /// Only cross-device authentication is available
    case crossDeviceOnly
    
    /// User-friendly description
    public var description: String {
        switch self {
        case .pubkyRingAvailable:
            return "Pubky-ring is available on this device"
        case .crossDeviceOnly:
            return "Use QR code to authenticate from another device"
        }
    }
}

