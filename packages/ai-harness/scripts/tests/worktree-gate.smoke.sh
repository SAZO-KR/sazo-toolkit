#!/usr/bin/env bash
# worktree-gate.smoke.sh — pre-worktree-gate.sh mutating filter regression smoke.
#
# 검증:
# 1. `git worktree (remove|prune|list|lock|unlock|move|repair)` → mutating=0 (통과, cleanup intent)
# 2. `git worktree add` → mutating=1 (차단, 새 작업 시작)
# 3. `git -C <path> <subcmd>` 패턴 인식 (현재 buggy — `-C` 끼어 있으면 regex가 인식 못함)
# 4. 기존 mutating subcommand (commit/push/merge/...) 회귀 방어
# 5. read-only subcommand (status/log/diff) 통과 회귀 방어

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$(cd "$HERE/../.." && pwd)"
HOOK="$HARNESS/scripts/hooks/pre-worktree-gate.sh"

export SAZO_STATE_DIR="/tmp/sazo-worktree-gate-smoke-$$"
TMP_REPO="/tmp/sazo-wt-gate-repo-$$"

cleanup() {
    rm -rf "$SAZO_STATE_DIR" "$TMP_REPO"
}
trap cleanup EXIT

# 가짜 git repo on main branch (보호 브랜치 → mutating cmd block 발동)
mkdir -p "$TMP_REPO"
(
    cd "$TMP_REPO"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    git commit -q --allow-empty -m "init"
) >/dev/null 2>&1

PASS=0
FAIL=0

# invoke_hook <expected_exit> <cmd> <label>
# - payload는 main branch (보호 브랜치)에서 mutating 가정
# - mutating=0인 cmd는 hook line 102 exit 0 (filter 즉시 통과)
# - mutating=1인 cmd는 cwd 검사 → 보호 브랜치 main → exit 2
invoke_hook() {
    local expected="$1" cmd="$2" label="$3"
    local payload
    payload=$(printf '%s' "{
        \"session_id\": \"smoketest-$$\",
        \"cwd\": \"$TMP_REPO\",
        \"tool_name\": \"Bash\",
        \"tool_input\": {\"command\": \"$cmd\"},
        \"model\": \"unknown\"
    }")
    local actual
    actual=$(printf '%s' "$payload" | SAZO_SKIP_WORKTREE_GATE=0 bash "$HOOK" 2>/dev/null; echo "rc=$?")
    actual=${actual##*rc=}
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS+1))
        echo "  ✓ $label (exit=$actual)"
    else
        FAIL=$((FAIL+1))
        echo "  ✗ $label (expected exit=$expected, got $actual)"
    fi
}

echo "=== worktree-gate.smoke: mutating filter ==="

# T1-T7: worktree subcommand carve-out (cleanup intent → mutating=0 → exit 0)
echo "--- T1-T7: worktree subcommand carve-out (cleanup) ---"
invoke_hook 0 'git worktree remove /foo' 'T1 git worktree remove → 통과 (cleanup)'
invoke_hook 0 'git worktree prune' 'T2 git worktree prune → 통과'
invoke_hook 0 'git worktree list' 'T3 git worktree list → 통과 (read-only)'
invoke_hook 0 'git worktree lock /foo' 'T4 git worktree lock → 통과'
invoke_hook 0 'git worktree unlock /foo' 'T5 git worktree unlock → 통과'
invoke_hook 0 'git worktree move /foo /bar' 'T6 git worktree move → 통과'
invoke_hook 0 'git worktree repair' 'T7 git worktree repair → 통과'

# T8: worktree add — 새 작업 시작 → mutating=1 → 보호 브랜치 차단
echo "--- T8: worktree add 차단 ---"
invoke_hook 2 'git worktree add /foo -b new' 'T8 git worktree add → 차단 (mutating)'

# T9-T12: git -C <path> 패턴 인식 (fix 후 mutating으로 분류)
echo "--- T9-T12: git -C path subcmd ---"
invoke_hook 2 "git -C $TMP_REPO commit -m foo" 'T9 git -C path commit → 차단'
invoke_hook 2 "git -C $TMP_REPO worktree add /foo" 'T10 git -C path worktree add → 차단'
invoke_hook 2 "git -C $TMP_REPO push" 'T11 git -C path push → 차단'
invoke_hook 0 "git -C $TMP_REPO worktree remove /foo" 'T12 git -C path worktree remove → 통과 (cleanup)'

# T13-T16: 기존 mutating subcommand 회귀 방어
echo "--- T13-T16: 기존 mutating 회귀 ---"
invoke_hook 2 'git commit -m foo' 'T13 git commit → 차단'
invoke_hook 2 'git push origin main' 'T14 git push → 차단'
invoke_hook 2 'git merge feature' 'T15 git merge → 차단'
invoke_hook 2 'git rebase main' 'T16 git rebase → 차단'

# T17-T20: read-only 회귀 (통과해야 함)
echo "--- T17-T20: read-only 회귀 ---"
invoke_hook 0 'git status' 'T17 git status → 통과'
invoke_hook 0 'git log --oneline' 'T18 git log → 통과'
invoke_hook 0 'git diff HEAD' 'T19 git diff → 통과'
invoke_hook 0 'git branch --show-current' 'T20 git branch --show-current → 통과'
invoke_hook 0 'git branch -a' 'T20a git branch -a → 통과 (list)'
invoke_hook 0 'git branch -v' 'T20b git branch -v → 통과 (verbose list)'
invoke_hook 2 'git branch new-feature' 'T20c git branch <name> → 차단 (create)'
invoke_hook 2 'git branch -d old-feature' 'T20d git branch -d → 차단 (delete)'
invoke_hook 2 'git branch -m new-name' 'T20e git branch -m → 차단 (rename)'

