#!/bin/bash
# workflow-hooks.smoke.sh — workflow enforcement hooks 통합 smoke test.
# 격리된 SAZO_STATE_DIR + 임시 git repo로 실 환경 영향 없음.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$(cd "$HERE/../.." && pwd)"
HOOKS="$HARNESS/scripts/hooks"

# 공통 환경
export SAZO_WORKFLOW_HOOKS_ENABLED=1   # opt-in으로 hook 활성
export SAZO_STATE_DIR="/tmp/sazo-workflow-smoke-$$"
TMP_REPO="/tmp/sazo-smoke-repo-$$"
TMP_WT="/tmp/sazo-smoke-worktree-$$"

cleanup() {
    rm -rf "$SAZO_STATE_DIR" "$TMP_REPO" "$TMP_WT"
}
trap cleanup EXIT

mkdir -p "$TMP_REPO"
(
    cd "$TMP_REPO"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    git commit -q --allow-empty -m "init"
)

FAIL=0
PASS=0

assert_exit() {
    local expected="$1" actual="$2" label="$3"
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS + 1))
        echo "  ✓ $label"
    else
        FAIL=$((FAIL + 1))
        echo "  ✗ $label (expected exit=$expected, got $actual)"
    fi
}

run_hook() {
    local hook_script="$1" mode="${2:-}" payload="$3"
    local rc
    if [ -n "$mode" ]; then
        echo "$payload" | bash "$hook_script" "$mode" >/dev/null 2>&1
    else
        echo "$payload" | bash "$hook_script" >/dev/null 2>&1
    fi
    rc=$?
    echo "$rc"
}

# stderr 캡처 — pass 케이스에서 unexpected error 없는지 검증
capture_stderr() {
    local hook_script="$1" mode="${2:-}" payload="$3"
    if [ -n "$mode" ]; then
        echo "$payload" | bash "$hook_script" "$mode" 2>&1 >/dev/null
    else
        echo "$payload" | bash "$hook_script" 2>&1 >/dev/null
    fi
}

# ============================================================
echo "=== opt-in flag ==="

# Plan 06: narrow hooks (pre-worktree-gate 등) default ON.
# 비활성화에는 SAZO_DISABLE_NARROW_HOOKS=1 필요.
rc=$(SAZO_DISABLE_NARROW_HOOKS=1 run_hook "$HOOKS/pre-worktree-gate.sh" "" \
    "{\"session_id\":\"o1\",\"cwd\":\"$TMP_REPO\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/x\"}}")
assert_exit 0 "$rc" "narrow opt-out: pre-worktree-gate passes"

# Broad hooks (state-machine)는 default OFF — SAZO_WORKFLOW_HOOKS_ENABLED 미설정 시 통과
rc=$(SAZO_WORKFLOW_HOOKS_ENABLED= run_hook "$HOOKS/workflow-state-machine.sh" "pre" \
    "{\"session_id\":\"o2\",\"cwd\":\"$TMP_REPO\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/x\"}}")
assert_exit 0 "$rc" "broad opt-out: state-machine passes"

# ============================================================
echo ""
echo "=== pre-worktree-gate ==="

rm -rf "$SAZO_STATE_DIR"
rc=$(run_hook "$HOOKS/pre-worktree-gate.sh" "" \
    '{"session_id":"w0","cwd":"/tmp","tool_name":"Write","tool_input":{"file_path":"/tmp/x"}}')
assert_exit 0 "$rc" "non-git cwd → pass"

rm -rf "$SAZO_STATE_DIR"
rc=$(run_hook "$HOOKS/pre-worktree-gate.sh" "" \
    "{\"session_id\":\"w1\",\"cwd\":\"$TMP_REPO\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/x\"}}")
assert_exit 2 "$rc" "main branch Write → block"

rm -rf "$SAZO_STATE_DIR"
rc=$(run_hook "$HOOKS/pre-worktree-gate.sh" "" \
    "{\"session_id\":\"w2\",\"cwd\":\"$TMP_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls -la\"}}")
assert_exit 0 "$rc" "read-only Bash on main → pass"

rm -rf "$SAZO_STATE_DIR"
rc=$(run_hook "$HOOKS/pre-worktree-gate.sh" "" \
    "{\"session_id\":\"w3\",\"cwd\":\"$TMP_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp /tmp/a /tmp/b\"}}")
assert_exit 0 "$rc" "cp on main → pass (not classified mutating)"

rm -rf "$SAZO_STATE_DIR"
rc=$(run_hook "$HOOKS/pre-worktree-gate.sh" "" \
    "{\"session_id\":\"w4\",\"cwd\":\"$TMP_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m foo\"}}")
assert_exit 2 "$rc" "git commit on main → block"

rm -rf "$SAZO_STATE_DIR"
rc=$(SAZO_SKIP_WORKTREE_GATE=1 run_hook "$HOOKS/pre-worktree-gate.sh" "" \
    "{\"session_id\":\"w5\",\"cwd\":\"$TMP_REPO\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/x\"}}")
assert_exit 0 "$rc" "SAZO_SKIP_WORKTREE_GATE=1 override"

# V4 reviewer #1 regression: --detach in compound with mutating subcommand → must block
rm -rf "$SAZO_STATE_DIR"
rc=$(run_hook "$HOOKS/pre-worktree-gate.sh" "" \
    "{\"session_id\":\"w6\",\"cwd\":\"$TMP_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git switch --detach abc && git push origin main\"}}")
assert_exit 2 "$rc" "compound (--detach + push) on main → still block (no carve-out hijack)"

# --detach 단독은 carve-out 작동 (read-only HEAD movement)
rm -rf "$SAZO_STATE_DIR"
rc=$(run_hook "$HOOKS/pre-worktree-gate.sh" "" \
    "{\"session_id\":\"w7\",\"cwd\":\"$TMP_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git switch --detach HEAD\"}}")
