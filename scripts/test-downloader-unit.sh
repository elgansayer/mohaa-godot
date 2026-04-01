#!/usr/bin/env bash
# test-downloader-unit.sh — Run MapDownloader + CacheManager unit tests headlessly.
#
# These tests verify the audit fixes:
#   - Path traversal sanitisation
#   - find_cached_file_by_name exact matching
#   - pr_downloads filelist parsing + queue size limits
#   - Reconnect loop prevention
#   - _fail() re-entry guard
#   - HTTP cancellation helper
#   - Dead variable removal
#
# Prerequisites:
#   - godot in PATH (Godot 4.2+)
#   - Built libopenmohaa.so deployed to project/bin/ (only needed for
#     GDExtension class registration; game assets NOT required)
#
# Usage:
#   ./scripts/test-downloader-unit.sh
#
# Exit codes:
#   0  All tests passed
#   1  One or more tests failed
#   2  Setup/infrastructure error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$REPO_ROOT/project"
LOG_DIR="$REPO_ROOT/test-results"
SUMMARY_FILE="$LOG_DIR/downloader-unit-test-latest.summary"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$LOG_DIR"

# Colours
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    RED=''; GREEN=''; BOLD=''; RESET=''
fi

echo "${BOLD}========================================"
echo " MapDownloader + CacheManager Unit Tests"
echo "========================================${RESET}"
echo ""

# Check prerequisites.
if ! command -v godot &>/dev/null; then
    echo "${RED}ERROR: 'godot' not found in PATH${RESET}" >&2
    exit 2
fi

LOG_FILE="$LOG_DIR/downloader-unit-test-$TIMESTAMP.log"

cd "$PROJECT_DIR"

# Run headlessly with a 30-second timeout.
set +e
timeout 30s godot --headless res://TestDownloaderUnit.tscn 2>&1 | tee "$LOG_FILE"
EXIT_CODE=${PIPESTATUS[0]}
set -e

echo ""

# Parse results from log.
PASS_COUNT=$(grep -c '\[✓\]' "$LOG_FILE" 2>/dev/null) || PASS_COUNT=0
FAIL_COUNT=$(grep -c '\[✗\]' "$LOG_FILE" 2>/dev/null) || FAIL_COUNT=0

echo "Passed:  $PASS_COUNT"
echo "Failed:  $FAIL_COUNT"
echo ""

# Write summary.
{
    echo "downloader-unit-test $TIMESTAMP"
    echo "pass=$PASS_COUNT fail=$FAIL_COUNT"
    echo "exit=$EXIT_CODE"
    if [[ $FAIL_COUNT -gt 0 ]]; then
        echo "result=FAIL"
    elif [[ $PASS_COUNT -gt 0 ]]; then
        echo "result=PASS"
    else
        echo "result=UNKNOWN"
    fi
} > "$SUMMARY_FILE"

if [[ $FAIL_COUNT -gt 0 ]]; then
    echo "${RED}RESULT: FAIL${RESET}"
    exit 1
elif [[ $EXIT_CODE -eq 124 ]]; then
    echo "${RED}RESULT: FAIL (timeout)${RESET}"
    exit 1
elif [[ $PASS_COUNT -gt 0 ]]; then
    echo "${GREEN}RESULT: PASS${RESET}"
    exit 0
else
    echo "${RED}RESULT: UNKNOWN (no assertions)${RESET}"
    exit 1
fi
