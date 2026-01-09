# iOS Background Lightning: Complete Master Plan

## Context

iOS Notification Service Extensions have hard production limits:

- Memory: 24MB maximum
- Execution time: 20-30 seconds

LDK-node with Tokio runtime exceeds these limits (~25-30MB). This plan provides a phased solution.

### Supported Contract (Explicit)

On iOS, for this release:

- We will notify immediately
- Completion requires the app process to run
- If the user does not open quickly enough, the attempt can fail and sender must retry

---


## PHASE 1: Mitigation (Wake-to-Complete)

### Goal

Ship iOS with graceful degradation: users receive notifications and can complete Lightning operations by opening the app.

### 1.1 Simplify NotificationService.swift

**File**: [BitkitNotification/NotificationService.swift](bitkit-ios/BitkitNotification/NotificationService.swift)

**Remove**:

- All `LDKNode` import/usage
- All `LightningService.shared` calls
- `handleLdkEvent()` method

**Keep**:

- `decryptPayload()` method (uses only Keychain + Crypto)

**Add**:

- `updateNotificationContent()` that sets user-facing text based on type
- Store minimal "incoming" metadata into App Group using `ReceivedTxSheetDetails(type:sats:).save()`

**Acceptance**:

- Notification extension never times out
- No memory termination attributed to extension
- Visible push always shows a sensible message even if decryption fails

### 1.2 Time-Sensitive Notification Categories (NOT Critical Alerts)

**IMPORTANT**: Do NOT use `UNNotificationSound.defaultCritical` - it requires Apple entitlement `com.apple.developer.usernotifications.critical-alerts` and will cause App Store rejection without approval.

**File**: [Bitkit/BitkitApp.swift](bitkit-ios/Bitkit/BitkitApp.swift)

Register categories at app launch:

```swift
func registerNotificationCategories() {
    let openAction = UNNotificationAction(
        identifier: "OPEN_NOW",
        title: "Open Now",
        options: [.foreground]
    )
    
    let incomingPayment = UNNotificationCategory(
        identifier: "INCOMING_PAYMENT",
        actions: [openAction],
        intentIdentifiers: [],
        options: [.customDismissAction]
    )
    
    UNUserNotificationCenter.current().setNotificationCategories([incomingPayment])
}
```

Use `.interruptionLevel = .timeSensitive` (not `.critical`) and default sound.

### 1.3 Notification Content Messaging

| Type | Title | Body |

|------|-------|------|

| `incomingHtlc` | "Payment Incoming" | "Open now to receive - funds are being held" |

| `cjitPaymentArrived` | "Payment Incoming" | "Open now to receive via new channel" |

| `orderPaymentConfirmed` | "Channel Ready" | "Open Bitkit to complete setup" |

| `mutualClose` | "Channel Closed" | "Funds moved to savings" |

### 1.4 Tap-to-Complete UX (Using Real LightningService API)

**File**: [Bitkit/BitkitApp.swift](bitkit-ios/Bitkit/BitkitApp.swift)

When app opens from notification, prioritize in this exact order using **actual existing methods**:

```swift
func handleNotificationOpen(paymentHash: String) async {
    // PRIORITY 1: Start node
    try await LightningService.shared.setup(walletIndex: currentWalletIndex, electrumServerUrl: nil, rgsServerUrl: nil)
    try await LightningService.shared.start(onEvent: { event in
        // Handle payment received event
    })
    
    // PRIORITY 2: Connect to trusted peers (includes Blocktank)
    try await LightningService.shared.connectToTrustedPeers()
    
    // PRIORITY 3: Sync to process pending events
    try await LightningService.shared.sync()
    
    // PRIORITY 4: Everything else (deferred)
    Task.detached(priority: .background) {
        await self.loadAnalytics()
        await self.fetchRemoteConfig()
    }
}
```


### 1.5 Dedicated Incoming Payment Screen

**File**: [Bitkit/Views/Transfer/IncomingPaymentView.swift](bitkit-ios/Bitkit/Views/Transfer/IncomingPaymentView.swift) (new file)