assert_exit 0 "$rc" "git switch --detach HEAD alone → pass (read-only)"

# V5 reviewer #1 regression: compound where one segment is --detach but another segment is mutating switch
rm -rf "$SAZO_STATE_DIR"
rc=$(run_hook "$HOOKS/pre-worktree-gate.sh" "" \
    "{\"session_id\":\"w8\",\"cwd\":\"$TMP_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git switch existing-branch && git switch --detach HEAD\"}}")
assert_exit 2 "$rc" "compound (mutating switch + --detach switch) → block (no carve-out hijack)"

# V5 reviewer #1: same with checkout file (mutating) + --detach
rm -rf "$SAZO_STATE_DIR"
rc=$(run_hook "$HOOKS/pre-worktree-gate.sh" "" \
    "{\"session_id\":\"w9\",\"cwd\":\"$TMP_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git checkout file.txt && git switch --detach HEAD\"}}")
assert_exit 2 "$rc" "compound (checkout file + --detach) → block"

# V5 reviewer #2: flags between subcommand and --detach should still carve-out
rm -rf "$SAZO_STATE_DIR"
rc=$(run_hook "$HOOKS/pre-worktree-gate.sh" "" \
    "{\"session_id\":\"w10\",\"cwd\":\"$TMP_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git switch -f --detach abc123\"}}")
assert_exit 0 "$rc" "git switch -f --detach (flags before --detach) → pass"

# Codex P2: append redirection (>>) 도 mutating으로 잡혀야
rm -rf "$SAZO_STATE_DIR"
rc=$(run_hook "$HOOKS/pre-worktree-gate.sh" "" \
    "{\"session_id\":\"w_append\",\"cwd\":\"$TMP_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo foo >> tracked.txt\"}}")
assert_exit 2 "$rc" "append redirection (>>) on main → block"

# Codex V8 P1: touch/mkdir/ln 파일 생성은 mutating
rm -rf "$SAZO_STATE_DIR"
rc=$(run_hook "$HOOKS/pre-worktree-gate.sh" "" \
    "{\"session_id\":\"w_touch\",\"cwd\":\"$TMP_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"touch file\"}}")
assert_exit 2 "$rc" "touch file on main → block"
rm -rf "$SAZO_STATE_DIR"
rc=$(run_hook "$HOOKS/pre-worktree-gate.sh" "" \
    "{\"session_id\":\"w_mkdir\",\"cwd\":\"$TMP_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mkdir newdir\"}}")
assert_exit 2 "$rc" "mkdir on main → block"

# Codex V6 P1: git tag v1.2.3 (인자 있음)은 mutating
rm -rf "$SAZO_STATE_DIR"
rc=$(run_hook "$HOOKS/pre-worktree-gate.sh" "" \
    "{\"session_id\":\"w_tag1\",\"cwd\":\"$TMP_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git tag v1.2.3\"}}")
assert_exit 2 "$rc" "git tag v1.2.3 on main → block"
rm -rf "$SAZO_STATE_DIR"
rc=$(run_hook "$HOOKS/pre-worktree-gate.sh" "" \
    "{\"session_id\":\"w_tag2\",\"cwd\":\"$TMP_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git tag -a foo -m bar\"}}")
assert_exit 2 "$rc" "git tag -a (annotate) on main → block"
rm -rf "$SAZO_STATE_DIR"
rc=$(run_hook "$HOOKS/pre-worktree-gate.sh" "" \
    "{\"session_id\":\"w_tag3\",\"cwd\":\"$TMP_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git tag -l\"}}")
assert_exit 0 "$rc" "git tag -l (list) on main → pass (read-only)"

# Codex V4 P2: stdout fd(1) redirect도 mutating
rm -rf "$SAZO_STATE_DIR"
rc=$(run_hook "$HOOKS/pre-worktree-gate.sh" "" \
    "{\"session_id\":\"w_fd1\",\"cwd\":\"$TMP_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo foo 1>tracked.txt\"}}")
assert_exit 2 "$rc" "1> redirect on main → block"
rm -rf "$SAZO_STATE_DIR"
rc=$(run_hook "$HOOKS/pre-worktree-gate.sh" "" \
    "{\"session_id\":\"w_fd1a\",\"cwd\":\"$TMP_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"printf x 1>>tracked.txt\"}}")
assert_exit 2 "$rc" "1>> redirect on main → block"

# stderr fd(2) redirect는 mutating 아님 (2>/dev/null 흔한 패턴)
rm -rf "$SAZO_STATE_DIR"
rc=$(run_hook "$HOOKS/pre-worktree-gate.sh" "" \
    "{\"session_id\":\"w_fd2\",\"cwd\":\"$TMP_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"grep foo bar 2>/dev/null\"}}")
assert_exit 0 "$rc" "2>/dev/null on main → pass (not mutating)"

# Codex P1: worktree gate auto-completed 이후에도 main branch 재검사
rm -rf "$SAZO_STATE_DIR"
# 1회차: non-protected 통과 → state에 worktree completed 기록됨
FEATURE_WT="/tmp/sazo-smoke-feature-$$"
git worktree add -b smoke-feature "$FEATURE_WT" >/dev/null 2>&1
(cd "$FEATURE_WT" && git commit --allow-empty -m feature -q)
rc=$(run_hook "$HOOKS/pre-worktree-gate.sh" "" \
    "{\"session_id\":\"w_recheck\",\"cwd\":\"$FEATURE_WT\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/x\"}}")
# feature branch에선 pass
if [ "$rc" = "0" ]; then echo "  (setup: feature write passed)"; fi
# 2회차: same session, main repo로 이동. stage marker auto-completed 있어도 재검사해야
rc=$(run_hook "$HOOKS/pre-worktree-gate.sh" "" \
    "{\"session_id\":\"w_recheck\",\"cwd\":\"$TMP_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\"}}")
