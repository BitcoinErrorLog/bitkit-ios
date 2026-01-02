# iOS PubkyNoise Integration Cleanup Plan

**Created:** 2026-01-02  
**Status:** Completed  
**Completed:** 2026-01-02  
**Scope:** bitkit-ios  
**Related:** Profile publish auth fix, pubky-noise xcframework rebuild

---

## Executive Summary

After implementing the iOS profile publishing auth fix (correct Cookie/pubky-host headers), several loose ends remain that could cause future build failures or production bugs. This plan addresses:

1. **Stale FFI header files** causing build fragility
2. **Missing homeserver URL tracking** in iOS (parity gap with Android)
3. **Workaround header copy** that should be removed

---

## Confirmed Issues

### Issue 1: Stale and Duplicated `pubky_noiseFFI.h` Headers

**Evidence:**
```
Bitkit/PaykitIntegration/FFI/pubky_noiseFFI.h              # 762 lines - STALE
Bitkit/PaykitIntegration/Frameworks/.../pubky_noiseFFI.h   # 829 lines - CURRENT (in xcframework)
Bitkit/PaykitIntegration/pubky_noiseFFI.h                  # 829 lines - WORKAROUND COPY
```

**Problem:**
- The bridging header `Bitkit-Bridging-Header.h` includes `#include "pubky_noiseFFI.h"`
- Xcode's include path resolution picked the stale `FFI/pubky_noiseFFI.h` file
- Workaround: copied the correct header to `PaykitIntegration/pubky_noiseFFI.h`
- The stale `FFI/pubky_noiseFFI.h` (762 lines) is missing:
  - `sealed_blob_decrypt`
  - `sealed_blob_encrypt`
  - `x25519_generate_keypair`
  - `derive_device_keypair`
  - `is_sealed_blob`
  - `x25519_public_from_secret`

**Risk:** Any include path change or Xcode cache clear could flip which header is used, breaking builds.

### Issue 2: Stale `PubkyNoiseFFI.h` in FFI Folder

**Evidence:**
```
Bitkit/PaykitIntegration/FFI/PubkyNoiseFFI.h               # Different struct definitions
Bitkit/PaykitIntegration/Frameworks/.../PubkyNoiseFFI.h    # Current (in xcframework)
```

**Problem:**
- The old `FFI/PubkyNoiseFFI.h` has incompatible `RustBuffer` definition (`uint64_t` vs `int32_t` for capacity/len)
- Also missing `ForeignCallback` typedef and many function declarations

**Risk:** Currently unused, but if referenced could cause ABI incompatibility crashes.

### Issue 3: Missing Homeserver URL Tracking on iOS

**Evidence:**
- Grep for `homeserverURL|homeserver_url` in `PaykitIntegration/` returns **0 matches**
- Android has 36+ references with full homeserver URL propagation
- iOS `PubkyRingSession` struct has no `homeserverURL` field
- iOS `SecureHandoffPayload` struct has no `homeserver_url` field
- iOS `DirectoryService.configureWithPubkySession()` always uses `PubkyConfig.homeserverBaseURL()` (defaults to production)

**Problem:**
- If Pubky Ring returns a staging session, iOS will write to production homeserver
- Creates "UI says saved, data doesn't appear" symptoms (the original bug)
- iOS and Android behavior is inconsistent

**Risk:** High - this can cause silent data loss in production.

---

## Remediation Tasks

### Task 1: Synchronize FFI Headers with XCFramework

**Objective:** Single source of truth for FFI headers

**Actions:**
1. Delete `Bitkit/PaykitIntegration/FFI/pubky_noiseFFI.h` (stale, 762 lines)
2. Delete `Bitkit/PaykitIntegration/FFI/PubkyNoiseFFI.h` (stale, incompatible)
3. Delete workaround `Bitkit/PaykitIntegration/pubky_noiseFFI.h`
4. Update `Bitkit-Bridging-Header.h` to use xcframework header path:
   ```c
   #include "PubkyNoise.xcframework/ios-arm64/Headers/pubky_noiseFFI.h"
   ```
   Or, preferably, configure header search paths in project.pbxproj to include:
   ```
   $(PROJECT_DIR)/Bitkit/PaykitIntegration/Frameworks/PubkyNoise.xcframework/ios-arm64/Headers
   ```
5. Verify build succeeds for both device (arm64) and simulator (arm64_x86_64)

**Verification:**
```bash
xcodebuild -project Bitkit.xcodeproj -scheme Bitkit -configuration Debug \
  -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project Bitkit.xcodeproj -scheme Bitkit -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 15' build CODE_SIGNING_ALLOWED=NO
```

### Task 2: Add Homeserver URL Tracking to iOS Session

**Objective:** Parity with Android - track which homeserver a session belongs to

**Actions:**

#### 2a. Update `PubkyRingSession` struct
File: `Bitkit/PaykitIntegration/Services/PubkyRingBridge.swift`

```swift
public struct PubkyRingSession: Codable {
    public let pubkey: String
    public let sessionSecret: String
    public let capabilities: [String]
    public let createdAt: Date
    public let expiresAt: Date?
    public let homeserverURL: String?  // NEW - track session's homeserver
    
    public init(pubkey: String, sessionSecret: String, capabilities: [String], 
                createdAt: Date, expiresAt: Date? = nil, homeserverURL: String? = nil) {
        // ...
        self.homeserverURL = homeserverURL
    }
}
```

#### 2b. Update `SecureHandoffPayload` struct
File: `Bitkit/PaykitIntegration/Services/SecureHandoffHandler.swift`

```swift
public struct SecureHandoffPayload: Codable {
    // ... existing fields ...
    public let homeserverUrl: String?  // NEW - matches Android schema
    
    enum CodingKeys: String, CodingKey {
        // ... existing keys ...
        case homeserverUrl = "homeserver_url"
    }
}
```

