# iOS Production Readiness Audit

You are a team of expert auditors reviewing this iOS Bitcoin/Lightning wallet app for production deployment. You must perform a comprehensive, hands-on audit - not a documentation review.

## MANDATORY FIRST STEPS (Do these before anything else)

### 1. Build & Test Verification

```bash
# Build for all configurations
xcodebuild -workspace Bitkit.xcodeproj/project.xcworkspace \
  -scheme Bitkit \
  -configuration Debug \
  build 2>&1

xcodebuild -workspace Bitkit.xcodeproj/project.xcworkspace \
  -scheme Bitkit \
  -configuration Release \
  build 2>&1

# Build for E2E tests
xcodebuild -workspace Bitkit.xcodeproj/project.xcworkspace \
  -scheme Bitkit \
  -configuration Debug \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) E2E_BUILD' \
  build 2>&1

# Build NotificationService extension
xcodebuild -workspace Bitkit.xcodeproj/project.xcworkspace \
  -scheme BitkitNotification \
  -configuration Debug \
  build 2>&1

# Run unit tests
xcodebuild test \
  -workspace Bitkit.xcodeproj/project.xcworkspace \
  -scheme Bitkit \
  -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1

# Run UI tests
xcodebuild test \
  -workspace Bitkit.xcodeproj/project.xcworkspace \
  -scheme BitkitUITests \
  -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1

# Validate translations
node scripts/validate-translations.js 2>&1

# Format check (if SwiftFormat configured)
swiftformat --lint . 2>&1
```

### 2. Dependency & Configuration Verification

```bash
# Check for Rust dependencies (BitkitCore, LDKNode, Paykit, PubkyNoise)
find . -name "*.a" -o -name "*.framework" -o -name "*.xcframework" | grep -v build/ | grep -v DerivedData/

# Verify FFI bindings exist
find . -name "*FFI.h" -o -name "*FFI.modulemap" -o -name "*FFI.swift" | grep -v build/

# Check for missing dependencies
grep -rn "import.*FFI\|import.*Core\|import.*Node" --include="*.swift" . | grep -v test

# Check Info.plist privacy usage descriptions
plutil -p Bitkit/Info.plist | grep -i "Usage\|Privacy"

# Check for hardcoded URLs/secrets vs Env struct
grep -rn "https://\|http://\|wss://\|ws://" --include="*.swift" . | grep -v test | grep -v build/ | grep -v "Env\."

# Check URL schemes registration
plutil -p Bitkit/Info.plist | grep -i "CFBundleURLSchemes\|CFBundleURLTypes"
```

### 3. Code Quality Searches

```bash
# Find all TODOs/FIXMEs in source code
grep -rn "TODO\|FIXME\|XXX\|HACK\|fatalError\|preconditionFailure" --include="*.swift" . | grep -v build/ | grep -v DerivedData/ | grep -v /archive/

# Find force unwraps in production code (be specific to avoid false positives)
grep -rn "\.unwrap\|try!\|as!" --include="*.swift" . | grep -v test | grep -v build/

# Find implicit force unwraps (! at end of variable access)
grep -rn "\w!\\." --include="*.swift" . | grep -v test | grep -v build/ | grep -v "@IBOutlet"

# Find potential memory leaks (missing weak/unowned)
grep -rn "Task\s*{" --include="*.swift" . | grep -v "\[weak\|unowned" | grep -v test | grep -v build/

# Find potential secret logging
grep -rn "print(\|Logger\.\|os_log\|NSLog" --include="*.swift" . | grep -vi test | grep -i "key\|secret\|mnemonic\|passphrase\|private"

# Find missing error handling
grep -rn "try\?$" --include="*.swift" . | grep -v test | grep -v build/

# Find blocking operations on main thread
grep -rn "DispatchQueue\.main\.sync\|MainActor\.assumeIsolated" --include="*.swift" . | grep -v test | grep -v build/

# Find deprecated APIs
grep -rn "@available.*deprecated\|#available" --include="*.swift" . | grep -v test | grep -v build/
```

## DO NOT

- ❌ Read archive/ directories as current state
- ❌ Trust README claims without code verification
- ❌ Skim files - read the actual implementations
- ❌ Assume tests pass without running them
- ❌ Report issues from docs instead of code inspection
- ❌ Conflate demo/example code with production app code
- ❌ Ignore SwiftUI-specific patterns and lifecycle issues
- ❌ Skip the NotificationService extension audit
- ❌ Ignore App Group/shared container security

## REQUIRED AUDIT CATEGORIES

For each category, read actual source files and grep for patterns:

---

### 1. Compilation & Build

- Does the project build for Debug and Release configurations?
- Do all schemes build successfully (main app AND extensions)?
- Are there missing dependencies or broken imports?
- Do Rust FFI bindings compile correctly?
- Are all frameworks and xcframeworks properly linked?
- Does the E2E build configuration work?
- Are there any deprecated APIs or warnings?
- Do build settings match between main app and extensions?
- Are code signing settings correct for all targets?

---

### 2. SwiftUI Architecture & Patterns

