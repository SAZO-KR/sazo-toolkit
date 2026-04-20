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
# - macOS는 shasum, Linux는 sha256sum을 기본 제공 — 둘 중 가용한 것 선택.
# - `sort -z`는 GNU extension이라 구 BSD sort(일부 macOS 버전)에서 미지원 →
#   sandbox 파일명은 우리가 완전 제어(공백/개행 없음)하므로 일반 `sort` 사용.
snapshot() {
    local dir="$1"
    local hash_cmd="shasum -a 256"
    command -v sha256sum >/dev/null 2>&1 && hash_cmd="sha256sum"
    find "$dir" -type f 2>/dev/null | sort | while IFS= read -r f; do
        printf '%s:' "$f"
        $hash_cmd "$f" 2>/dev/null | awk '{print $1}'
    done
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
assert_file_present "allowlist marker created" "$H/.config/sazo-ai-harness/.rtk-allowlist-done"

# allowlist 실제로 주입되었는지 내용 확인 (대표 패턴 2종 present).
# rtk 스텁이 덮어쓴 settings.json에 union-merge로 추가되어야 한다.
aws_present=$("$JQ_BIN" -r '.permissions.allow | contains(["Bash(rtk aws * describe-*:*)"])' "$H/.claude/settings.json" 2>/dev/null)
assert_equal "allowlist contains aws describe pattern" "true" "$aws_present"
kubectl_present=$("$JQ_BIN" -r '.permissions.allow | contains(["Bash(rtk kubectl get:*)"])' "$H/.claude/settings.json" 2>/dev/null)
assert_equal "allowlist contains kubectl get pattern" "true" "$kubectl_present"

# 민감/mutation 접두사는 allowlist에 **없어야** 한다 — 과도한 범위 회귀 방지
# (aws get-*는 sts get-session-token / secretsmanager get-secret-value 등 자격증명 발급
# 위험이 있어 의도적으로 제외됨. kubectl config view도 토큰 노출 위험.)
get_absent=$("$JQ_BIN" -r '.permissions.allow | any(. == "Bash(rtk aws * get-*:*)")' "$H/.claude/settings.json" 2>/dev/null)
assert_equal "allowlist does NOT include aws get-* (credential exposure risk)" "false" "$get_absent"
delete_absent=$("$JQ_BIN" -r '.permissions.allow | any(. == "Bash(rtk aws * delete-*:*)")' "$H/.claude/settings.json" 2>/dev/null)
assert_equal "allowlist does NOT include aws delete-*" "false" "$delete_absent"
kubecfg_absent=$("$JQ_BIN" -r '.permissions.allow | any(. == "Bash(rtk kubectl config view:*)")' "$H/.claude/settings.json" 2>/dev/null)
assert_equal "allowlist does NOT include kubectl config view (token exposure)" "false" "$kubecfg_absent"
ls_absent=$("$JQ_BIN" -r '.permissions.allow | any(. == "Bash(rtk aws * ls:*)")' "$H/.claude/settings.json" 2>/dev/null)
assert_equal "allowlist does NOT include aws ls (pattern scoping uncertain)" "false" "$ls_absent"

# Case 4 멱등성: 2회 연속 호출 후 state 불변
snap1=$(snapshot "$H/.config/sazo-ai-harness")
settings_snap1=$(cat "$H/.claude/settings.json")
run_setup_quiet "$H" "$STUB_PATH" >/dev/null 2>&1
snap2=$(snapshot "$H/.config/sazo-ai-harness")
settings_snap2=$(cat "$H/.claude/settings.json")
assert_equal "idempotent: config dir state unchanged after 2nd run" "$snap1" "$snap2"
assert_equal "idempotent: settings.json unchanged after 2nd run (marker prevents re-inject)" "$settings_snap1" "$settings_snap2"

# rtk init은 정확히 1회만 호출되어야 (마커 덕분에 2회차는 skip)
call_count=$(wc -l < "$LOG" | tr -d ' ')
assert_equal "rtk init called exactly once (marker prevents re-run)" "1" "$call_count"

# ─── Case 5: rtk stub + init-done 마커 + settings.json 부재 → 재등록 경로 ───
echo ""
echo "Case 5: init-done + allowlist 마커 + settings.json 부재 → 두 마커 삭제 후 allowlist 재주입"
H="$SANDBOX/c5"
mkdir -p "$H/.config/sazo-ai-harness" "$H/.claude" "$H/stub-bin"
# 사용자가 이전에 완전 셋업을 끝낸 상태 — 두 마커 모두 존재
touch "$H/.config/sazo-ai-harness/.rtk-init-done"
touch "$H/.config/sazo-ai-harness/.rtk-allowlist-done"
# settings.json 파일 없음 (reset/reinstall 시뮬레이션)
LOG="$H/.rtk-call-log"

# 실제 rtk init처럼 hook 등록된 settings.json을 다시 깔아주는 stub.
# 이 stub 없으면 inject_rtk_allowlist가 `[ -f $SETTINGS ] || return`으로 skip.
cat > "$H/stub-bin/rtk" <<'STUBEOF'
#!/bin/bash
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
assert_file_content "rtk init re-called after settings.json disappeared" "$LOG" "init --auto-patch --global"
assert_file_present "init-done marker re-created" "$H/.config/sazo-ai-harness/.rtk-init-done"
# 회귀 방지 (Codex P2): 이전 라운드의 stale allowlist 마커가 재주입을 막지 않아야 한다.
assert_file_present "allowlist marker re-created (Codex P2 regression guard)" "$H/.config/sazo-ai-harness/.rtk-allowlist-done"
describe_present=$("$JQ_BIN" -r '.permissions.allow | contains(["Bash(rtk aws * describe-*:*)"])' "$H/.claude/settings.json" 2>/dev/null)
assert_equal "allowlist re-injected into regenerated settings.json" "true" "$describe_present"

# ─── Case 6: hook 이미 등록됨 (마커 없음) → init-done + allowlist 둘 다 생성 ───
echo ""
echo "Case 6: hook 이미 등록된 상태(마커 없음) → 마커 생성 + allowlist 주입"
H="$SANDBOX/c6"
mkdir -p "$H/.config/sazo-ai-harness" "$H/.claude" "$H/stub-bin"
# rtk hook 이미 등록된 settings.json — rtk init이 깐 상태를 재현
cat > "$H/.claude/settings.json" <<'HOOKED'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"rtk-rewrite.sh"}]}]}}
HOOKED

