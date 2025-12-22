#!/bin/bash
# Test Pubky Ring Integration - iOS
#
# This script runs the Pubky Ring integration tests.
# Usage: ./scripts/test-pubky-ring-integration.sh [--unit-only] [--ui-only] [--flow-only]
#
# Prerequisites:
# - Xcode installed
# - iOS Simulator available and booted

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RUN_UNIT=true
RUN_DEEPLINK=true
RUN_UIFLOW=true
SIMULATOR="iPhone 17 Pro"

# Parse arguments
for arg in "$@"; do
    case $arg in
        --unit-only)
            RUN_DEEPLINK=false
            RUN_UIFLOW=false
            ;;
        --ui-only)
            RUN_UNIT=false
            ;;
        --flow-only)
            RUN_UNIT=false
            RUN_DEEPLINK=false
            ;;
        --simulator=*)
            SIMULATOR="${arg#*=}"
            ;;
    esac
done

echo "=== Pubky Ring Integration Tests (iOS) ==="
echo "Simulator: $SIMULATOR"
echo ""

cd "$PROJECT_DIR"

if [ "$RUN_UNIT" = true ]; then
    echo "1. Running PubkyRingBridge unit tests..."
    xcodebuild test \
        -scheme Bitkit \
        -destination "platform=iOS Simulator,name=$SIMULATOR" \
        -only-testing:BitkitTests/PubkyRingBridgeTests \
        2>&1 | tail -30
    echo ""
fi

if [ "$RUN_DEEPLINK" = true ]; then
    echo "2. Running deep link tests..."
    xcodebuild test \
        -scheme Bitkit \
        -destination "platform=iOS Simulator,name=$SIMULATOR" \
        -only-testing:BitkitUITests/PubkyRingDeepLinkTests \
        2>&1 | tail -30
    echo ""
fi

if [ "$RUN_UIFLOW" = true ]; then
    echo "3. Running UI flow tests (taps on actual UI)..."
    xcodebuild test \
        -scheme Bitkit \
        -destination "platform=iOS Simulator,name=$SIMULATOR" \
        -only-testing:BitkitUITests/PubkyRingUIFlowTests \
        2>&1 | tail -50
    echo ""
fi

echo "=== Tests Complete ==="
echo ""
echo "To run specific tests:"
echo "  --unit-only    Run only unit tests (fast)"
echo "  --ui-only      Run only UI tests"
echo "  --flow-only    Run only UI flow tests (actual taps)"