```swift
struct IncomingPaymentView: View {
    @State private var state: IncomingState = .connecting
    
    enum IncomingState {
        case connecting
        case completing
        case completed(sats: UInt64)
        case expired
    }
    
    var body: some View {
        VStack(spacing: 24) {
            switch state {
            case .connecting:
                ProgressView()
                Text("Connecting to Lightning peer...")
            case .completing:
                ProgressView()
                Text("Completing payment...")
            case .completed(let sats):
                Image(systemName: "checkmark.circle.fill")
                Text("Received \(sats) sats")
            case .expired:
                Image(systemName: "exclamationmark.triangle")
                Text("Payment expired or canceled")
                Text("Ask sender to retry").foregroundColor(.secondary)
                
                Button("Retry Now") { retryCompletion() }
                    .buttonStyle(.borderedProminent)
                
                Button("Copy Message for Sender") {
                    UIPasteboard.general.string = 
                        "My wallet needs me to open the app to receive. Please retry in 10 seconds."
                }.buttonStyle(.bordered)
            }
        }
    }
}
```

### 1.6 Two-Push Strategy from Blocktank

Blocktank sends TWO pushes for inbound HTLC:

**Push 1: Silent/Background Push**

```json
{
  "aps": { "content-available": 1 },
  "payment_hash": "...",
  "amount_msat": 100000,
  "type": "incoming_htlc_wake"
}
```

**Push 2: Alert Push**

```json
{
  "aps": {
    "alert": { "title": "Payment Incoming", "body": "Open Bitkit to receive" },
    "sound": "default",
    "interruption-level": "time-sensitive",
    "mutable-content": 1
  },
  "payload": { ... encrypted ... }
}
```

### 1.7 Sender-Side Automatic Retry (Detailed)

Where Bitkit controls sender UX, implement intelligent retry with Blocktank hints.

#### 1.7.1 Failure Classification

**NOT Retryable (fail immediately):**

- Invoice expired
- Amount too high or below minimum
- Unsupported features (onion or invoice feature mismatch)
- Incorrect payment details / unknown payment hash
- Final recipient rejected (wrong preimage, incorrect amount)
- Permanent policy errors

**MAYBE Retryable:**

- Route not found
- Temporary channel failure
- Node unreachable
- Fee or CLTV constraints that could change

#### 1.7.2 Blocktank Forwarding Hint API

**Endpoint** (Blocktank backend work required):

```
GET /lsp/forwarding_hint?recipient=<node_id>&amount_msat=<n>
```

**Response:**

```json
{
  "hint": "retry_now | retry_later | do_not_retry",
  "reason": "disconnected | insufficient_liquidity | recipient_channel_disabled | unknown",
  "recommended_delay_ms": 1000
}
```

#### 1.7.3 Retry Policy Based on Hint

| Hint | Action |
|------|--------|
| `retry_now` | Retry quickly with small backoff |
| `retry_later` | Retry once with longer delay (still within UX window) |
| `do_not_retry` | Fail immediately with actionable message |

#### 1.7.4 Backoff Schedule

Jittered exponential backoff, stop early on success:

| Attempt | Delay |
|---------|-------|
| 1 | Immediately |
| 2 | 1.0s + jitter |
| 3 | 3.0s + jitter |
| 4 (optional) | 7.0s + jitter |

**Hard stop at 10-15 seconds total.**

#### 1.7.5 Implementation (Interim - Ship Now)

Until Blocktank hint API is ready, use simple retry for `route_not_found` only:

```swift
func sendPaymentWithRetry(invoice: String) async throws -> PaymentResult {
    let maxRetries = 3
    let maxTotalTime: TimeInterval = 12  // Hard stop
    let startTime = Date()
    
    for attempt in 1...maxRetries {
        let result = try await LightningService.shared.send(bolt11: invoice, sats: nil, params: nil)
        
        switch result {
        case .success(let payment):
            return .success(payment)
            
        case .failure(let error):
            // Classify error
            if isNonRetryable(error) {
                return .failure(error)
            }
            
            // Check time budget
            if Date().timeIntervalSince(startTime) > maxTotalTime {
                return .failure(error)
            }
            
            // Backoff with jitter
            let baseDelay: TimeInterval = attempt == 1 ? 1.0 : (attempt == 2 ? 3.0 : 7.0)
            let jitter = Double.random(in: 0...0.5)
            try await Task.sleep(nanoseconds: UInt64((baseDelay + jitter) * 1_000_000_000))
        }
    }
    
    return .failure(.routeNotFound)
}

private func isNonRetryable(_ error: PaymentError) -> Bool {
    switch error {
    case .invoiceExpired, .amountTooHigh, .amountBelowMinimum,
         .unsupportedFeatures, .incorrectPaymentDetails,
         .recipientRejected, .permanentPolicyError:
        return true
    case .routeNotFound, .temporaryChannelFailure, .nodeUnreachable:
        return false
    }
}
```

