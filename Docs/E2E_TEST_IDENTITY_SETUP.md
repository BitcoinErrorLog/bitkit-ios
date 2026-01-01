# E2E Test Identity Setup Guide

This guide explains how to set up a test identity for running production E2E tests against the real Pubky homeserver.

## Prerequisites

1. **Pubky-ring app** installed on your test device/simulator
2. **Valid invite code** for the production Pubky homeserver (if creating new identity)
3. Access to environment variable configuration

## Pre-configured Test Identities

Test identity backup files are available in the workspace:

```
/Users/john/vibes-dev/credentials/
├── ios-ai-tester-backup-2026-01-01_12-16-19.pkarr    # iOS test identity
└── android-ai-tester-backup-2026-01-01_12-18-17.pkarr # Android test identity
```

**Password for both files: `tester`**

### Importing Pre-configured Identity (Recommended)

1. Open Pubky-ring on your test device/simulator
2. Tap "Add pubky" → "Import"
3. Select "Import from backup file"
4. Choose the appropriate `.pkarr` file:
   - iOS: `ios-ai-tester-backup-2026-01-01_12-16-19.pkarr`
   - Android: `android-ai-tester-backup-2026-01-01_12-18-17.pkarr`
5. Enter password: `tester`
6. The test identity will be imported and ready to use

**Pre-decrypted Pubkeys:**

| Platform | Pubkey (z-base-32) |
|----------|-------------------|
| iOS | `n3pfudgxncn8i1e6icuq7umoczemjuyi6xdfrfczk3o8ej3e55my` |
| Android | `tjtigrhbiinfwwh8nwwgbq4b17t71uqesshsd7zp37zt3huwmwyo` |

7. Set the environment variable:
```bash
# For iOS tests
export E2E_TEST_PUBKEY="n3pfudgxncn8i1e6icuq7umoczemjuyi6xdfrfczk3o8ej3e55my"

# For cross-platform follow tests, set the other as secondary
export E2E_SECONDARY_PUBKEY="tjtigrhbiinfwwh8nwwgbq4b17t71uqesshsd7zp37zt3huwmwyo"
```

## Step 1: Generate New Test Identity (Alternative)

### Option A: Using Pubky-ring

1. Open Pubky-ring on your test device
2. Tap "Add pubky" → "New pubky"
3. **IMPORTANT**: Save the mnemonic phrase securely
4. Select "Default" homeserver (production)
5. Enter your invite code when prompted
6. Note the generated pubkey (z-base-32 format)

### Option B: Using CLI Tools

```bash
# If you have the pubky-sdk CLI available:
pubky generate-keypair
# This outputs: mnemonic, secret_key, public_key
```

## Step 2: Record Test Credentials

Store the following securely:

| Credential | Description | Example |
|------------|-------------|---------|
| `mnemonic` | 12-word recovery phrase | "word1 word2 word3..." |
| `pubkey` | Z-base-32 public key | "8um71us3fyw..." |
| `homeserver` | Homeserver pubkey | "8um71us3fyw6h8wbcxb5ar3rwusy1a6u49956ikzojg3gcwd1dty" |

**Never commit these credentials to git!**

## Step 3: Configure Environment Variables

### For Local Development

Add to your shell profile (`.zshrc` or `.bashrc`):

```bash
# Bitkit iOS E2E Test Configuration
export E2E_TEST_PUBKEY="your-test-pubkey-here"
export E2E_SECONDARY_PUBKEY="optional-secondary-pubkey"  # For follow tests
```

### For Xcode

1. Edit Scheme → Run → Arguments → Environment Variables
2. Add:
   - `E2E_TEST_PUBKEY` = your test pubkey
   - `E2E_SECONDARY_PUBKEY` = secondary pubkey (optional)

### For CI/CD (GitHub Actions)

Add secrets to your repository:

1. Go to Settings → Secrets and variables → Actions
2. Add repository secrets:
   - `E2E_TEST_PUBKEY`
   - `E2E_SECONDARY_PUBKEY`
   - `E2E_TEST_MNEMONIC` (if needed for Pubky-ring setup)

## Step 4: Configure Pubky-ring for E2E

### Manual Setup

1. Open Pubky-ring on the test device/simulator
2. Import the test identity using the mnemonic
3. Ensure it's signed in to the production homeserver

### Automated Setup (Future)

The E2E tests can automatically configure Pubky-ring if:
- `E2E_TEST_MNEMONIC` environment variable is set
- Pubky-ring supports auto-import via deep link

## Step 5: Run E2E Tests

### Command Line

```bash
# Set environment variables
export E2E_TEST_PUBKEY="your-pubkey"

# Run all E2E tests
./scripts/run-e2e-tests.sh

# Run specific test
./scripts/run-e2e-tests.sh testRealProfilePublish
```

### Xcode

1. Ensure environment variables are set in the scheme
2. Select BitkitUITests target
3. Run tests (Cmd+U)

## Test Isolation

Each test run generates a unique `E2E_RUN_ID` to isolate test data:

- Profile names include the run ID: `"E2E Test [abc12345]"`
- This prevents conflicts between concurrent test runs
- Test data can be identified and cleaned up

## Creating a Secondary Test Identity

For follow/contact tests, you need a second pubkey to add/remove:

1. Create another identity in Pubky-ring (different device or account)
2. Set `E2E_SECONDARY_PUBKEY` to this pubkey
3. Tests like `testRealAddFollow` will use this pubkey

## Troubleshooting

### "Test skipped: requires E2E_TEST_PUBKEY"

Environment variable not set. Verify:
```bash
echo $E2E_TEST_PUBKEY
```

### "Pubky-ring app not installed"

Install Pubky-ring on the simulator:
```bash
xcrun simctl install booted /path/to/pubkyring.app
```

### Session not establishing

1. Verify Pubky-ring has the test identity imported
2. Check the identity is signed in to homeserver
3. Check console logs for callback handling

### Profile publish fails

1. Verify session is active (not expired)
2. Check network connectivity to homeserver
3. Verify the test pubkey has write access

## Security Considerations

1. **Test identities only**: Never use production user credentials
2. **Separate from production**: Use dedicated test pubkeys
3. **Rotate periodically**: Generate new test identities occasionally
4. **Secure storage**: Store mnemonics in secure secret managers
5. **CI secrets**: Use GitHub encrypted secrets, never commit

## Related Documentation

- [PAYKIT_TESTING.md](PAYKIT_TESTING.md) - General Paykit testing guide
- [PAYKIT_ARCHITECTURE.md](PAYKIT_ARCHITECTURE.md) - Paykit architecture overview
- [PAYKIT_SETUP.md](PAYKIT_SETUP.md) - Paykit setup instructions