```bash
# Find ViewModel usage (should be transitioning to @Observable)
grep -rn "class.*ViewModel.*ObservableObject\|@Published\|@StateObject" --include="*.swift" . | grep -v test | grep -v build/

# Find @Observable usage (preferred pattern)
grep -rn "@Observable\|@Observation" --include="*.swift" . | grep -v test | grep -v build/

# Find improper state management
grep -rn "@State.*var.*Service\|@State.*var.*Manager" --include="*.swift" . | grep -v test | grep -v build/

# Find .onAppear usage (should use .task for async)
grep -rn "\.onAppear" --include="*.swift" . | grep -v test | grep -v build/

# Find missing @MainActor annotations on classes with @Published
grep -rn "@Published" --include="*.swift" . | grep -v "@MainActor" | grep -v test | grep -v build/

# Find NavigationStack vs deprecated NavigationView
grep -rn "NavigationView\|NavigationStack\|NavigationPath" --include="*.swift" . | grep -v test | grep -v build/

# Find environment injection patterns
grep -rn "\.environment\|@Environment\|@EnvironmentObject" --include="*.swift" . | grep -v test | grep -v build/
```

- Are `@Observable` objects used instead of traditional ViewModels where appropriate?
- Is state management following SwiftUI best practices?
- Are all UI updates happening on `@MainActor`?
- Is `.task` used for async operations instead of `.onAppear`?
- Are views properly decomposed into small, focused components?
- Is the environment injection pattern used correctly?
- Are there retain cycles in closures and async contexts?
- Is `NavigationStack` used instead of deprecated `NavigationView`?
- Is `NavigationPath` properly managed for deep linking?

---

### 3. Swift 6 & Strict Concurrency Readiness

```bash
# Find Sendable conformance issues
grep -rn "Sendable\|@unchecked Sendable" --include="*.swift" . | grep -v test | grep -v build/

# Find implicit self capture in Task (potential data race)
grep -rn "Task\s*{\s*\n.*self\." --include="*.swift" . | grep -v "\[weak self\]\|\[self\]" | grep -v test | grep -v build/

# Find nonisolated usage (ensure intentional)
grep -rn "nonisolated" --include="*.swift" . | grep -v test | grep -v build/

# Find actor isolation issues
grep -rn "actor\s\|@globalActor" --include="*.swift" . | grep -v test | grep -v build/

# Find potential data races with mutable shared state
grep -rn "static\s*var\|class\s*var" --include="*.swift" . | grep -v test | grep -v build/ | grep -v "let"

# Find @preconcurrency usage
grep -rn "@preconcurrency" --include="*.swift" . | grep -v test | grep -v build/
```

- Are types crossing actor boundaries marked `Sendable`?
- Are `Task { }` closures capturing `self` safely (explicit `[weak self]` or `[self]`)?
- Is `nonisolated` used intentionally with proper justification?
- Are there mutable `static var` or `class var` that need actor isolation?
- Is `@MainActor` applied to all UI-related classes consistently?
- Are there any `@preconcurrency` imports that need addressing?

---

### 4. Error Handling

```bash
# Find force unwraps and try!
grep -rn "try!" --include="*.swift" . | grep -v test | grep -v build/

# Find empty catch blocks
grep -rn "catch\s*{" --include="*.swift" . | grep -v test | grep -v build/

# Find functions that swallow errors
grep -rn "catch\s*_\s*{" --include="*.swift" . | grep -v test | grep -v build/

# Find try? that silently fails
grep -rn "try\?" --include="*.swift" . | grep -v test | grep -v build/

# Find Result type usage
grep -rn "Result<\|\.success\|\.failure" --include="*.swift" . | grep -v test | grep -v build/
```

- Are `try!` and force unwraps (`!`) used only where absolutely safe?
- Are errors properly propagated with `throws` and `try`?
- Are user-facing errors displayed via toast/alert mechanisms?
- Are errors logged appropriately without exposing secrets?
- Are retryable errors distinguished from permanent failures?
- Is error handling consistent across async/await boundaries?
- Are `try?` usages justified (not silently swallowing important errors)?

---

### 5. Security (act as security engineer)

#### 5.1 Keychain & Secure Storage

```bash
# Find Keychain usage
grep -rn "Keychain\|SecItem\|kSecClass\|kSecAttr" --include="*.swift" . | grep -v test | grep -v build/

# Find plaintext secret storage
grep -rn "UserDefaults\|FileManager.*write\|Data.*write" --include="*.swift" . | grep -i "key\|secret\|mnemonic\|passphrase" | grep -v test | grep -v build/

# Find secret logging
grep -rn "Logger\.\|print(\|os_log" --include="*.swift" . | grep -i "key\|secret\|mnemonic\|passphrase\|private" | grep -v test | grep -v build/

# Find Keychain access control
grep -rn "kSecAttrAccessible\|SecAccessControl" --include="*.swift" . | grep -v test | grep -v build/

# Find biometric authentication
grep -rn "LAContext\|biometryType\|canEvaluatePolicy" --include="*.swift" . | grep -v test | grep -v build/
```

