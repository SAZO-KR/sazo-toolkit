#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_FILE="$HOME/.claude/settings.json"
HOOKS_DIR="$HOME/.claude/hooks"

echo "Installing Claude notification hooks..."

# Create directories
mkdir -p "$HOME/.claude"
mkdir -p "$HOOKS_DIR"

# Check if jq is available
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed."
    echo "Install it with: brew install jq"
    exit 1
fi

# Copy hook scripts
cp "$SCRIPT_DIR/scripts/stop-hook.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/scripts/notification-hook.sh" "$HOOKS_DIR/"
chmod +x "$HOOKS_DIR/stop-hook.sh"
chmod +x "$HOOKS_DIR/notification-hook.sh"
echo "Copied hook scripts to $HOOKS_DIR"

# Define new hook entries
NEW_STOP_ENTRY=$(jq -n --arg cmd "$HOOKS_DIR/stop-hook.sh" '{
    "matcher": "",
    "hooks": [{"type": "command", "command": $cmd}]
}')

NEW_NOTIFICATION_ENTRY=$(jq -n --arg cmd "$HOOKS_DIR/notification-hook.sh" '{
    "hooks": [{"type": "command", "command": $cmd}]
}')

# Function to handle existing hook
# Args: $1=hook_name
# Returns action via stdout: INSTALL, REPLACE, APPEND, SKIP
handle_hook() {
    local hook_name="$1"
    local existing

    existing=$(jq -r ".hooks.$hook_name // empty" "$SETTINGS_FILE" 2>/dev/null)

    if [ -z "$existing" ] || [ "$existing" = "null" ]; then
        echo "[$hook_name] No existing hook found. Installing new hook." >&2
        echo "INSTALL"
        return
    fi

    # Show existing hook to user (via stderr so it displays)
    echo "" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo "[$hook_name] Existing hook found:" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo "$existing" | jq '.' >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo "" >&2
    echo "What do you want to do?" >&2
    echo "  r) Replace - Remove existing, install new" >&2
    echo "  a) Append  - Keep existing, add new" >&2
    echo "  s) Skip    - Keep existing, don't install" >&2
    echo "" >&2
    read -p "[$hook_name] Choose [r/a/s]: " choice

    case "$choice" in
        r|R)
            echo "REPLACE"
            ;;
        a|A)
            echo "APPEND"
            ;;
        s|S)
            echo "SKIP"
            ;;
        *)
            echo "Invalid choice. Skipping." >&2
            echo "SKIP"
            ;;
    esac
}

# Create settings file if it doesn't exist
if [ ! -f "$SETTINGS_FILE" ]; then
    echo '{}' > "$SETTINGS_FILE"
    echo "Created new settings file at $SETTINGS_FILE"
fi

# Backup existing settings
BACKUP_FILE="$SETTINGS_FILE.backup.$(date +%Y%m%d%H%M%S)"
cp "$SETTINGS_FILE" "$BACKUP_FILE"
echo "Backed up existing settings to $BACKUP_FILE"

# Handle Stop hook
STOP_ACTION=$(handle_hook "Stop" "$NEW_STOP_ENTRY")
STOP_ACTION=$(echo "$STOP_ACTION" | tail -1)  # Get last line (the action)

# Handle Notification hook
NOTIFICATION_ACTION=$(handle_hook "Notification" "$NEW_NOTIFICATION_ENTRY")
NOTIFICATION_ACTION=$(echo "$NOTIFICATION_ACTION" | tail -1)

# Apply changes
TMP_FILE=$(mktemp)
trap "rm -f '$TMP_FILE'" EXIT

cp "$SETTINGS_FILE" "$TMP_FILE"

# Apply Stop hook action
case "$STOP_ACTION" in
    INSTALL|REPLACE)
        jq --argjson entry "[$NEW_STOP_ENTRY]" '.hooks.Stop = $entry' "$TMP_FILE" > "$TMP_FILE.new" && mv "$TMP_FILE.new" "$TMP_FILE"
        echo "[Stop] Installed new hook."
        ;;
    APPEND)
        jq --argjson entry "$NEW_STOP_ENTRY" '.hooks.Stop += [$entry]' "$TMP_FILE" > "$TMP_FILE.new" && mv "$TMP_FILE.new" "$TMP_FILE"
        echo "[Stop] Appended new hook to existing ones."
        ;;
    SKIP)
        echo "[Stop] Skipped."
        ;;
esac

# Apply Notification hook action
case "$NOTIFICATION_ACTION" in
    INSTALL|REPLACE)
        jq --argjson entry "[$NEW_NOTIFICATION_ENTRY]" '.hooks.Notification = $entry' "$TMP_FILE" > "$TMP_FILE.new" && mv "$TMP_FILE.new" "$TMP_FILE"
        echo "[Notification] Installed new hook."
        ;;
    APPEND)
        jq --argjson entry "$NEW_NOTIFICATION_ENTRY" '.hooks.Notification += [$entry]' "$TMP_FILE" > "$TMP_FILE.new" && mv "$TMP_FILE.new" "$TMP_FILE"
        echo "[Notification] Appended new hook to existing ones."
        ;;
    SKIP)
        echo "[Notification] Skipped."
        ;;
esac

mv "$TMP_FILE" "$SETTINGS_FILE"

echo ""
echo "Installation complete!"
echo ""
echo "Hooks:"
echo "  - Stop: 작업 완료 시 알림"
echo "  - Notification: 입력 대기 시 알림 (idle_prompt 제외)"
echo ""
echo "Scripts location: $HOOKS_DIR"
echo "Backup: $BACKUP_FILE"