# rtk 바이너리는 PATH에 있어야 step 3를 통과하지만, init은 불려서는 안 된다 (step 5에서 early return).
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
assert_file_present "init-done marker created" "$H/.config/sazo-ai-harness/.rtk-init-done"
assert_file_present "allowlist marker created" "$H/.config/sazo-ai-harness/.rtk-allowlist-done"
assert_file_absent "rtk init NOT called (hook already present)" "$LOG"

aws_present=$("$JQ_BIN" -r '.permissions.allow | contains(["Bash(rtk aws * list-*:*)"])' "$H/.claude/settings.json" 2>/dev/null)
assert_equal "allowlist contains aws list pattern" "true" "$aws_present"

# 기존 hook 정의는 보존되어야 한다 (union만, 덮어쓰기 금지)
hook_preserved=$("$JQ_BIN" -r '.hooks.PreToolUse[0].hooks[0].command' "$H/.claude/settings.json" 2>/dev/null)
assert_equal "existing hook preserved (not overwritten)" "rtk-rewrite.sh" "$hook_preserved"

# ─── Case 7: .permissions가 비표준 타입(문자열) → 주입 skip, 원본 보존 ───
echo ""
echo "Case 7: .permissions 비-object → 조용히 skip, settings.json 손상 없음"
H="$SANDBOX/c7"
mkdir -p "$H/.config/sazo-ai-harness" "$H/.claude" "$H/stub-bin"
# hook은 이미 있지만 .permissions가 문자열인 비표준 상태
cat > "$H/.claude/settings.json" <<'WEIRD'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"rtk-rewrite.sh"}]}]},"permissions":"disabled"}
WEIRD
original_settings=$(cat "$H/.claude/settings.json")

