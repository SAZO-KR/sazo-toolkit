#!/bin/bash
#
# AI Harness Root Uninstaller
# Removes all installed tools and shared artifacts.
#
# Usage:
#   curl -fsSL .../uninstall.sh | bash
#   bash packages/ai-harness/uninstall.sh --tool awake   # Uninstall specific tool
#   bash packages/ai-harness/uninstall.sh --all           # Remove everything
#
set -uo pipefail

INSTALL_DIR="$HOME/.config/sazo-ai-harness"

removed=0
skipped=0
TOOL_TO_REMOVE=""
REMOVE_ALL=0

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --tool)
                shift
                TOOL_TO_REMOVE="${1:-}"
                [ -z "$TOOL_TO_REMOVE" ] && { echo "Error: --tool requires a name" >&2; exit 1; }
                shift
                ;;
            --all|-a)
                REMOVE_ALL=1
                shift
                ;;
            --help|-h)
                echo "Usage: uninstall.sh [--tool <name>] [--all]"
                echo "  --tool   Uninstall a specific tool"
                echo "  --all    Remove everything including shared artifacts"
                echo "  --help   Show this help"
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                exit 1
                ;;
        esac
    done
}

parse_args "$@"

LIB_PATH="$INSTALL_DIR/packages/ai-harness/lib/installer-common.sh"

