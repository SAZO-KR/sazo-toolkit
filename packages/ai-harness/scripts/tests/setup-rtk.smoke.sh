#!/bin/bash
# setup-rtk.sh 멱등성 smoke test
#
# 목적: `bash -n` 문법 검사로는 못 잡는 **분기 로직 회귀**를 감지한다.
# - 각 초기 상태에서 exit 0 보장
# - 예상치 못한 state mutation 감지 (opt-out/init-done 마커 무단 생성,
#   settings.json 손상 시 무단 수정)
# - **2회 연속 호출 후 state 불변** (멱등성 핵심 원칙)
# - rtk init 분기는 fake rtk stub으로 커버
#
# 호스트 jq는 필요 (환경 시뮬레이션 PATH에 포함). rtk/brew는 stub.
# 실행: bash packages/ai-harness/scripts/tests/setup-rtk.smoke.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SETUP="$SCRIPT_DIR/setup-rtk.sh"

if [ ! -x "$SETUP" ]; then
    echo "FAIL: $SETUP not executable"
    exit 1
fi

# 호스트 jq 필수 — 없으면 설정 검증 분기를 테스트할 수 없음
JQ_BIN=$(command -v jq || true)
if [ -z "$JQ_BIN" ]; then
    echo "SKIP: jq not installed on host — smoke test requires jq to verify settings.json branches"
    exit 0
fi

SANDBOX=$(mktemp -d)
trap "rm -rf $SANDBOX" EXIT

# jq만 격리 bin 디렉토리에 심볼릭 링크. /opt/homebrew/bin 같은 곳에 rtk가 같이
# 있을 수 있어 dirname(jq)을 그대로 PATH에 넣으면 "rtk 없음" 시뮬레이션이 깨진다.
ISOLATED_BIN="$SANDBOX/bin"
mkdir -p "$ISOLATED_BIN"
ln -s "$JQ_BIN" "$ISOLATED_BIN/jq"

FAIL=0

assert_equal() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  OK   $label"
    else
        echo "  FAIL $label"
        echo "       expected=<$expected>"
        echo "       actual=<$actual>"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_absent() {
    local label="$1" path="$2"
    if [ ! -e "$path" ]; then
        echo "  OK   $label"
    else
        echo "  FAIL $label — unexpectedly exists: $path"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_present() {
    local label="$1" path="$2"
    if [ -e "$path" ]; then
        echo "  OK   $label"
    else
        echo "  FAIL $label — missing: $path"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_content() {
    local label="$1" path="$2" expected="$3"
    local actual
    actual=$(cat "$path" 2>/dev/null || echo "<missing>")
    if [ "$actual" = "$expected" ]; then
        echo "  OK   $label"
    else
        echo "  FAIL $label"
        echo "       expected=<$expected>"
        echo "       actual=<$actual>"
        FAIL=$((FAIL + 1))
    fi
}

# 디렉토리 상태 스냅샷 (멱등성 검증용)
# macOS는 shasum, Linux는 sha256sum을 기본 제공 — 둘 중 가용한 것 선택.
snapshot() {
    local dir="$1"
    local hash_cmd="shasum -a 256"
    command -v sha256sum >/dev/null 2>&1 && hash_cmd="sha256sum"
    find "$dir" -type f -print0 2>/dev/null \
        | sort -z \
        | xargs -0 -I {} sh -c "printf '%s:' \"\$1\"; $hash_cmd \"\$1\" 2>/dev/null | awk '{print \$1}'" _ {}
}

# rtk/brew 배제한 최소 PATH + jq 격리 심볼릭 포함
MIN_PATH="$ISOLATED_BIN:/usr/bin:/bin"

run_setup_quiet() {
    local home="$1"
    local path_override="${2:-$MIN_PATH}"
    env -i HOME="$home" PATH="$path_override" "$SETUP" --quiet 2>&1
}

# ─── Case 1: opt-out 마커 존재 ───
echo "Case 1: opt-out 마커 존재 → 즉시 exit 0, state mutation 없음"
H="$SANDBOX/c1"
mkdir -p "$H/.config/sazo-ai-harness" "$H/.claude"
touch "$H/.config/sazo-ai-harness/.rtk-optout"
echo '{}' > "$H/.claude/settings.json"

out=$(run_setup_quiet "$H")
rc=$?
assert_equal "exit code 0" "0" "$rc"
assert_equal "no stdout (quiet)" "" "$out"
assert_file_absent "no init-done marker" "$H/.config/sazo-ai-harness/.rtk-init-done"
assert_file_content "settings.json unchanged" "$H/.claude/settings.json" '{}'

# ─── Case 2: rtk 없음 + 유효 settings + jq 있음 ───
echo ""
echo "Case 2: rtk 없음 + quiet → exit 0, 마커 무단 생성 없음"
H="$SANDBOX/c2"
mkdir -p "$H/.config/sazo-ai-harness" "$H/.claude"
echo '{"permissions":{"allow":[]}}' > "$H/.claude/settings.json"

out=$(run_setup_quiet "$H")
rc=$?
assert_equal "exit code 0" "0" "$rc"
assert_equal "no stdout (quiet)" "" "$out"
assert_file_absent "no opt-out marker" "$H/.config/sazo-ai-harness/.rtk-optout"
assert_file_absent "no init-done marker" "$H/.config/sazo-ai-harness/.rtk-init-done"
assert_file_content "settings.json unchanged" "$H/.claude/settings.json" '{"permissions":{"allow":[]}}'

# ─── Case 3: settings.json 손상 (jq 있음) ───
echo ""
echo "Case 3: settings.json 손상 → exit 0, 파일 보존 (손상 감지 분기)"
H="$SANDBOX/c3"
mkdir -p "$H/.config/sazo-ai-harness" "$H/.claude"
echo 'not a json {{{' > "$H/.claude/settings.json"

out=$(run_setup_quiet "$H")
rc=$?
assert_equal "exit code 0" "0" "$rc"
assert_file_content "settings.json unchanged" "$H/.claude/settings.json" 'not a json {{{'
assert_file_absent "no init-done marker" "$H/.config/sazo-ai-harness/.rtk-init-done"

# ─── Case 4: rtk stub + hook 없음 → rtk init 호출 + init-done 생성 ───
echo ""
echo "Case 4: rtk stub 존재 + hook 미등록 → rtk init 호출, init-done 마커 생성"
H="$SANDBOX/c4"
mkdir -p "$H/.config/sazo-ai-harness" "$H/.claude" "$H/stub-bin"
echo '{"permissions":{"allow":[]}}' > "$H/.claude/settings.json"
LOG="$H/.rtk-call-log"

cat > "$H/stub-bin/rtk" <<'STUBEOF'
#!/bin/bash
# fake rtk — 인자 기록 + `init`이면 settings.json에 fake hook 주입해 실제 rtk 시뮬레이트.
# 실제 rtk init은 hooks.PreToolUse에 rtk-rewrite.sh를 등록하는데, 이를 흉내내야
# setup-rtk.sh의 두 번째 호출에서 "hook 이미 있음" 경로로 올바르게 분기된다.
echo "$@" >> "$HOME/.rtk-call-log"
if [ "${1:-}" = "init" ]; then
    cat > "$HOME/.claude/settings.json" <<'FAKE'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"fake-rtk-rewrite.sh"}]}]}}