assert_exit 2 "$rc" "recheck after auto-completed: main commit → block"
# cleanup
git worktree remove --force "$FEATURE_WT" >/dev/null 2>&1

# V6 reviewer #1: pass 케이스에서 hook stderr 비어 있어야 함 (`local: can only be used in a function` 같은 노이즈 차단)
rm -rf "$SAZO_STATE_DIR"
err=$(capture_stderr "$HOOKS/pre-worktree-gate.sh" "" \
    "{\"session_id\":\"w11\",\"cwd\":\"$TMP_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git switch --detach HEAD\"}}")
if [ -z "$err" ]; then
    PASS=$((PASS + 1))
    echo "  ✓ pre-worktree-gate stderr clean on pass case"
else
    FAIL=$((FAIL + 1))
    echo "  ✗ pre-worktree-gate stderr leaked: $err"
fi

# ============================================================
echo ""
echo "=== pre-exploration-gate ==="

rm -rf "$SAZO_STATE_DIR"
rc=$(run_hook "$HOOKS/pre-exploration-gate.sh" "" \
    '{"session_id":"e1","cwd":"/tmp","tool_name":"Grep","tool_input":{"pattern":"foo"},"model":"claude-sonnet-4-6"}')
assert_exit 0 "$rc" "sonnet Grep → pass"

rm -rf "$SAZO_STATE_DIR"
for i in 1 2 3 4; do
    rc=$(run_hook "$HOOKS/pre-exploration-gate.sh" "" \
        '{"session_id":"e2","cwd":"/tmp","tool_name":"Grep","tool_input":{"pattern":"foo"},"model":"claude-opus-4-7"}')
    if [ "$i" -le 2 ]; then
        assert_exit 0 "$rc" "opus Grep #$i → soft pass"
    else
        assert_exit 2 "$rc" "opus Grep #$i → block"
    fi
done

# Codex V9 P2: SAZO_ALLOW_GREP_ONCE one-shot 소진
rm -rf "$SAZO_STATE_DIR"
for _ in 1 2 3 4; do
    run_hook "$HOOKS/pre-exploration-gate.sh" "" \
        '{"session_id":"once","cwd":"/tmp","tool_name":"Grep","tool_input":{"pattern":"foo"},"model":"claude-opus-4-7"}' >/dev/null
done
rc=$(SAZO_ALLOW_GREP_ONCE=1 run_hook "$HOOKS/pre-exploration-gate.sh" "" \
    '{"session_id":"once","cwd":"/tmp","tool_name":"Grep","tool_input":{"pattern":"foo"},"model":"claude-opus-4-7"}')
assert_exit 0 "$rc" "GREP_ONCE first use → bypass"
rc=$(SAZO_ALLOW_GREP_ONCE=1 run_hook "$HOOKS/pre-exploration-gate.sh" "" \
    '{"session_id":"once","cwd":"/tmp","tool_name":"Grep","tool_input":{"pattern":"foo"},"model":"claude-opus-4-7"}')
assert_exit 2 "$rc" "GREP_ONCE consumed → block (not infinite bypass)"

# git grep should also trigger
rm -rf "$SAZO_STATE_DIR"
rc=$(run_hook "$HOOKS/pre-exploration-gate.sh" "" \
    '{"session_id":"e3","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"git grep -r foo"},"model":"claude-opus-4-7"}')
assert_exit 0 "$rc" "opus git grep #1 → soft pass (counted as exploration)"

# Decay: post-hook Task subagent decrements explore_count
rm -rf "$SAZO_STATE_DIR"
for _ in 1 2 3; do
    run_hook "$HOOKS/pre-exploration-gate.sh" "" \
        '{"session_id":"e4","cwd":"/tmp","tool_name":"Grep","tool_input":{"pattern":"foo"},"model":"claude-opus-4-7"}' >/dev/null
done
# Now blocked. Run code-searcher Task post → decrement
run_hook "$HOOKS/workflow-state-machine.sh" "post" \
    '{"session_id":"e4","cwd":"/tmp","tool_name":"Task","tool_input":{"subagent_type":"code-searcher"}}' >/dev/null
# Next grep should soft-pass (count went from 3→2)
rc=$(run_hook "$HOOKS/pre-exploration-gate.sh" "" \
    '{"session_id":"e4","cwd":"/tmp","tool_name":"Grep","tool_input":{"pattern":"foo"},"model":"claude-opus-4-7"}')
assert_exit 2 "$rc" "after decay: count=3, still over threshold"

# ============================================================
echo ""
echo "=== workflow-state-machine (Write/Edit soft warn) ==="

STATE_HOOK="$HOOKS/workflow-state-machine.sh"

rm -rf "$SAZO_STATE_DIR"
# 처음 3회 Write soft warn (exit 0)
for i in 1 2 3 4; do
    rc=$(run_hook "$STATE_HOOK" "pre" \
        '{"session_id":"sm1","cwd":"/tmp","tool_name":"Write","tool_input":{"file_path":"/tmp/x"}}')
    if [ "$i" -le 3 ]; then
        assert_exit 0 "$rc" "Write #$i without research → soft warn (exit 0)"
    else
        assert_exit 2 "$rc" "Write #$i without research → hard block"
    fi
done

# After research subagent, research stage passed → soft warn restarts on plan
rm -rf "$SAZO_STATE_DIR"
run_hook "$STATE_HOOK" "post" \
    '{"session_id":"sm2","cwd":"/tmp","tool_name":"Task","tool_input":{"subagent_type":"code-searcher"}}' >/dev/null
rc=$(run_hook "$STATE_HOOK" "pre" \
    '{"session_id":"sm2","cwd":"/tmp","tool_name":"Write","tool_input":{"file_path":"/tmp/x"}}')
