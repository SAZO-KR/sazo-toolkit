#!/bin/bash
#
# AI Harness Root Installer
# Interactive menu for selecting and installing individual tools.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/SAZO-KR/sazo-toolkit/main/packages/ai-harness/install.sh | bash
#   # Or install specific tools non-interactively:
#   curl -fsSL ... | bash -s -- --tools awake
#   bash packages/ai-harness/install.sh --tools awake
#
set -euo pipefail

REPO_URL="https://github.com/SAZO-KR/sazo-toolkit.git"
INSTALL_DIR="$HOME/.config/sazo-ai-harness"
CREATED_INSTALL_DIR=0
INSTALL_FAILED=0
export SAZO_ROOT_INSTALL=1

cleanup() {
    if [ "${INSTALL_FAILED:-}" = "1" ] && [ "$CREATED_INSTALL_DIR" = "1" ] && [ -d "$INSTALL_DIR" ]; then
        rm -rf "$INSTALL_DIR"
    fi
}
trap cleanup EXIT

LIB_PATH=""
HARNESS_DIR=""

discover_tools() {
    local tools_dir="$HARNESS_DIR/tools"
    local tool_name
    for tool_dir in "$tools_dir"/*/; do
        [ -d "$tool_dir" ] || continue
        [ -f "$tool_dir/tool.sh" ] || continue
        tool_name="$(basename "$tool_dir")"
        printf '%s\n' "$tool_name"
    done
}

load_tool_metadata() {
    local tool_name="$1"
    local tool_sh="$HARNESS_DIR/tools/$tool_name/tool.sh"
    [ -f "$tool_sh" ] || return 1
    (
        TOOL_NAME="" TOOL_DESC="" TOOL_VERSION="" TOOL_PLATFORM="" TOOL_REQUIRES_SUDO=""
        source "$tool_sh"
        printf '%s\t%s\t%s\t%s\t%s\n' "$TOOL_NAME" "$TOOL_DESC" "$TOOL_VERSION" "$TOOL_PLATFORM" "$TOOL_REQUIRES_SUDO"
    )
}

parse_args() {
    local tools_arg=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --tools)
                shift
                tools_arg="${1:-}"
                [ -z "$tools_arg" ] && { echo "Error: --tools requires a comma-separated list" >&2; exit 1; }
                SELECTED_TOOLS="$(echo "$tools_arg" | tr ',' ' ')"
                export SAZO_NON_INTERACTIVE=1
                shift
                ;;
            --yes|-y)
                export SAZO_NON_INTERACTIVE=1
                shift
                ;;
            --help|-h)
                echo "Usage: install.sh [--tools tool1,tool2] [--yes]"
                echo "  --tools   Comma-separated list of tools to install (non-interactive)"
                echo "  --yes     Accept all defaults (non-interactive)"
                echo "  --help    Show this help"
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                exit 1
                ;;
        esac
    done
}

SELECTED_TOOLS=""

echo "==================================="
echo "  AI Harness Installer"
echo "==================================="
echo ""

# --- Prerequisites ---

if ! command -v git &>/dev/null; then
    echo "Error: git is required." >&2
    INSTALL_FAILED=1
    exit 1
fi

parse_args "$@"

# --- Source common library ---

# Clone/update first to get the library
if [ -d "$INSTALL_DIR/.git" ]; then
    echo "Updating existing installation..."
    cd "$INSTALL_DIR"
    SPARSE_LIST=$(git sparse-checkout list 2>/dev/null || echo "")
    if echo "$SPARSE_LIST" | grep -q "packages/ai-prompts"; then
        git sparse-checkout set packages/ai-harness
    fi
    git pull --ff-only 2>/dev/null || echo "Warning: Could not update (local changes?)" >&2
    cd - >/dev/null
else
    echo "Installing to $INSTALL_DIR..."
    rm -rf "$INSTALL_DIR"
    mkdir -p "$(dirname "$INSTALL_DIR")"
    CREATED_INSTALL_DIR=1
    git clone --sparse --filter=blob:none --depth=1 --single-branch -b main "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    git sparse-checkout set packages/ai-harness
    cd - >/dev/null
fi

HARNESS_DIR="$INSTALL_DIR/packages/ai-harness"

if [ ! -d "$HARNESS_DIR/tools" ]; then
    echo "Error: ai-harness package not found or incomplete" >&2
    INSTALL_FAILED=1
    exit 1
fi

LIB_PATH="$HARNESS_DIR/lib/installer-common.sh"
if [ ! -f "$LIB_PATH" ]; then
    echo "Error: installer-common.sh not found" >&2
    INSTALL_FAILED=1
    exit 1
fi
source "$LIB_PATH"

# --- Discover available tools ---

AVAILABLE_TOOLS=()
TOOL_DESCS=()

while IFS= read -r tool_name; do
    [ -z "$tool_name" ] && continue
    metadata="$(load_tool_metadata "$tool_name")" || continue
    AVAILABLE_TOOLS+=("$tool_name")
    desc="$(echo "$metadata" | cut -f2)"
    TOOL_DESCS+=("$desc")
done <<< "$(discover_tools)"

if [ ${#AVAILABLE_TOOLS[@]} -eq 0 ]; then
    log_error "No installable tools found"
    INSTALL_FAILED=1
    exit 1
fi

# --- Tool selection ---

if [ -n "$SELECTED_TOOLS" ]; then
    TOOLS_TO_INSTALL=()
    for tool in $SELECTED_TOOLS; do
        found=0
        for available in "${AVAILABLE_TOOLS[@]}"; do
            if [ "$tool" = "$available" ]; then
                TOOLS_TO_INSTALL+=("$tool")
                found=1
                break
            fi
        done
        if [ "$found" -eq 0 ]; then
            log_warn "Unknown tool: $tool (skipping)"
        fi
    done
elif [ "${SAZO_NON_INTERACTIVE:-0}" = "1" ]; then
    TOOLS_TO_INSTALL=("${AVAILABLE_TOOLS[@]}")
else
    echo "Available tools:"
    echo ""
    for i in "${!AVAILABLE_TOOLS[@]}"; do
        printf "  %2d) %-15s %s\n" "$((i + 1))" "${AVAILABLE_TOOLS[$i]}" "${TOOL_DESCS[$i]}"
    done
    echo ""
    echo "Enter tool numbers to install (comma-separated), or 'all':"
    printf "> "

    if [ -e /dev/tty ]; then
        exec 3</dev/tty
        read -r selection <&3
        exec 3<&-
    elif [ -t 0 ]; then
        read -r selection
    else
        selection="all"
    fi

    if [ "$selection" = "all" ] || [ "$selection" = "a" ]; then
        TOOLS_TO_INSTALL=("${AVAILABLE_TOOLS[@]}")
    else
        TOOLS_TO_INSTALL=()
        IFS=',' read -ra nums <<< "$selection"
        for num in "${nums[@]}"; do
            num=$(echo "$num" | tr -d ' ')
            idx=$((num - 1))
            if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#AVAILABLE_TOOLS[@]}" ]; then
                TOOLS_TO_INSTALL+=("${AVAILABLE_TOOLS[$idx]}")
            fi
        done
    fi
fi

if [ ${#TOOLS_TO_INSTALL[@]} -eq 0 ]; then
    echo "No tools selected. Exiting."
    exit 0
fi

echo ""
echo "Installing: ${TOOLS_TO_INSTALL[*]}"
echo ""

# --- Symlinks (commands, skills, agents) ---

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

        if [[ "$filename" == _* ]] || [[ "$filename" == .* ]]; then
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

if [ -d "$HOME/.config/opencode" ]; then
    local_oc_cmd_dir="$HOME/.config/opencode/commands"
    mkdir -p "$local_oc_cmd_dir"
    echo ""
    echo "OpenCode commands:"
    link_files "$HARNESS_DIR/commands" "$local_oc_cmd_dir"
fi

# --- Tool-provided commands/skills/agents ---
# A tool may ship its own commands/skills/agents under tools/<name>/. The root
# installer owns ~/.claude linking (see CLAUDE.md §3), so link them here, gated on
# the tools actually being installed — a tool's command only appears when the tool
# is. Without this, /<tool> commands are never linked for fresh installs.
for tool in "${TOOLS_TO_INSTALL[@]}"; do
    tool_src="$HARNESS_DIR/tools/$tool"
    if [ -d "$tool_src/commands" ]; then
        echo "Tool commands ($tool):"
        link_files "$tool_src/commands" "$HOME/.claude/commands"
        if [ -d "$HOME/.config/opencode" ]; then
            mkdir -p "$HOME/.config/opencode/commands"
            link_files "$tool_src/commands" "$HOME/.config/opencode/commands"
        fi
    fi
    if [ -d "$tool_src/skills" ]; then
        echo "Tool skills ($tool):"
        link_files "$tool_src/skills" "$HOME/.claude/skills"
    fi
    if [ -d "$tool_src/agents" ]; then
        echo "Tool agents ($tool):"
        link_files "$tool_src/agents" "$HOME/.claude/agents"
    fi
done

# --- Legacy agent cleanup ---

OLD_AGENT_NAMES=(
    sisyphus prometheus metis momus atlas oracle
    librarian explore multimodal-looker document-writer frontend-engineer
)
ORPHANS=()
for name in "${OLD_AGENT_NAMES[@]}"; do
    f="$HOME/.claude/agents/$name.md"
    if [ -L "$f" ] || [ -e "$f" ]; then
        ORPHANS+=("$f")
    fi
done

if [ ${#ORPHANS[@]} -gt 0 ]; then
    echo ""
    echo "Legacy agent files detected:"
    for f in "${ORPHANS[@]}"; do
        echo "  - $f"
    done
    if ask_yes_no "Remove these legacy files?" n; then
        rm -f "${ORPHANS[@]}"
        log_info "Removed ${#ORPHANS[@]} legacy files"
    fi
fi

# --- Install selected tools ---

INSTALL_RESULTS=()

for tool in "${TOOLS_TO_INSTALL[@]}"; do
    echo ""
    echo "--- Installing $tool ---"
    echo ""

    TOOL_INSTALLER="$HARNESS_DIR/tools/$tool/install.sh"
    if [ ! -f "$TOOL_INSTALLER" ]; then
        log_warn "No installer found for $tool, skipping"
        INSTALL_RESULTS+=("$tool: SKIPPED (no installer)")
        continue
    fi

    if bash "$TOOL_INSTALLER"; then
        INSTALL_RESULTS+=("$tool: OK")
    else
        exit_code=$?
        log_error "$tool installer failed (exit $exit_code)"
        INSTALL_RESULTS+=("$tool: FAILED (exit $exit_code)")
    fi
done

# --- Summary ---

VERSION=$(git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")

echo ""
echo "==================================="
echo "  Installation Complete!"
echo "==================================="
echo ""
echo "Version: $VERSION"
echo ""
echo "Results:"
for result in "${INSTALL_RESULTS[@]}"; do
    echo "  $result"
done
echo ""
echo "Update: re-run this script or reinstall."
echo "Uninstall: bash $HARNESS_DIR/uninstall.sh"
echo ""

trap - EXIT