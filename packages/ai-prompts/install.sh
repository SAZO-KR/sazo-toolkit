#!/bin/bash

set -euo pipefail

REPO_URL="https://github.com/SAZO-KR/sazo-toolkit.git"
INSTALL_DIR="$HOME/.config/sazo-ai-prompts"
SETTINGS_FILE="$HOME/.claude/settings.json"

cleanup() {
    if [ "${INSTALL_FAILED:-}" = "1" ] && [ -d "$INSTALL_DIR" ]; then
        rm -rf "$INSTALL_DIR"
    fi
}
trap cleanup EXIT

echo "==================================="
echo "  AI Prompts Installer"
echo "==================================="
echo ""

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

if [ -d "$INSTALL_DIR/.git" ]; then
    echo "Updating existing installation..."
    cd "$INSTALL_DIR"
    git pull --ff-only || echo "Warning: Could not update (local changes?)" >&2
else
    echo "Installing to $INSTALL_DIR..."
    rm -rf "$INSTALL_DIR"
    mkdir -p "$(dirname "$INSTALL_DIR")"
    
    git clone --sparse --filter=blob:none --depth=1 --single-branch -b main "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    git sparse-checkout set packages/ai-prompts
fi

AI_PROMPTS_DIR="$INSTALL_DIR/packages/ai-prompts"

if [ ! -f "$AI_PROMPTS_DIR/install.sh" ] || [ ! -d "$AI_PROMPTS_DIR/commands" ]; then
    echo "Error: ai-prompts package not found or incomplete"
    INSTALL_FAILED=1
    exit 1
fi

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
            echo "  Skip: $filename (local file exists - will not receive updates)"
            continue
        fi
        
        ln -s "$file" "$target"
        echo "  Linked: $filename"
    done
}

echo "Commands:"
link_files "$AI_PROMPTS_DIR/commands" "$HOME/.claude/commands"

echo "Skills:"
link_files "$AI_PROMPTS_DIR/skills" "$HOME/.claude/skills"

echo "Agents:"
link_files "$AI_PROMPTS_DIR/agents" "$HOME/.claude/agents"

echo ""
echo "Registering auto-update hook..."

if [ ! -f "$SETTINGS_FILE" ]; then
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    echo '{}' > "$SETTINGS_FILE"
fi

HOOK_SCRIPT="$AI_PROMPTS_DIR/scripts/auto-update.sh"
chmod +x "$HOOK_SCRIPT"

if grep -q "auto-update.sh" "$SETTINGS_FILE" 2>/dev/null; then
    echo "Auto-update hook already registered"
else
    NEW_HOOK=$(jq -n --arg cmd "$HOOK_SCRIPT" '{
        "matcher": "startup",
        "hooks": [{"type": "command", "command": $cmd}]
    }')
    
    TMP_FILE=$(mktemp)
    jq --argjson entry "$NEW_HOOK" '.hooks.SessionStart = (.hooks.SessionStart // []) + [$entry]' "$SETTINGS_FILE" > "$TMP_FILE"
    mv "$TMP_FILE" "$SETTINGS_FILE"
    echo "Registered SessionStart hook"
fi

VERSION=$(git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")

echo ""
echo "==================================="
echo "  Installation Complete!"
echo "==================================="
echo ""
echo "Version: $VERSION"
echo ""
echo "Usage:"
echo "  /generate-changelog"
echo ""
echo "Auto-updates on every Claude session start."
echo ""