assert_exit 0 "$rc" "after research → Write soft warn on plan (exit 0)"

# After plan-drafter subagent, plan stage passed
run_hook "$STATE_HOOK" "post" \
    '{"session_id":"sm2","cwd":"/tmp","tool_name":"Task","tool_input":{"subagent_type":"plan-drafter"}}' >/dev/null
rc=$(run_hook "$STATE_HOOK" "pre" \
    '{"session_id":"sm2","cwd":"/tmp","tool_name":"Write","tool_input":{"file_path":"/tmp/x"}}')
assert_exit 0 "$rc" "after plan → Write soft warn on approval (always soft)"

echo ""
echo "=== workflow-state-machine (gh pr create hard block) ==="

# Without ci, gh pr create blocks
rm -rf "$SAZO_STATE_DIR"
rc=$(run_hook "$STATE_HOOK" "pre" \
    '{"session_id":"pr1","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"gh pr create --title foo"}}')
assert_exit 2 "$rc" "gh pr create without ci → hard block"

# With SAZO_ALLOW_CI_SKIP=1, ci is auto-skipped, then review block
rm -rf "$SAZO_STATE_DIR"
rc=$(SAZO_ALLOW_CI_SKIP=1 run_hook "$STATE_HOOK" "pre" \
    '{"session_id":"pr2","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"gh pr create --title foo"}}')
assert_exit 2 "$rc" "SAZO_ALLOW_CI_SKIP set, but review missing → block"

# Add review, then SAZO_ALLOW_CI_SKIP allows pr create
run_hook "$STATE_HOOK" "post" \
    '{"session_id":"pr2","cwd":"/tmp","tool_name":"Task","tool_input":{"subagent_type":"code-reviewer"}}' >/dev/null
rc=$(SAZO_ALLOW_CI_SKIP=1 run_hook "$STATE_HOOK" "pre" \
    '{"session_id":"pr2","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"gh pr create --title foo"}}')
assert_exit 0 "$rc" "SAZO_ALLOW_CI_SKIP + review → pass"

echo ""
echo "=== validator: approval/ci require by != auto-claude ==="

rm -rf "$SAZO_STATE_DIR"
# Source lib in subshell, manually mark approval as auto-claude
(
    source "$HOOKS/lib/session-state.sh"
    SAZO_SESSION_ID="val1" SAZO_CWD="/tmp" state_init "val1" "/tmp"
    stage_mark "val1" "approval" "completed" "auto-claude" "self-mark" "/tmp"
)
# Validator should reject this
(
    source "$HOOKS/lib/session-state.sh"
    if SAZO_CWD="/tmp" stage_is_passed "val1" "approval"; then
        echo "  ✗ approval auto-claude should NOT pass validator"
        exit 1
    else
        echo "  ✓ approval auto-claude blocked by validator"
        exit 0
    fi
) && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

# By 'user' WITHOUT plan_approved_at → still fail (defense-in-depth)
rm -rf "$SAZO_STATE_DIR"
(
    source "$HOOKS/lib/session-state.sh"
    SAZO_SESSION_ID="val2a" SAZO_CWD="/tmp" state_init "val2a" "/tmp"
    stage_mark "val2a" "approval" "completed" "user" "fake" "/tmp"
    # plan_approved_at 비어 있음
)
(
    source "$HOOKS/lib/session-state.sh"
    if SAZO_CWD="/tmp" stage_is_passed "val2a" "approval"; then
        echo "  ✗ approval by=user without plan_approved_at should fail"
        exit 1
    else
        echo "  ✓ approval by=user without plan_approved_at rejected"
        exit 0
    fi
) && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

# By 'user' AND plan_approved_at set → pass
rm -rf "$SAZO_STATE_DIR"
(
    source "$HOOKS/lib/session-state.sh"
    SAZO_SESSION_ID="val2b" SAZO_CWD="/tmp" state_init "val2b" "/tmp"
    state_set_str "val2b" ".plan_approved_at" "$(date +%Y-%m-%dT%H:%M:%S%z)" "/tmp"
    stage_mark "val2b" "approval" "completed" "user" "/approved" "/tmp"
)
(
    source "$HOOKS/lib/session-state.sh"
    if SAZO_CWD="/tmp" stage_is_passed "val2b" "approval"; then
        echo "  ✓ approval by=user + plan_approved_at passes validator"
        exit 0
    fi
    exit 1
) && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

echo ""
echo "=== state file cwd-keying ==="

rm -rf "$SAZO_STATE_DIR"
(
    source "$HOOKS/lib/session-state.sh"
    state_init "samesid" "/path/A" "opus"
    stage_mark "samesid" "research" "completed" "auto" "test" "/path/A"
    state_init "samesid" "/path/B" "opus"
    if stage_is_passed "samesid" "research" "/path/B"; then
        echo "  ✗ research leaked from /path/A to /path/B"
        exit 1
    else
        echo "  ✓ different cwd → independent state"
        exit 0
    fi
) && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

echo ""
echo "=== /skip lib operations ==="

# /skip plan with reason → state honored
rm -rf "$SAZO_STATE_DIR"
(
    source "$HOOKS/lib/session-state.sh"
    state_init "skip2" "/tmp" "opus"
    stage_mark "skip2" "plan" "skipped" "user" "≤5줄 typo" "/tmp"
    if stage_is_passed "skip2" "plan" "/tmp"; then
        echo "  ✓ /skip plan marker honored"
        exit 0
    fi
    exit 1
) && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

# Validator: approval skip should NOT pass even with by=user (skipped 인정 안 함)
rm -rf "$SAZO_STATE_DIR"
(
    source "$HOOKS/lib/session-state.sh"
    state_init "skip3" "/tmp" "opus"
    stage_mark "skip3" "approval" "skipped" "user" "user-skip" "/tmp"
    if stage_is_passed "skip3" "approval" "/tmp"; then
        echo "  ✗ approval skip should not pass validator"
        exit 1
    else
        echo "  ✓ approval skip rejected (only completed by=user + plan_approved_at)"
        exit 0
    fi
) && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

