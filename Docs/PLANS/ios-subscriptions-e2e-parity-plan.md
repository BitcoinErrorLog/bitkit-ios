# iOS Subscriptions E2E Parity Plan

This plan brings iOS Bitkit subscription testing to parity with Android.

## Overview

Android implementation is complete with:
- ✅ Compose `testTag` modifiers on all subscription UI elements
- ✅ `adb_tap_by_test_tag` helper for reliable UI automation
- ✅ Identity sync fix in `PubkyRingBridge.persistSession`
- ✅ Unit tests: `SendSubscriptionProposalE2ETest`, `FullSubscriptionE2EFlowTest`
- ✅ Updated `03-subscription-proposal.sh` E2E test script

## Phase 1: iOS UI Accessibility Identifiers

Add SwiftUI accessibility identifiers to match Android testTags.

### Files to Update

1. **`Bitkit/Views/Paykit/PaykitSubscriptionsView.swift`**
   - Add `.accessibilityIdentifier("subscriptions_create_button")` to create button
   - Add `.accessibilityIdentifier("subscriptions_tab_my_subscriptions")` to My Subscriptions tab
   - Add `.accessibilityIdentifier("subscriptions_tab_proposals")` to Proposals tab

2. **`Bitkit/Views/Paykit/CreateSubscriptionView.swift`** (or equivalent dialog)
   - Add `.accessibilityIdentifier("create_sub_recipient")` to recipient TextField
   - Add `.accessibilityIdentifier("create_sub_amount")` to amount TextField
   - Add `.accessibilityIdentifier("create_sub_send")` to Send Proposal button

3. **`Bitkit/Views/Paykit/ProposalRowView.swift`** (or equivalent)
   - Add `.accessibilityIdentifier("proposal_row_\(proposal.id)")` to each row
   - Add `.accessibilityIdentifier("proposal_accept_\(proposal.id)")` to accept button

4. **`Bitkit/Views/Paykit/SubscriptionRowView.swift`** (or equivalent)
   - Add `.accessibilityIdentifier("subscription_row_\(subscription.id)")` to each row

### Example Pattern

```swift
Button("Create Subscription") { ... }
    .accessibilityIdentifier("subscriptions_create_button")

TextField("Recipient Pubkey", text: $recipientPubkey)
    .accessibilityIdentifier("create_sub_recipient")
```

## Phase 2: iOS Identity Sync Fix

Verify and apply the same identity sync fixes as Android.

### Files to Review

1. **`Bitkit/PaykitIntegration/Services/PubkyRingBridge.swift`**
   - Ensure `persistSession()` calls `KeyManager.storePublicKey(session.pubkey)`
   - Ensure `restoreSessions()` calls `KeyManager.storePublicKey` for each restored session
   - Add `syncIdentityFromCachedSession()` method if not present

2. **`Bitkit/PaykitIntegration/KeyManager.swift`**
   - Verify `storePublicKey(_:)` method exists and stores to Keychain
   - Verify `getCurrentPublicKeyZ32()` returns the stored key

3. **`Bitkit/PaykitIntegration/ViewModels/SubscriptionsViewModel.swift`**
   - Call `pubkyRingBridge.syncIdentityFromCachedSession()` in `init`
   - Call before `loadIncomingProposals()`, `sendSubscriptionProposal()`, `acceptProposal()`, `declineProposal()`

## Phase 3: E2E Test Script Enhancement

Update the E2E test script to support iOS.

### Files to Update

1. **`e2e-tests/lib/simctl-utils.sh`**
   - Add `simctl_tap_by_accessibility_id()` function using `xcuitest` or `appium`
   - Alternative: Use coordinate-based tapping with `simctl io` screenshots and OCR

2. **`e2e-tests/tests/03-subscription-proposal.sh`**
   - Add iOS variants of `create_proposal_ios()` and `discover_proposal_ios()`
   - Use accessibility identifiers for UI automation

3. **`e2e-tests/fixtures/coordinates/ios-bitkit.json`**
   - Add coordinates for subscription UI elements (fallback)
   - Add accessibility_id fields matching SwiftUI identifiers

### iOS UI Automation Options

1. **XCUITest (Recommended for CI)**
   ```swift
   // In BitkitUITests/
   func testSubscriptionProposalFlow() {
       let app = XCUIApplication()
       app.buttons["subscriptions_create_button"].tap()
       app.textFields["create_sub_recipient"].typeText("...")
   }
   ```

2. **simctl for screenshots + coordinate-based taps**
   ```bash
   xcrun simctl io $UDID screenshot /tmp/screen.png
   xcrun simctl io $UDID tap $x $y
   ```

## Phase 4: iOS Unit Tests

Create unit tests matching Android.

### Files to Create

1. **`BitkitTests/PaykitIntegration/SendSubscriptionProposalE2ETest.swift`**
   ```swift
   import XCTest
   @testable import Bitkit

   final class SendSubscriptionProposalE2ETest: XCTestCase {
       func testSendProposalPublishesToDirectory() async throws {
           // Mock DirectoryService, KeyManager, PubkyRingBridge
           // Verify publishSubscriptionProposal is called with expected data
       }
   }
   ```

2. **`BitkitTests/PaykitIntegration/FullSubscriptionE2EFlowTest.swift`**
   ```swift
   final class FullSubscriptionE2EFlowTest: XCTestCase {
       func testFullE2EFlow_ASendsProposal_BDiscoveryAndAccepts_BSeesInList() async throws {
           // Phase 1: A sends proposal
           // Phase 2: B discovers proposal
           // Phase 3: B accepts proposal
           // Phase 4: B sees subscription in list
       }
   }
   ```

## Phase 5: Evidence Collection

Run E2E tests and collect screenshots.

### Evidence Directory Structure

```
e2e-tests/evidence/2026-01-XX_ios_subscriptions/
├── 01-A-create-dialog-filled.png
├── 02-A-after-send-success.png
├── 03-B-proposals-with-incoming.png
├── 04-B-accept-dialog.png
├── 05-B-subscription-in-list.png
├── 06-B-subscription-detail.png
└── README.md
```

### Commands

```bash
# Screenshot from simulator
xcrun simctl io $UDID screenshot /path/to/screenshot.png

# Boot simulator
xcrun simctl boot "iPhone 15 Pro"

# Install app
xcrun simctl install booted /path/to/Bitkit.app

# Launch app
xcrun simctl launch booted to.bitkit.dev
```

## Dependencies

- iOS Simulator with iPhone 15 Pro or similar
- Xcode 15+ with XCUITest support
- Two test identities in `/credentials/` with PKARR backups
- Live homeserver access for real E2E testing

## Success Criteria

1. ✅ All accessibility identifiers added to subscription UI
2. ✅ Identity sync fix verified in iOS PubkyRingBridge
3. ✅ Unit tests pass: `SendSubscriptionProposalE2ETest`, `FullSubscriptionE2EFlowTest`
4. ✅ E2E script captures all 6 screenshots showing both sides of the flow
5. ✅ Evidence folder with README documenting successful run

## Timeline Estimate

- Phase 1: 2 hours (UI identifiers)
- Phase 2: 1 hour (identity sync verification)
- Phase 3: 3 hours (E2E script enhancement)
- Phase 4: 2 hours (unit tests)
- Phase 5: 1 hour (evidence collection)

Total: ~9 hours

