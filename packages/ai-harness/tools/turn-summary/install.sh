#!/bin/bash
#
# turn-summary — Individual tool installer
# Can be run standalone: curl -fsSL .../tools/turn-summary/install.sh | bash
# Or invoked by the root installer.
#
# Registers a Claude Code "Stop" hook that asks the main Claude to summarize each
# working turn and surface any decisions. The hook is merged into
# ~/.claude/settings.json (jq, idempotent). The hook command lives inside the
# sazo-ai-harness install dir, so the root uninstaller's --all sweep also
# removes it; per-tool uninstall removes just this entry.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

LIB_PATH="$HARNESS_DIR/lib/installer-common.sh"
if [ ! -f "$LIB_PATH" ]; then
    if [ "${SAZO_ROOT_INSTALL:-0}" != "1" ] && [ "${SAZO_TURN_SUMMARY_BOOTSTRAPPED:-0}" != "1" ]; then
        SAZO_BASE_DIR="${SAZO_BASE_DIR:-$HOME/.config/sazo-ai-harness}"
        SAZO_REPO_URL="${SAZO_REPO_URL:-https://github.com/SAZO-KR/sazo-toolkit.git}"

        if ! command -v git >/dev/null 2>&1; then
            echo "Error: git is required" >&2
            exit 1
        fi

        if [ -d "$SAZO_BASE_DIR/.git" ]; then
            echo "Updating existing installation at $SAZO_BASE_DIR..."
            git -C "$SAZO_BASE_DIR" pull --ff-only || true
        else
            echo "Installing turn-summary to $SAZO_BASE_DIR..."
            mkdir -p "$(dirname "$SAZO_BASE_DIR")"
            git clone --filter=blob:none --sparse "$SAZO_REPO_URL" "$SAZO_BASE_DIR"
            git -C "$SAZO_BASE_DIR" sparse-checkout set packages/ai-harness
        fi

        exec env SAZO_TURN_SUMMARY_BOOTSTRAPPED=1 bash "$SAZO_BASE_DIR/packages/ai-harness/tools/turn-summary/install.sh" "$@"
    fi

    echo "Error: installer-common.sh not found at $LIB_PATH" >&2
    exit 1
fi
source "$LIB_PATH"

source "$SCRIPT_DIR/tool.sh"

STATE_DIR="${SAZO_BASE_DIR}"
INSTALLED_MARKER="$STATE_DIR/turn-summary.installed"

INSTALL_FAILED=0

cleanup() {
    if [ "$INSTALL_FAILED" = "1" ]; then
        release_lock 2>/dev/null || true
        clear_receipt "$TOOL_NAME" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "==================================="
echo "  turn-summary Installer"
echo "==================================="
echo ""

# --- Prerequisites ---

check_platform "$TOOL_PLATFORM" || exit $?

# --- Lock ---

LOCK_DIR="${SAZO_BASE_DIR}.lock.d"
if ! acquire_lock "$LOCK_DIR"; then
    log_error "Another installation is in progress"
    exit 1
fi

# --- Idempotency check ---

if is_tool_installed "$TOOL_NAME"; then
    log_info "turn-summary is already installed"
    log_info "Re-running will refresh the hook registration"
fi

# --- Clone / Update (standalone mode) ---

if [ "${SAZO_ROOT_INSTALL:-0}" != "1" ]; then
    sparse_clone_tool "$SAZO_BASE_DIR" "$SAZO_REPO_URL" "packages/ai-harness"
fi

HARNESS_DIR="${SAZO_BASE_DIR}/packages/ai-harness"

if [ ! -d "$HARNESS_DIR/tools/turn-summary/scripts" ]; then
    log_error "turn-summary package not found or incomplete"
    INSTALL_FAILED=1
    exit 1
fi

HOOK_PATH="$HARNESS_DIR/tools/turn-summary/scripts/stop-summary.sh"
chmod +x "$HARNESS_DIR/tools/turn-summary/scripts/"*.sh 2>/dev/null || true

# Claude Code runs a command hook through the shell when no args are given, so the
# stored command must be shell-safe. Single-quote the path (escaping any embedded
# single quotes) so install dirs with whitespace still launch the hook correctly.
shell_quote() { local q="'\''"; printf "'%s'" "${1//\'/$q}"; }
HOOK_CMD="$(shell_quote "$HOOK_PATH")"

# --- Register the Stop hook in settings.json (jq, idempotent) ---

echo ""
echo "Registering Stop hook in ~/.claude/settings.json..."

# Pass the raw path; settings-hook.sh resolves symlinks portably (no readlink -f).
SETTINGS_FILE="$HOME/.claude/settings.json"

if command -v jq >/dev/null 2>&1; then
    if bash "$HARNESS_DIR/tools/turn-summary/scripts/settings-hook.sh" add "$SETTINGS_FILE" "$HOOK_CMD"; then
        log_info "Stop hook registered: $HOOK_PATH"
    else
        log_warn "Failed to update settings.json — manual registration needed"
    fi
else
    log_warn "jq not installed — turn-summary needs jq to register/run."
    log_warn "Install jq (brew install jq), then re-run this installer."
fi

# --- Record install marker (receipt-tracked; settings.json is NOT receipt-tracked) ---

ensure_dir "$STATE_DIR"
: > "$INSTALLED_MARKER"

RECEIPT_ENTRIES=()
RECEIPT_ENTRIES+=("state:$INSTALLED_MARKER")
RECEIPT_ENTRIES+=("dir:$STATE_DIR")

if [ ${#RECEIPT_ENTRIES[@]} -gt 0 ]; then
    write_receipt "$TOOL_NAME" "${RECEIPT_ENTRIES[@]}"
fi

# --- Done ---

release_lock
trap - EXIT

echo ""
echo "==================================="
echo "  turn-summary Installation Complete!"
echo "==================================="
echo ""
echo "The Stop hook will summarize turns where Claude did real work"
echo "(file edits, writes, or subagent runs) and surface any decisions."
echo ""
echo "Uninstall: bash $SCRIPT_DIR/uninstall.sh"
echo ""

exit 0