# Validator: ci skip with by=user → pass (SAZO_ALLOW_CI_SKIP path)
rm -rf "$SAZO_STATE_DIR"
(
    source "$HOOKS/lib/session-state.sh"
    state_init "skip4" "/tmp" "opus"
    stage_mark "skip4" "ci" "skipped" "user" "SAZO_ALLOW_CI_SKIP" "/tmp"
    if stage_is_passed "skip4" "ci" "/tmp"; then
        echo "  ✓ ci skip by=user passes (env override path)"
        exit 0
    fi
    exit 1
) && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

# Validator: ci skip by=auto-claude (자가 위장) → reject
rm -rf "$SAZO_STATE_DIR"
(
    source "$HOOKS/lib/session-state.sh"
    state_init "skip5" "/tmp" "opus"
    stage_mark "skip5" "ci" "skipped" "auto-claude" "self-skip" "/tmp"
    if stage_is_passed "skip5" "ci" "/tmp"; then
        echo "  ✗ ci skip by=auto-claude should not pass"
        exit 1
    fi
    echo "  ✓ ci skip by=auto-claude rejected"
    exit 0
) && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

echo ""
echo "=== nonce-based approval ==="

rm -rf "$SAZO_STATE_DIR"
(
    source "$HOOKS/lib/session-state.sh"
    state_init "ap1" "/tmp" "opus"
    # No nonce set yet → consume should fail
    if approval_nonce_consume "ap1" "fakenonce" "/tmp"; then
        echo "  ✗ consume without set should fail"
        exit 1
    fi
    # Set nonce, then consume with same → success
    approval_nonce_set "ap1" "abc123" "/tmp"
    if approval_nonce_consume "ap1" "abc123" "/tmp"; then
        echo "  ✓ nonce set+consume works"
    else
        echo "  ✗ nonce consume failed"
        exit 1
    fi
    # After consume, nonce cleared
    if approval_nonce_consume "ap1" "abc123" "/tmp"; then
        echo "  ✗ nonce should be one-shot"
        exit 1
    fi
    echo "  ✓ nonce one-shot semantics"
    exit 0
) && { PASS=$((PASS + 3)); } || FAIL=$((FAIL + 3))

echo ""
echo "=== /approved ordering (plan_approved_at before stage_mark) ==="

# Mid-write에 stage_is_passed가 transient false 반환되면 안 됨.
# /approved 흐름 시뮬레이션: nonce_consume → state_set_str(plan_approved_at) → stage_mark.
# 각 단계 후 validator 상태 확인.
rm -rf "$SAZO_STATE_DIR"
(
    source "$HOOKS/lib/session-state.sh"
    state_init "ord1" "/tmp" "opus"
    approval_nonce_set "ord1" "abc" "/tmp"
    approval_nonce_consume "ord1" "abc" "/tmp"
    # plan_approved_at 만 set, stage_mark 전 — validator는 false (history 없음)
    state_set_str "ord1" ".plan_approved_at" "$(date +%Y-%m-%dT%H:%M:%S%z)" "/tmp"
    if SAZO_CWD="/tmp" stage_is_passed "ord1" "approval"; then
        echo "  ✗ approval should fail before stage_mark"
        exit 1
    fi
    # stage_mark — validator 통과
    stage_mark "ord1" "approval" "completed" "user" "/approved" "/tmp"
    if SAZO_CWD="/tmp" stage_is_passed "ord1" "approval"; then
        echo "  ✓ ordered nonce flow: validator passes after both fields set"
        exit 0
    fi
    exit 1
) && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

echo ""
echo "=== consecutive_skip_count ==="

rm -rf "$SAZO_STATE_DIR"
(
    source "$HOOKS/lib/session-state.sh"
    state_init "csk" "/tmp" "opus"
    stage_mark "csk" "worktree" "completed" "auto" "" "/tmp"
    stage_mark "csk" "research" "skipped" "user" "x" "/tmp"
    stage_mark "csk" "plan" "skipped" "user" "y" "/tmp"
    stage_mark "csk" "review" "skipped" "user" "z" "/tmp"
    n=$(consecutive_skip_count "csk" "/tmp")
    if [ "$n" = "3" ]; then
        echo "  ✓ consecutive_skip_count = 3"
    else
        echo "  ✗ expected 3, got $n"
        exit 1
    fi
) && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

echo ""
echo "=== CI command whitelist (Codex round2 P1) ==="

# CLAUDE.md 본문의 non-CI 백틱 토큰(date, echo 등)이 _is_full_ci_command에
# 매치되면 안 됨. 임시 CLAUDE.md 생성 후 검증.
FAKE_PROJECT="/tmp/sazo-smoke-proj-$$"
mkdir -p "$FAKE_PROJECT"
cat > "$FAKE_PROJECT/CLAUDE.md" <<'MDEOF'
# Fake project

- 허용된 명령: `date`, `echo`, `/some/path`
- CI 검증: `bash -n scripts/*.sh && bash -n other.sh`
- Go 패키지: `go build ./...`
- Node: `yarn test`
MDEOF

