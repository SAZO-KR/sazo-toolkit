#!/bin/bash
# sync_awake_cleanup_legacy() smoke — auto-update.sh 의 self-heal 함수가 구
# sleep-guard 잔재를 정확히 정리하고 정상 항목을 보존하는지 검증.
#
# 격리 전략:
#   - HOME=$TMP 로 fork된 bash 서브쉘에서 함수 실행 → 실제 사용자 ~/.config /
#     ~/.claude / ~/Library 영향 방지
#   - launchctl 호출은 sandbox HOME 에 plist를 두면 launchctl이 실제 시스템에
#     load 시도하나 미존재 path라 silent fail. 추가 모킹 불필요.
#   - jq filter 격리 테스트는 별도 fixture 사용.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
HARNESS_DIR="$PROJECT_DIR/packages/ai-harness"
AUTO_UPDATE="$HARNESS_DIR/scripts/auto-update.sh"

if [ ! -f "$AUTO_UPDATE" ]; then
    echo "FAIL: auto-update.sh not found" >&2
    exit 1
fi

TMP=$(mktemp -d -t sleep-guard-cleanup.XXXXXX)
trap "rm -rf $TMP" EXIT

PASS=0
FAIL=0
assert() {
    local label="$1" cond="$2"
    if eval "$cond"; then
        echo "  ✓ $label"
        PASS=$((PASS+1))
    else
        echo "  ✗ $label" >&2
        FAIL=$((FAIL+1))
    fi
}

# ─── 1. legacy file cleanup ───
echo "[1] legacy file cleanup (plist / hook symlink / marker / /tmp)"
SANDBOX="$TMP/sandbox1"
mkdir -p "$SANDBOX/Library/LaunchAgents" "$SANDBOX/.claude/hooks" "$SANDBOX/.config/sazo-ai-harness"
# 잔재 fixture
touch "$SANDBOX/Library/LaunchAgents/shop.sazo.claude-sleep-guard.plist"
ln -s /nonexistent "$SANDBOX/.claude/hooks/sazo-caffeinate-session.sh"
ln -s /nonexistent "$SANDBOX/.claude/hooks/sazo-sleep-watchdog.sh"
touch "$SANDBOX/.config/sazo-ai-harness/.sleep-guard-init-done"
touch "$SANDBOX/.config/sazo-ai-harness/.sleep-guard-optout"
touch "$SANDBOX/.config/sazo-ai-harness/.sleep-guard-notify-throttle"
touch "$SANDBOX/.config/sazo-ai-harness/.sleep-guard-optin-notify-throttle"
# fixture USER 와 다른 prefix — cleanup이 본인 외 디렉토리 미터치 검증.
OTHER_USER_TMP="/tmp/claude-awake-different-prefix-$$"
mkdir -p "$OTHER_USER_TMP"

# 격리 실행: HOME, USER override + AUTOUPDATE_LOAD_ONLY 로 함수만 로드
# USER 는 OTHER_USER_TMP 와 다른 값
HOME="$SANDBOX" USER="cleanup-test-$$" AUTOUPDATE_LOAD_ONLY=1 \
    bash -c "source '$AUTO_UPDATE'; sync_awake_cleanup_legacy" 2>/dev/null || true

assert "plist removed"             '[ ! -e "$SANDBOX/Library/LaunchAgents/shop.sazo.claude-sleep-guard.plist" ]'
assert "caffeinate hook removed"   '[ ! -L "$SANDBOX/.claude/hooks/sazo-caffeinate-session.sh" ]'
assert "watchdog hook removed"     '[ ! -L "$SANDBOX/.claude/hooks/sazo-sleep-watchdog.sh" ]'
assert "init-done marker removed"  '[ ! -e "$SANDBOX/.config/sazo-ai-harness/.sleep-guard-init-done" ]'
assert "optout marker removed"     '[ ! -e "$SANDBOX/.config/sazo-ai-harness/.sleep-guard-optout" ]'
assert "notify marker removed"     '[ ! -e "$SANDBOX/.config/sazo-ai-harness/.sleep-guard-notify-throttle" ]'
assert "optin marker removed"      '[ ! -e "$SANDBOX/.config/sazo-ai-harness/.sleep-guard-optin-notify-throttle" ]'
# /tmp는 USER suffix 기준 — cleanup-test-$$ 은 함수가 정리 안 함. 정리 대상은 USER=USER 와 동일 경로만.
# fixture는 다른 prefix 라 의도적으로 잔존 → 본인 외 디렉토리 미터치 검증 가능.
assert "/tmp other-prefix dir NOT touched"  '[ -d "$OTHER_USER_TMP" ]'
rm -rf "$OTHER_USER_TMP"

