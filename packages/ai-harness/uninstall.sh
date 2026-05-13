#!/bin/bash
#
# AI Harness Uninstaller
# 설치된 모든 ai-harness 아티팩트를 깔끔하게 제거합니다.
#
# 사용법:
#   curl -fsSL https://raw.githubusercontent.com/SAZO-KR/sazo-toolkit/main/packages/ai-harness/uninstall.sh | bash
#   # 또는
#   bash packages/ai-harness/uninstall.sh
#

set -uo pipefail

INSTALL_DIR="$HOME/.config/sazo-ai-harness"
INSTALL_DIR_LEGACY="$HOME/.config/sazo-ai-prompts"
SETTINGS_FILE="$HOME/.claude/settings.json"
[ -L "$SETTINGS_FILE" ] && SETTINGS_FILE=$(readlink -f "$SETTINGS_FILE" 2>/dev/null || readlink "$SETTINGS_FILE")
CLAUDE_MD="$HOME/.claude/CLAUDE.md"
OPENCODE_CONFIG="$HOME/.config/opencode/opencode.json"

removed=0
skipped=0

info()  { printf "  ✓ %s\n" "$1"; }
skip()  { printf "  - %s (없음)\n" "$1"; skipped=$((skipped + 1)); }
warn()  { printf "  ⚠ %s\n" "$1" >&2; }

echo "==================================="
echo "  AI Harness Uninstaller"
echo "==================================="
echo ""

# --- 1. awake 프로세스 중지 ---

echo "[1/8] awake 프로세스 정리..."

AWAKE_PID_FILE="$INSTALL_DIR/awake.pid"
if [ -f "$AWAKE_PID_FILE" ]; then
    AWAKE_PID=$(cat "$AWAKE_PID_FILE" 2>/dev/null)
    if [ -n "$AWAKE_PID" ] && kill -0 "$AWAKE_PID" 2>/dev/null; then
        kill "$AWAKE_PID" 2>/dev/null && info "awake 프로세스 종료 (PID $AWAKE_PID)"
    else
        info "awake 프로세스 이미 종료됨"
    fi
    rm -f "$AWAKE_PID_FILE" "$INSTALL_DIR/awake.expires"
else
    skip "awake 프로세스"
fi

# --- 2. LaunchAgent 해제 ---

echo ""
echo "[2/8] LaunchAgent 정리..."

PLIST="$HOME/Library/LaunchAgents/com.opencode.claude-sync.plist"
PLIST_LEGACY="$HOME/Library/LaunchAgents/shop.sazo.claude-sleep-guard.plist"

found_plist=0
for p in "$PLIST" "$PLIST_LEGACY"; do
    if [ -f "$p" ]; then
        launchctl unload "$p" 2>/dev/null || true
        rm -f "$p"
        info "$(basename "$p") 해제 및 삭제"
        removed=$((removed + 1))
        found_plist=1
    fi
done
[ "$found_plist" -eq 0 ] && skip "LaunchAgent"

# --- 3. 심볼릭 링크 제거 (sazo-ai-harness를 가리키는 것만) ---

echo ""
echo "[3/8] 심볼릭 링크 제거..."