#### 1.7.6 Implementation (Target - With Blocktank Hint)

Once Blocktank exposes `/lsp/forwarding_hint`:

```swift
func sendPaymentWithBlocktankHint(invoice: String, recipientNodeId: String, amountMsat: UInt64) async throws -> PaymentResult {
    for attempt in 1...4 {
        let result = try await LightningService.shared.send(bolt11: invoice, sats: nil, params: nil)
        
        guard case .failure(let error) = result, !isNonRetryable(error) else {
            return result
        }
        
        // Query Blocktank for hint
        let hint = try await BlocktankService.shared.getForwardingHint(
            recipientNodeId: recipientNodeId,
            amountMsat: amountMsat
        )
        
        switch hint.hint {
        case .doNotRetry:
            return .failure(error)
        case .retryNow:
            try await Task.sleep(nanoseconds: UInt64(hint.recommendedDelayMs ?? 1000) * 1_000_000)
        case .retryLater:
            try await Task.sleep(nanoseconds: UInt64(hint.recommendedDelayMs ?? 5000) * 1_000_000)
        }
    }
    
    return .failure(.routeNotFound)
}
```

#### 1.7.7 UI Messaging for Failure

After exhausting retries, show:

```swift
struct PaymentFailedView: View {
    let error: PaymentError
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.orange)
            
            Text("Route Not Found")
                .font(.headline)
            
            // iOS wake-to-complete hint
            Text("Recipient may need to open their wallet to receive. Try again in a few seconds.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button("Retry Now") { retryPayment() }
                .buttonStyle(.borderedProminent)
        }
    }
}
```

### 1.8 Blocktank HTLC Hold Enhancement (Optional, Non-Custodial)

Server-side HTLC parking:

1. When HTLC arrives for offline recipient, hold it (do not forward yet)
2. Send push notification (both silent and alert)
3. Wait for recipient connection (10-25 seconds)
4. If recipient connects: forward HTLC
5. If timeout: fail HTLC gracefully with `temporary_channel_failure`

---

## PHASE 1.5: Background Push Handler 

### Goal

When iOS allows, complete receive without immediate user open; otherwise fall back to Phase 1 UX.

### Important: Silent Push Reliability

**Silent push notifications are BEST-EFFORT ONLY.** Apple documentation confirms iOS may:

- Delay or drop silent pushes based on device state
- Throttle apps that fail to complete background work efficiently
- Not deliver if Low Power Mode is enabled or Background App Refresh is off

**This phase is an optimization, not a guarantee.** The Phase 1 alert push fallback is the reliable path. Design all UX assuming silent push may not work.

### 1.5.1 Implement Silent Push in Real AppDelegate