(
    _is_full_ci_command_fn=$(awk '/^_is_full_ci_command\(\)/,/^}$/' "$HOOKS/workflow-state-machine.sh")
    eval "$_is_full_ci_command_fn"
    SAZO_CWD="$FAKE_PROJECT"

    rc=0
    _is_full_ci_command "date" && { echo "  ✗ 'date' matched (bypass risk)"; rc=1; }
    _is_full_ci_command "echo foo" && { echo "  ✗ 'echo foo' matched"; rc=1; }
    _is_full_ci_command "/some/path" && { echo "  ✗ bare path matched"; rc=1; }
    [ "$rc" = "0" ] && echo "  ✓ non-CI tokens (date/echo/path) rejected"

    rc2=0
    _is_full_ci_command "bash -n scripts/*.sh && bash -n other.sh" || { echo "  ✗ chained CI not matched"; rc2=1; }
    _is_full_ci_command "go build ./..." || { echo "  ✗ go build not matched"; rc2=1; }
    _is_full_ci_command "yarn test" || { echo "  ✗ yarn test not matched"; rc2=1; }
    [ "$rc2" = "0" ] && echo "  ✓ whitelisted CI commands accepted"

    [ "$rc" = "0" ] && [ "$rc2" = "0" ]
) && PASS=$((PASS + 2)) || FAIL=$((FAIL + 2))

# V3 Codex P2: {placeholder} 템플릿 CI 매치
FAKE_GO_PROJECT="/tmp/sazo-smoke-goproj-$$"
mkdir -p "$FAKE_GO_PROJECT"
cat > "$FAKE_GO_PROJECT/CLAUDE.md" <<'MDEOF'
# Go multi-package

| 패키지 | 검증 |
|---|---|
| Go packages | `cd packages/{name} && go build ./...` |
MDEOF
(
    _is_full_ci_command_fn=$(awk '/^_is_full_ci_command\(\)/,/^}$/' "$HOOKS/workflow-state-machine.sh")
    eval "$_is_full_ci_command_fn"
    SAZO_CWD="$FAKE_GO_PROJECT"

    rc=0
    _is_full_ci_command "cd packages/translate-bot && go build ./..." || { echo "  ✗ templated CI not matched"; rc=1; }
    _is_full_ci_command "cd packages/shuffle-bot && go build ./..." || { echo "  ✗ templated (different name) not matched"; rc=1; }
    # subpath escape 시도 — `/` 포함 → placeholder 매치 차단
    _is_full_ci_command "cd packages/foo/bar && go build ./..." && { echo "  ✗ subpath escape should fail"; rc=1; }
    [ "$rc" = "0" ] && echo "  ✓ {placeholder} template CI matching works"
    [ "$rc" = "0" ]
) && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))
rm -rf "$FAKE_GO_PROJECT"

# Codex V8 P1: monorepo package scope — 다른 package CI는 현재 package 통과시키지 않음
FAKE_MONO="/tmp/sazo-smoke-mono-$$"
mkdir -p "$FAKE_MONO/packages/a" "$FAKE_MONO/packages/b"
(cd "$FAKE_MONO" && git init -q -b main 2>/dev/null && git config user.email a@b && git config user.name a && git commit -q --allow-empty -m init 2>/dev/null)
cat > "$FAKE_MONO/CLAUDE.md" <<'MDEOF'
| package | CI |
|---|---|
| a | `cd packages/a && yarn test` |
| b | `cd packages/b && go build ./...` |
MDEOF
(
    _is_full_ci_command_fn=$(awk '/^_is_full_ci_command\(\)/,/^}$/' "$HOOKS/workflow-state-machine.sh")
    eval "$_is_full_ci_command_fn"
    # In packages/a: package b의 CI는 거부
    SAZO_CWD="$FAKE_MONO/packages/a"
    _is_full_ci_command "cd packages/a && yarn test" || { echo "  ✗ pkg a CI should match from pkg a"; exit 1; }
    if _is_full_ci_command "cd packages/b && go build ./..."; then
        echo "  ✗ pkg b CI leaked into pkg a"
        exit 1
    fi
    echo "  ✓ monorepo package scope: other pkg CI rejected"
    exit 0
) && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))
rm -rf "$FAKE_MONO"

# Codex V7 P1: repo boundary 바깥 CI metadata 무시
FAKE_ANCESTOR="/tmp/sazo-smoke-ancestor-$$"
FAKE_REPO="$FAKE_ANCESTOR/myrepo"
mkdir -p "$FAKE_REPO"
(cd "$FAKE_REPO" && git init -q -b main 2>/dev/null && git config user.email a@b && git config user.name a && git commit -q --allow-empty -m init 2>/dev/null)
cat > "$FAKE_ANCESTOR/CLAUDE.md" <<'MDEOF'
- Global CI: `go build ./malicious-repo`
MDEOF
cat > "$FAKE_REPO/CLAUDE.md" <<'MDEOF'
- Actual CI: `yarn test`
MDEOF
(
    _is_full_ci_command_fn=$(awk '/^_is_full_ci_command\(\)/,/^}$/' "$HOOKS/workflow-state-machine.sh")
    eval "$_is_full_ci_command_fn"
    SAZO_CWD="$FAKE_REPO"
    # In-repo CI 매치
    _is_full_ci_command "yarn test" || { echo "  ✗ in-repo CI should match"; exit 1; }
    # Ancestor CI는 매치되지 말아야
    if _is_full_ci_command "go build ./malicious-repo"; then
        echo "  ✗ ancestor CI (outside repo) matched — bypass"
        exit 1
    fi
    echo "  ✓ repo boundary: ancestor CI rejected, in-repo CI accepted"
    exit 0
) && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))
rm -rf "$FAKE_ANCESTOR"

# Codex V7 P2: `npm ci`/`pnpm install` 같은 normal CI command도 매치 (awk \b 제거)
FAKE_NPMCI="/tmp/sazo-smoke-npmci-$$"
mkdir -p "$FAKE_NPMCI"
cat > "$FAKE_NPMCI/CLAUDE.md" <<'MDEOF'
- CI: `npm ci && npm test`
- Install: `pnpm install`
MDEOF
(
    _is_full_ci_command_fn=$(awk '/^_is_full_ci_command\(\)/,/^}$/' "$HOOKS/workflow-state-machine.sh")
    eval "$_is_full_ci_command_fn"
    SAZO_CWD="$FAKE_NPMCI"
    _is_full_ci_command "npm ci && npm test" || { echo "  ✗ npm ci CI not matched"; exit 1; }
    _is_full_ci_command "pnpm install" || { echo "  ✗ pnpm install not matched"; exit 1; }
    echo "  ✓ npm/pnpm CI commands match (awk POSIX boundaries)"
    exit 0
) && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))
rm -rf "$FAKE_NPMCI"

