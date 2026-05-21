#!/bin/bash
#
# awake — Individual tool uninstaller
# Removes all awake artifacts using receipt-based tracking.
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

INSTALL_DIR="${SAZO_BASE_DIR}"
AWAKE_CLI="$HOME/.local/bin/awake"
AWAKE_HELPER_ROOT="/usr/local/libexec/sazo-ai-harness/awake-helper"
AWAKE_HELPER_ROOT_DIR="/usr/local/libexec/sazo-ai-harness"
AWAKE_HELPER_STATE_DIR="/var/db/sazo-ai-harness"
AWAKE_HELPER_LOCK_DIR="/var/run/sazo-ai-harness-awake.lock.d"
AWAKE_SUDOERS_FILE="/etc/sudoers.d/sazo-ai-harness-awake"

removed=0
skipped=0

echo "==================================="
echo "  awake Uninstaller"
echo "==================================="
echo ""

# --- 1. Stop awake process ---

echo "[1/6] Stopping awake process..."

AWAKE_PID_FILE="$INSTALL_DIR/awake.pid"
AWAKE_EXPIRES_FILE="$INSTALL_DIR/awake.expires"
AWAKE_STATE_FILE="$INSTALL_DIR/awake.state"
AWAKE_CLI_MANAGED=0

if [ -L "$AWAKE_CLI" ]; then
    AWAKE_CLI_TARGET=$(readlink "$AWAKE_CLI" 2>/dev/null || true)
    if echo "$AWAKE_CLI_TARGET" | grep -qE "sazo-ai-harness|sazo-ai-prompts"; then
        AWAKE_CLI_MANAGED=1
    fi
fi

if [ "$AWAKE_CLI_MANAGED" -eq 1 ] && [ -x "$AWAKE_CLI" ]; then
    "$AWAKE_CLI" off >/dev/null 2>&1 || "$AWAKE_CLI" reset >/dev/null 2>&1 || true
fi

if [ -f "$AWAKE_PID_FILE" ]; then
    AWAKE_PID=$(cat "$AWAKE_PID_FILE" 2>/dev/null)
    if [ -n "$AWAKE_PID" ] && kill -0 "$AWAKE_PID" 2>/dev/null; then
        kill "$AWAKE_PID" 2>/dev/null && log_info "awake process killed (PID $AWAKE_PID)"
    else
        log_info "awake process already stopped"
    fi
    rm -f "$AWAKE_PID_FILE" "$AWAKE_EXPIRES_FILE"
    removed=$((removed + 1))
else
    skipped=$((skipped + 1))
fi

if [ -f "$AWAKE_STATE_FILE" ]; then
    rm -f "$AWAKE_STATE_FILE"
    log_info "awake state file removed"
    removed=$((removed + 1))
fi

# --- 2. CLI symlink ---

echo ""
echo "[2/6] Removing CLI symlink..."

if [ -L "$AWAKE_CLI" ]; then
    AWAKE_CLI_TARGET=$(readlink "$AWAKE_CLI" 2>/dev/null || true)
    if echo "$AWAKE_CLI_TARGET" | grep -qE "sazo-ai-harness|sazo-ai-prompts"; then
        rm -f "$AWAKE_CLI"
        log_info "awake CLI removed (symlink)"
    else
        log_warn "awake CLI points elsewhere — preserving: $AWAKE_CLI"
    fi
elif [ -e "$AWAKE_CLI" ]; then
    log_warn "awake CLI is a local file — preserving: $AWAKE_CLI"
fi

# --- 3. Root helper ---

echo ""
echo "[3/6] Removing root helper..."

AWAKE_HELPER_MANAGED=0
[ -x "$AWAKE_HELPER_ROOT" ] && AWAKE_HELPER_MANAGED=1
[ -d "$AWAKE_HELPER_STATE_DIR" ] && AWAKE_HELPER_MANAGED=1
[ -d "$AWAKE_HELPER_LOCK_DIR" ] && AWAKE_HELPER_MANAGED=1
[ -f "$AWAKE_SUDOERS_FILE" ] && AWAKE_HELPER_MANAGED=1

if [ -x "$AWAKE_HELPER_ROOT" ]; then
    sudo "$AWAKE_HELPER_ROOT" reset >/dev/null 2>&1 || true
    sudo rm -f "$AWAKE_HELPER_ROOT" && log_info "awake helper removed" && removed=$((removed + 1))
    sudo rmdir "$AWAKE_HELPER_ROOT_DIR" >/dev/null 2>&1 || true
fi

if [ "$AWAKE_HELPER_MANAGED" -eq 1 ] && sudo test -d "$AWAKE_HELPER_STATE_DIR" >/dev/null 2>&1; then
    sudo rm -rf "$AWAKE_HELPER_STATE_DIR" && log_info "awake helper state removed" && removed=$((removed + 1))
fi

if [ "$AWAKE_HELPER_MANAGED" -eq 1 ] && sudo test -d "$AWAKE_HELPER_LOCK_DIR" >/dev/null 2>&1; then
    sudo rm -rf "$AWAKE_HELPER_LOCK_DIR" && log_info "awake helper lock removed" && removed=$((removed + 1))
fi

if [ "$AWAKE_HELPER_MANAGED" -eq 1 ] && sudo test -f "$AWAKE_SUDOERS_FILE" >/dev/null 2>&1; then
    if sudo grep -q "SAZO-AI-HARNESS-AWAKE" "$AWAKE_SUDOERS_FILE" 2>/dev/null; then
        sudo rm -f "$AWAKE_SUDOERS_FILE" && log_info "awake sudoers removed" && removed=$((removed + 1))
    else
        log_warn "awake sudoers missing managed marker — preserving: $AWAKE_SUDOERS_FILE"
    fi
fi

# --- 4. Receipt-based cleanup ---

echo ""
echo "[4/6] Receipt-based cleanup..."

if is_tool_installed "$TOOL_NAME"; then
    remove_receipt_entries "$TOOL_NAME"
    removed=$((removed + 1))
    clear_receipt "$TOOL_NAME"
else
    log_warn "No receipt found for $TOOL_NAME"
fi

# --- 5. Directories (rmdir only, not recursive) ---

echo ""
echo "[5/6] Cleaning up directories..."

for d in "$INSTALL_DIR/awake.pid" \
         "$INSTALL_DIR/awake.expires" \
         "$INSTALL_DIR/awake.state"; do
    if [ -f "$d" ]; then
        rm -f "$d"
        log_info "$(basename "$d") removed"
        removed=$((removed + 1))
    fi
done

# --- 6. Command symlink (if any) ---

echo ""
echo "[6/6] Removing command links..."

remove_harness_symlinks "$HOME/.claude/commands" "~/.claude/commands"
remove_harness_symlinks "$HOME/.config/opencode/commands" "~/.config/opencode/commands"

echo ""
echo "==================================="
echo "  awake Uninstall Complete"
echo "==================================="
echo ""
echo "  Removed: ${removed} items"
echo "  Skipped: ${skipped} items (already absent)"
echo ""