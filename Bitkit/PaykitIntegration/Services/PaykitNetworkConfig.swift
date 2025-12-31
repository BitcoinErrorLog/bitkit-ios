//
//  PaykitNetworkConfig.swift
//  Bitkit
//
//  Shared URLSession configuration for Paykit network operations.
//  Centralizes timeout, caching, and security settings.
//

import Foundation

/// Shared network configuration for Paykit operations.
///
/// Provides a pre-configured URLSession with appropriate timeouts and security settings
/// for Paykit network operations. Use `PaykitNetworkConfig.shared.session` instead of
/// creating individual URLSession instances.
///
/// ## Usage
///
/// ```swift
/// let session = PaykitNetworkConfig.shared.session
/// let (data, response) = try await session.data(from: url)
/// ```
public final class PaykitNetworkConfig {
    
    // MARK: - Singleton
    
    public static let shared = PaykitNetworkConfig()
    
    // MARK: - Configuration Constants
    
    /// Timeout for individual requests (30 seconds)
    public static let defaultRequestTimeout: TimeInterval = 30.0
    
    /// Timeout for resource loading (60 seconds)
    public static let defaultResourceTimeout: TimeInterval = 60.0
    
    /// Maximum concurrent connections per host
    public static let maxConnectionsPerHost = 4
    
    // MARK: - Properties
    
    /// Shared URLSession for Paykit network operations.
    ///
    /// Pre-configured with:
    /// - 30 second request timeout
    /// - 60 second resource timeout
    /// - HTTP cookie storage for session management
    /// - Caching disabled for sensitive payment data
    public let session: URLSession
    
    /// The underlying configuration (exposed for testing)
    public let configuration: URLSessionConfiguration
    
    // MARK: - Initialization
    
    private init() {
        let config = URLSessionConfiguration.default
        
        // Timeouts
        config.timeoutIntervalForRequest = Self.defaultRequestTimeout
        config.timeoutIntervalForResource = Self.defaultResourceTimeout
        
        // Connection settings
        config.httpMaximumConnectionsPerHost = Self.maxConnectionsPerHost
        
        // Cookie storage for session management
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        
        // Disable URL cache for sensitive payment data
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        
        // Enable HTTP/2 when available
        config.httpAdditionalHeaders = [
            "Accept": "application/json",
            "User-Agent": "Bitkit-iOS/1.0 Paykit/1.0",
        ]
        
        self.configuration = config
        self.session = URLSession(configuration: config)
    }
    
    // MARK: - Factory Methods
    
    /// Create a session with custom timeout.
    ///
    /// - Parameter timeout: Request timeout in seconds.
    /// - Returns: A new URLSession with the custom timeout.
    public func sessionWithTimeout(_ timeout: TimeInterval) -> URLSession {
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = timeout
        return URLSession(configuration: config)
    }
    
    /// Create a session for background transfers.
    ///
    /// - Parameter identifier: Background session identifier.
    /// - Returns: A background URLSession.
    public func backgroundSession(identifier: String) -> URLSession {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.timeoutIntervalForRequest = Self.defaultRequestTimeout
        config.timeoutIntervalForResource = Self.defaultResourceTimeout * 2
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config)
    }
}