# Codex V6 P2: nested dir의 local CLAUDE.md에 CI 없어도 root-level에서 발견
FAKE_NESTED_ROOT="/tmp/sazo-smoke-nested-$$"
mkdir -p "$FAKE_NESTED_ROOT/sub"
(cd "$FAKE_NESTED_ROOT" && git init -q -b main 2>/dev/null && git config user.email a@b && git config user.name a && git commit -q --allow-empty -m init 2>/dev/null)
cat > "$FAKE_NESTED_ROOT/CLAUDE.md" <<'MDEOF'
- Root CI: `yarn test && yarn build`
MDEOF
cat > "$FAKE_NESTED_ROOT/sub/CLAUDE.md" <<'MDEOF'
# Subdirectory metadata — no CI entries
MDEOF
(
    _is_full_ci_command_fn=$(awk '/^_is_full_ci_command\(\)/,/^}$/' "$HOOKS/workflow-state-machine.sh")
    eval "$_is_full_ci_command_fn"
    SAZO_CWD="$FAKE_NESTED_ROOT/sub"
    if _is_full_ci_command "yarn test && yarn build"; then
        echo "  ✓ upward walk continues past empty local metadata"
        exit 0
    fi
    echo "  ✗ CI not found in root-level CLAUDE.md despite empty local"
    exit 1
) && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))
rm -rf "$FAKE_NESTED_ROOT"

# Codex V5 P2: 경로에 공백 있어도 CI 매치
FAKE_SPACE_PROJECT="/tmp/sazo smoke proj-$$"
mkdir -p "$FAKE_SPACE_PROJECT"
cat > "$FAKE_SPACE_PROJECT/CLAUDE.md" <<'MDEOF'
- CI: `yarn test && yarn build`
MDEOF
(
    _is_full_ci_command_fn=$(awk '/^_is_full_ci_command\(\)/,/^}$/' "$HOOKS/workflow-state-machine.sh")
    eval "$_is_full_ci_command_fn"
    SAZO_CWD="$FAKE_SPACE_PROJECT"
    if _is_full_ci_command "yarn test && yarn build"; then
        echo "  ✓ CI match works with spaces in path"
        exit 0
    fi
    echo "  ✗ CI match failed for path with spaces"
    exit 1
) && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))
rm -rf "$FAKE_SPACE_PROJECT"

# Codex V5 P1: failed Task는 stage 마킹 안 함
rm -rf "$SAZO_STATE_DIR"
rc=$(echo '{"session_id":"task_fail","cwd":"/tmp","tool_name":"Task","tool_input":{"subagent_type":"code-reviewer"},"tool_response":{"is_error":true}}' \
    | bash "$HOOKS/workflow-state-machine.sh" post >/dev/null 2>&1; echo $?)
(
    source "$HOOKS/lib/session-state.sh"
    if stage_is_passed "task_fail" "review" "/tmp"; then
        echo "  ✗ failed Task should NOT mark review stage"
        exit 1
    fi
    echo "  ✓ failed Task (is_error=true) → stage not marked"
    exit 0
) && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

# 성공 Task는 마킹
rm -rf "$SAZO_STATE_DIR"
echo '{"session_id":"task_ok","cwd":"/tmp","tool_name":"Task","tool_input":{"subagent_type":"code-reviewer"},"tool_response":{}}' \
    | bash "$HOOKS/workflow-state-machine.sh" post >/dev/null 2>&1
(
    source "$HOOKS/lib/session-state.sh"
    if stage_is_passed "task_ok" "review" "/tmp"; then
        echo "  ✓ successful Task → stage marked"
        exit 0
    fi
    echo "  ✗ successful Task should mark review stage"
    exit 1
) && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

# Codex V4 P2: AGENTS.md-only repo CI 매치
FAKE_AGENTS_PROJECT="/tmp/sazo-smoke-agents-$$"
mkdir -p "$FAKE_AGENTS_PROJECT"
cat > "$FAKE_AGENTS_PROJECT/AGENTS.md" <<'MDEOF'
# Agents-only project
- CI: `yarn lint && yarn test`
MDEOF
(
    _is_full_ci_command_fn=$(awk '/^_is_full_ci_command\(\)/,/^}$/' "$HOOKS/workflow-state-machine.sh")
    eval "$_is_full_ci_command_fn"
    SAZO_CWD="$FAKE_AGENTS_PROJECT"
    if _is_full_ci_command "yarn lint && yarn test"; then
        echo "  ✓ AGENTS.md-only CI matched"
        exit 0
    fi
    echo "  ✗ AGENTS.md-only CI should match"
    exit 1
) && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))
rm -rf "$FAKE_AGENTS_PROJECT"