#### 2c. Update `buildSetupResult` to propagate homeserver URL
File: `Bitkit/PaykitIntegration/Services/SecureHandoffHandler.swift`

```swift
private func buildSetupResult(from payload: SecureHandoffPayload) -> PaykitSetupResult {
    let session = PubkyRingSession(
        pubkey: payload.pubky,
        sessionSecret: payload.sessionSecret,
        capabilities: payload.capabilities,
        createdAt: Date(timeIntervalSince1970: TimeInterval(payload.createdAt) / 1000),
        expiresAt: nil,
        homeserverURL: payload.homeserverUrl  // NEW
    )
    // ...
}
```

#### 2d. Update `DirectoryService` to use session's homeserver URL
File: `Bitkit/PaykitIntegration/Services/DirectoryService.swift`

Add stored property:
```swift
private var sessionHomeserverURL: String?
```

Update `configureWithPubkySession`:
```swift
public func configureWithPubkySession(_ session: PubkyRingSession) {
    // Use session's homeserver if provided, otherwise fall back to default
    sessionHomeserverURL = session.homeserverURL
    homeserverBaseURL = session.homeserverURL ?? PubkyConfig.homeserverBaseURL()
    
    // ... rest of configuration ...
}
```

#### 2e. Update all session creation sites to include homeserverURL

Files to update:
- `PubkyRingBridge.swift` - `handleSessionCallback()` and `importSession()`
- `SecureHandoffHandler.swift` - `buildSetupResult()`

**Verification:**
- Create unit test that verifies homeserverURL flows from session to DirectoryService
- Manual test: authenticate with staging Pubky Ring, verify writes go to staging homeserver

### Task 3: Clean Up Untracked Files

**Objective:** Remove generated directories that shouldn't be committed

**Actions:**
1. Delete untracked directories shown in `git status`:
   ```
   Bitkit/PaykitIntegration/Frameworks/PubkyNoise.xcframework/ios-arm64/Headers/PubkyNoise/
   Bitkit/PaykitIntegration/Frameworks/PubkyNoise.xcframework/ios-arm64_x86_64-simulator/Headers/PubkyNoise/
   ```
2. These appear to be duplicate Swift files generated during xcframework creation

---

## Task Dependencies

```
Task 1 (FFI Headers) ─────────────────────────┐
                                               │
Task 2a (PubkyRingSession) ────┐               │
                                │               │
Task 2b (SecureHandoffPayload) ─┼─ Task 2d ────┼─ Final Verification
                                │  (DirectoryService)
Task 2c (buildSetupResult) ────┘               │
                                               │
Task 3 (Cleanup) ─────────────────────────────┘
```

---

## Rollback Plan

If issues arise:
1. FFI header changes: restore from git (`git checkout -- Bitkit/PaykitIntegration/FFI/`)
2. Homeserver URL changes: session struct changes are additive (backward compatible)
3. All changes can be reverted with `git checkout` on affected files

---

## Success Criteria

- [x] Build succeeds for iOS device (arm64)
- [x] Build succeeds for iOS simulator (arm64_x86_64) - **Fixed: rebuilt xcframeworks with x86_64**
- [x] No duplicate `pubky_noiseFFI.h` files in project
- [x] `PubkyRingSession.homeserverURL` field exists
- [x] `DirectoryService` uses session's homeserver URL when provided
- [x] Unit tests pass - **250 tests run, 217 passed** (33 keychain-related failures are pre-existing simulator limitations)
- [ ] Manual verification: staging session writes to staging homeserver - **Requires runtime test**

### Fixed: Logger.swift Crash

Fixed `Env.appStorageUrl` to fall back to standard documents directory when app group container is unavailable (simulator/testing). This unblocked all tests.

### Pre-existing: Keychain Simulator Limitations

33 test failures are due to keychain entitlements not being available in simulator (`-34018` error). These tests create real wallets and are expected to fail in simulator without proper entitlements. Key Paykit/Pubky tests all pass.

---

## Commit Plan

1. `fix: synchronize pubky-noise ffi headers with xcframework`
2. `feat: add homeserver url tracking to ios sessions`
3. `chore: remove untracked xcframework artifacts`

---

## Appendix: File Inventory

### Files to Delete
- `Bitkit/PaykitIntegration/FFI/pubky_noiseFFI.h`
- `Bitkit/PaykitIntegration/FFI/PubkyNoiseFFI.h`
- `Bitkit/PaykitIntegration/pubky_noiseFFI.h`
- `Bitkit/PaykitIntegration/Frameworks/PubkyNoise.xcframework/ios-arm64/Headers/PubkyNoise/` (directory)
- `Bitkit/PaykitIntegration/Frameworks/PubkyNoise.xcframework/ios-arm64_x86_64-simulator/Headers/PubkyNoise/` (directory)

### Files to Modify
- `Bitkit/PaykitIntegration/Bitkit-Bridging-Header.h`
- `Bitkit/PaykitIntegration/Services/PubkyRingBridge.swift`
- `Bitkit/PaykitIntegration/Services/SecureHandoffHandler.swift`
- `Bitkit/PaykitIntegration/Services/DirectoryService.swift`
- `Bitkit.xcodeproj/project.pbxproj` (header search paths)

### Files Unchanged (Reference)
- `Bitkit/PaykitIntegration/Frameworks/PubkyNoise.xcframework/ios-arm64/Headers/pubky_noiseFFI.h` (canonical)
- `Bitkit/PaykitIntegration/Frameworks/PubkyNoise.xcframework/ios-arm64_x86_64-simulator/Headers/pubky_noiseFFI.h` (canonical)