# T20f-T20o: branch precision (Plan v3 Phase A)
echo "--- T20f-T20o: branch carve-out precision ---"
invoke_hook 2 'git branch -f topic' 'T20f git branch -f → 차단 (force)'
invoke_hook 2 'git branch --force topic main' 'T20g git branch --force → 차단'
invoke_hook 2 'git branch --track topic origin/main' 'T20h git branch --track → 차단'
invoke_hook 2 'git branch --no-track topic main' 'T20i git branch --no-track → 차단'
invoke_hook 2 'git branch --set-upstream-to=origin/main' 'T20j git branch --set-upstream-to → 차단'
invoke_hook 2 'git branch --unset-upstream' 'T20k git branch --unset-upstream → 차단'
invoke_hook 2 'git branch --edit-description topic' 'T20l git branch --edit-description → 차단'
invoke_hook 0 'git branch --merged' 'T20m git branch --merged → 통과 (read-only)'
invoke_hook 0 'git branch --contains HEAD' 'T20n git branch --contains → 통과 (read-only)'
invoke_hook 0 'git branch --sort=-committerdate' 'T20o git branch --sort → 통과 (read-only)'

# T20p-T20r: Gemini PR#39 medium — clustered short flag
echo "--- T20p-T20r: clustered short flag (Gemini PR#39) ---"
invoke_hook 2 'git branch -dr origin/feature' 'T20p git branch -dr (clustered delete remote-tracking) → 차단'
invoke_hook 2 'git branch -Df name' 'T20q git branch -Df (clustered force delete) → 차단'
invoke_hook 0 'git branch -av' 'T20r git branch -av (clustered list+verbose) → 통과 (read-only)'
# Codex PR#39 round 2: short upstream flag `-u`
invoke_hook 2 'git branch -u origin/main' 'T20s git branch -u (short --set-upstream-to) → 차단'
invoke_hook 2 'git branch -du topic' 'T20t git branch -du (clustered delete + upstream) → 차단'
# Codex PR#39 round 3: segment boundary — read-only branch + chain의 unrelated `-f`
invoke_hook 0 'git branch --show-current && echo -f' 'T20u branch --show-current && echo -f → 통과 (chain boundary)'
invoke_hook 2 'git branch -a && rm -rf tmp.log' 'T20v branch -a && rm ... → 차단 (rm이 별도 mutating filter)'
# Codex PR#39 round 4: --create-reflog 옵션
invoke_hook 2 'git branch --create-reflog topic' 'T20w branch --create-reflog topic → 차단 (long mutating option)'
invoke_hook 2 'git branch --no-create-reflog topic' 'T20x branch --no-create-reflog topic → 차단'
# Codex PR#39 round 5: pipe boundary
invoke_hook 0 'git branch --show-current | grep -f patterns' 'T20y branch --show-current | grep -f → 통과 (pipe boundary)'
invoke_hook 0 'git branch -a | wc -l' 'T20z branch -a | wc -l → 통과 (pipe boundary)'
# Codex PR#39 round 8: --recurse-submodules
invoke_hook 2 'git branch --recurse-submodules topic' 'T20aa branch --recurse-submodules topic → 차단'
invoke_hook 2 'git branch --no-recurse-submodules topic' 'T20bb branch --no-recurse-submodules topic → 차단'

# T21: cwd 변경 trick — non-git dir + git -C ...
# 현재 hook은 cd "$SAZO_CWD" → not git → stage_mark auto skip → exit 0.
# 하지만 cmd 안에서 git -C로 다른 repo 조작 시도면 mutating으로 분류돼야 안전.
# 이 케이스는 hook이 cwd 의존 — git -C 실 효과는 외부 repo. mutating filter는 cmd 분류만.
echo "--- T21: non-git cwd + git -C 외부 repo ---"
T21_PAYLOAD=$(printf '%s' "{
    \"session_id\": \"smoketest-$$\",
    \"cwd\": \"/tmp\",
    \"tool_name\": \"Bash\",
    \"tool_input\": {\"command\": \"git -C $TMP_REPO commit -m foo\"},
    \"model\": \"unknown\"
}")
T21_RC=$(printf '%s' "$T21_PAYLOAD" | bash "$HOOK" 2>/dev/null; echo "rc=$?")
T21_RC=${T21_RC##*rc=}
# cwd=/tmp (not git) → hook line 110 stage_mark auto skip + exit 0.
# 즉 외부 repo 변경 명령이 cwd가 non-git이면 hook이 못 잡음 — 알려진 한계.
# 본 smoke는 현재 동작 documenting (regression 방어 목적).
if [ "$T21_RC" = "0" ]; then
    PASS=$((PASS+1))
    echo "  ✓ T21 non-git cwd + git -C → exit 0 (알려진 한계: hook은 cwd 의존)"
else
    FAIL=$((FAIL+1))
    echo "  ✗ T21 expected exit=0, got $T21_RC"
fi

echo ""
echo "─────────────────────"
echo "PASS: $PASS  FAIL: $FAIL"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
