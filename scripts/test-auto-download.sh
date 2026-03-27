#!/usr/bin/env bash
# test-auto-download.sh — Automated map auto-download E2E test
#
# Connects to a MOHAA server that has a map the client doesn't, and verifies
# the MapDownloader system detects the missing map, downloads it, installs it,
# and reconnects successfully.
#
# Prerequisites:
#   - Built libopenmohaa.so deployed to project/bin/
#   - Game assets in ~/.local/share/openmohaa/ (main/)
#   - godot in PATH (Godot 4.2+)
#   - A MOHAA server running with a custom map the client doesn't have
#
# Usage:
#   ./scripts/test-auto-download.sh --server=127.0.0.1:12203
#   ./scripts/test-auto-download.sh --server=127.0.0.1:12203 --force-map=dm/dm_rockbound
#   ./scripts/test-auto-download.sh --server=127.0.0.1:12203 --timeout=30 --download-timeout=120
#
# Exit codes:
#   0  Test passed
#   1  Test failed
#   2  Setup/infrastructure error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$REPO_ROOT/project"
LOG_DIR="$REPO_ROOT/test-results"
SUMMARY_FILE="$LOG_DIR/auto-download-test-latest.summary"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

# Defaults
SERVER=""
GAME_FILTER="aa"
TIMEOUT=30
DOWNLOAD_TIMEOUT=120
SETTLE=5
FORCE_MAP=""

# Parse args
for arg in "$@"; do
    case "$arg" in
        --server=*)           SERVER="${arg#--server=}" ;;
        --game=*)             GAME_FILTER="${arg#--game=}" ;;
        --timeout=*)          TIMEOUT="${arg#--timeout=}" ;;
        --download-timeout=*) DOWNLOAD_TIMEOUT="${arg#--download-timeout=}" ;;
        --settle=*)           SETTLE="${arg#--settle=}" ;;
        --force-map=*)        FORCE_MAP="${arg#--force-map=}" ;;
        --help|-h)
            echo "Usage: $0 --server=IP:PORT [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --server=IP:PORT        Server to connect to (required)"
            echo "  --game=aa|sh|bt         Game variant (default: aa)"
            echo "  --timeout=30            Connect timeout in seconds"
            echo "  --download-timeout=120  Download timeout in seconds"
            echo "  --settle=5             Settle time after final map load"
            echo "  --force-map=MAP         Send 'rcon map MAP' to trigger download"
            echo ""
            echo "Example (localhost with custom map on rotation):"
            echo "  $0 --server=127.0.0.1:12203"
            echo ""
            echo "Example (force the server to change to a custom map):"
            echo "  $0 --server=127.0.0.1:12203 --force-map=dm/dm_rockbound"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Use --help for usage." >&2
            exit 2
            ;;
    esac
done

if [[ -z "$SERVER" ]]; then
    echo "ERROR: --server=IP:PORT is required." >&2
    echo "Usage: $0 --server=IP:PORT [OPTIONS]" >&2
    exit 2
fi

# Setup
mkdir -p "$LOG_DIR"

echo "========================================"
echo " Map Auto-Download E2E Test"
echo "========================================"

# Check prerequisites
if ! command -v godot &>/dev/null; then
    echo "ERROR: 'godot' not found in PATH" >&2
    exit 2
fi

if [[ ! -f "$PROJECT_DIR/bin/libopenmohaa.so" ]]; then
    echo "ERROR: project/bin/libopenmohaa.so not found. Run ./build.sh first." >&2
    exit 2
fi

# Resolve game variant
case "$GAME_FILTER" in
    aa|AA|0) GAME_ID=0 ;;
    sh|SH|1) GAME_ID=1 ;;
    bt|BT|2) GAME_ID=2 ;;
    *)
        echo "ERROR: Unknown game '$GAME_FILTER'. Use aa, sh, bt." >&2
        exit 2
        ;;
esac

echo "Server:           $SERVER"
echo "Game:             $GAME_FILTER (com_target_game=$GAME_ID)"
echo "Connect timeout:  ${TIMEOUT}s"
echo "Download timeout: ${DOWNLOAD_TIMEOUT}s"
echo "Settle time:      ${SETTLE}s"
echo "Force map:        ${FORCE_MAP:-"(none — rely on server rotation)"}"
echo ""

# Build godot args
GODOT_ARGS=(--headless res://TestAutoDownload.tscn --)
GODOT_ARGS+=(--server="$SERVER")
GODOT_ARGS+=(--game="$GAME_ID")
GODOT_ARGS+=(--timeout="$TIMEOUT")
GODOT_ARGS+=(--download-timeout="$DOWNLOAD_TIMEOUT")
GODOT_ARGS+=(--settle="$SETTLE")
if [[ -n "$FORCE_MAP" ]]; then
    GODOT_ARGS+=(--force-map="$FORCE_MAP")
fi

LOG_FILE="$LOG_DIR/auto-download-test-$TIMESTAMP.log"

echo "Launching Godot with: ${GODOT_ARGS[*]}"
echo ""

cd "$PROJECT_DIR"

# Run with timeout: connect + download + reconnect + settle + overhead
TOTAL_TIMEOUT=$(( TIMEOUT + DOWNLOAD_TIMEOUT + TIMEOUT + SETTLE + 30 ))
set +e
timeout "${TOTAL_TIMEOUT}s" godot "${GODOT_ARGS[@]}" 2>&1 | tee "$LOG_FILE"
EXIT_CODE=${PIPESTATUS[0]}
set -e

echo ""
echo "========================================"
echo " Test Output Analysis"
echo "========================================"

# Parse results from log
PASS_COUNT=$(grep -c "\[✓\]" "$LOG_FILE" 2>/dev/null) || PASS_COUNT=0
FAIL_COUNT=$(grep -c "\[✗\]" "$LOG_FILE" 2>/dev/null) || FAIL_COUNT=0
SKIP_COUNT=$(grep -c "\[—\]" "$LOG_FILE" 2>/dev/null) || SKIP_COUNT=0
WARN_COUNT=$(grep -c "\[⚠\]" "$LOG_FILE" 2>/dev/null) || WARN_COUNT=0

echo "Passed:   $PASS_COUNT"
echo "Failed:   $FAIL_COUNT"
echo "Skipped:  $SKIP_COUNT"
echo "Warnings: $WARN_COUNT"

# Show detailed results
echo ""
grep "AutoDownloadTest:" "$LOG_FILE" 2>/dev/null | grep -E "(PASS|FAIL|SKIP|WARN|OVERALL)" || true

# Write summary
{
    echo "auto-download-test $TIMESTAMP"
    echo "server=$SERVER game=$GAME_FILTER"
    echo "pass=$PASS_COUNT fail=$FAIL_COUNT skip=$SKIP_COUNT warn=$WARN_COUNT"
    echo "exit=$EXIT_CODE"
    if [[ $FAIL_COUNT -gt 0 ]]; then
        echo "result=FAIL"
    elif [[ $PASS_COUNT -gt 0 ]]; then
        echo "result=PASS"
    else
        echo "result=UNKNOWN"
    fi
} > "$SUMMARY_FILE"

echo ""
if [[ $FAIL_COUNT -gt 0 ]]; then
    echo "RESULT: FAIL"
    exit 1
elif [[ $EXIT_CODE -eq 124 ]]; then
    echo "RESULT: FAIL (timeout — godot exceeded ${TOTAL_TIMEOUT}s)"
    exit 1
elif [[ $PASS_COUNT -gt 0 ]]; then
    echo "RESULT: PASS"
    exit 0
else
    echo "RESULT: UNKNOWN (no assertions)"
    exit 1
fi