# ─── 2. /tmp 본인 디렉토리만 정리 ───
echo "[2] /tmp self-user only"
SANDBOX2="$TMP/sandbox2"
mkdir -p "$SANDBOX2/.config/sazo-ai-harness"
TEST_USER="my-cleanup-test-$$"
SELF_TMP="/tmp/claude-awake-${TEST_USER}"
OTHER_TMP="/tmp/claude-awake-other-user-$$"
mkdir -p "$SELF_TMP" "$OTHER_TMP"
HOME="$SANDBOX2" USER="$TEST_USER" AUTOUPDATE_LOAD_ONLY=1 \
    bash -c "source '$AUTO_UPDATE'; sync_awake_cleanup_legacy" 2>/dev/null || true

assert "self /tmp dir removed"          '[ ! -d "$SELF_TMP" ]'
assert "other-user /tmp dir untouched"  '[ -d "$OTHER_TMP" ]'
rm -rf "$OTHER_TMP"

# ─── 3. settings.json jq filter — partial removal (sazo + 정상 hook 혼재) ───
echo "[3] settings.json — partial removal"
SANDBOX3="$TMP/sandbox3"
mkdir -p "$SANDBOX3/.claude"
cat > "$SANDBOX3/.claude/settings.json" <<'EOF'
{
  "permissions": {"allow": ["Bash(ls:*)"]},
  "hooks": {
    "UserPromptSubmit": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "/path/to/sazo-caffeinate-session.sh heartbeat"}]},
      {"matcher": "*", "hooks": [{"type": "command", "command": "/other/hook.sh"}]}
    ],
    "PreToolUse": [
      {"matcher": "Bash(git commit:*)", "hooks": [{"type": "command", "command": "/path/to/pre-commit-lint.sh"}]}
    ]
  }
}
EOF
HOME="$SANDBOX3" USER="test-$$" AUTOUPDATE_LOAD_ONLY=1 \
    bash -c "source '$AUTO_UPDATE'; sync_awake_cleanup_legacy" 2>/dev/null || true

OUT=$(cat "$SANDBOX3/.claude/settings.json")
assert "sazo hook removed"            '! echo "$OUT" | grep -q "sazo-caffeinate-session.sh"'
assert "other UserPromptSubmit kept"  'echo "$OUT" | grep -q "/other/hook.sh"'
assert "PreToolUse hook preserved"    'echo "$OUT" | grep -q "pre-commit-lint.sh"'
assert "permissions preserved"        'echo "$OUT" | grep -q "Bash(ls:\*)"'

# ─── 4. settings.json — sazo-only matcher 전체 제거 + 빈 key del ───
echo "[4] settings.json — sazo-only matcher dropped, empty key deleted"
SANDBOX4="$TMP/sandbox4"
mkdir -p "$SANDBOX4/.claude"
cat > "$SANDBOX4/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "Stop": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "/path/to/sazo-caffeinate-session.sh stop"}]}
    ],
    "PreToolUse": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "/rtk.sh"}]}
    ]
  }
}
EOF
HOME="$SANDBOX4" USER="test-$$" AUTOUPDATE_LOAD_ONLY=1 \
    bash -c "source '$AUTO_UPDATE'; sync_awake_cleanup_legacy" 2>/dev/null || true

# Stop 키 자체가 제거되어야 함 (모든 hook이 sazo만이었으므로)
HAS_STOP=$(jq 'has("hooks") and (.hooks | has("Stop"))' "$SANDBOX4/.claude/settings.json")
assert "Stop key deleted entirely"    '[ "$HAS_STOP" = "false" ]'
assert "PreToolUse rtk preserved"     'grep -q "/rtk.sh" "$SANDBOX4/.claude/settings.json"'