# V3 Codex P1: worktree fast-path은 by=user만
rm -rf "$SAZO_STATE_DIR"
(
    source "$HOOKS/lib/session-state.sh"
    state_init "wt_fastpath" "/tmp" "opus"
    # by=auto skipped (non-git repo 케이스 시뮬)
    stage_mark "wt_fastpath" "worktree" "skipped" "auto" "not a git repo" "/tmp"

    LAST_WT_STATUS=$(state_get "wt_fastpath" '[.history[] | select(.stage == "worktree")] | last.status' "/tmp")
    LAST_WT_BY=$(state_get "wt_fastpath" '[.history[] | select(.stage == "worktree")] | last.by' "/tmp")
    if [ "$LAST_WT_STATUS" = "skipped" ] && [ "$LAST_WT_BY" = "user" ]; then
        echo "  ✗ by=auto skipped should NOT hit fast-path"
        exit 1
    fi
    echo "  ✓ by=auto skipped rejected for fast-path"

    # by=user skipped → fast-path 적용
    stage_mark "wt_fastpath2" "worktree" "skipped" "user" "/skip worktree manual" "/tmp"
    LAST_WT_STATUS=$(state_get "wt_fastpath2" '[.history[] | select(.stage == "worktree")] | last.status' "/tmp")
    LAST_WT_BY=$(state_get "wt_fastpath2" '[.history[] | select(.stage == "worktree")] | last.by' "/tmp")
    if [ "$LAST_WT_STATUS" = "skipped" ] && [ "$LAST_WT_BY" = "user" ]; then
        echo "  ✓ by=user skipped hits fast-path"
        exit 0
    fi
    exit 1
) && PASS=$((PASS + 2)) || FAIL=$((FAIL + 2))

rm -rf "$FAKE_PROJECT"

echo ""
echo "=== register-workflow-hooks idempotency ==="

TMP_SETTINGS=$(mktemp)
echo '{}' > "$TMP_SETTINGS"
# shellcheck disable=SC1090
source "$HARNESS/scripts/register-workflow-hooks.sh"
register_workflow_hooks "$HARNESS" "$TMP_SETTINGS" >/dev/null
PRE1=$(jq '(.hooks.PreToolUse // []) | length' "$TMP_SETTINGS")
POST1=$(jq '(.hooks.PostToolUse // []) | length' "$TMP_SETTINGS")
USR1=$(jq '(.hooks.UserPromptSubmit // []) | length' "$TMP_SETTINGS")
register_workflow_hooks "$HARNESS" "$TMP_SETTINGS" >/dev/null
PRE2=$(jq '(.hooks.PreToolUse // []) | length' "$TMP_SETTINGS")
POST2=$(jq '(.hooks.PostToolUse // []) | length' "$TMP_SETTINGS")
USR2=$(jq '(.hooks.UserPromptSubmit // []) | length' "$TMP_SETTINGS")

if [ "$PRE1" = "$PRE2" ] && [ "$PRE1" = "3" ]; then
    PASS=$((PASS + 1))
    echo "  ✓ PreToolUse 3 entries idempotent"
else
    FAIL=$((FAIL + 1))
    echo "  ✗ PreToolUse: run1=$PRE1 run2=$PRE2 (expected 3)"
fi
if [ "$POST1" = "$POST2" ] && [ "$POST1" = "1" ]; then
    PASS=$((PASS + 1))
    echo "  ✓ PostToolUse 1 entry idempotent"
else
    FAIL=$((FAIL + 1))
    echo "  ✗ PostToolUse: run1=$POST1 run2=$POST2 (expected 1)"
fi
if [ "$USR1" = "$USR2" ] && [ "$USR1" = "1" ]; then
    PASS=$((PASS + 1))
    echo "  ✓ UserPromptSubmit 1 entry idempotent"
else
    FAIL=$((FAIL + 1))
    echo "  ✗ UserPromptSubmit: run1=$USR1 run2=$USR2 (expected 1)"
fi

# workflow-state-machine.sh pre matcher must include Task — Plan 04 §6 (B)
# GH#34692 fallback (Codex PR #30 P1). Task 빠지면 mutating subagent의
# preemptive ci_passed_at invalidate가 실제 설치 환경에서 절대 발동 안 함.
WSM_PRE_MATCHER=$(jq -r '
    (.hooks.PreToolUse // [])
    | map(select(.hooks // [] | any(.command | endswith("workflow-state-machine.sh pre"))))
    | .[0].matcher // ""
' "$TMP_SETTINGS")
if echo "$WSM_PRE_MATCHER" | grep -qE '(^|\|)Task(\||$)'; then
    PASS=$((PASS + 1))
    echo "  ✓ workflow-state-machine.sh pre matcher includes Task ($WSM_PRE_MATCHER)"
else
    FAIL=$((FAIL + 1))
    echo "  ✗ workflow-state-machine.sh pre matcher missing Task: $WSM_PRE_MATCHER"
fi

# Migration: 기존 설치 환경에서 matcher가 'Write|Edit|NotebookEdit|Bash'로
# 등록돼 있어도 register_workflow_hooks 재호출 시 'Task|...'로 갱신돼야 한다.
TMP_MIGRATE=$(mktemp)
WSM_PRE_CMD="$HARNESS/scripts/hooks/workflow-state-machine.sh pre"
jq -n --arg cmd "$WSM_PRE_CMD" '{
    "hooks": {
        "PreToolUse": [
            {"matcher": "Write|Edit|NotebookEdit|Bash", "hooks": [{"type": "command", "command": $cmd}]}
        ]
    }
}' > "$TMP_MIGRATE"
register_workflow_hooks "$HARNESS" "$TMP_MIGRATE" >/dev/null
MIGRATED_MATCHER=$(jq -r --arg cmd "$WSM_PRE_CMD" '
    (.hooks.PreToolUse // [])
    | map(select(.hooks // [] | any(.command == $cmd)))
    | .[0].matcher // ""
' "$TMP_MIGRATE")
if echo "$MIGRATED_MATCHER" | grep -qE '(^|\|)Task(\||$)'; then
    PASS=$((PASS + 1))
    echo "  ✓ legacy matcher migrated to include Task ($MIGRATED_MATCHER)"
else
    FAIL=$((FAIL + 1))
    echo "  ✗ legacy matcher not migrated: $MIGRATED_MATCHER"
fi
rm -f "$TMP_MIGRATE"

rm -f "$TMP_SETTINGS"

echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"

[ "$FAIL" = "0" ]
