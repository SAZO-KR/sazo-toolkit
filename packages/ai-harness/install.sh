#!/bin/bash

set -euo pipefail

REPO_URL="https://github.com/SAZO-KR/sazo-toolkit.git"
INSTALL_DIR="$HOME/.config/sazo-ai-harness"
SETTINGS_FILE="$HOME/.claude/settings.json"
OPENCODE_CONFIG="$HOME/.config/opencode/opencode.json"

SKIP_OPENCODE=0
for arg in "$@"; do
    case "$arg" in
        --no-opencode) SKIP_OPENCODE=1 ;;
    esac
done

cleanup() {
    if [ "${INSTALL_FAILED:-}" = "1" ] && [ -d "$INSTALL_DIR" ]; then
        rm -rf "$INSTALL_DIR"
    fi
}
trap cleanup EXIT

ask_yes_no() {
    local prompt="$1"
    local default="${2:-y}"

    if [ ! -t 0 ] && [ -e /dev/tty ]; then
        exec 3</dev/tty
    elif [ -t 0 ]; then
        exec 3<&0
    else
        [ "$default" = "y" ] && return 0 || return 1
    fi

    local yn
    if [ "$default" = "y" ]; then
        printf "%s [Y/n] " "$prompt"
    else
        printf "%s [y/N] " "$prompt"
    fi
    read -r yn <&3 2>/dev/null || yn=""
    exec 3<&- 2>/dev/null || true

    case "$yn" in
        [Yy]*) return 0 ;;
        [Nn]*) return 1 ;;
        "") [ "$default" = "y" ] && return 0 || return 1 ;;
        *) [ "$default" = "y" ] && return 0 || return 1 ;;
    esac
}

echo "==================================="
echo "  AI Harness Installer"
echo "==================================="
echo ""

# --- Prerequisites ---

if ! command -v jq &> /dev/null; then
    echo "Error: jq is required. Install with: brew install jq"
    INSTALL_FAILED=1
    exit 1
fi

if ! command -v git &> /dev/null; then
    echo "Error: git is required."
    INSTALL_FAILED=1
    exit 1
fi

# --- Clone / Update ---

if [ -d "$INSTALL_DIR/.git" ]; then
    echo "Updating existing installation..."
    cd "$INSTALL_DIR"

    # Migrate from ai-prompts sparse-checkout to ai-harness
    SPARSE_LIST=$(git sparse-checkout list 2>/dev/null || echo "")
    if echo "$SPARSE_LIST" | grep -q "packages/ai-prompts"; then
        git sparse-checkout set packages/ai-harness
    fi

    git pull --ff-only || echo "Warning: Could not update (local changes?)" >&2
else
    echo "Installing to $INSTALL_DIR..."
    rm -rf "$INSTALL_DIR"
    mkdir -p "$(dirname "$INSTALL_DIR")"

    git clone --sparse --filter=blob:none --depth=1 --single-branch -b main "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    git sparse-checkout set packages/ai-harness
fi

HARNESS_DIR="$INSTALL_DIR/packages/ai-harness"

if [ ! -f "$HARNESS_DIR/install.sh" ] || [ ! -d "$HARNESS_DIR/commands" ]; then
    echo "Error: ai-harness package not found or incomplete"
    INSTALL_FAILED=1
    exit 1
fi

# ===================================
# Part 1: Claude Code Prompts
# ===================================

echo ""
echo "--- Claude Code Setup ---"
echo ""
echo "Setting up symlinks..."

mkdir -p "$HOME/.claude/commands"
mkdir -p "$HOME/.claude/skills"
mkdir -p "$HOME/.claude/agents"

