//
//  PubkyStorageAdapter.swift
//  Bitkit
//
//  Adapter for Pubky SDK storage operations
//  Uses URLSession for HTTP requests to Pubky homeservers
//

import Foundation
// PaykitMobile types are available from FFI/PaykitMobile.swift

/// Adapter for Pubky SDK storage operations
/// This provides a simplified interface to Pubky storage
public final class PubkyStorageAdapter {
    
    public static let shared = PubkyStorageAdapter()
    
    private let session: URLSession
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }
    
    /// Store data in Pubky storage (requires authenticated adapter)
    public func store(path: String, data: Data, adapter: PubkyAuthenticatedStorageAdapter) async throws {
        let content = String(data: data, encoding: .utf8) ?? ""
        let result = adapter.put(path: path, content: content)
        if !result.success {
            throw PubkyStorageError.saveFailed(result.error ?? "Unknown error")
        }
        Logger.debug("Stored data to Pubky: \(path)", context: "PubkyStorageAdapter")
    }
    
    /// Retrieve data from Pubky storage
    public func retrieve(path: String, adapter: PubkyUnauthenticatedStorageAdapter, ownerPubkey: String) async throws -> Data? {
        let result = adapter.get(ownerPubkey: ownerPubkey, path: path)
        if !result.success {
            throw PubkyStorageError.retrieveFailed(result.error ?? "Unknown error")
        }
        return result.content?.data(using: .utf8)
    }
    
    /// List items in a directory
    public func listDirectory(path: String, adapter: PubkyUnauthenticatedStorageAdapter, ownerPubkey: String) async throws -> [String] {
        let result = adapter.list(ownerPubkey: ownerPubkey, prefix: path)
        if !result.success {
            throw PubkyStorageError.listFailed(result.error ?? "Unknown error")
        }
        return result.entries
    }
    
    /// Read a file from Pubky storage (unauthenticated)
    /// Callers must pass a PubkyUnauthenticatedStorageAdapter, not an FFI transport
    public func readFile(path: String, adapter: Any, ownerPubkey: String) async throws -> Data? {
        guard let unauthAdapter = adapter as? PubkyUnauthenticatedStorageAdapter else {
            throw PubkyStorageError.retrieveFailed("Invalid adapter type - expected PubkyUnauthenticatedStorageAdapter")
        }
        
        let result = unauthAdapter.get(ownerPubkey: ownerPubkey, path: path)
        if !result.success {
            if result.error?.contains("404") == true {
                return nil
            }
            throw PubkyStorageError.retrieveFailed(result.error ?? "Unknown error")
        }
        return result.content?.data(using: .utf8)
    }
    
    /// Write a file to Pubky storage (requires authentication)
    /// Uses the authenticated adapter which properly sets session cookies
    public func writeFile(path: String, data: Data, adapter: PubkyAuthenticatedStorageAdapter) async throws {
        let content = String(data: data, encoding: .utf8) ?? ""
        let result = adapter.put(path: path, content: content)
        if !result.success {
            throw PubkyStorageError.saveFailed(result.error ?? "Unknown error")
        }
        Logger.debug("Wrote file to Pubky: \(path)", context: "PubkyStorageAdapter")
    }
    
    /// Delete a file from Pubky storage (requires authentication)
    /// Uses the authenticated adapter which properly sets session cookies
    public func deleteFile(path: String, adapter: PubkyAuthenticatedStorageAdapter) async throws {
        let result = adapter.delete(path: path)
        if !result.success {
            throw PubkyStorageError.deleteFailed(result.error ?? "Unknown error")
        }
        Logger.debug("Deleted file from Pubky: \(path)", context: "PubkyStorageAdapter")
    }
}

enum PubkyStorageError: LocalizedError {
    case saveFailed(String)
    case retrieveFailed(String)
    case listFailed(String)
    case deleteFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .saveFailed(let msg):
            return "Failed to save to Pubky storage: \(msg)"
        case .retrieveFailed(let msg):
            return "Failed to retrieve from Pubky storage: \(msg)"
        case .listFailed(let msg):
            return "Failed to list Pubky directory: \(msg)"
        case .deleteFailed(let msg):
            return "Failed to delete from Pubky storage: \(msg)"
        }
    }
}

/// Adapter for unauthenticated (read-only) Pubky storage operations
/// Makes HTTP requests to Pubky homeservers to read public data
public class PubkyUnauthenticatedStorageAdapter: PubkyUnauthenticatedStorageCallback {
    
    private let homeserverBaseURL: String?
    private let session: URLSession
    
