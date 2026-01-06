import Foundation

/// Persistent storage for nonces used in signature replay attack prevention.
///
/// # Security
///
/// This storage persists nonces across app restarts to prevent replay attacks.
/// Each nonce can only be used once - if a nonce is seen again, it indicates
/// a potential replay attack.
///
/// Nonces are stored with their expiration timestamps and are cleaned up
/// periodically to prevent unbounded storage growth.
@MainActor
final class NonceStorage {
    // MARK: - Constants

    private static let defaultsKey = "paykit_nonces"
    private static let keyPrefix = "nonce_"

    // MARK: - Properties

    private let userDefaults: UserDefaults

    /// Serial queue for thread-safe nonce operations
    private let queue = DispatchQueue(label: "to.bitkit.NonceStorage", qos: .userInitiated)

    // MARK: - Initialization

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    // MARK: - Public Methods

    /// Check if a nonce has been used, and mark it as used if not.
    ///
    /// # Security
    ///
    /// This is the critical function for replay attack prevention.
    /// This operation is atomic - no other thread can modify the nonce
    /// between checking and marking.
    ///
    /// - Parameters:
    ///   - nonce: The 32-byte nonce as hex string
    ///   - expiresAt: When this nonce's signature expires (Unix timestamp)
    /// - Returns: `true` if nonce is fresh (never seen), `false` if used (replay attack)
    func checkAndMark(nonce: String, expiresAt: Int64) -> Bool {
        queue.sync {
            var nonces = loadNonces()
            let key = Self.keyPrefix + nonce

            // Check if nonce already exists
            if nonces[key] != nil {
                Logger.warn("Nonce already used: \(nonce.prefix(16))... - potential replay attack", context: "NonceStorage")
                return false
            }

            // Mark as used with expiration time
            nonces[key] = expiresAt
            saveNonces(nonces)

            Logger.debug("Nonce marked as used: \(nonce.prefix(16))...", context: "NonceStorage")
            return true
        }
    }

    /// Check if a nonce has been used (read-only, doesn't mark).
    ///
    /// - Parameter nonce: The 32-byte nonce as hex string
    /// - Returns: `true` if nonce has been used
    func isUsed(nonce: String) -> Bool {
        queue.sync {
            let nonces = loadNonces()
            let key = Self.keyPrefix + nonce
            return nonces[key] != nil
        }
    }

    /// Clean up expired nonces to prevent unbounded storage growth.
    ///
    /// Should be called periodically (e.g., on app startup or hourly).
    ///
    /// - Parameter before: Remove nonces that expired before this timestamp
    /// - Returns: Number of nonces removed
    @discardableResult
    func cleanupExpired(before: Int64) -> Int {
        queue.sync {
            var nonces = loadNonces()
            let originalCount = nonces.count

            nonces = nonces.filter { _, expiresAt in
                expiresAt >= before
            }

            let removed = originalCount - nonces.count
            if removed > 0 {
                saveNonces(nonces)
                Logger.debug("Cleaned up \(removed) expired nonces", context: "NonceStorage")
            }

            return removed
        }
    }

    /// Get the count of tracked nonces (for monitoring/debugging).
    func count() -> Int {
        queue.sync {
            loadNonces().count
        }
    }

    /// Clear all nonces (for testing only).
    func clear() {
        queue.sync {
            userDefaults.removeObject(forKey: Self.defaultsKey)
        }
    }

    // MARK: - Private Methods

    private func loadNonces() -> [String: Int64] {
        guard let data = userDefaults.data(forKey: Self.defaultsKey) else {
            return [:]
        }

        do {
            return try JSONDecoder().decode([String: Int64].self, from: data)
        } catch {
            Logger.error("Failed to decode nonces: \(error)", context: "NonceStorage")
            return [:]
        }
    }

    private func saveNonces(_ nonces: [String: Int64]) {
        do {
            let data = try JSONEncoder().encode(nonces)
            userDefaults.set(data, forKey: Self.defaultsKey)
        } catch {
            Logger.error("Failed to encode nonces: \(error)", context: "NonceStorage")
        }
    }
}