# ─── 5. 원래 없던 key는 빈 array로 삽입되지 않음 ───
echo "[5] no empty-key insertion"
SANDBOX5="$TMP/sandbox5"
mkdir -p "$SANDBOX5/.claude"
# UserPromptSubmit / PostToolUse / Stop 모두 없는 상태
cat > "$SANDBOX5/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "/path/to/sazo-caffeinate-session.sh other"}]}
    ]
  }
}
EOF
HOME="$SANDBOX5" USER="test-$$" AUTOUPDATE_LOAD_ONLY=1 \
    bash -c "source '$AUTO_UPDATE'; sync_awake_cleanup_legacy" 2>/dev/null || true

# 입력에 없던 key 가 빈 [] 로 추가되면 안 됨
HAS_UPS=$(jq '.hooks | has("UserPromptSubmit")' "$SANDBOX5/.claude/settings.json")
HAS_PTU=$(jq '.hooks | has("PostToolUse")' "$SANDBOX5/.claude/settings.json")
HAS_STOP=$(jq '.hooks | has("Stop")' "$SANDBOX5/.claude/settings.json")
assert "UserPromptSubmit key not inserted"  '[ "$HAS_UPS" = "false" ]'
assert "PostToolUse key not inserted"        '[ "$HAS_PTU" = "false" ]'
assert "Stop key not inserted"               '[ "$HAS_STOP" = "false" ]'
# PreToolUse 자체는 cleanup 대상 아님 — sazo hook 그대로 잔존 (의도된 scope)
assert "PreToolUse untouched (out of scope)" 'grep -q "sazo-caffeinate-session.sh" "$SANDBOX5/.claude/settings.json"'

# ─── 6. settings.json symlink 처리 ───
echo "[6] settings.json symlink not overwritten"
SANDBOX6="$TMP/sandbox6"
mkdir -p "$SANDBOX6/.claude"
mkdir -p "$SANDBOX6/dotfiles"
cat > "$SANDBOX6/dotfiles/settings.json" <<'EOF'
{
  "hooks": {
    "UserPromptSubmit": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "/path/to/sazo-caffeinate-session.sh heartbeat"}]},
      {"matcher": "*", "hooks": [{"type": "command", "command": "/keep.sh"}]}
    ]
  }
}
EOF
ln -s "$SANDBOX6/dotfiles/settings.json" "$SANDBOX6/.claude/settings.json"
HOME="$SANDBOX6" USER="test-$$" AUTOUPDATE_LOAD_ONLY=1 \
    bash -c "source '$AUTO_UPDATE'; sync_awake_cleanup_legacy" 2>/dev/null || true

assert "symlink still a symlink"           '[ -L "$SANDBOX6/.claude/settings.json" ]'
assert "real file updated"                 '! grep -q "sazo-caffeinate-session.sh" "$SANDBOX6/dotfiles/settings.json"'
assert "real file kept other hook"         'grep -q "/keep.sh" "$SANDBOX6/dotfiles/settings.json"'

# ─── 7. settings.json 부재 시 noop ───
echo "[7] settings.json absent — noop"
SANDBOX7="$TMP/sandbox7"
mkdir -p "$SANDBOX7/.claude"
# settings.json 없음
HOME="$SANDBOX7" USER="test-$$" AUTOUPDATE_LOAD_ONLY=1 \
    bash -c "source '$AUTO_UPDATE'; sync_awake_cleanup_legacy" 2>/dev/null
RC=$?
assert "noop exits 0"          '[ "$RC" -eq 0 ]'
assert "no settings created"   '[ ! -e "$SANDBOX7/.claude/settings.json" ]'

# ─── 8. 멱등성 — 두 번 호출해도 동일 결과 ───
echo "[8] idempotent — second call no error"
HOME="$SANDBOX3" USER="test-$$" AUTOUPDATE_LOAD_ONLY=1 \
    bash -c "source '$AUTO_UPDATE'; sync_awake_cleanup_legacy" 2>/dev/null
RC=$?
assert "second cleanup exits 0"     '[ "$RC" -eq 0 ]'
assert "no sazo hook re-introduced" '! grep -q "sazo-caffeinate-session.sh" "$SANDBOX3/.claude/settings.json"'

# ─── 결과 ───
echo ""
echo "PASS: $PASS, FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "✅ sleep-guard-cleanup smoke tests passed"
