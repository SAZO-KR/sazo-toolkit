#!/bin/bash
#
# awake — Individual tool installer
# Can be run standalone: curl -fsSL .../tools/awake/install.sh | bash
# Or invoked by the root installer.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

LIB_PATH="$HARNESS_DIR/lib/installer-common.sh"
if [ ! -f "$LIB_PATH" ]; then
    echo "Error: installer-common.sh not found at $LIB_PATH" >&2
    exit 1
fi
source "$LIB_PATH"

source "$SCRIPT_DIR/tool.sh"

STATE_DIR="${SAZO_BASE_DIR}"
AWAKE_SCRIPT="$SCRIPT_DIR/scripts/awake.sh"
AWAKE_HELPER_SRC="$SCRIPT_DIR/scripts/awake-helper.sh"
AWAKE_SYMLINK="$HOME/.local/bin/awake"
AWAKE_HELPER_DST="/usr/local/libexec/sazo-ai-harness/awake-helper"
AWAKE_SUDOERS_FILE="/etc/sudoers.d/sazo-ai-harness-awake"

INSTALL_FAILED=0

cleanup() {
    if [ "$INSTALL_FAILED" = "1" ]; then
        release_lock 2>/dev/null || true
        clear_receipt "$TOOL_NAME" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "==================================="
echo "  awake Installer"
echo "==================================="
echo ""

# --- Prerequisites ---

check_platform "$TOOL_PLATFORM" || exit $?

if ! command -v git &>/dev/null; then
    log_error "git is required"
    INSTALL_FAILED=1
    exit 1
fi

# --- Lock ---

LOCK_DIR="${SAZO_BASE_DIR}.lock.d"
if ! acquire_lock "$LOCK_DIR"; then
    log_error "Another installation is in progress"
    exit 1
fi

# --- Idempotency check ---

if is_tool_installed "$TOOL_NAME"; then
    log_info "awake is already installed"
    log_info "Re-running will update the installation"
fi

# --- Clone / Update (standalone mode) ---

if [ "${SAZO_ROOT_INSTALL:-0}" != "1" ]; then
    sparse_clone_tool "$SAZO_BASE_DIR" "$SAZO_REPO_URL" "packages/ai-harness"
fi

HARNESS_DIR="${SAZO_BASE_DIR}/packages/ai-harness"

if [ ! -d "$HARNESS_DIR/tools/awake/scripts" ]; then
    log_error "awake package not found or incomplete"
    INSTALL_FAILED=1
    exit 1
fi

# --- Install awake CLI symlink ---

echo ""
echo "Installing awake CLI..."

mkdir -p "$HOME/.local/bin"

INSTALL_AWAKE=1
if [ -L "$AWAKE_SYMLINK" ]; then
    existing_target=$(readlink "$AWAKE_SYMLINK" 2>/dev/null || true)
    if ! echo "$existing_target" | grep -qE "sazo-ai-harness|sazo-ai-prompts"; then
        log_warn "Skip: awake (existing symlink → $existing_target, not managed by ai-harness)"
        INSTALL_AWAKE=0
    fi
elif [ -e "$AWAKE_SYMLINK" ]; then
    log_warn "Skip: awake (local file exists at $AWAKE_SYMLINK)"
    INSTALL_AWAKE=0
fi

if [ "$INSTALL_AWAKE" -eq 1 ]; then
    safe_symlink "$AWAKE_SCRIPT" "$AWAKE_SYMLINK"
    log_info "Installed: $AWAKE_SYMLINK"
fi

case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *)
        log_warn "$HOME/.local/bin is not in PATH"
        echo "    echo 'export PATH=\$HOME/.local/bin:\$PATH' >> ~/.zshrc"
        ;;
esac

RECEIPT_ENTRIES=()

if [ "$INSTALL_AWAKE" -eq 1 ]; then
    RECEIPT_ENTRIES+=("symlink:$AWAKE_SYMLINK")
fi

# --- Awake helper (optional, requires sudo) ---

if [ -f "$AWAKE_HELPER_SRC" ]; then
    echo ""
    echo "awake closed-lid helper (optional):"
    echo "  - helper path: $AWAKE_HELPER_DST"
    echo "  - needed for lid-closed execution persistence"
    echo "  - requires sudo because pmset is global"

    if ask_yes_no "Install root-owned awake helper now?" n; then
        HELPER_INSTALLED=0

        if sudo install -d -o root -g wheel -m 0755 "$(dirname "$AWAKE_HELPER_DST")" 2>/dev/null && \
           sudo install -o root -g wheel -m 0755 "$AWAKE_HELPER_SRC" "$AWAKE_HELPER_DST" 2>/dev/null; then
            log_info "Installed helper: $AWAKE_HELPER_DST"
            RECEIPT_ENTRIES+=("sudo:file:$AWAKE_HELPER_DST")
            HELPER_INSTALLED=1
        else
            log_error "Failed to install helper (sudo denied or error)"
            INSTALL_FAILED=1
            exit "$EXIT_SUDO_DENIED"
        fi

        if [ "$HELPER_INSTALLED" -eq 1 ]; then
            if ask_yes_no "Install passwordless sudoers entry for awake helper?" n; then
                tmp_sudoers="$(mktemp)"
                cat > "$tmp_sudoers" <<EOF
# SAZO-AI-HARNESS-AWAKE
${USER:-$(id -un)} ALL=(root) NOPASSWD: $AWAKE_HELPER_DST
EOF
                if sudo visudo -cf "$tmp_sudoers" >/dev/null 2>&1 && \
                   sudo cp "$tmp_sudoers" "$AWAKE_SUDOERS_FILE" 2>/dev/null && \
                   sudo chmod 0440 "$AWAKE_SUDOERS_FILE" 2>/dev/null; then
                    log_info "Installed sudoers: $AWAKE_SUDOERS_FILE"
                    RECEIPT_ENTRIES+=("sudo:file:$AWAKE_SUDOERS_FILE")
                else
                    log_warn "Failed to install sudoers entry"
                fi
                rm -f "$tmp_sudoers"
            else
                log_warn "Skipped sudoers. 'awake on/off' may require sudo in a terminal."
            fi
        fi
    else
        log_warn "Skipped helper install. closed-lid awake mode will not work until helper is installed."
    fi
fi

# --- Record state directory ---

RECEIPT_ENTRIES+=("dir:$STATE_DIR")
RECEIPT_ENTRIES+=("state:$STATE_DIR/awake.state")

# --- Write receipt ---

if [ ${#RECEIPT_ENTRIES[@]} -gt 0 ]; then
    write_receipt "$TOOL_NAME" "${RECEIPT_ENTRIES[@]}"
fi

# --- Done ---

release_lock

trap - EXIT

VERSION=$(git -C "$SAZO_BASE_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")

echo ""
echo "==================================="
echo "  awake Installation Complete!"
echo "==================================="
echo ""
echo "Version: $VERSION"
echo ""
echo "Commands:"
echo "  awake on [duration]   Keep running with lid closed (default: 2h)"
echo "  awake off             Restore previous sleep setting"
echo "  awake status          Show current awake state"
echo "  awake extend <dur>    Add to remaining time"
echo "  awake reset           Force disablesleep 0 and clear state"
echo ""
echo "Uninstall: bash $SCRIPT_DIR/uninstall.sh"
echo ""

exit 0