remove_harness_symlinks() {
    local dir="$1"
    local label="$2"
    local count=0

    if [ ! -d "$dir" ]; then
        skip "$label"
        return
    fi

    for item in "$dir"/*; do
        [ -L "$item" ] || continue
        target=$(readlink "$item" 2>/dev/null || true)
        if echo "$target" | grep -qE "sazo-ai-harness|sazo-ai-prompts"; then
            rm -f "$item"
            count=$((count + 1))
        fi
    done

    if [ "$count" -gt 0 ]; then
        info "$label: ${count}개 링크 제거"
        removed=$((removed + count))
    else
        skip "$label 링크"
    fi
}

remove_harness_symlinks "$HOME/.claude/commands" "~/.claude/commands"
remove_harness_symlinks "$HOME/.claude/skills" "~/.claude/skills"
remove_harness_symlinks "$HOME/.claude/agents" "~/.claude/agents"
remove_harness_symlinks "$HOME/.config/opencode/commands" "~/.config/opencode/commands"

# --- 4. ~/.claude/settings.json에서 ai-harness hook 제거 ---

echo ""
echo "[4/8] settings.json hook 정리..."

if [ -f "$SETTINGS_FILE" ] && command -v jq &>/dev/null; then
    TMP_FILE=$(mktemp)

    # sazo-ai-harness 경로를 참조하는 hook 항목 제거
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

      # SAZO env 항목 제거
      | if .env then
          .env |= with_entries(select(.key | startswith("SAZO_") | not))
          | if .env == {} then del(.env) else . end
        else . end
    ' "$SETTINGS_FILE" > "$TMP_FILE" 2>/dev/null

    if [ $? -eq 0 ] && [ -s "$TMP_FILE" ]; then
        mv "$TMP_FILE" "$SETTINGS_FILE"
        info "sazo-ai-harness hook 및 env 항목 제거 완료"
        removed=$((removed + 1))
    else
        rm -f "$TMP_FILE"
        warn "settings.json 정리 실패 — 수동 확인 필요"
    fi
else
    if [ ! -f "$SETTINGS_FILE" ]; then
        skip "settings.json"
    else
        warn "jq 미설치 — settings.json 수동 정리 필요"
    fi
fi

# --- 5. CLAUDE.md managed block 제거 ---

echo ""
echo "[5/8] CLAUDE.md managed block 제거..."

if [ -f "$CLAUDE_MD" ] \
  && grep -qF "BEGIN SAZO-AI-HARNESS MANAGED BLOCK" "$CLAUDE_MD" \
  && grep -qF "END SAZO-AI-HARNESS MANAGED BLOCK" "$CLAUDE_MD"; then
    TMP_FILE=$(mktemp)
    awk '
      /^# BEGIN SAZO-AI-HARNESS MANAGED BLOCK/ { skip=1; next }
      /^# END SAZO-AI-HARNESS MANAGED BLOCK/   { skip=0; next }
      !skip
    ' "$CLAUDE_MD" > "$TMP_FILE"

    # 연속 빈 줄 3개 이상을 2개로 정리
    TMP2=$(mktemp)
    awk 'NF{blank=0} !NF{blank++} blank<=2' "$TMP_FILE" > "$TMP2"

    mv "$TMP2" "$CLAUDE_MD"
    rm -f "$TMP_FILE"
    info "managed block 제거 (사용자 콘텐츠 보존)"
    removed=$((removed + 1))
else
    skip "CLAUDE.md managed block"
fi

# --- 6. OpenCode config에서 ai-harness agent 항목 제거 ---

echo ""
echo "[6/8] OpenCode config 정리..."

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
        info "OpenCode agent 항목 제거"
        removed=$((removed + 1))
    else
        skip "OpenCode agent 항목"
    fi
else
    skip "OpenCode config"
fi

# --- 7. CLI 심볼릭 링크, 세션 상태, 로그 제거 ---

echo ""
echo "[7/8] CLI 도구 및 상태 파일 제거..."

for f in "$HOME/.local/bin/awake" \
         "$HOME/.local/bin/sazo-workflow" \
         "$HOME/.local/bin/claude-sync-notify.sh"; do
    if [ -L "$f" ]; then
        target=$(readlink "$f" 2>/dev/null || true)
        if echo "$target" | grep -qE "sazo-ai-harness|sazo-ai-prompts"; then
            rm -f "$f"
            info "$(basename "$f") 제거 (심볼릭 링크)"
            removed=$((removed + 1))
        else
            skip "$(basename "$f") (sazo-ai-harness 외 링크 — 보존)"
        fi
    elif [ -f "$f" ] && echo "$f" | grep -q "claude-sync-notify"; then
        rm -f "$f"
        info "$(basename "$f") 제거 (복사된 파일)"
        removed=$((removed + 1))
    elif [ -f "$f" ]; then
        skip "$(basename "$f") (사용자 파일 — 보존)"
    fi
done

for d in "$HOME/.claude/session-state"; do
    if [ -d "$d" ]; then
        rm -rf "$d"
        info "$(basename "$d")/ 제거"
        removed=$((removed + 1))
    fi
done

if [ -f "$HOME/.claude/logs/ai-harness-update.log" ]; then
    rm -f "$HOME/.claude/logs/ai-harness-update.log"
    info "ai-harness-update.log 제거"
    removed=$((removed + 1))
fi

# --- 8. 설치 디렉토리 전체 삭제 ---

echo ""
echo "[8/8] 설치 디렉토리 삭제..."

for d in "$INSTALL_DIR" "$INSTALL_DIR_LEGACY"; do
    if [ -d "$d" ]; then
        rm -rf "$d"
        info "$d 삭제 완료"
        removed=$((removed + 1))
    fi
done

[ ! -d "$INSTALL_DIR" ] && [ ! -d "$INSTALL_DIR_LEGACY" ] && skip "설치 디렉토리"

# --- 완료 ---

echo ""
echo "==================================="
echo "  제거 완료"
echo "==================================="
echo ""
echo "  제거됨: ${removed}건"
echo "  건너뜀: ${skipped}건 (이미 없음)"
echo ""
echo "참고:"
echo "  - RTK (brew install rtk)는 별도 관리됩니다. 제거: brew uninstall rtk"
echo "  - claude-sync는 별도 설치입니다. 제거: rm ~/.local/bin/claude-sync"
echo "  - OpenCode 플러그인/모델 설정은 보존됩니다."
echo ""