source_lib() {
    if [ -f "$LIB_PATH" ]; then
        source "$LIB_PATH"
    else
        info()  { printf "  ✓ %s\n" "$1"; }
        skip()  { printf "  - %s (not found)\n" "$1"; }
        warn()  { printf "  ⚠ %s\n" "$1" >&2; }
        remove_harness_symlinks() {
            local dir="$1"
            local label="$2"
            local count=0

            if [ ! -d "$dir" ]; then
                return 0
            fi

            for item in "$dir"/*; do
                [ -L "$item" ] || continue
                local target
                target=$(readlink "$item" 2>/dev/null || true)
                if echo "$target" | grep -qE "sazo-ai-harness|sazo-ai-prompts"; then
                    rm -f "$item"
                    count=$((count + 1))
                fi
            done

            if [ "$count" -gt 0 ]; then
                info "$label: ${count} symlinks removed"
            fi
            return 0
        }
    fi
}

source_lib

echo "==================================="
echo "  AI Harness Uninstaller"
echo "==================================="
echo ""

# --- Per-tool uninstall ---

if [ -n "$TOOL_TO_REMOVE" ]; then
    HARNESS_DIR="$INSTALL_DIR/packages/ai-harness"
    TOOL_UNINSTALLER="$HARNESS_DIR/tools/$TOOL_TO_REMOVE/uninstall.sh"

    if [ ! -f "$TOOL_UNINSTALLER" ]; then
        echo "Error: No uninstaller found for tool '$TOOL_TO_REMOVE'" >&2
        echo "Available tools:"
        for tool_dir in "$HARNESS_DIR/tools"/*/; do
            [ -d "$tool_dir" ] || continue
            [ -f "$tool_dir/uninstall.sh" ] || continue
            printf "  - %s\n" "$(basename "$tool_dir")"
        done 2>/dev/null || true
        exit 1
    fi

    echo "Uninstalling tool: $TOOL_TO_REMOVE"
    echo ""
    bash "$TOOL_UNINSTALLER"
    tool_rc=$?

    # Root owns ~/.claude linking (mirror of install.sh's per-tool linking), so
    # remove this tool's command/skill/agent symlinks too. Filter by the tool's own
    # basenames so shared/other-tool artifacts stay intact; remove_harness_symlinks
    # only deletes symlinks that resolve into the harness.
    TOOL_SRC="$HARNESS_DIR/tools/$TOOL_TO_REMOVE"
    for sub in commands skills agents; do
        [ -d "$TOOL_SRC/$sub" ] || continue
        names=()
        for f in "$TOOL_SRC/$sub"/*; do
            [ -e "$f" ] || continue
            names+=("$(basename "$f")")
        done
        [ ${#names[@]} -gt 0 ] || continue
        case "$sub" in
            commands)
                remove_harness_symlinks "$HOME/.claude/commands" "~/.claude/commands" "${names[@]}"
                remove_harness_symlinks "$HOME/.config/opencode/commands" "~/.config/opencode/commands" "${names[@]}"
                ;;
            skills)
                remove_harness_symlinks "$HOME/.claude/skills" "~/.claude/skills" "${names[@]}"
                ;;
            agents)
                remove_harness_symlinks "$HOME/.claude/agents" "~/.claude/agents" "${names[@]}"
                ;;
        esac
    done

    exit $tool_rc
fi

# --- Full uninstall ---

if [ "$REMOVE_ALL" -eq 0 ] && [ -z "$TOOL_TO_REMOVE" ]; then
    echo "Removing all ai-harness artifacts (use --tool <name> for per-tool uninstall)."
    echo ""
fi

SETTINGS_FILE="$HOME/.claude/settings.json"
[ -L "$SETTINGS_FILE" ] && SETTINGS_FILE=$(readlink -f "$SETTINGS_FILE" 2>/dev/null || readlink "$SETTINGS_FILE")
CLAUDE_MD="$HOME/.claude/CLAUDE.md"
OPENCODE_CONFIG="$HOME/.config/opencode/opencode.json"

# --- 1. Run per-tool uninstallers ---

echo "[1/8] Running per-tool uninstallers..."

HARNESS_DIR="$INSTALL_DIR/packages/ai-harness"

if [ -d "$HARNESS_DIR/tools" ]; then
    for tool_dir in "$HARNESS_DIR/tools"/*/; do
        [ -d "$tool_dir" ] || continue
        tool_name="$(basename "$tool_dir")"
        uninstaller="$tool_dir/uninstall.sh"
        if [ -f "$uninstaller" ]; then
            echo "  Uninstalling $tool_name..."
            bash "$uninstaller" || echo "  Warning: $tool_name uninstaller had errors" >&2
        fi
    done
else
    skip "per-tool uninstallers"
fi

# --- 2. awake legacy process cleanup ---

echo ""
echo "[2/8] Cleaning awake processes..."

AWAKE_PID_FILE="$INSTALL_DIR/awake.pid"
AWAKE_EXPIRES_FILE="$INSTALL_DIR/awake.expires"
AWAKE_STATE_FILE="$INSTALL_DIR/awake.state"
AWAKE_CLI="$HOME/.local/bin/awake"
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
        kill "$AWAKE_PID" 2>/dev/null && info "awake process killed (PID $AWAKE_PID)"
    fi
    rm -f "$AWAKE_PID_FILE" "$AWAKE_EXPIRES_FILE"
fi

[ -f "$AWAKE_STATE_FILE" ] && rm -f "$AWAKE_STATE_FILE"

# --- 3. LaunchAgent cleanup ---

echo ""
echo "[3/8] Cleaning LaunchAgents..."

PLIST="$HOME/Library/LaunchAgents/com.opencode.claude-sync.plist"
PLIST_LEGACY="$HOME/Library/LaunchAgents/shop.sazo.claude-sleep-guard.plist"

for p in "$PLIST" "$PLIST_LEGACY"; do
    if [ -f "$p" ]; then
        launchctl unload "$p" 2>/dev/null || true
        rm -f "$p"
        info "$(basename "$p") removed"
        removed=$((removed + 1))
    fi
done

# --- 4. Symlink removal ---

echo ""
echo "[4/8] Removing symlinks..."

remove_harness_symlinks "$HOME/.claude/commands" "~/.claude/commands"
remove_harness_symlinks "$HOME/.claude/skills" "~/.claude/skills"
remove_harness_symlinks "$HOME/.claude/agents" "~/.claude/agents"
remove_harness_symlinks "$HOME/.config/opencode/commands" "~/.config/opencode/commands"

# --- 5. settings.json hook cleanup ---

echo ""
echo "[5/8] Cleaning settings.json hooks..."

if [ -f "$SETTINGS_FILE" ] && command -v jq &>/dev/null; then
    TMP_FILE=$(mktemp)
    jq '
      def filter_harness_commands:
        if type == "array" then
          [ .[] | .hooks = ([(.hooks // [])[] | select((.command // "") | test("sazo-ai-harness|sazo-ai-prompts") | not)])
            | select((.hooks | length) > 0) ]
        else . end;

      if .hooks then
        .hooks |= with_entries(.value |= filter_harness_commands)
        | .hooks |= with_entries(select(.value | length > 0))
      else . end

      | if .env then
          .env |= with_entries(select(.key | startswith("SAZO_") | not))
          | if .env == {} then del(.env) else . end
        else . end
    ' "$SETTINGS_FILE" > "$TMP_FILE" 2>/dev/null

    if [ $? -eq 0 ] && [ -s "$TMP_FILE" ]; then
        mv "$TMP_FILE" "$SETTINGS_FILE"
        info "sazo-ai-harness hook and env entries removed"
        removed=$((removed + 1))
    else
        rm -f "$TMP_FILE"
        warn "settings.json cleanup failed — manual check needed"
    fi
else
    [ ! -f "$SETTINGS_FILE" ] && skip "settings.json"
    [ -f "$SETTINGS_FILE" ] && ! command -v jq &>/dev/null && warn "jq not installed — settings.json needs manual cleanup"
fi

# --- 6. CLAUDE.md managed block cleanup ---

echo ""
echo "[6/8] Cleaning CLAUDE.md..."

if [ -f "$CLAUDE_MD" ] \
  && grep -qF "BEGIN SAZO-AI-HARNESS MANAGED BLOCK" "$CLAUDE_MD" \
  && grep -qF "END SAZO-AI-HARNESS MANAGED BLOCK" "$CLAUDE_MD"; then
    TMP_FILE=$(mktemp)
    awk '
      /^# BEGIN SAZO-AI-HARNESS MANAGED BLOCK/ { skip=1; next }
      /^# END SAZO-AI-HARNESS MANAGED BLOCK/   { skip=0; next }
      !skip
    ' "$CLAUDE_MD" > "$TMP_FILE"

    TMP2=$(mktemp)
    awk 'NF{blank=0} !NF{blank++} blank<=2' "$TMP_FILE" > "$TMP2"

    mv "$TMP2" "$CLAUDE_MD"
    rm -f "$TMP_FILE"
    info "managed block removed (user content preserved)"
    removed=$((removed + 1))
else
    skip "CLAUDE.md managed block"
fi

# --- 7. OpenCode config cleanup ---

echo ""
echo "[7/8] Cleaning OpenCode config..."

if [ -f "$OPENCODE_CONFIG" ] && command -v jq &>/dev/null; then
    HARNESS_AGENTS=$(jq -r '
      .agent // {} | to_entries[]
      | select(.value.prompt // "" | contains("sazo-ai-harness"))
      | .key
    ' "$OPENCODE_CONFIG" 2>/dev/null)

    if [ -n "$HARNESS_AGENTS" ]; then
        TMP_FILE=$(mktemp)
        jq '
          .agent |= with_entries(
            select(.value.prompt // "" | contains("sazo-ai-harness") | not)
          )
          | if .agent == {} then del(.agent) else . end
        ' "$OPENCODE_CONFIG" > "$TMP_FILE" && mv "$TMP_FILE" "$OPENCODE_CONFIG"
        info "OpenCode agent entries removed"
        removed=$((removed + 1))
    else
        skip "OpenCode agent entries"
    fi
else
    skip "OpenCode config"
fi

# --- 8. Installation directory removal ---

echo ""
echo "[8/8] Removing installation directory..."

INSTALL_DIR_LEGACY="$HOME/.config/sazo-ai-prompts"

for d in "$INSTALL_DIR" "$INSTALL_DIR_LEGACY"; do
    if [ -d "$d" ]; then
        rm -rf "$d"
        info "$d removed"
        removed=$((removed + 1))
    fi
done

[ ! -d "$INSTALL_DIR" ] && [ ! -d "$INSTALL_DIR_LEGACY" ] && skip "installation directory"

# --- Done ---

echo ""
echo "==================================="
echo "  Uninstall Complete"
echo "==================================="
echo ""
echo "  Removed: ${removed} items"
echo "  Skipped: ${skipped} items (already absent)"
echo ""