cat > "$H/stub-bin/rtk" <<'STUBEOF'
#!/bin/bash
exit 0
STUBEOF
chmod +x "$H/stub-bin/rtk"

STUB_PATH="$H/stub-bin:$MIN_PATH"
out=$(run_setup_quiet "$H" "$STUB_PATH")
rc=$?
assert_equal "exit code 0" "0" "$rc"
assert_file_content "non-object .permissions preserved verbatim" "$H/.claude/settings.json" "$original_settings"
assert_file_absent "allowlist marker NOT created (skipped)" "$H/.config/sazo-ai-harness/.rtk-allowlist-done"

# ─── Case 8: init-done 마커 + hook 모두 존재 → step 4 allowlist 주입 경로 ───
echo ""
echo "Case 8: init-done + hook 있음 (step 4 경로) → allowlist 주입"
H="$SANDBOX/c8"
mkdir -p "$H/.config/sazo-ai-harness" "$H/.claude" "$H/stub-bin"
touch "$H/.config/sazo-ai-harness/.rtk-init-done"
cat > "$H/.claude/settings.json" <<'HOOKED'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"rtk-rewrite.sh"}]}]}}
HOOKED

cat > "$H/stub-bin/rtk" <<'STUBEOF'
#!/bin/bash
# step 4에서 rtk 호출 없어야 정상
echo "$@" >> "$HOME/.rtk-call-log"
exit 0
STUBEOF
chmod +x "$H/stub-bin/rtk"

STUB_PATH="$H/stub-bin:$MIN_PATH"
out=$(run_setup_quiet "$H" "$STUB_PATH")
rc=$?
assert_equal "exit code 0" "0" "$rc"
assert_file_present "allowlist marker created via step 4" "$H/.config/sazo-ai-harness/.rtk-allowlist-done"
assert_file_absent "rtk NOT invoked (step 4 early-return)" "$H/.rtk-call-log"
describe_present=$("$JQ_BIN" -r '.permissions.allow | contains(["Bash(rtk aws * describe-*:*)"])' "$H/.claude/settings.json" 2>/dev/null)
assert_equal "allowlist contains aws describe pattern (step 4 path)" "true" "$describe_present"

# ─── Case 9: .permissions.allow가 비-array(문자열) → 주입 skip, 원본 보존 ───
echo ""
echo "Case 9: .permissions.allow 비-array → skip, 침묵 no-op 방지"
H="$SANDBOX/c9"
mkdir -p "$H/.config/sazo-ai-harness" "$H/.claude" "$H/stub-bin"
cat > "$H/.claude/settings.json" <<'WEIRD'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"rtk-rewrite.sh"}]}]},"permissions":{"allow":"not-an-array"}}
WEIRD
original_settings=$(cat "$H/.claude/settings.json")

cat > "$H/stub-bin/rtk" <<'STUBEOF'
#!/bin/bash
exit 0
STUBEOF
chmod +x "$H/stub-bin/rtk"

STUB_PATH="$H/stub-bin:$MIN_PATH"
out=$(run_setup_quiet "$H" "$STUB_PATH")
rc=$?
assert_equal "exit code 0" "0" "$rc"
assert_file_content "non-array .permissions.allow preserved verbatim" "$H/.claude/settings.json" "$original_settings"
assert_file_absent "allowlist marker NOT created (type guard)" "$H/.config/sazo-ai-harness/.rtk-allowlist-done"

echo ""
echo "─────────────────────"
if [ "$FAIL" -eq 0 ]; then
    echo "OK: All setup-rtk smoke tests passed"
    exit 0
else
    echo "FAIL: $FAIL assertion(s) failed"
    exit 1
fi
