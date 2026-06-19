#!/bin/bash
#
# turn-summary — Individual tool uninstaller
# Removes the Stop hook from settings.json and clears receipt artifacts.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

LIB_PATH="$HARNESS_DIR/lib/installer-common.sh"
if [ ! -f "$LIB_PATH" ]; then
    echo "Error: installer-common.sh not found at $LIB_PATH" >&2
    exit 1
fi
source "$LIB_PATH"

source "$SCRIPT_DIR/tool.sh"

# Match this tool's hook by its stable command-path suffix, robust to base-dir.
HOOK_MATCH="turn-summary/scripts/stop-summary.sh"

removed=0
skipped=0

echo "==================================="
echo "  turn-summary Uninstaller"
echo "==================================="
echo ""

# --- 1. Remove the Stop hook from settings.json (jq, scoped to our command) ---

echo "[1/2] Cleaning settings.json Stop hook..."

# Pass the raw path; settings-hook.sh resolves symlinks portably (no readlink -f).
SETTINGS_FILE="$HOME/.claude/settings.json"

if [ -f "$SETTINGS_FILE" ] && command -v jq >/dev/null 2>&1; then
    if bash "$HARNESS_DIR/tools/turn-summary/scripts/settings-hook.sh" remove "$SETTINGS_FILE" "$HOOK_MATCH"; then
        log_info "Stop hook removed from settings.json"
        removed=$((removed + 1))
    else
        log_warn "settings.json cleanup failed — manual check needed"
        skipped=$((skipped + 1))
    fi
else
    [ ! -f "$SETTINGS_FILE" ] && log_warn "settings.json not found — nothing to clean"
    [ -f "$SETTINGS_FILE" ] && ! command -v jq >/dev/null 2>&1 && \
        log_warn "jq not installed — remove the turn-summary Stop hook from settings.json manually"
    skipped=$((skipped + 1))
fi

# --- 2. Receipt-based cleanup (install marker, dir) ---

echo ""
echo "[2/2] Receipt-based cleanup..."

if is_tool_installed "$TOOL_NAME"; then
    remove_receipt_entries "$TOOL_NAME"
    removed=$((removed + 1))
    clear_receipt "$TOOL_NAME"
else
    log_warn "No receipt found for $TOOL_NAME"
    skipped=$((skipped + 1))
fi

echo ""
echo "==================================="
echo "  turn-summary Uninstall Complete"
echo "==================================="
echo ""
echo "  Removed: ${removed} items"
echo "  Skipped: ${skipped} items (already absent)"
echo ""
