#!/bin/bash

set -e

SETTINGS_FILE="$HOME/.claude/settings.json"

echo "Installing Claude notification hooks..."

# Create .claude directory if it doesn't exist
mkdir -p "$HOME/.claude"

# Check if jq is available
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed."
    echo "Install it with: brew install jq"
    exit 1
fi

# Inline notification commands (macOS only)
# Uses CLAUDE_PROJECT_DIR environment variable provided by Claude Code hooks
STOP_CMD='PROJECT=$(echo "$CLAUDE_PROJECT_DIR" | sed "s/\.worktrees.*//" | xargs basename) && BRANCH=$(git -C "$CLAUDE_PROJECT_DIR" branch --show-current 2>/dev/null || echo "no-git") && osascript -e "display notification \"응답 완료\" with title \"$PROJECT ($BRANCH)\" sound name \"Glass\""'

NOTIFICATION_CMD='PROJECT=$(echo "$CLAUDE_PROJECT_DIR" | sed "s/\.worktrees.*//" | xargs basename) && BRANCH=$(git -C "$CLAUDE_PROJECT_DIR" branch --show-current 2>/dev/null || echo "no-git") && osascript -e "display notification \"입력 대기 중\" with title \"$PROJECT ($BRANCH)\" sound name \"Glass\""'

# Define hook configuration
STOP_HOOK=$(jq -n --arg cmd "$STOP_CMD" '[{
    "matcher": "",
    "hooks": [{"type": "command", "command": $cmd}]
}]')

NOTIFICATION_HOOK=$(jq -n --arg cmd "$NOTIFICATION_CMD" '[{
    "hooks": [{"type": "command", "command": $cmd}]
}]')

# Create or update settings file
if [ ! -f "$SETTINGS_FILE" ]; then
    # Create new settings file
    jq -n \
        --argjson stop "$STOP_HOOK" \
        --argjson notification "$NOTIFICATION_HOOK" \
        '{hooks: {Stop: $stop, Notification: $notification}}' > "$SETTINGS_FILE"
    echo "Created new settings file at $SETTINGS_FILE"
else
    # Backup existing settings
    BACKUP_FILE="$SETTINGS_FILE.backup.$(date +%Y%m%d%H%M%S)"
    cp "$SETTINGS_FILE" "$BACKUP_FILE"
    echo "Backed up existing settings to $BACKUP_FILE"

    # Check for existing hooks
    EXISTING_STOP=$(jq -r '.hooks.Stop // empty' "$SETTINGS_FILE" 2>/dev/null)
    EXISTING_NOTIFICATION=$(jq -r '.hooks.Notification // empty' "$SETTINGS_FILE" 2>/dev/null)

    if [ -n "$EXISTING_STOP" ] || [ -n "$EXISTING_NOTIFICATION" ]; then
        echo "Warning: Existing hooks.Stop or hooks.Notification will be replaced."
        read -p "Continue? (y/N): " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            echo "Aborted. Restoring from backup..."
            mv "$BACKUP_FILE" "$SETTINGS_FILE"
            exit 1
        fi
    fi

    # Update settings file
    TMP_FILE=$(mktemp)
    trap "rm -f '$TMP_FILE'" EXIT

    jq \
        --argjson stop "$STOP_HOOK" \
        --argjson notification "$NOTIFICATION_HOOK" \
        '.hooks.Stop = $stop | .hooks.Notification = $notification' \
        "$SETTINGS_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$SETTINGS_FILE"

    echo "Updated hooks in $SETTINGS_FILE"
fi

echo ""
echo "Installation complete!"
echo ""
echo "Hooks installed:"
echo "  - Stop: 작업 완료 시 알림"
echo "  - Notification: 입력 대기 시 알림 (60초 후)"
