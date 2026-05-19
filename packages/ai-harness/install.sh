#!/bin/bash
#
# AI Harness Installer (Lite)
# Commands, Skills, Agents 심볼릭 링크 + awake CLI 설치.
#
# 사용법:
#   curl -fsSL https://raw.githubusercontent.com/SAZO-KR/sazo-toolkit/main/packages/ai-harness/install.sh | bash
#   # 또는
#   bash packages/ai-harness/install.sh
#

set -euo pipefail

REPO_URL="https://github.com/SAZO-KR/sazo-toolkit.git"
INSTALL_DIR="$HOME/.config/sazo-ai-harness"
CREATED_INSTALL_DIR=0

cleanup() {
    if [ "${INSTALL_FAILED:-}" = "1" ] && [ "$CREATED_INSTALL_DIR" = "1" ] && [ -d "$INSTALL_DIR" ]; then
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
echo "  AI Harness Installer (Lite)"
echo "==================================="
echo ""

# --- Prerequisites ---

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
    CREATED_INSTALL_DIR=1

    git clone --sparse --filter=blob:none --depth=1 --single-branch -b main "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    git sparse-checkout set packages/ai-harness
fi

HARNESS_DIR="$INSTALL_DIR/packages/ai-harness"

if [ ! -d "$HARNESS_DIR/commands" ]; then
    echo "Error: ai-harness package not found or incomplete"
    INSTALL_FAILED=1
    exit 1
fi

# --- Symlinks ---

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

        # Skip template files/folders and .DS_Store
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
    echo "Legacy agent files detected (renamed or removed in this package):"
    for f in "${ORPHANS[@]}"; do
        echo "  - $f"
    done
    echo ""
    if ask_yes_no "기존 에이전트 파일이 남아있으면 이름이 바뀐 새 에이전트를 가릴 수 있습니다. 삭제할까요?" n; then
        rm -f "${ORPHANS[@]}"
        echo "  제거 완료 (${#ORPHANS[@]}개)"
    else
        echo "  건너뜀. 구 이름('oracle', 'explore' 등)으로 호출 시 stale 프롬프트가 노출될 수 있음."
    fi
fi

# --- OpenCode commands (if installed) ---

if [ -d "$HOME/.config/opencode" ]; then
    local_oc_cmd_dir="$HOME/.config/opencode/commands"
    mkdir -p "$local_oc_cmd_dir"
    echo ""
    echo "OpenCode commands:"
    link_files "$HARNESS_DIR/commands" "$local_oc_cmd_dir"
fi

# --- awake CLI (macOS) ---

AWAKE_SCRIPT="$HARNESS_DIR/scripts/awake/awake.sh"
AWAKE_HELPER_SRC="$HARNESS_DIR/scripts/awake/awake-helper.sh"
AWAKE_SYMLINK="$HOME/.local/bin/awake"
AWAKE_HELPER_DST="/usr/local/libexec/sazo-ai-harness/awake-helper"
AWAKE_SUDOERS_FILE="/etc/sudoers.d/sazo-ai-harness-awake"

if [ -f "$AWAKE_SCRIPT" ] && [ "$(uname -s)" = "Darwin" ]; then
    echo ""
    echo "Installing awake CLI..."
    mkdir -p "$HOME/.local/bin"

    # BEGIN AWAKE_INSTALL_GUARD
    install_awake=1
    if [ -L "$AWAKE_SYMLINK" ]; then
        existing_target=$(readlink "$AWAKE_SYMLINK" 2>/dev/null || true)
        if ! echo "$existing_target" | grep -qE "sazo-ai-harness|sazo-ai-prompts"; then
            echo "  Skip: awake (existing symlink → $existing_target, not managed by ai-harness)"
            install_awake=0
        fi
    elif [ -e "$AWAKE_SYMLINK" ]; then
        echo "  Skip: awake (local file exists at $AWAKE_SYMLINK)"
        install_awake=0
    fi

    if [ "$install_awake" -eq 1 ]; then
        ln -sfn "$AWAKE_SCRIPT" "$AWAKE_SYMLINK"
        echo "  Installed: $AWAKE_SYMLINK"
    fi
    # END AWAKE_INSTALL_GUARD

    case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *)
            echo "  Warning: $HOME/.local/bin is not in PATH"
            echo "    echo 'export PATH=\$HOME/.local/bin:\$PATH' >> ~/.zshrc"
            ;;
    esac

    if [ -f "$AWAKE_HELPER_SRC" ]; then
        echo ""
        echo "awake closed-lid helper (optional):"
        echo "  - helper path: $AWAKE_HELPER_DST"
        echo "  - needed for lid-closed execution persistence"
        echo "  - requires sudo because pmset is global"

        if ask_yes_no "Install root-owned awake helper now?" n; then
            sudo install -d -o root -g wheel -m 0755 "$(dirname "$AWAKE_HELPER_DST")"
            sudo install -o root -g wheel -m 0755 "$AWAKE_HELPER_SRC" "$AWAKE_HELPER_DST"
            echo "  Installed helper: $AWAKE_HELPER_DST"

            if ask_yes_no "Install passwordless sudoers entry for awake helper?" n; then
                tmp_sudoers="$(mktemp)"
                cat > "$tmp_sudoers" <<EOF
# SAZO-AI-HARNESS-AWAKE
${USER:-$(id -un)} ALL=(root) NOPASSWD: $AWAKE_HELPER_DST *
EOF
                sudo visudo -cf "$tmp_sudoers" >/dev/null
                sudo cp "$tmp_sudoers" "$AWAKE_SUDOERS_FILE"
                sudo chmod 0440 "$AWAKE_SUDOERS_FILE"
                rm -f "$tmp_sudoers"
                echo "  Installed sudoers: $AWAKE_SUDOERS_FILE"
            else
                echo "  Skipped sudoers install. 'awake on/off' may require sudo in a terminal."
            fi
        else
            echo "  Skipped helper install. closed-lid awake mode will not work until helper is installed."
        fi
    fi
fi

# --- Done ---

VERSION=$(git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")

echo ""
echo "==================================="
echo "  Installation Complete!"
echo "==================================="
echo ""
echo "Version: $VERSION"
echo ""
echo "Commands:"
echo "  /awake on|off|status|extend|reset   macOS closed-lid 실행 유지"
echo "  /weekly-report                주간 업무 보고서 생성"
echo ""
echo "Update: re-run this script or reinstall."
echo "Uninstall: bash $HARNESS_DIR/uninstall.sh"
echo ""
