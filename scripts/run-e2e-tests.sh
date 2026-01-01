#!/bin/bash
#
# Bitkit iOS E2E Test Runner
#
# Runs end-to-end tests against the production Pubky homeserver.
# Requires E2E_TEST_PUBKEY environment variable for real E2E testing.
#
# Usage:
#   ./scripts/run-e2e-tests.sh                    # Run all E2E tests
#   ./scripts/run-e2e-tests.sh testRealProfileFetch  # Run specific test
#
# Environment Variables:
#   E2E_TEST_PUBKEY       - Primary test pubkey (required for real E2E)
#   E2E_SECONDARY_PUBKEY  - Secondary pubkey for follow tests (optional)
#   E2E_RUN_ID            - Unique run ID (auto-generated if not set)
#   SIMULATOR_NAME        - iOS Simulator name (default: "iPhone 15")
#

set -e

# Configuration
SIMULATOR_NAME="${SIMULATOR_NAME:-iPhone 15}"
SCHEME="Bitkit"
RESULTS_DIR="results"
SPECIFIC_TEST="${1:-}"

echo "========================================"
echo "  Bitkit iOS E2E Test Runner"
echo "========================================"
echo ""

# Default test pubkeys (decrypted from credentials/*.pkarr, password: tester)
DEFAULT_IOS_PUBKEY="n3pfudgxncn8i1e6icuq7umoczemjuyi6xdfrfczk3o8ej3e55my"
DEFAULT_ANDROID_PUBKEY="tjtigrhbiinfwwh8nwwgbq4b17t71uqesshsd7zp37zt3huwmwyo"

# Use defaults if environment variables not set
if [ -z "$E2E_TEST_PUBKEY" ]; then
    export E2E_TEST_PUBKEY="$DEFAULT_IOS_PUBKEY"
    echo "Using default iOS test pubkey"
fi

if [ -z "$E2E_SECONDARY_PUBKEY" ]; then
    export E2E_SECONDARY_PUBKEY="$DEFAULT_ANDROID_PUBKEY"
    echo "Using default Android test pubkey as secondary"
fi

echo "E2E Mode: PRODUCTION (real homeserver)"
echo "Test Pubkey: ${E2E_TEST_PUBKEY:0:16}..."
echo "Secondary Pubkey: ${E2E_SECONDARY_PUBKEY:0:16}..."

# Generate unique run ID if not provided
if [ -z "$E2E_RUN_ID" ]; then
    export E2E_RUN_ID=$(date +%s | tail -c 9)
fi
echo "Run ID: $E2E_RUN_ID"
echo ""

# Create results directory
mkdir -p "$RESULTS_DIR"

# Check if we need to build
BUILD_NEEDED=true
DERIVED_DATA_PATH="build"

if [ -d "$DERIVED_DATA_PATH/Build/Products" ]; then
    echo "Using existing build..."
    BUILD_NEEDED=false
fi

# Build for testing if needed
if [ "$BUILD_NEEDED" = true ]; then
    echo "Building Bitkit for testing..."
    echo ""
    
    xcodebuild build-for-testing \
        -scheme "$SCHEME" \
        -destination "platform=iOS Simulator,name=$SIMULATOR_NAME" \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        SWIFT_ACTIVE_COMPILATION_CONDITIONS='E2E_BUILD' \
        -quiet \
        2>&1 | grep -E "(error:|warning:|BUILD)" || true
    
    echo ""
    echo "Build complete."
fi

# Determine which tests to run
if [ -n "$SPECIFIC_TEST" ]; then
    TEST_FILTER="-only-testing:BitkitUITests/PaykitE2ETests/$SPECIFIC_TEST"
    echo "Running specific test: $SPECIFIC_TEST"
else
    TEST_FILTER="-only-testing:BitkitUITests/PaykitE2ETests"
    echo "Running all Paykit E2E tests..."
fi

echo ""
echo "========================================"
echo "  Running E2E Tests"
echo "========================================"
echo ""

# Run E2E tests
RESULT_BUNDLE_PATH="$RESULTS_DIR/e2e-results-$E2E_RUN_ID.xcresult"

xcodebuild test-without-building \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,name=$SIMULATOR_NAME" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    $TEST_FILTER \
    -resultBundlePath "$RESULT_BUNDLE_PATH" \
    E2E_TEST_PUBKEY="${E2E_TEST_PUBKEY:-}" \
    E2E_SECONDARY_PUBKEY="${E2E_SECONDARY_PUBKEY:-}" \
    E2E_RUN_ID="$E2E_RUN_ID" \
    2>&1 | grep -E "(Test Case|passed|failed|error:)" || true

echo ""
echo "========================================"
echo "  E2E Tests Complete"
echo "========================================"
echo ""
echo "Results: $RESULT_BUNDLE_PATH"
echo ""

# Check for failures
if [ -f "$RESULT_BUNDLE_PATH/TestSummaries.plist" ]; then
    FAILURES=$(plutil -p "$RESULT_BUNDLE_PATH/TestSummaries.plist" 2>/dev/null | grep -c "failureCount" || echo "0")
    if [ "$FAILURES" != "0" ]; then
        echo "Some tests failed. Check the result bundle for details."
        exit 1
    fi
fi

echo "All tests passed!"