FAKE
fi
exit 0
STUBEOF
chmod +x "$H/stub-bin/rtk"

STUB_PATH="$H/stub-bin:$MIN_PATH"
out=$(run_setup_quiet "$H" "$STUB_PATH")
rc=$?
assert_equal "exit code 0" "0" "$rc"
assert_file_content "rtk init called with correct args" "$LOG" "init --auto-patch --global"
assert_file_present "init-done marker created" "$H/.config/sazo-ai-harness/.rtk-init-done"

# Case 4 멱등성: 2회 연속 호출 후 state 불변
snap1=$(snapshot "$H/.config/sazo-ai-harness")
run_setup_quiet "$H" "$STUB_PATH" >/dev/null 2>&1
snap2=$(snapshot "$H/.config/sazo-ai-harness")
assert_equal "idempotent: config dir state unchanged after 2nd run" "$snap1" "$snap2"

# rtk init은 정확히 1회만 호출되어야 (마커 덕분에 2회차는 skip)
call_count=$(wc -l < "$LOG" | tr -d ' ')
assert_equal "rtk init called exactly once (marker prevents re-run)" "1" "$call_count"

# ─── Case 5: rtk stub + init-done 마커 + settings.json 부재 → 재등록 경로 ───
echo ""
echo "Case 5: init-done 마커 + settings.json 부재 → 마커 삭제 후 rtk init 재호출"
H="$SANDBOX/c5"
mkdir -p "$H/.config/sazo-ai-harness" "$H/.claude" "$H/stub-bin"
touch "$H/.config/sazo-ai-harness/.rtk-init-done"
# settings.json 파일 없음 (삭제된 상태 시뮬레이션)
LOG="$H/.rtk-call-log"

cat > "$H/stub-bin/rtk" <<'STUBEOF'
#!/bin/bash
echo "$@" >> "$HOME/.rtk-call-log"
exit 0
STUBEOF
chmod +x "$H/stub-bin/rtk"

STUB_PATH="$H/stub-bin:$MIN_PATH"
out=$(run_setup_quiet "$H" "$STUB_PATH")
rc=$?
assert_equal "exit code 0" "0" "$rc"
assert_file_content "rtk init re-called after settings.json disappeared" "$LOG" "init --auto-patch --global"
assert_file_present "init-done marker re-created" "$H/.config/sazo-ai-harness/.rtk-init-done"

echo ""
echo "─────────────────────"
if [ "$FAIL" -eq 0 ]; then
    echo "OK: All setup-rtk smoke tests passed"
    exit 0
else
    echo "FAIL: $FAIL assertion(s) failed"
    exit 1
fi