link_files() {
    local source_dir="$1"
    local target_dir="$2"

    if [ ! -d "$source_dir" ]; then
        return
    fi

    for file in "$source_dir"/*; do
        [ -e "$file" ] || continue

        local filename
        filename=$(basename "$file")

        # Skip template files/folders
        if [[ "$filename" == _* ]]; then
            continue
        fi

        local target="$target_dir/$filename"

        if [ -L "$target" ]; then
            rm "$target"
        elif [ -e "$target" ]; then
            echo "  Skip: $filename (local file exists)"
            continue
        fi

        ln -s "$file" "$target"
        echo "  Linked: $filename"
    done
}

echo "Commands:"
link_files "$HARNESS_DIR/commands" "$HOME/.claude/commands"

echo "Skills:"
link_files "$HARNESS_DIR/skills" "$HOME/.claude/skills"

echo "Agents:"
link_files "$HARNESS_DIR/agents" "$HOME/.claude/agents"

# --- OpenCode commands ---

OPENCODE_COMMANDS_DIR="$HOME/.config/opencode/commands"
if [ -d "$HOME/.config/opencode" ]; then
    echo ""
    echo "OpenCode commands:"
    mkdir -p "$OPENCODE_COMMANDS_DIR"
    link_files "$HARNESS_DIR/commands" "$OPENCODE_COMMANDS_DIR"
fi

# --- Auto-update hook (Claude Code) ---

echo ""
echo "Registering auto-update hook..."

if [ ! -f "$SETTINGS_FILE" ]; then
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    echo '{}' > "$SETTINGS_FILE"
fi

HOOK_SCRIPT="$HARNESS_DIR/scripts/auto-update.sh"
chmod +x "$HOOK_SCRIPT"

if grep -q "auto-update.sh" "$SETTINGS_FILE" 2>/dev/null; then
    echo "  Claude Code: already registered"
else
    NEW_HOOK=$(jq -n --arg cmd "$HOOK_SCRIPT" '{
        "matcher": "startup",
        "hooks": [{"type": "command", "command": $cmd}]
    }')

    TMP_FILE=$(mktemp)
    jq --argjson entry "$NEW_HOOK" '.hooks.SessionStart = (.hooks.SessionStart // []) + [$entry]' "$SETTINGS_FILE" > "$TMP_FILE"
    mv "$TMP_FILE" "$SETTINGS_FILE"
    echo "  Claude Code: registered SessionStart hook"
fi

# --- OpenCode agent config ---

OPENCODE_AGENTS_TEMPLATE="$HARNESS_DIR/opencode/agents.json"

if [ -f "$OPENCODE_AGENTS_TEMPLATE" ] && command -v jq &> /dev/null; then
    AGENT_OBJ="{}"

    while IFS= read -r agent_name; do
        agent_file="$HOME/.claude/agents/${agent_name}.md"
        [ -e "$agent_file" ] || [ -L "$agent_file" ] || continue

        entry=$(jq --arg k "$agent_name" --arg prompt "{file:${agent_file}}" \
            '.[$k] + {prompt: $prompt}' "$OPENCODE_AGENTS_TEMPLATE")
        AGENT_OBJ=$(echo "$AGENT_OBJ" | jq --arg k "$agent_name" --argjson v "$entry" '.[$k] = $v')
        echo "  OpenCode agent: $agent_name"
    done < <(jq -r 'keys[]' "$OPENCODE_AGENTS_TEMPLATE")

    if [ "$AGENT_OBJ" != "{}" ]; then
        mkdir -p "$HOME/.config/opencode"
        if [ -f "$OPENCODE_CONFIG" ]; then
            TMP_OC=$(mktemp)
            jq --argjson agents "$AGENT_OBJ" '.agent = ((.agent // {}) + $agents)' "$OPENCODE_CONFIG" > "$TMP_OC" && mv "$TMP_OC" "$OPENCODE_CONFIG"
        else
            jq -n --argjson agents "$AGENT_OBJ" '{agent: $agents}' > "$OPENCODE_CONFIG"
        fi
    fi
fi

# ===================================
# Part 2: OpenCode Setup (optional)
# ===================================

if [ "$SKIP_OPENCODE" -eq 1 ]; then
    echo ""
    echo "Skipping OpenCode setup (--no-opencode)"
else
    echo ""
    if ask_yes_no "OpenCode 설정도 함께 설치할까요?"; then
        echo ""
        echo "--- OpenCode Setup ---"

        # --- Install OpenCode via Homebrew ---

        if ! command -v opencode &> /dev/null; then
            echo ""
            if command -v brew &> /dev/null; then
                echo "Installing OpenCode via Homebrew..."
                brew install opencode
            else
                echo "Warning: OpenCode not found and Homebrew not available."
                echo "  Install manually: https://opencode.ai"
            fi
        else
            OPENCODE_VERSION=$(opencode --version 2>/dev/null || echo "unknown")
            echo "OpenCode already installed (v$OPENCODE_VERSION)"
        fi

        # --- Merge OpenCode config ---

        OPENCODE_CONFIG_TEMPLATE="$HARNESS_DIR/opencode/config.json"

        if [ -f "$OPENCODE_CONFIG_TEMPLATE" ]; then
            echo ""
            echo "Merging OpenCode configuration..."
            mkdir -p "$HOME/.config/opencode"

            if [ -f "$OPENCODE_CONFIG" ]; then
                TMP_OC=$(mktemp)
                # Merge plugins (union, no duplicates)
                # Merge disabled_providers (union, no duplicates)
                # Deep merge provider models
                jq -s '
                    .[0] as $existing | .[1] as $template |
                    $existing
                    | .plugin = ([$existing.plugin // [], $template.plugin // []] | add | unique)
                    | .disabled_providers = ([$existing.disabled_providers // [], $template.disabled_providers // []] | add | unique)
                    | .provider = ($existing.provider // {} | . * ($template.provider // {}))
                ' "$OPENCODE_CONFIG" "$OPENCODE_CONFIG_TEMPLATE" > "$TMP_OC" && mv "$TMP_OC" "$OPENCODE_CONFIG"
                echo "  Merged into existing config"
            else
                cp "$OPENCODE_CONFIG_TEMPLATE" "$OPENCODE_CONFIG"
                echo "  Created new config"
            fi
        fi

        # --- Install claude-sync (token sync) ---

        if ! command -v claude-sync &> /dev/null; then
            echo ""
            echo "Installing claude-sync (Claude → OpenCode token sync)..."
            if command -v claude &> /dev/null; then
                curl -fsSL https://raw.githubusercontent.com/lehdqlsl/opencode-claude-auth-sync/main/install.sh | bash -s -- --no-scheduler
                echo "  Installed claude-sync"
            else
                echo "  Skip: Claude CLI not found (claude-sync requires it)"
            fi
        else
            echo "claude-sync already installed"
        fi

        # --- Install notify wrapper + LaunchAgent ---

        NOTIFY_SCRIPT="$HOME/.local/bin/claude-sync-notify.sh"

        if command -v claude-sync &> /dev/null; then
            echo ""
            echo "Setting up claude-sync notification wrapper..."
            mkdir -p "$HOME/.local/bin"
            cp "$HARNESS_DIR/opencode/claude-sync-notify.sh" "$NOTIFY_SCRIPT"
            chmod +x "$NOTIFY_SCRIPT"
            echo "  Installed: $NOTIFY_SCRIPT"

            # Update LaunchAgent to use notify wrapper and fix PATH
            PLIST="$HOME/Library/LaunchAgents/com.opencode.claude-sync.plist"
            if [ -f "$PLIST" ]; then
                LOCAL_BIN="$HOME/.local/bin"
                SYNC_SCRIPT="$LOCAL_BIN/sync-claude-to-opencode.sh"

                NEEDS_RELOAD=0

                # Replace ProgramArguments to use notify wrapper
                if grep -q "$SYNC_SCRIPT" "$PLIST" 2>/dev/null; then
                    sed -i '' "s|$SYNC_SCRIPT|$NOTIFY_SCRIPT|g" "$PLIST"
                    NEEDS_RELOAD=1
                    echo "  LaunchAgent updated to use notification wrapper"
                fi

                # Ensure ~/.local/bin is in PATH
                if ! grep -q "$LOCAL_BIN" "$PLIST" 2>/dev/null; then
                    sed -i '' "s|<string>/usr/local/bin|<string>$LOCAL_BIN:/usr/local/bin|" "$PLIST"
                    NEEDS_RELOAD=1
                    echo "  LaunchAgent PATH updated to include $LOCAL_BIN"
                fi

                if [ "$NEEDS_RELOAD" -eq 1 ]; then
                    launchctl unload "$PLIST" 2>/dev/null || true
                    launchctl load "$PLIST" 2>/dev/null || true
                fi
            fi
        fi

        # --- Link commands into OpenCode (after setup created the dir) ---
        if [ -d "$HOME/.config/opencode" ]; then
            OPENCODE_COMMANDS_DIR="$HOME/.config/opencode/commands"
            mkdir -p "$OPENCODE_COMMANDS_DIR"
            echo ""
            echo "OpenCode commands (post-setup):"
            link_files "$HARNESS_DIR/commands" "$OPENCODE_COMMANDS_DIR"
        fi

        echo ""
        echo "OpenCode setup complete!"
    else
        echo "Skipping OpenCode setup."
    fi
fi

# ===================================
# Done
# ===================================

VERSION=$(git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")

echo ""
echo "==================================="
echo "  Installation Complete!"
echo "==================================="
echo ""
echo "Version: $VERSION"
echo ""
echo "Claude Code:"
echo "  /weekly-report          주간 업무 보고서 생성 (코드+이슈+메일+슬랙+캘린더+문서)"
echo ""
if [ "$SKIP_OPENCODE" -eq 0 ]; then
echo "OpenCode:"
echo "  claude-sync --status    Check token status"
echo "  opencode models anthropic   List available models"
echo ""
fi
echo "Auto-updates on every Claude/OpenCode session start."
echo ""