- Are mnemonics and passphrases stored ONLY in Keychain?
- Are secrets never logged or printed?
- Is Keychain access properly protected with access control flags (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`)?
- Are secrets zeroized from memory when no longer needed?
- Is there proper separation between demo/test code (plaintext OK) and production code?
- Is biometric authentication properly implemented for sensitive operations?
- Are Keychain items protected from backup extraction?

#### 5.2 Data Privacy & Backup Exclusion

```bash
# Find iCloud backup exclusion
grep -rn "isExcludedFromBackupKey\|excludedFromBackup" --include="*.swift" . | grep -v test | grep -v build/

# Find App Group container usage
grep -rn "containerURL\|appGroupIdentifier\|group\." --include="*.swift" . | grep -v test | grep -v build/

# Find file protection attributes
grep -rn "FileProtection\|NSFileProtection" --include="*.swift" . | grep -v test | grep -v build/

# Check for sensitive data in UserDefaults
grep -rn "UserDefaults\|@AppStorage" --include="*.swift" . | grep -v test | grep -v build/
```

- Is the LDK storage directory excluded from iCloud backup?
- Are Lightning channel state files excluded from backup?
- Is the App Group shared container properly secured?
- Are sensitive files protected with `FileProtectionType.complete`?
- Is UserDefaults used ONLY for non-sensitive preferences?
- Are logs excluded from backup?

#### 5.3 Cryptographic Operations

```bash
# Find cryptographic operations
grep -rn "CryptoKit\|CommonCrypto\|SecKey\|Ed25519\|X25519\|Curve25519" --include="*.swift" . | grep -v test | grep -v build/

# Find nonce/IV handling
grep -rn "nonce\|Nonce\|iv\|IV\|AES\.GCM" --include="*.swift" . | grep -v test | grep -v build/

# Find random number generation
grep -rn "SecRandomCopyBytes\|SystemRandomNumberGenerator\|\.random" --include="*.swift" . | grep -v test | grep -v build/

# Find key derivation
grep -rn "HKDF\|PBKDF2\|deriveKey" --include="*.swift" . | grep -v test | grep -v build/
```

- Are cryptographic operations using secure APIs (CryptoKit, not deprecated CommonCrypto)?
- Are nonces generated with secure random number generators?
- Are nonces never reused?
- Is key derivation using proper HKDF or similar?
- Are Ed25519 keys used ONLY for signatures?
- Are X25519 keys used ONLY for key exchange?
- Is there proper domain separation for different signature types?

#### 5.4 Input Validation & Deep Linking

```bash
# Find URL scheme handling
grep -rn "onOpenURL\|application.*open.*url\|openURL" --include="*.swift" . | grep -v test | grep -v build/

# Find external data parsing
grep -rn "JSONDecoder\|Codable\|decode\|parse" --include="*.swift" . | grep -v test | grep -v build/

# Find URL/URI handling (Bitcoin, Lightning, Paykit schemes)
grep -rn "URL(\|URLComponents\|bitcoin:\|lightning:\|paykit:\|pubky:" --include="*.swift" . | grep -v test | grep -v build/

# Find QR code scanning
grep -rn "AVCapture\|QRCode\|scanner\|ScannerManager" --include="*.swift" . | grep -v test | grep -v build/

# Find universal links handling
grep -rn "userActivity\|NSUserActivity\|webpageURL" --include="*.swift" . | grep -v test | grep -v build/
```

- Are all external inputs (QR codes, URLs, JSON) validated before use?
- Are Bitcoin addresses validated before use?
- Are BOLT11 invoices validated before parsing?
- Are path traversal attacks prevented in file operations?
- Are injection attacks prevented in URL/URI construction?
- Is the `onOpenURL` handler validating all URL parameters?
- Are `paykit://` and `pubky://` schemes registered and handled securely?
- Are deep link timeouts implemented to prevent hanging?
- Are universal links properly validated against associated domains?

---

### 6. Bitcoin & Lightning Network Operations

#### 6.1 Lightning Network (LDK Node)

```bash
# Find LDK Node operations
grep -rn "LDKNode\|LightningService\|Node\.\|node\." --include="*.swift" . | grep -v test | grep -v build/

# Find Lightning payment operations
grep -rn "send.*bolt11\|payInvoice\|sendPayment\|bolt11Invoice" --include="*.swift" . | grep -v test | grep -v build/

# Find channel management
grep -rn "openChannel\|closeChannel\|ChannelDetails\|forceClose" --include="*.swift" . | grep -v test | grep -v build/

# Find StateLocker usage for Lightning
grep -rn "StateLocker\|lock.*lightning\|isLocked" --include="*.swift" . | grep -v test | grep -v build/

# Find node event handling
grep -rn "addOnEvent\|Event\.\|onPayment" --include="*.swift" . | grep -v test | grep -v build/

# Find network configuration
grep -rn "regtest\|testnet\|mainnet\|signet" --include="*.swift" . | grep -v test | grep -v build/
```

- Is `StateLocker` used to prevent concurrent Lightning operations?
- Are Lightning operations properly queued via `ServiceQueue`?
- Is the node lifecycle properly managed (start/stop/restart)?
- Are Lightning events properly handled and propagated to UI?
- Are payment states properly tracked (pending/successful/failed)?
- Is channel state properly synchronized?
- Are network configuration changes (regtest/testnet/mainnet) properly handled?
- Is force-close properly gated with user confirmation?
- Are payment preimages properly stored for proof of payment?

#### 6.2 Bitcoin Operations (BitkitCore)

```bash
# Find BitkitCore operations
grep -rn "BitkitCore\|CoreService" --include="*.swift" . | grep -v test | grep -v build/

# Find onchain payment operations
grep -rn "send.*address\|createTransaction\|broadcast\|signTransaction" --include="*.swift" . | grep -v test | grep -v build/

# Find UTXO management
grep -rn "Utxo\|spendable\|unspent\|coin.*select" --include="*.swift" . | grep -v test | grep -v build/

# Find RBF handling
grep -rn "rbf\|RBF\|bumpFee\|replaceable" --include="*.swift" . | grep -v test | grep -v build/

# Find address generation
grep -rn "getAddress\|newAddress\|receiveAddress" --include="*.swift" . | grep -v test | grep -v build/
```

- Are Bitcoin operations properly queued via `ServiceQueue`?
- Is RBF (Replace-By-Fee) properly handled?
- Are transaction fees properly calculated and validated?
- Is the wallet properly synchronized with blockchain state?
- Are balance calculations accurate (confirmed vs unconfirmed)?
- Are transaction confirmations properly tracked?
- Is address reuse prevented?
- Are change outputs handled correctly?

#### 6.3 Financial/Arithmetic Safety

```bash
# Find amount/satoshi handling
grep -rn "UInt64.*sats\|sats.*UInt64\|Satoshi\|satoshi" --include="*.swift" . | grep -v test | grep -v build/

# Find dangerous floating-point usage for amounts
grep -rn "Double.*sats\|Float.*sats\|CGFloat.*sats" --include="*.swift" . | grep -v test | grep -v build/

# Find currency conversion
grep -rn "CurrencyService\|exchangeRate\|convert\|fiat" --include="*.swift" . | grep -v test | grep -v build/

# Find Decimal usage (preferred for currency)
grep -rn "Decimal\|NSDecimalNumber" --include="*.swift" . | grep -v test | grep -v build/

# Find overflow-prone operations
grep -rn "sats\s*\+\|sats\s*-\|sats\s*\*\|\.addingReportingOverflow\|\.subtractingReportingOverflow" --include="*.swift" . | grep -v test | grep -v build/
```

- Is floating-point NEVER used for satoshi amounts?
- Are all amounts stored as `UInt64` (satoshi)?
- Is checked arithmetic used to prevent overflow/underflow?
- Are currency conversions using `Decimal` (not `Double`)?
- Are spending limits enforced atomically (no TOCTOU races)?
- Are fee calculations accurate and validated?
- Is dust limit properly enforced?
- Are amounts displayed with proper formatting (no precision loss)?

---

### 7. Paykit Integration

```bash
# Find Paykit usage
grep -rn "Paykit\|PaykitManager\|PaykitPayment\|PaykitService" --include="*.swift" . | grep -v test | grep -v build/

# Find executor registration
grep -rn "registerExecutor\|BitkitExecutor\|LightningExecutor\|BitcoinExecutor" --include="*.swift" . | grep -v test | grep -v build/

# Find payment request handling
grep -rn "PaymentRequest\|paykit://\|parsePaymentRequest" --include="*.swift" . | grep -v test | grep -v build/

# Find spending limits
grep -rn "SpendingLimit\|spendingLimit\|maxAmount\|dailyLimit" --include="*.swift" . | grep -v test | grep -v build/

# Find receipt handling
grep -rn "Receipt\|PaymentReceipt\|proof\|preimage" --include="*.swift" . | grep -v test | grep -v build/

# Find directory service
grep -rn "DirectoryService\|directory\|lookup\|resolve" --include="*.swift" . | grep -v test | grep -v build/
```

- Is Paykit properly initialized on app startup?
- Are executors (Bitcoin/Lightning) properly registered?
- Are payment requests properly parsed and validated?
- Is the Paykit client lifecycle properly managed?
- Are payment receipts properly generated and stored?
- Is the directory service integration working correctly?
- Are spending limits properly enforced via Paykit?
- Is autopay properly gated with user consent?
- Are payment method preferences persisted correctly?

---

### 8. Pubky & Noise Protocol Integration

```bash
# Find Pubky/Noise usage
grep -rn "Pubky\|Noise\|PubkyNoise\|pubky_noise" --include="*.swift" . | grep -v test | grep -v build/

# Find Noise handshake operations
grep -rn "handshake\|Handshake\|initiator\|responder" --include="*.swift" . | grep -v test | grep -v build/

# Find session/rekey operations
grep -rn "rekey\|Rekey\|session\|Session\|channelState" --include="*.swift" . | grep -i noise | grep -v test | grep -v build/

# Find Pubky storage operations
grep -rn "PubkyStorage\|pubky://\|/pub/\|homeserver" --include="*.swift" . | grep -v test | grep -v build/

# Find Pkarr operations
grep -rn "Pkarr\|pkarr\|dns\|resolve" --include="*.swift" . | grep -v test | grep -v build/
```

- Is the Noise protocol handshake properly implemented?
- Are session keys properly rotated (rekeying)?
- Is the channel state machine correct (no invalid transitions)?
- Are Pubky storage paths using consistent prefixes?
- Is 404 handling correct (missing data is `nil`, not error)?
- Are public vs authenticated operations properly separated?
- Is homeserver integration working correctly?
- Is Pkarr resolution working for identity lookups?

---

### 9. Concurrency & Thread Safety

```bash
# Find actor usage
grep -rn "^actor\s\|@MainActor\|@globalActor" --include="*.swift" . | grep -v test | grep -v build/

# Find DispatchQueue usage (legacy, prefer async/await)
grep -rn "DispatchQueue\.\|\.async\s*{\|\.sync\s*{" --include="*.swift" . | grep -v test | grep -v build/

# Find ServiceQueue usage
grep -rn "ServiceQueue\|\.core\|\.ldk" --include="*.swift" . | grep -v test | grep -v build/

# Find potential race conditions with mutable arrays/dictionaries
grep -rn "var\s.*:\s*\[" --include="*.swift" . | grep -v "@MainActor" | grep -v "private.*let" | grep -v test | grep -v build/

# Find lock/mutex usage
grep -rn "NSLock\|os_unfair_lock\|DispatchSemaphore" --include="*.swift" . | grep -v test | grep -v build/

# Find async let usage
grep -rn "async\s+let" --include="*.swift" . | grep -v test | grep -v build/
```

- Are all UI updates happening on `@MainActor`?
- Is `ServiceQueue` used for all Core/Lightning operations?
- Are shared mutable state protected with actors or locks?
- Are there potential race conditions in state management?
- Is `block_on` or blocking operations avoided in async contexts?
- Are callbacks and closures properly marked with `@MainActor` where needed?
- Is thread safety maintained across FFI boundaries?
- Are `async let` used for parallel operations where appropriate?

---

### 10. Background Tasks & Push Notifications

```bash
# Find background task handling
grep -rn "BGTaskScheduler\|beginBackgroundTask\|backgroundTimeRemaining\|BGAppRefreshTask" --include="*.swift" . | grep -v test | grep -v build/

# Find push notification handling
grep -rn "UNUserNotificationCenter\|didReceive\|pushNotification\|APNs" --include="*.swift" . | grep -v test | grep -v build/

# Find NotificationService extension
grep -rn "NotificationService\|UNNotificationServiceExtension\|serviceExtension" --include="*.swift" . | grep -v test | grep -v build/

# Find App Group usage for extension communication
grep -rn "appGroup\|suiteName\|containerURL" --include="*.swift" . | grep -v test | grep -v build/

# Find background URLSession
grep -rn "URLSessionConfiguration\.background\|isDiscretionary" --include="*.swift" . | grep -v test | grep -v build/
```

- Are background tasks properly registered and handled?
- Is the NotificationService extension properly handling incoming payments?
- Are push notifications properly processed when app is in background?
- Is the Lightning node properly woken up for background notifications?
- Are background task timeouts properly handled?
- Is StateLocker properly checked before starting node in background?
- Is App Group properly configured for main app <-> extension communication?
- Are extension memory limits respected (~50MB)?
- Is extension time limit respected (~30 seconds)?

---

### 11. App Extension Security

```bash
# Find extension-specific code
find . -path "*/BitkitNotification/*" -name "*.swift" | xargs grep -l ""

# Find shared Keychain access
grep -rn "kSecAttrAccessGroup\|accessGroup" --include="*.swift" . | grep -v test | grep -v build/

# Find extension file access
grep -rn "FileManager\|containerURL" --include="*.swift" BitkitNotification/

# Check for extension-safe APIs
grep -rn "UIApplication\.shared\|openURL" --include="*.swift" BitkitNotification/
```

- Is the NotificationService extension using only extension-safe APIs?
- Are Keychain items shared correctly between app and extension?
- Is the shared container properly accessed by both targets?
- Are extension memory and time limits respected?
- Is LDK node state properly synchronized between app and extension?
- Are crashes in extension handled gracefully?

---

### 12. FFI & Rust Integration

```bash
# Find FFI bindings usage
grep -rn "import.*FFI\|import BitkitCore\|import LDKNode\|import PubkyNoise" --include="*.swift" . | grep -v test | grep -v build/

# Find async/sync boundaries
grep -rn "Task\s*{\|async\s*{\|await\s" --include="*.swift" . | grep -v test | grep -v build/

# Find callback patterns (potential retain cycles)
grep -rn "callback\|completion\|@escaping\|closure" --include="*.swift" . | grep -v test | grep -v build/

# Find blocking FFI calls
grep -rn "\.sync\|blockingGet\|semaphore\.wait" --include="*.swift" . | grep -v test | grep -v build/

# Find UniFFI-specific patterns
grep -rn "uniffi\|UniffiCallback" --include="*.swift" . | grep -v test | grep -v build/
```

- Are all FFI calls properly wrapped in async/await?
- Are callbacks safe from retain cycles (`[weak self]`)?
- Is `block_on` never called on an existing async context?
- Are Rust types properly bridged to Swift types?
- Are errors from Rust properly converted to Swift errors?
- Is memory management correct (no leaks, proper cleanup)?
- Are callbacks from Rust dispatched to the correct queue?
- Do heavy FFI callbacks block the Rust thread?

---

### 13. Network & Transport Layer

```bash
# Find network operations
grep -rn "URLSession\|URLRequest\|async.*await.*URL" --include="*.swift" . | grep -v test | grep -v build/

# Find Electrum/Esplora integration
grep -rn "Electrum\|Esplora\|electrumServer\|esploraUrl" --include="*.swift" . | grep -v test | grep -v build/

# Find timeout configurations
grep -rn "timeoutInterval\|timeout\|TimeInterval" --include="*.swift" . | grep -v test | grep -v build/

# Find certificate pinning
grep -rn "pinnedCertificates\|SecTrust\|URLAuthenticationChallenge" --include="*.swift" . | grep -v test | grep -v build/

# Find network reachability
grep -rn "NWPathMonitor\|NetworkMonitor\|reachability" --include="*.swift" . | grep -v test | grep -v build/

# Find WebSocket usage
grep -rn "URLSessionWebSocketTask\|WebSocket\|ws://\|wss://" --include="*.swift" . | grep -v test | grep -v build/
```

- Are network requests using proper timeouts?
- Is TLS/HTTPS required for all network operations?
- Are network errors properly handled and retried where appropriate?
- Is the Electrum/Esplora backend properly configured?
- Are network configuration changes (regtest/testnet/mainnet) properly handled?
- Is certificate pinning implemented for production?
- Is network reachability properly monitored?
- Are WebSocket connections properly managed (reconnection, heartbeat)?

---

### 14. State Management & Lifecycle

```bash
# Find app lifecycle handling
grep -rn "scenePhase\|applicationDidBecomeActive\|applicationWillResignActive\|applicationDidEnterBackground" --include="*.swift" . | grep -v test | grep -v build/

# Find state persistence
grep -rn "UserDefaults\|@AppStorage\|Codable.*save\|JSONEncoder" --include="*.swift" . | grep -v test | grep -v build/

# Find state restoration
grep -rn "\.onAppear\|\.task\|\.onChange\|onReceive" --include="*.swift" . | grep -v test | grep -v build/

# Find scene phase handling
grep -rn "ScenePhase\|\.active\|\.inactive\|\.background" --include="*.swift" . | grep -v test | grep -v build/

# Find app termination handling
grep -rn "applicationWillTerminate\|willTerminate" --include="*.swift" . | grep -v test | grep -v build/
```

- Is app state properly restored on launch?
- Are critical operations (node startup, wallet loading) properly handled on app launch?
- Is state properly persisted and restored across app launches?
- Are view lifecycle methods (`.task`, `.onAppear`) used correctly?
- Is state properly cleaned up when views disappear?
- Are there memory leaks from retained state?
- Is the app properly handling scene phase transitions?
- Is node state properly saved before app termination?

---

### 15. Testing Quality

```bash
# Find test files
find . -name "*Test.swift" -o -name "*Tests.swift" | grep -v build/ | grep -v DerivedData/

# Find test coverage patterns
grep -rn "@testable\|XCTest\|XCTAssert" --include="*.swift" . | grep -i test | grep -v build/

# Find mock implementations
grep -rn "Mock\|Fake\|Stub\|Spy" --include="*.swift" . | grep -i test | grep -v build/

# Find async test patterns
grep -rn "async\s*throws\s*->\|expectation\|fulfillment" --include="*.swift" . | grep -i test | grep -v build/

# Find UI test patterns
grep -rn "XCUIApplication\|XCUIElement\|launchArguments" --include="*.swift" . | grep -i test | grep -v build/
```

- Is there adequate test coverage for critical paths?
- Are Lightning operations properly tested?
- Are Bitcoin operations properly tested?
- Are security-critical operations (keychain, crypto) properly tested?
- Are edge cases tested (network failures, invalid inputs, etc.)?
- Are integration tests covering real scenarios?
- Are UI tests covering critical user flows?
- Are async operations tested with proper expectations?
- Are mocks properly isolating units under test?

---

### 16. Performance & Memory

```bash
# Find potential performance issues
grep -rn "for.*in.*for\|\.map.*\.map\|\.filter.*\.filter" --include="*.swift" . | grep -v test | grep -v build/

# Find unnecessary allocations
grep -rn "Array\(repeating:\|String\(repeating:\|\.map\(.*\.map" --include="*.swift" . | grep -v test | grep -v build/

# Find image/data caching
grep -rn "NSCache\|URLCache\|ImageCache\|cache" --include="*.swift" . | grep -v test | grep -v build/

# Find potential main thread blocking
grep -rn "\.sync\s*{\|Thread\.sleep\|usleep" --include="*.swift" . | grep -v test | grep -v build/

# Find large data loading
grep -rn "Data(contentsOf:\|String(contentsOf:" --include="*.swift" . | grep -v test | grep -v build/

# Find memory warnings handling
grep -rn "didReceiveMemoryWarning\|applicationDidReceiveMemoryWarning" --include="*.swift" . | grep -v test | grep -v build/
```

- Are expensive operations moved off the main thread?
- Are images and data properly cached?
- Are there unnecessary allocations in hot paths?
- Is memory usage reasonable (no leaks, proper cleanup)?
- Are list views using proper lazy loading (`LazyVStack`, `LazyHStack`)?
- Are network responses properly cached where appropriate?
- Are large data files loaded asynchronously?
- Is memory warning handling implemented?
- Does the UI freeze during node startup or sync?

---

### 17. Accessibility & Localization

```bash
# Find accessibility modifiers
grep -rn "\.accessibilityLabel\|\.accessibilityHint\|\.accessibilityValue" --include="*.swift" . | grep -v test | grep -v build/

# Find accessibility identifiers (for UI testing)
grep -rn "\.accessibilityIdentifier" --include="*.swift" . | grep -v test | grep -v build/

# Find localization usage
grep -rn 'NSLocalizedString\|String(localized:\|LocalizedStringKey\|".*"\.localized' --include="*.swift" . | grep -v test | grep -v build/

# Find hardcoded strings in Text views
grep -rn 'Text("' --include="*.swift" . | grep -v test | grep -v build/ | grep -v "Preview"

# Find Dynamic Type support
grep -rn "\.dynamicTypeSize\|preferredFont\|UIFont\.preferredFont" --include="*.swift" . | grep -v test | grep -v build/
```

- Are all UI elements properly accessible?
- Are all user-facing strings localized?
- Are there hardcoded strings that should be localized?
- Are accessibility labels descriptive and helpful?
- Is VoiceOver support properly implemented?
- Are accessibility identifiers set for UI testing?
- Is Dynamic Type properly supported?
- Are color contrasts sufficient for accessibility?

---

### 18. Environment & Configuration

```bash
# Find Env struct usage
grep -rn "Env\.\|Environment\." --include="*.swift" . | grep -v test | grep -v build/

# Find compilation conditions
grep -rn "#if\s\|#ifdef\|#else\|#endif\|E2E_BUILD\|DEBUG" --include="*.swift" . | grep -v test | grep -v build/

# Find feature flags
grep -rn "FeatureFlag\|isEnabled\|toggles" --include="*.swift" . | grep -v test | grep -v build/

# Find hardcoded configuration
grep -rn "https://.*\.\|http://.*\.\|wss://.*\." --include="*.swift" . | grep -v test | grep -v build/ | grep -v "Env\."
```

- Are all URLs/endpoints coming from `Env` struct (not hardcoded)?
- Are feature flags properly managed?
- Are debug vs release configurations properly separated?
- Is `E2E_BUILD` flag properly used for test builds?
- Are API keys and secrets in environment variables (not code)?
- Is the Info.plist properly configured for all required privacy permissions?

---

## OUTPUT FORMAT

```markdown
# iOS Audit Report: Bitkit iOS

## Build Status
- [ ] Debug build succeeds: YES/NO
- [ ] Release build succeeds: YES/NO
- [ ] E2E build succeeds: YES/NO
- [ ] NotificationService extension builds: YES/NO
- [ ] Unit tests pass: YES/NO
- [ ] UI tests pass: YES/NO
- [ ] Translations validated: YES/NO
- [ ] Code formatting clean: YES/NO

## Architecture Assessment
- [ ] @Observable pattern used correctly: YES/NO
- [ ] All UI updates on @MainActor: YES/NO
- [ ] .task used for async (not .onAppear): YES/NO
- [ ] Proper state management: YES/NO
- [ ] No retain cycles: YES/NO
- [ ] NavigationStack used (not NavigationView): YES/NO
- [ ] Swift 6 concurrency ready: YES/NO

## Security Assessment
- [ ] Secrets stored only in Keychain: YES/NO
- [ ] No secrets in logs: YES/NO
- [ ] Cryptographic operations secure: YES/NO
- [ ] Input validation comprehensive: YES/NO
- [ ] Ed25519/X25519 used correctly: YES/NO
- [ ] LDK data excluded from backup: YES/NO
- [ ] Deep links properly validated: YES/NO
- [ ] Biometric auth implemented: YES/NO

## Bitcoin/Lightning Assessment
- [ ] Lightning operations properly queued: YES/NO
- [ ] StateLocker used for Lightning: YES/NO
- [ ] Node lifecycle properly managed: YES/NO
- [ ] Payment states properly tracked: YES/NO
- [ ] Amount arithmetic safe (no f64): YES/NO
- [ ] RBF properly handled: YES/NO
- [ ] Network configuration correct: YES/NO

## Paykit Integration
- [ ] Paykit properly initialized: YES/NO
- [ ] Executors properly registered: YES/NO
- [ ] Payment requests validated: YES/NO
- [ ] Receipts properly generated: YES/NO
- [ ] Spending limits enforced: YES/NO

## Pubky/Noise Integration
- [ ] Noise handshake correct: YES/NO
- [ ] Session key rotation working: YES/NO
- [ ] Pubky storage paths consistent: YES/NO
- [ ] 404 handling correct: YES/NO

## Background & Notifications
- [ ] Background tasks registered: YES/NO
- [ ] Push notifications handled: YES/NO
- [ ] NotificationService extension works: YES/NO
- [ ] App Group properly configured: YES/NO
- [ ] Extension memory limits respected: YES/NO

## FFI & Rust Integration
- [ ] All FFI calls async-wrapped: YES/NO
- [ ] Callbacks safe from retain cycles: YES/NO
- [ ] Errors properly bridged: YES/NO
- [ ] Memory management correct: YES/NO

## Critical Issues (blocks release)
1. [Issue]: [Location] - [Description]

## High Priority (fix before release)
1. [Issue]: [Location] - [Description]

## Medium Priority (fix soon)
1. [Issue]: [Location] - [Description]

## Low Priority (technical debt)
1. [Issue]: [Location] - [Description]

## What's Actually Good
- [Positive finding with specific evidence]

## Recommended Fix Order
1. [First fix]
2. [Second fix]
```

---

## EXPERT PERSPECTIVES

Review as ALL of these experts simultaneously:

- **iOS Security Engineer**: Keychain usage, secure storage, crypto implementation, input validation, secrets management, backup exclusion
- **Bitcoin/Lightning Engineer**: LDK Node integration, payment flows, channel management, RBF handling, fee calculation, UTXO management
- **SwiftUI Architect**: State management, @Observable patterns, lifecycle management, view composition, data flow, navigation
- **Swift Concurrency Expert**: @MainActor usage, Sendable conformance, actor isolation, data races, async/await correctness
- **Concurrency Specialist**: ServiceQueue patterns, thread safety, FFI boundaries, callback safety
- **Mobile Security Expert**: Background tasks, push notifications, app lifecycle, memory safety, secure communication, extension security
- **Protocol Engineer**: Noise handshake, Pubky storage, session management, key rotation, state machines, Pkarr resolution
- **Paykit Specialist**: Executor registration, payment request handling, receipt generation, directory service integration, spending limits
- **QA Engineer**: Test coverage, edge cases, error paths, user flows, accessibility, localization, UI tests
- **Performance Engineer**: Memory usage, allocations, caching, network efficiency, UI responsiveness, main thread blocking
- **App Extension Expert**: NotificationService extension, App Group, shared Keychain, extension limits, extension-safe APIs

---

## PROTOCOL-SPECIFIC CONSIDERATIONS

### Lightning Network (LDK Node)
- Verify node lifecycle is properly managed (start/stop/restart)
- Check that StateLocker prevents concurrent operations
- Verify payment states are properly tracked and persisted
- Ensure channel state is properly synchronized
- Verify network configuration (regtest/testnet/mainnet) is correct
- Check that events are properly propagated to UI
- Verify force-close is properly gated
- Check that payment preimages are stored for proof

### Bitcoin Operations (BitkitCore)
- Verify ServiceQueue is used for all Core operations
- Check that RBF is properly handled
- Ensure fee calculations are accurate
- Verify wallet synchronization is working
- Check balance calculations (confirmed vs unconfirmed)
- Verify transaction confirmation tracking
- Check address reuse prevention

### Paykit Protocol
- Verify executors are properly registered on startup
- Check payment request parsing and validation
- Ensure receipts are properly generated and stored
- Verify directory service integration
- Check spending limit enforcement
- Verify payment method selection logic
- Check autopay consent flow

### Noise Protocol
- Verify handshake pattern matches specification
- Check session key rotation (rekeying) is implemented
- Ensure channel state machine has no invalid transitions
- Verify rekeying is triggered at appropriate times

### Pubky Storage
- Verify path prefixes are consistent (`/pub/paykit.app/v0/`, `/pub/pubky.app/follows/`)
- Check 404 handling (missing data returns `nil`, not error)
- Verify public vs authenticated operations are separated
- Check homeserver integration patterns
- Verify storage operations use proper error handling

### Ed25519/X25519 Key Usage
- Ed25519 for signatures ONLY
- X25519 for key exchange ONLY
- Never use X25519 keys for signing
- Verify keypair derivation is correct
- Check that keys are properly stored in Keychain

---

## MANUAL VERIFICATION CHECKLIST

Some things cannot be grepped. Manually verify:

### UI/UX Verification
- [ ] Does the UI handle "No Network" states gracefully?
- [ ] Do transitions flicker when data refreshes?
- [ ] Does the app handle background → foreground transitions correctly?
- [ ] Does the node restart properly after being unlocked?
- [ ] Are loading states shown during async operations?
- [ ] Are error states recoverable (retry buttons)?
- [ ] Is haptic feedback used appropriately?

### Security Manual Checks
- [ ] Run the app with Instruments to check for memory leaks
- [ ] Test with airplane mode to verify offline behavior
- [ ] Test deep links with malformed URLs
- [ ] Verify biometric prompt appears for sensitive operations
- [ ] Check that secrets don't appear in debug console

### Performance Manual Checks
- [ ] Does the app launch in < 3 seconds?
- [ ] Does scrolling remain smooth at 60fps?
- [ ] Does the UI freeze during node sync?
- [ ] Is memory usage reasonable (< 200MB typical)?

---

## FINAL CHECKLIST

Before concluding the audit:

1. [ ] Ran all build/test commands and recorded output
2. [ ] Searched for all security-critical patterns (Keychain, secrets, crypto)
3. [ ] Read actual implementation of critical services (LightningService, CoreService, PaykitManager)
4. [ ] Verified Bitcoin/Lightning operations follow proper patterns
5. [ ] Checked SwiftUI architecture follows @Observable patterns
6. [ ] Verified all UI updates happen on @MainActor
7. [ ] Checked ServiceQueue usage for Core/Lightning operations
8. [ ] Verified StateLocker usage for Lightning operations
9. [ ] Checked background task and push notification handling
10. [ ] Reviewed error handling for information leakage
11. [ ] Checked for proper resource cleanup (deinit, task cancellation)
12. [ ] Verified accessibility and localization coverage
13. [ ] Checked test coverage for critical paths
14. [ ] Verified NotificationService extension works correctly
15. [ ] Checked App Group and shared container security
16. [ ] Verified deep link handling is secure
17. [ ] Checked Swift 6 concurrency readiness (Sendable, actor isolation)
18. [ ] Completed manual verification checklist

---

Now audit the iOS codebase.