    public init(homeserverBaseURL: String? = nil) {
        self.homeserverBaseURL = homeserverBaseURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60  // Increased timeout
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }
    
    public func get(ownerPubkey: String, path: String) -> StorageGetResult {
        let baseURL = homeserverBaseURL ?? PubkyConfig.homeserverBaseURL()
        // URL format: {baseURL}{path} with pubky-host header for routing
        let urlString = "\(baseURL)\(path)"
        
        guard let url = URL(string: urlString) else {
            return StorageGetResult(success: false, content: nil, error: "Invalid URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(ownerPubkey, forHTTPHeaderField: "pubky-host")
        
        var result: StorageGetResult?
        let semaphore = DispatchSemaphore(value: 0)
        
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            
            if let error = error {
                result = StorageGetResult(success: false, content: nil, error: "Network error: \(error.localizedDescription)")
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                result = StorageGetResult(success: false, content: nil, error: "Invalid HTTP response")
                return
            }
            
            switch httpResponse.statusCode {
            case 404:
                result = StorageGetResult(success: true, content: nil, error: nil)
            case 200...299:
                let content = data.flatMap { String(data: $0, encoding: .utf8) }
                result = StorageGetResult(success: true, content: content, error: nil)
            default:
                result = StorageGetResult(success: false, content: nil, error: "HTTP \(httpResponse.statusCode)")
            }
        }
        
        task.resume()
        semaphore.wait()
        
        return result ?? StorageGetResult(success: false, content: nil, error: "Unknown error")
    }
    
    public func list(ownerPubkey: String, prefix: String) -> StorageListResult {
        let baseURL = homeserverBaseURL ?? PubkyConfig.homeserverBaseURL()
        // URL format: {baseURL}{prefix}?shallow=true with pubky-host header for routing
        let urlString = "\(baseURL)\(prefix)?shallow=true"
        
        Logger.info("LIST request:", context: "PubkyStorageAdapter")
        Logger.info("  - baseURL: \(baseURL)", context: "PubkyStorageAdapter")
        Logger.info("  - prefix: \(prefix)", context: "PubkyStorageAdapter")
        Logger.info("  - full URL: \(urlString)", context: "PubkyStorageAdapter")
        Logger.info("  - pubky-host header: \(ownerPubkey)", context: "PubkyStorageAdapter")
        
        guard let url = URL(string: urlString) else {
            return StorageListResult(success: false, entries: [], error: "Invalid URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(ownerPubkey, forHTTPHeaderField: "pubky-host")
        
        var result: StorageListResult?
        let semaphore = DispatchSemaphore(value: 0)
        
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            
            if let error = error {
                result = StorageListResult(success: false, entries: [], error: "Network error: \(error.localizedDescription)")
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                result = StorageListResult(success: false, entries: [], error: "Invalid HTTP response")
                return
            }
            
            switch httpResponse.statusCode {
            case 404:
                Logger.info("LIST response: 404 - directory not found (this means no proposals at this path)", context: "PubkyStorageAdapter")
                result = StorageListResult(success: true, entries: [], error: nil)
            case 200...299:
                guard let data = data, let responseString = String(data: data, encoding: .utf8) else {
                    Logger.debug("LIST response: 2xx but no data", context: "PubkyStorageAdapter")
                    result = StorageListResult(success: true, entries: [], error: nil)
                    return
                }
                
                Logger.debug("LIST raw (\(responseString.count) chars): \(responseString.prefix(300))", context: "PubkyStorageAdapter")
                
                // Homeserver returns newline-separated pubky:// URIs
                // Extract just the final path component (the pubkey or file ID)
                let lines = responseString.components(separatedBy: .newlines)
                    .filter { !$0.isEmpty }
                
                let entries = lines.compactMap { uri -> String? in
                    // Parse pubky://owner/pub/path/to/item to extract just "item"
                    guard let url = URL(string: uri) else { return nil }
                    return url.lastPathComponent
                }
                
                Logger.debug("LIST extracted \(entries.count) entries: \(entries.prefix(5))...", context: "PubkyStorageAdapter")
                result = StorageListResult(success: true, entries: entries, error: nil)
            default:
                Logger.debug("LIST response: HTTP \(httpResponse.statusCode)", context: "PubkyStorageAdapter")
                result = StorageListResult(success: false, entries: [], error: "HTTP \(httpResponse.statusCode)")
            }
        }
        
        task.resume()
        semaphore.wait()
        
        return result ?? StorageListResult(success: false, entries: [], error: "Unknown error")
    }
}

/// Adapter for authenticated Pubky storage operations
/// Makes HTTP requests to Pubky homeservers with session authentication
/// Cookie format: {ownerPubkey}={sessionSecret}
/// When using central homeserver, also adds pubky-host: {ownerPubkey} header
public class PubkyAuthenticatedStorageAdapter: PubkyAuthenticatedStorageCallback {
    
    private let sessionSecret: String
    private let ownerPubkey: String
    private let homeserverBaseURL: String?
    private let session: URLSession
    
    public init(sessionSecret: String, ownerPubkey: String, homeserverBaseURL: String? = nil) {
        self.sessionSecret = sessionSecret
        self.ownerPubkey = ownerPubkey
        self.homeserverBaseURL = homeserverBaseURL
        // Use ephemeral config to avoid any cached QUIC state
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        config.httpCookieStorage = nil  // We set cookies manually in headers
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Force single connection per host
        config.httpMaximumConnectionsPerHost = 1
        // Disable HTTP/3 multiplexing and connection coalescing which can cause QUIC issues
        config.multipathServiceType = .none
        self.session = URLSession(configuration: config)
    }
    
    /// Build the session cookie in Pubky format: {ownerPubkey}={sessionSecret}
    private func buildSessionCookie() -> String {
        // The sessionSecret may come as "{pubkey}:{actualSecret}" format from Pubky Ring,
        // so we extract just the actualSecret portion after the colon.
        let actualSecret = sessionSecret.contains(":") ? String(sessionSecret.split(separator: ":").last ?? "") : sessionSecret
        return "\(ownerPubkey)=\(actualSecret)"
    }
    
    /// Check if we need to add the pubky-host header (when using central homeserver URL)
    private var needsPubkyHostHeader: Bool {
        return homeserverBaseURL != nil
    }
    
    public func put(path: String, content: String) -> StorageOperationResult {
        let baseURL = homeserverBaseURL ?? PubkyConfig.homeserverBaseURL()
        let urlString = "\(baseURL)\(path)"
        
        // SECURITY: Never log session secrets or request content
        Logger.debug("PUT request to: \(urlString)", context: "PubkyStorageAdapter")
        
        guard let url = URL(string: urlString) else {
            Logger.error("PUT failed: Invalid URL for path: \(path)", context: "PubkyStorageAdapter")
            return StorageOperationResult(success: false, error: "Invalid URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(buildSessionCookie(), forHTTPHeaderField: "Cookie")
        if needsPubkyHostHeader {
            request.setValue(ownerPubkey, forHTTPHeaderField: "pubky-host")
            Logger.debug("Added pubky-host header for owner: \(String(ownerPubkey.prefix(12)))...", context: "PubkyStorageAdapter")
        }
        request.httpBody = content.data(using: .utf8)
        // Disable HTTP/3 (QUIC) to avoid connectivity issues on some networks/simulators
        if #available(iOS 17.0, *) {
            request.assumesHTTP3Capable = false
        }
        
        var result: StorageOperationResult?
        let semaphore = DispatchSemaphore(value: 0)
        
        let task = session.dataTask(with: request) { [weak self] _, response, error in
            defer { semaphore.signal() }
            
            if let error = error {
                Logger.error("PUT network error: \(error.localizedDescription)", context: "PubkyStorageAdapter")
                result = StorageOperationResult(success: false, error: "Network error: \(error.localizedDescription)")
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                Logger.error("PUT failed: Invalid HTTP response", context: "PubkyStorageAdapter")
                result = StorageOperationResult(success: false, error: "Invalid HTTP response")
                return
            }
            
            if (200...299).contains(httpResponse.statusCode) {
                Logger.debug("PUT succeeded: HTTP \(httpResponse.statusCode)", context: "PubkyStorageAdapter")
                result = StorageOperationResult(success: true, error: nil)
            } else {
                Logger.error("PUT failed: HTTP \(httpResponse.statusCode) for path: \(path)", context: "PubkyStorageAdapter")
                result = StorageOperationResult(success: false, error: "HTTP \(httpResponse.statusCode)")
            }
        }
        
        task.resume()
        let waitResult = semaphore.wait(timeout: .now() + 60)  // 60 second timeout
        if waitResult == .timedOut {
            task.cancel()
            Logger.error("PUT timed out for path: \(path)", context: "PubkyStorageAdapter")
            return StorageOperationResult(success: false, error: "Request timed out")
        }
        
        return result ?? StorageOperationResult(success: false, error: "Unknown error")
    }
    
    /// PUT binary data (for blob uploads like images)
    public func putData(path: String, data: Data, contentType: String) -> StorageOperationResult {
        let baseURL = homeserverBaseURL ?? PubkyConfig.homeserverBaseURL()
        let urlString = "\(baseURL)\(path)"
        
        Logger.debug("PUT binary data to: \(urlString) (\(data.count) bytes)", context: "PubkyStorageAdapter")
        
        guard let url = URL(string: urlString) else {
            Logger.error("PUT failed: Invalid URL for path: \(path)", context: "PubkyStorageAdapter")
            return StorageOperationResult(success: false, error: "Invalid URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(buildSessionCookie(), forHTTPHeaderField: "Cookie")
        if needsPubkyHostHeader {
            request.setValue(ownerPubkey, forHTTPHeaderField: "pubky-host")
        }
        request.httpBody = data
        // Disable HTTP/3 (QUIC) to avoid connectivity issues
        if #available(iOS 17.0, *) {
            request.assumesHTTP3Capable = false
        }
        
        var result: StorageOperationResult?
        let semaphore = DispatchSemaphore(value: 0)
        
        let task = session.dataTask(with: request) { _, response, error in
            defer { semaphore.signal() }
            
            if let error = error {
                Logger.error("PUT binary network error: \(error.localizedDescription)", context: "PubkyStorageAdapter")
                result = StorageOperationResult(success: false, error: "Network error: \(error.localizedDescription)")
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                result = StorageOperationResult(success: false, error: "Invalid HTTP response")
                return
            }
            
            if (200...299).contains(httpResponse.statusCode) {
                Logger.debug("PUT binary succeeded: HTTP \(httpResponse.statusCode)", context: "PubkyStorageAdapter")
                result = StorageOperationResult(success: true, error: nil)
            } else {
                Logger.error("PUT binary failed: HTTP \(httpResponse.statusCode)", context: "PubkyStorageAdapter")
                result = StorageOperationResult(success: false, error: "HTTP \(httpResponse.statusCode)")
            }
        }
        
        task.resume()
        let waitResult = semaphore.wait(timeout: .now() + 60)
        if waitResult == .timedOut {
            task.cancel()
            Logger.error("PUT binary timed out for path: \(path)", context: "PubkyStorageAdapter")
            return StorageOperationResult(success: false, error: "Request timed out")
        }
        
        return result ?? StorageOperationResult(success: false, error: "Unknown error")
    }
    
    public func get(path: String) -> StorageGetResult {
        let baseURL = homeserverBaseURL ?? PubkyConfig.homeserverBaseURL()
        let urlString = "\(baseURL)\(path)"
        
        Logger.debug("GET request to: \(urlString)", context: "PubkyStorageAdapter")
        
        guard let url = URL(string: urlString) else {
            Logger.error("GET failed: Invalid URL for path: \(path)", context: "PubkyStorageAdapter")
            return StorageGetResult(success: false, content: nil, error: "Invalid URL")
        }
        
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(buildSessionCookie(), forHTTPHeaderField: "Cookie")
        if needsPubkyHostHeader {
            request.setValue(ownerPubkey, forHTTPHeaderField: "pubky-host")
        }
        
        var result: StorageGetResult?
        let semaphore = DispatchSemaphore(value: 0)
        
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            
            if let error = error {
                Logger.error("GET network error: \(error.localizedDescription)", context: "PubkyStorageAdapter")
                result = StorageGetResult(success: false, content: nil, error: "Network error: \(error.localizedDescription)")
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                Logger.error("GET failed: Invalid HTTP response", context: "PubkyStorageAdapter")
                result = StorageGetResult(success: false, content: nil, error: "Invalid HTTP response")
                return
            }
            
            switch httpResponse.statusCode {
            case 404:
                Logger.debug("GET returned 404 (not found)", context: "PubkyStorageAdapter")
                result = StorageGetResult(success: true, content: nil, error: nil)
            case 200...299:
                let content = data.flatMap { String(data: $0, encoding: .utf8) }
                Logger.debug("GET succeeded: HTTP \(httpResponse.statusCode)", context: "PubkyStorageAdapter")
                result = StorageGetResult(success: true, content: content, error: nil)
            default:
                Logger.error("GET failed: HTTP \(httpResponse.statusCode)", context: "PubkyStorageAdapter")
                result = StorageGetResult(success: false, content: nil, error: "HTTP \(httpResponse.statusCode)")
            }
        }
        
        task.resume()
        semaphore.wait()
        
        return result ?? StorageGetResult(success: false, content: nil, error: "Unknown error")
    }
    
    public func delete(path: String) -> StorageOperationResult {
        let baseURL = homeserverBaseURL ?? PubkyConfig.homeserverBaseURL()
        let urlString = "\(baseURL)\(path)"
        
        Logger.debug("DELETE request to: \(urlString)", context: "PubkyStorageAdapter")
        
        guard let url = URL(string: urlString) else {
            Logger.error("DELETE failed: Invalid URL for path: \(path)", context: "PubkyStorageAdapter")
            return StorageOperationResult(success: false, error: "Invalid URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(buildSessionCookie(), forHTTPHeaderField: "Cookie")
        if needsPubkyHostHeader {
            request.setValue(ownerPubkey, forHTTPHeaderField: "pubky-host")
        }
        // Disable HTTP/3 (QUIC) to avoid connectivity issues
        if #available(iOS 17.0, *) {
            request.assumesHTTP3Capable = false
        }
        
        var result: StorageOperationResult?
        let semaphore = DispatchSemaphore(value: 0)
        
        let task = session.dataTask(with: request) { _, response, error in
            defer { semaphore.signal() }
            
            if let error = error {
                Logger.error("DELETE network error: \(error.localizedDescription)", context: "PubkyStorageAdapter")
                result = StorageOperationResult(success: false, error: "Network error: \(error.localizedDescription)")
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                Logger.error("DELETE failed: Invalid HTTP response", context: "PubkyStorageAdapter")
                result = StorageOperationResult(success: false, error: "Invalid HTTP response")
                return
            }
            
            // 204 No Content or 200 OK are both valid for DELETE
            if (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 404 {
                Logger.debug("DELETE succeeded: HTTP \(httpResponse.statusCode)", context: "PubkyStorageAdapter")
                result = StorageOperationResult(success: true, error: nil)
            } else {
                Logger.error("DELETE failed: HTTP \(httpResponse.statusCode)", context: "PubkyStorageAdapter")
                result = StorageOperationResult(success: false, error: "HTTP \(httpResponse.statusCode)")
            }
        }
        
        task.resume()
        let waitResult = semaphore.wait(timeout: .now() + 60)
        if waitResult == .timedOut {
            task.cancel()
            Logger.error("DELETE timed out for path: \(path)", context: "PubkyStorageAdapter")
            return StorageOperationResult(success: false, error: "Request timed out")
        }
        
        return result ?? StorageOperationResult(success: false, error: "Unknown error")
    }
    
    public func list(prefix: String) -> StorageListResult {
        let baseURL = homeserverBaseURL ?? PubkyConfig.homeserverBaseURL()
        let urlString = "\(baseURL)\(prefix)?shallow=true"
        
        guard let url = URL(string: urlString) else {
            return StorageListResult(success: false, entries: [], error: "Invalid URL")
        }
        
        var request = URLRequest(url: url)
        request.setValue(buildSessionCookie(), forHTTPHeaderField: "Cookie")
        if needsPubkyHostHeader {
            request.setValue(ownerPubkey, forHTTPHeaderField: "pubky-host")
        }
        
        var result: StorageListResult?
        let semaphore = DispatchSemaphore(value: 0)
        
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            
            if let error = error {
                result = StorageListResult(success: false, entries: [], error: "Network error: \(error.localizedDescription)")
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                result = StorageListResult(success: false, entries: [], error: "Invalid HTTP response")
                return
            }
            
            switch httpResponse.statusCode {
            case 404:
                result = StorageListResult(success: true, entries: [], error: nil)
            case 200...299:
                guard let data = data, let responseString = String(data: data, encoding: .utf8) else {
                    result = StorageListResult(success: true, entries: [], error: nil)
                    return
                }
                
                // Homeserver returns newline-separated pubky:// URIs
                // Extract just the final path component (the pubkey or file ID)
                let lines = responseString.components(separatedBy: .newlines)
                    .filter { !$0.isEmpty }
                
                let entries = lines.compactMap { uri -> String? in
                    // Parse pubky://owner/pub/path/to/item to extract just "item"
                    guard let url = URL(string: uri) else { return nil }
                    return url.lastPathComponent
                }
                
                result = StorageListResult(success: true, entries: entries, error: nil)
            default:
                result = StorageListResult(success: false, entries: [], error: "HTTP \(httpResponse.statusCode)")
            }
        }
        
        task.resume()
        semaphore.wait()
        
        return result ?? StorageListResult(success: false, entries: [], error: "Unknown error")
    }
}