**CRITICAL**: The plan previously referenced `AppDelegate_integration.swift` which is NOT compiled (it's in `membershipExceptions`).

**File**: [Bitkit/BitkitApp.swift](bitkit-ios/Bitkit/BitkitApp.swift) - the REAL AppDelegate used by SwiftUI

Add to the existing `AppDelegate` class:

```swift
func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
) {
    guard let type = userInfo["type"] as? String, type == "incoming_htlc_wake" else {
        completionHandler(.noData)
        return
    }
    
    var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    backgroundTaskID = application.beginBackgroundTask(withName: "ProcessIncomingHTLC") {
        Task { try? await LightningService.shared.stop() }
        application.endBackgroundTask(backgroundTaskID)
    }
    
    Task {
        defer { application.endBackgroundTask(backgroundTaskID) }
        
        do {
            try await processIncomingHTLCInBackground(userInfo: userInfo)
            completionHandler(.newData)
        } catch {
            Logger.error("Background HTLC processing failed: \(error)")
            completionHandler(.failed)
        }
    }
}
```

### 1.5.2 Lightning Background Handler (Using Real API)

```swift
private func processIncomingHTLCInBackground(userInfo: [AnyHashable: Any]) async throws {
    // Acquire lock to prevent concurrent node manipulation
    try StateLocker.lock(.lightning)
    defer { try? StateLocker.unlock(.lightning) }
    
    // 1. Start node with event handler
    try await LightningService.shared.setup(walletIndex: currentWalletIndex, electrumServerUrl: nil, rgsServerUrl: nil)
    try await LightningService.shared.start(onEvent: { event in
        // Handle .paymentReceived
    })
    
    // 2. Connect to trusted peers (includes Blocktank)
    try await LightningService.shared.connectToTrustedPeers()
    
    // 3. Sync to process pending events
    try await LightningService.shared.sync()
    
    // 4. Brief wait for receive event (bounded)
    try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds max
    
    // 5. Stop node
    try await LightningService.shared.stop()
}
```



### 1.5.3 Metrics (Observability)

Add local logging counters:

- Silent push received
- Background handler started
- Node start latency
- Connected-to-peer latency
- Receive success vs fallback-to-alert

---

## PHASE 2: KMP Evaluation (HIGH-RISK - Do Not Implement Without Re-evaluation)

### Status After Audit: NOT RECOMMENDED AS CURRENTLY DESCRIBED

**Reason**: Lightning receive isn't a simple "sign a claim" operation. To settle an incoming HTLC you need:

- Node online
- Handle onion messages
- Update channel state
- Reveal preimages

Doing this inside a Notification Service Extension implies either:

- Fitting a real Lightning implementation inside ~24MB, OR
- Redefining the protocol so a server can settle on your behalf (custody/trust)

### If Re-evaluating KMP

The **highest ROI** use of KMP would be:

- Shared crypto + protocol plumbing for Paykit/Atomicity (where you control the protocol surface)
- NOT "run Lightning receive in an iOS extension"

### KMP Foundation Work (Only If Protocol Redefined)

If Blocktank develops a "claim preparation" API where the wallet only needs to:

1. Derive preimage (pure crypto)
2. Sign a prepared transaction (secp256k1)
3. HTTP calls to LSP

Then KMP could work. But this requires significant Blocktank protocol changes first.


---

## Testing Matrix

### bitkit-ios TestFlight Testing

| Scenario | Expected Behavior |

|----------|-------------------|

| App foreground | Notification displays, payment auto-completes |

| App backgrounded | Silent push attempts completion; alert shows if needed |

| App killed | Alert push shows; tap opens app and completes |

| Low Power Mode | May throttle; alert push is fallback |

| After reboot, before unlock | Keychain unavailable; wait for user |

| Background App Refresh disabled | Alert push is fallback |

| Notifications disabled | No notification; must open app manually |

### Metrics to Track

- Peak RSS during extension run (must be < 24MB)
- Peak RSS during background handler (must be < 100MB)
- Cold-start to peer-connected latency (target < 3s)
- Background task completion rate
- Payment success rate within 15s of push

### CI Integration

- Add RSS measurement to Xcode build scheme
- Test under iOS background execution constraints (Xcode: Debug -> Simulate Background Fetch)
- Run on production-signed builds (critical - memory limits not enforced on debug)

---

## Summary

| Phase | Timeline | Priority | Key Deliverables |

|-------|----------|----------|------------------|

| Phase 1 | 2 weeks | HIGH | Remove LDK from extension, wake-to-complete UX, real API usage, two-push strategy |

| Phase 1.5 | 4-6 weeks | HIGH | Silent push in real AppDelegate, unified node lifecycle, Paykit BG task fix |

| Phase 2 | TBD | LOW/HOLD | KMP evaluation only if Blocktank protocol redefined |


---

## Cross-Repo Impact

### bitkit-ios

- Notification extension: remove LDK linkage
- AppDelegate: add silent push in real SwiftUI AppDelegate
- Add `BackgroundNodeHelper` for unified node lifecycle
- Deep link parity for `bitkit://subscriptions`

### bitkit-android

- Confirm `PaykitPollingWorker` node-ready wait matches production behavior
- No new ProGuard work needed
