#!/bin/bash
# ci-invalidate.smoke.sh — Plan 04 ci_passed_at invalidate smoke tests.
# 격리된 SAZO_STATE_DIR + 임시 git repo. 실 환경 영향 없음.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$(cd "$HERE/../.." && pwd)"
HOOKS="$HARNESS/scripts/hooks"
STATE_HOOK="$HOOKS/workflow-state-machine.sh"
LIB="$HOOKS/lib/session-state.sh"

export SAZO_WORKFLOW_HOOKS_ENABLED=1
export SAZO_STATE_DIR="/tmp/sazo-ci-invalidate-smoke-$$"
TMP_REPO="/tmp/sazo-ci-invalidate-repo-$$"

cleanup() {
    rm -rf "$SAZO_STATE_DIR" "$TMP_REPO"
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

PASS=0
FAIL=0

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        echo "  ✓ $label"
    else
        FAIL=$((FAIL + 1))
        echo "  ✗ $label (expected '$expected', got '$actual')"
    fi
}

assert_exit() {
    local expected="$1" actual="$2" label="$3"
    assert_eq "$expected" "$actual" "$label"
}

# state_get returns empty string for JSON null (jq // empty). Treat both as
# "invalidated" — empty == JSON null per state_get semantics.
assert_null() {
    local actual="$1" label="$2"
    if [ -z "$actual" ] || [ "$actual" = "null" ]; then
        PASS=$((PASS + 1))
        echo "  ✓ $label"
    else
        FAIL=$((FAIL + 1))
        echo "  ✗ $label (expected null/empty, got '$actual')"
    fi
}

# Helper: state file path for given sid + cwd
state_path() {
    local sid="$1" cwd="$2"
    bash -c "
        export SAZO_STATE_DIR='$SAZO_STATE_DIR'
        source '$LIB'
        state_file '$sid' '$cwd'
    "
}

# Helper: directly mark CI passed (init state + ci_passed_at + history)
mark_ci_passed() {
    local sid="$1" cwd="$2"
    bash -c "
        export SAZO_STATE_DIR='$SAZO_STATE_DIR'
        source '$LIB'
        state_init '$sid' '$cwd' 'opus'
        state_set_str '$sid' '.ci_passed_at' '2026-05-09T10:00:00+0900' '$cwd'
        stage_mark '$sid' 'ci' 'completed' 'auto' 'mock-ci' '$cwd'
    "
}

# Helper: read ci_passed_at value
get_ci_passed_at() {
    local sid="$1" cwd="$2"
    bash -c "
        export SAZO_STATE_DIR='$SAZO_STATE_DIR'
        source '$LIB'
        state_get '$sid' '.ci_passed_at' '$cwd'
    "
}

# Helper: stage_is_passed exit code
stage_passed_rc() {
    local sid="$1" stage="$2" cwd="$3"
    bash -c "
        export SAZO_STATE_DIR='$SAZO_STATE_DIR'
        source '$LIB'
        if stage_is_passed '$sid' '$stage' '$cwd'; then echo 0; else echo 1; fi
    "
}

# Helper: run hook with payload, return exit code
run_hook_post() {
    local payload="$1"
    echo "$payload" | bash "$STATE_HOOK" "post" >/dev/null 2>&1
    echo $?
}

run_hook_pre() {
    local payload="$1"
    echo "$payload" | bash "$STATE_HOOK" "pre" >/dev/null 2>&1
    echo $?
}

reset_state() {
    rm -rf "$SAZO_STATE_DIR"
}

echo "=== Plan 04: ci_passed_at invalidate ==="

# 1. CI 통과 모킹 → ci_passed_at 설정 + stage_is_passed ci true
reset_state
mark_ci_passed "t1" "/tmp"
val=$(get_ci_passed_at "t1" "/tmp")
[ -n "$val" ] && [ "$val" != "null" ]
assert_exit "0" "$?" "1. ci_passed_at set after mock CI"
rc=$(stage_passed_rc "t1" "ci" "/tmp")
assert_eq "0" "$rc" "1b. stage_is_passed ci true after mock CI"

# 2. CI 통과 후 *.go Edit PostToolUse → ci_passed_at null
reset_state
mark_ci_passed "t2" "/tmp"
rc=$(run_hook_post "{\"session_id\":\"t2\",\"cwd\":\"/tmp\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/tmp/foo.go\"}}")
assert_eq "0" "$rc" "2. Edit *.go hook exits 0"
val=$(get_ci_passed_at "t2" "/tmp")
assert_null "$val" "2b. ci_passed_at null after .go Edit"
rc=$(stage_passed_rc "t2" "ci" "/tmp")
assert_eq "1" "$rc" "2c. stage_is_passed ci false after invalidate"

# 3. CI 통과 후 README.md Edit → ci_passed_at 유지
reset_state
mark_ci_passed "t3" "/tmp"
run_hook_post "{\"session_id\":\"t3\",\"cwd\":\"/tmp\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/tmp/README.md\"}}" >/dev/null
val=$(get_ci_passed_at "t3" "/tmp")
[ -n "$val" ] && [ "$val" != "null" ]
assert_exit "0" "$?" "3. ci_passed_at preserved after README.md Edit"

# 4. CI 통과 후 package.json Edit → null
reset_state
mark_ci_passed "t4" "/tmp"
run_hook_post "{\"session_id\":\"t4\",\"cwd\":\"/tmp\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/tmp/package.json\"}}" >/dev/null
val=$(get_ci_passed_at "t4" "/tmp")
assert_null "$val" "4. ci_passed_at null after package.json (config=code) Edit"

# 5. CI 통과 후 docs/foo.go Edit → 유지 (docs 경로 우선)
reset_state
mark_ci_passed "t5" "/tmp"
run_hook_post "{\"session_id\":\"t5\",\"cwd\":\"/tmp\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"docs/foo.go\"}}" >/dev/null
val=$(get_ci_passed_at "t5" "/tmp")
[ -n "$val" ] && [ "$val" != "null" ]
assert_exit "0" "$?" "5. ci_passed_at preserved for docs/foo.go (docs path priority)"

# 6. CI 통과 후 Write *.ts → null
reset_state
mark_ci_passed "t6" "/tmp"
run_hook_post "{\"session_id\":\"t6\",\"cwd\":\"/tmp\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/handler.ts\"}}" >/dev/null
val=$(get_ci_passed_at "t6" "/tmp")
assert_null "$val" "6. ci_passed_at null after Write *.ts"

# 7. NotebookEdit *.ipynb (not in code list) → 유지
reset_state
mark_ci_passed "t7" "/tmp"
run_hook_post "{\"session_id\":\"t7\",\"cwd\":\"/tmp\",\"tool_name\":\"NotebookEdit\",\"tool_input\":{\"notebook_path\":\"/tmp/n.ipynb\"}}" >/dev/null
val=$(get_ci_passed_at "t7" "/tmp")
[ -n "$val" ] && [ "$val" != "null" ]
assert_exit "0" "$?" "7. ci_passed_at preserved for .ipynb (current policy)"

# 8. Invalidate 후 gh pr create PreToolUse → block (exit 2)
reset_state
mark_ci_passed "t8" "/tmp"
run_hook_post "{\"session_id\":\"t8\",\"cwd\":\"/tmp\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/tmp/foo.go\"}}" >/dev/null
rc=$(run_hook_pre "{\"session_id\":\"t8\",\"cwd\":\"/tmp\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"gh pr create --title foo\"}}")
assert_eq "2" "$rc" "8. gh pr create blocked after invalidate"

# 8b. Codex PR #30 round 5 P2: chain `... && git add . && git commit && gh pr create`
#     pre-hook git status 안 보이는 inline 코드 작성을 conservative invalidate 로 차단.
reset_state
mark_ci_passed "t8b" "/tmp"
# Chain pattern: opaque file creation + git add + gh pr create. ci_passed_at
# should be invalidated BEFORE PR gate, then PR gate blocks (exit 2).
rc=$(run_hook_pre "{\"session_id\":\"t8b\",\"cwd\":\"/tmp\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"python -c 'open(\\\"foo.go\\\",\\\"w\\\").write(\\\"package main\\\")' && git add . && git commit -m x && gh pr create --title foo\"}}")
assert_eq "2" "$rc" "8b. opaque chain (pyfile + git add . + commit + pr create) blocked"
val=$(get_ci_passed_at "t8b" "/tmp")
assert_null "$val" "8b2. ci_passed_at invalidated by chain detector"

# 8c. git commit -am chain + gh pr create → invalidate + block
reset_state
mark_ci_passed "t8c" "/tmp"
rc=$(run_hook_pre "{\"session_id\":\"t8c\",\"cwd\":\"/tmp\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -am inline && gh pr create --title foo\"}}")
assert_eq "2" "$rc" "8c. chain (commit -am + pr create) blocked"

# 8d. plain `gh pr create` (no chain) — no preemptive invalidate, normal gate
# (ci_passed_at + review must be set; this case ci is set so just review missing → block)
reset_state
mark_ci_passed "t8d" "/tmp"
rc=$(run_hook_pre "{\"session_id\":\"t8d\",\"cwd\":\"/tmp\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"gh pr create --title foo\"}}")
# Should block on review (not on ci) — but result is exit 2 either way; verify
# ci_passed_at NOT touched (only chain triggers preemptive invalidate).
val=$(get_ci_passed_at "t8d" "/tmp")
[ -n "$val" ] && [ "$val" != "null" ]
assert_exit "0" "$?" "8d. plain gh pr create — ci_passed_at NOT touched by chain detector"

# 9. CI 재실행 → 다시 set + PR create 통과
# 모킹: invalidate 후 CI 통과 강제 마킹 → review도 마킹 → PR create pass
reset_state
mark_ci_passed "t9" "/tmp"
run_hook_post "{\"session_id\":\"t9\",\"cwd\":\"/tmp\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/tmp/foo.go\"}}" >/dev/null
val=$(get_ci_passed_at "t9" "/tmp")
assert_null "$val" "9-pre. invalidated"
# 재CI: 다시 mark (Stage B: approval도 함께 마킹)
bash -c "
    export SAZO_STATE_DIR='$SAZO_STATE_DIR'
    source '$LIB'
    state_set_str 't9' '.ci_passed_at' '2026-05-09T11:00:00+0900' '/tmp'
    stage_mark 't9' 'ci' 'completed' 'auto' 'mock-rerun' '/tmp'
    stage_mark 't9' 'review' 'completed' 'auto' 'mock' '/tmp'
    mark_approval_complete 't9' 'user' 'smoke-test' '/tmp'
"
rc=$(run_hook_pre "{\"session_id\":\"t9\",\"cwd\":\"/tmp\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"gh pr create --title foo\"}}")
assert_eq "0" "$rc" "9. gh pr create passes after re-CI"

# 10. git commit PreToolUse + staged 코드 + ci_passed_at!=null → invalidate (commit 자체는 통과 exit 0)
reset_state
# 임시 repo 에 staged code 파일
WORK_REPO="/tmp/sazo-ci-invalidate-commit-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO"
(
    cd "$WORK_REPO"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    git commit -q --allow-empty -m init
    echo "package main" > foo.go
    git add foo.go
)
mark_ci_passed "t10" "$WORK_REPO"
rc=$(run_hook_pre "{\"session_id\":\"t10\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m foo\"}}")
# git commit isn't gh pr create — workflow-state-machine pre 가 block 안 함 → 0
assert_eq "0" "$rc" "10. git commit pre exits 0 (defense, no block)"
val=$(get_ci_passed_at "t10" "$WORK_REPO")
assert_null "$val" "10b. ci_passed_at invalidated by git commit defense"
rm -rf "$WORK_REPO"

# 11. git commit + staged docs only → ci_passed_at 유지
WORK_REPO="/tmp/sazo-ci-invalidate-commit2-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO"
(
    cd "$WORK_REPO"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    git commit -q --allow-empty -m init
    echo "# Title" > README.md
    git add README.md
)
mark_ci_passed "t11" "$WORK_REPO"
run_hook_pre "{\"session_id\":\"t11\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m docs\"}}" >/dev/null
val=$(get_ci_passed_at "t11" "$WORK_REPO")
[ -n "$val" ] && [ "$val" != "null" ]
assert_exit "0" "$?" "11. ci_passed_at preserved (docs-only staged)"
rm -rf "$WORK_REPO"

# 11b. git commit + staged DELETED code file (Codex PR #30 P2-1) → invalidate
# 코드 파일 삭제도 build break 가능 → diff-filter에 D 포함 필요
WORK_REPO="/tmp/sazo-ci-invalidate-commit-del-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO"
(
    cd "$WORK_REPO"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    echo "package main" > foo.go
    git add foo.go
    git commit -q -m init
    git rm -q foo.go
)
mark_ci_passed "t11b" "$WORK_REPO"
run_hook_pre "{\"session_id\":\"t11b\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m delete-go\"}}" >/dev/null
val=$(get_ci_passed_at "t11b" "$WORK_REPO")
assert_null "$val" "11b. ci_passed_at invalidated by staged code DELETION"
rm -rf "$WORK_REPO"

# 11c. git commit + staged DELETED docs only → ci_passed_at 유지 (코드 아님)
WORK_REPO="/tmp/sazo-ci-invalidate-commit-del2-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO"
(
    cd "$WORK_REPO"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    echo "# Old" > old.md
    git add old.md
    git commit -q -m init
    git rm -q old.md
)
mark_ci_passed "t11c" "$WORK_REPO"
run_hook_pre "{\"session_id\":\"t11c\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m delete-md\"}}" >/dev/null
val=$(get_ci_passed_at "t11c" "$WORK_REPO")
[ -n "$val" ] && [ "$val" != "null" ]
assert_exit "0" "$?" "11c. ci_passed_at preserved (docs-only DELETION)"
rm -rf "$WORK_REPO"

# 11d. git commit + staged RENAME code→doc (Codex PR #30 P2-2) → invalidate
# `git mv src/foo.go docs/foo.md` 후 commit. --name-only는 dest(.md)만 노출 →
# _is_doc_only_path에 걸려 invalidate skip되었음. --name-status -M로 source(.go)도 검사.
WORK_REPO="/tmp/sazo-ci-invalidate-rename-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO"
(
    cd "$WORK_REPO"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    mkdir -p src docs
    echo "package main" > src/foo.go
    git add src/foo.go
    git commit -q -m init
    git mv src/foo.go docs/foo.md
)
mark_ci_passed "t11d" "$WORK_REPO"
run_hook_pre "{\"session_id\":\"t11d\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m rename-to-doc\"}}" >/dev/null
val=$(get_ci_passed_at "t11d" "$WORK_REPO")
assert_null "$val" "11d. ci_passed_at invalidated by code→doc RENAME (source .go counts)"
rm -rf "$WORK_REPO"

# 11e. git commit with global option `git -C <path> commit` (Codex PR #30 P2-1)
# regex가 `git commit`만 매치하면 -C/--git-dir/-c 등으로 우회 가능.
WORK_REPO="/tmp/sazo-ci-invalidate-globalopt-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO"
(
    cd "$WORK_REPO"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    git commit -q --allow-empty -m init
    echo "package main" > foo.go
    git add foo.go
)
mark_ci_passed "t11e" "$WORK_REPO"
# session cwd는 다른 곳, git -C로 repo 지정
run_hook_pre "{\"session_id\":\"t11e\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $WORK_REPO commit -m globalopt\"}}" >/dev/null
val=$(get_ci_passed_at "t11e" "$WORK_REPO")
assert_null "$val" "11e. ci_passed_at invalidated by 'git -C <path> commit' (global option matched)"
rm -rf "$WORK_REPO"

# 11f. `git -c user.name=bot commit` 도 매치
WORK_REPO="/tmp/sazo-ci-invalidate-cflag-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO"
(
    cd "$WORK_REPO"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    git commit -q --allow-empty -m init
    echo "package main" > bar.go
    git add bar.go
)
mark_ci_passed "t11f" "$WORK_REPO"
run_hook_pre "{\"session_id\":\"t11f\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -c user.name=bot commit -m cflag\"}}" >/dev/null
val=$(get_ci_passed_at "t11f" "$WORK_REPO")
assert_null "$val" "11f. ci_passed_at invalidated by 'git -c k=v commit'"
rm -rf "$WORK_REPO"

# 11g. `git -C /other/repo commit` 실제 cross-directory 우회 차단 (Codex PR #30 round 2 P2)
# session cwd 와 다른 repo 를 -C 로 지정. 이전 fix 는 regex 만 통과시키고 staged
# diff 는 SAZO_CWD 기준으로 봐서 0건 → invalidate 안 됨 → 이 commit 으로 PR 우회 가능.
# git_target 추출 후 그 repo 의 staged diff 로 검사해야 함.
SESSION_CWD="/tmp/sazo-ci-other-cwd-$$"
WORK_REPO="/tmp/sazo-ci-invalidate-cross-repo-$$"
rm -rf "$SESSION_CWD" "$WORK_REPO"
mkdir -p "$SESSION_CWD" "$WORK_REPO"
# session cwd 자체도 git repo (mark_ci_passed 가 동작하기 위함)
(cd "$SESSION_CWD" && git init -q -b main && git config user.email smoke@test && git config user.name smoke && git commit -q --allow-empty -m init)
(
    cd "$WORK_REPO"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    git commit -q --allow-empty -m init
    echo "package main" > foo.go
    git add foo.go
)
mark_ci_passed "t11g" "$SESSION_CWD"
run_hook_pre "{\"session_id\":\"t11g\",\"cwd\":\"$SESSION_CWD\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $WORK_REPO commit -m cross-repo\"}}" >/dev/null
val=$(get_ci_passed_at "t11g" "$SESSION_CWD")
assert_null "$val" "11g. ci_passed_at invalidated by 'git -C /other/repo commit' (target repo staged code detected)"
rm -rf "$SESSION_CWD" "$WORK_REPO"

# 11h. Edit /workspace/docs/proj/src/foo.go — 상위 디렉토리에 docs 가 있어도 코드로 분류
# (Codex PR #30 round 2 P2). _is_doc_only_path 가 absolute path 에서 단순히 `*/docs/*`
# 매치하면 워크스페이스 위 docs 디렉토리가 docs-only 로 오인 → invalidate skip.
# repo root 기준 relative 변환 후 매칭해야 정상.
PARENT="/tmp/sazo-ci-docs-parent-$$/docs"  # 일부러 부모에 'docs'
WORK_REPO="$PARENT/proj"
rm -rf "/tmp/sazo-ci-docs-parent-$$"
mkdir -p "$WORK_REPO/src"
(cd "$WORK_REPO" && git init -q -b main && git config user.email smoke@test && git config user.name smoke && echo "package main" > src/foo.go && git add src/foo.go && git commit -q -m init)
mark_ci_passed "t11h" "$WORK_REPO"
# Edit 시 file_path 가 absolute. 부모에 docs 가 있어 _is_doc_only_path 가 잘못 true 면 ci_passed_at 유지됨.
run_hook_post "{\"session_id\":\"t11h\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$WORK_REPO/src/foo.go\"},\"tool_response\":{\"success\":true}}" >/dev/null
val=$(get_ci_passed_at "t11h" "$WORK_REPO")
assert_null "$val" "11h. ci_passed_at invalidated even when workspace parent contains 'docs' directory"
rm -rf "/tmp/sazo-ci-docs-parent-$$"

# 11i. chained command: `echo ... >> foo.go && git add foo.go && git commit -m x`
# (Codex PR #30 round 3 P2-A). Pre-hook은 Bash 실행 전에 발동되므로 staged set은
# 비어있음. cmd 토큰에서 `git add foo.go` 인자 추출 → 코드 파일이면 invalidate.
WORK_REPO="/tmp/sazo-ci-invalidate-chain-add-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO"
(cd "$WORK_REPO" && git init -q -b main && git config user.email smoke@test && git config user.name smoke && git commit -q --allow-empty -m init)
mark_ci_passed "t11i" "$WORK_REPO"
# cmd 자체에 add 토큰이 포함됨. file 자체는 아직 디스크에 없어도 OK — 토큰 분석으로 판단.
run_hook_pre "{\"session_id\":\"t11i\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo 'package main' >> $WORK_REPO/foo.go && git -C $WORK_REPO add foo.go && git -C $WORK_REPO commit -m chained\"}}" >/dev/null
val=$(get_ci_passed_at "t11i" "$WORK_REPO")
assert_null "$val" "11i. ci_passed_at invalidated by chained 'git add foo.go && git commit'"
rm -rf "$WORK_REPO"

# 11j. `git commit -am x` (-a/--all): tracked 파일의 unstaged 변경을 자동 stage
# (Codex PR #30 round 3 P2-B). diff --cached 는 비어있어도 working tree(`git diff`)
# 검사로 잡아야.
WORK_REPO="/tmp/sazo-ci-invalidate-am-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO"
(
    cd "$WORK_REPO"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    echo "package main" > bar.go
    git add bar.go
    git commit -q -m init
    # Now modify tracked file but DO NOT stage. -am will pick it up at commit time.
    echo "// edit" >> bar.go
)
mark_ci_passed "t11j" "$WORK_REPO"
run_hook_pre "{\"session_id\":\"t11j\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -am dash-a-flag\"}}" >/dev/null
val=$(get_ci_passed_at "t11j" "$WORK_REPO")
assert_null "$val" "11j. ci_passed_at invalidated by 'git commit -am' (working-tree code changes)"
rm -rf "$WORK_REPO"

# 11k. `git commit -a` 단독 + tracked docs only 변경 → ci_passed_at 유지 (false positive 방지)
WORK_REPO="/tmp/sazo-ci-invalidate-am-docs-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO"
(
    cd "$WORK_REPO"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    echo "# v1" > README.md
    git add README.md
    git commit -q -m init
    echo "# v2" >> README.md
)
mark_ci_passed "t11k" "$WORK_REPO"
run_hook_pre "{\"session_id\":\"t11k\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -a -m docs\"}}" >/dev/null
val=$(get_ci_passed_at "t11k" "$WORK_REPO")
[ -n "$val" ] && [ "$val" != "null" ]
assert_exit "0" "$?" "11k. ci_passed_at preserved when 'git commit -a' touches only docs"
rm -rf "$WORK_REPO"

# 11l. chained `git add .` + redirect creates code file (Codex PR #30 round 4 P2)
# `echo 'package main' > foo.go && git add . && git commit -m x` 형태.
# add 인자가 `.` 라 단일 파일로 매핑 안 됨 → ambiguous → redirect target(.go) 검사로 감지.
WORK_REPO="/tmp/sazo-ci-invalidate-add-dot-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO"
(cd "$WORK_REPO" && git init -q -b main && git config user.email smoke@test && git config user.name smoke && git commit -q --allow-empty -m init)
mark_ci_passed "t11l" "$WORK_REPO"
run_hook_pre "{\"session_id\":\"t11l\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo 'package main' > $WORK_REPO/foo.go && git -C $WORK_REPO add . && git -C $WORK_REPO commit -m chained\"}}" >/dev/null
val=$(get_ci_passed_at "t11l" "$WORK_REPO")
assert_null "$val" "11l. ci_passed_at invalidated by chained 'git add . && git commit' (redirect-target detection)"
rm -rf "$WORK_REPO"

# 11m. `git add -A` + working-tree untracked code → invalidate
# echo 가 chain 밖, 이전에 file 만들어진 후 add -A & commit. ambiguous → working-tree untracked 검사.
WORK_REPO="/tmp/sazo-ci-invalidate-add-A-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO"
(
    cd "$WORK_REPO"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    git commit -q --allow-empty -m init
    echo "package main" > foo.go  # untracked
)
mark_ci_passed "t11m" "$WORK_REPO"
run_hook_pre "{\"session_id\":\"t11m\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $WORK_REPO add -A && git -C $WORK_REPO commit -m all\"}}" >/dev/null
val=$(get_ci_passed_at "t11m" "$WORK_REPO")
assert_null "$val" "11m. ci_passed_at invalidated by 'git add -A' + working-tree untracked code"
rm -rf "$WORK_REPO"

# 11n. `git add src/` (디렉토리) + working-tree untracked code → invalidate
WORK_REPO="/tmp/sazo-ci-invalidate-add-dir-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO/src"
(
    cd "$WORK_REPO"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    git commit -q --allow-empty -m init
    echo "package main" > src/foo.go
)
mark_ci_passed "t11n" "$WORK_REPO"
run_hook_pre "{\"session_id\":\"t11n\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $WORK_REPO add src/ && git -C $WORK_REPO commit -m dir\"}}" >/dev/null
val=$(get_ci_passed_at "t11n" "$WORK_REPO")
assert_null "$val" "11n. ci_passed_at invalidated by 'git add src/' (directory pathspec) + untracked code"
rm -rf "$WORK_REPO"

# 11o. `git add .` + working-tree only docs → ci_passed_at 유지 (false positive 방지)
WORK_REPO="/tmp/sazo-ci-invalidate-add-dot-docs-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO"
(
    cd "$WORK_REPO"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    git commit -q --allow-empty -m init
    echo "# title" > README.md  # untracked docs
)
mark_ci_passed "t11o" "$WORK_REPO"
run_hook_pre "{\"session_id\":\"t11o\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $WORK_REPO add . && git -C $WORK_REPO commit -m docs\"}}" >/dev/null
val=$(get_ci_passed_at "t11o" "$WORK_REPO")
[ -n "$val" ] && [ "$val" != "null" ]
assert_exit "0" "$?" "11o. ci_passed_at preserved when 'git add .' + working-tree has only docs"
rm -rf "$WORK_REPO"

# 11p. chained `git rm code.go && git commit && gh pr create` (Codex PR #30 round 5 P2)
# 코드 파일 삭제는 build break 가능 → invalidate.
WORK_REPO="/tmp/sazo-ci-invalidate-rm-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO"
(
    cd "$WORK_REPO"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    echo "package main" > foo.go
    git add foo.go
    git commit -q -m init
)
mark_ci_passed "t11p" "$WORK_REPO"
run_hook_pre "{\"session_id\":\"t11p\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $WORK_REPO rm foo.go && git -C $WORK_REPO commit -m rm-code\"}}" >/dev/null
val=$(get_ci_passed_at "t11p" "$WORK_REPO")
assert_null "$val" "11p. ci_passed_at invalidated by chained 'git rm <code> && git commit'"
rm -rf "$WORK_REPO"

# 11q. chained `git rm <code> && git commit && gh pr create` opaque guard
# (PR create 시점에 ci_passed_at != null 이라도 chain 의 git rm 검출되면 invalidate)
WORK_REPO="/tmp/sazo-ci-invalidate-rm-prchain-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO"
(
    cd "$WORK_REPO"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    echo "package main" > bar.go
    git add bar.go
    git commit -q -m init
)
mark_ci_passed "t11q" "$WORK_REPO"
# PR create chain opaque guard 가 git rm 도 trigger 해야.
run_hook_pre "{\"session_id\":\"t11q\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $WORK_REPO rm bar.go && gh pr create --title rm\"}}" >/dev/null 2>&1
val=$(get_ci_passed_at "t11q" "$WORK_REPO")
assert_null "$val" "11q. ci_passed_at invalidated by 'git rm ... && gh pr create' opaque-chain guard"
rm -rf "$WORK_REPO"

# 11r. chained `git mv code.go docs.md && git commit && gh pr create` (Codex PR #30 round 6 P2)
# git mv 도 opaque-stage primitive — gh pr create opaque guard 가 trigger.
WORK_REPO="/tmp/sazo-ci-invalidate-mv-prchain-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO/src"
(
    cd "$WORK_REPO"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    echo "package main" > src/foo.go
    git add src/foo.go
    git commit -q -m init
)
mark_ci_passed "t11r" "$WORK_REPO"
run_hook_pre "{\"session_id\":\"t11r\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $WORK_REPO mv src/foo.go src/bar.go && gh pr create --title mv\"}}" >/dev/null 2>&1
val=$(get_ci_passed_at "t11r" "$WORK_REPO")
assert_null "$val" "11r. ci_passed_at invalidated by 'git mv ... && gh pr create' opaque-chain guard"
rm -rf "$WORK_REPO"

# 11s. -C extraction bound to commit invocation (Codex PR #30 round 7 P2)
# `git commit -m x && git -C /tmp/other status` — greedy 추출 시 잘못된 `-C` 잡아
# /tmp/other 의 staged diff 조회 → invalidate 누락. fix: commit 토큰 segment 안의 -C 만 사용.
WORK_REPO="/tmp/sazo-ci-invalidate-greedyC-$$"
OTHER_REPO="/tmp/sazo-ci-invalidate-greedyC-other-$$"
rm -rf "$WORK_REPO" "$OTHER_REPO"; mkdir -p "$WORK_REPO" "$OTHER_REPO"
(
    cd "$WORK_REPO"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    git commit -q --allow-empty -m init
    echo "package main" > foo.go
    git add foo.go
)
(cd "$OTHER_REPO" && git init -q -b main && git config user.email smoke@test && git config user.name smoke && git commit -q --allow-empty -m init)
mark_ci_passed "t11s" "$WORK_REPO"
run_hook_pre "{\"session_id\":\"t11s\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x && git -C $OTHER_REPO status\"}}" >/dev/null
val=$(get_ci_passed_at "t11s" "$WORK_REPO")
assert_null "$val" "11s. -C extraction bound to commit segment (chain 의 다른 -C 우회 차단)"
rm -rf "$WORK_REPO" "$OTHER_REPO"

# 11s2. Quoted global option value (Codex PR #30 round 10 P2).
# `git -c user.name='Bot User' commit foo.go -m x` — `'Bot User'` 안 공백이
# 옵션 토큰 정규식을 깨서 commit 도달 못함 → defense 우회. 새 GIT_OPTS_RE 는
# single/double quoted run 도 옵션 값으로 인정.
WORK_REPO="/tmp/sazo-ci-invalidate-quoted-opt-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO"
(
    cd "$WORK_REPO"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    echo "package main" > foo.go
    git add foo.go
    git commit -q -m init
    echo "// edit" >> foo.go
)
mark_ci_passed "t11s2" "$WORK_REPO"
run_hook_pre "{\"session_id\":\"t11s2\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -c user.name='Bot User' -C $WORK_REPO commit foo.go -m x\"}}" >/dev/null
val=$(get_ci_passed_at "t11s2" "$WORK_REPO")
assert_null "$val" "11s2. ci_passed_at invalidated by 'git -c user.name=<quoted>' commit (quoted value with internal space)"
rm -rf "$WORK_REPO"

# 11s3. Quoted opt value + `&& gh pr create` chain — opaque-chain guard 도 동일 regex 사용.
WORK_REPO="/tmp/sazo-ci-invalidate-quoted-prchain-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO"
(
    cd "$WORK_REPO"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    echo "package main" > foo.go
    git add foo.go
    git commit -q -m init
    echo "// edit" >> foo.go
)
mark_ci_passed "t11s3" "$WORK_REPO"
run_hook_pre "{\"session_id\":\"t11s3\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -c user.name=\\\"Bot User\\\" -C $WORK_REPO commit -am quoted && gh pr create --title quoted\"}}" >/dev/null 2>&1
val=$(get_ci_passed_at "t11s3" "$WORK_REPO")
assert_null "$val" "11s3. opaque-chain guard catches 'git -c name=\"quoted value\" commit -am ... && gh pr create'"
rm -rf "$WORK_REPO"

# 11t. Pathspec commit form (Codex PR #30 round 8 P2)
# `git commit foo.go -m x` — git docs: `git commit [<pathspec>...]`. 기본 동작은
# `--only` 로, working-tree 의 해당 path 변경을 stage 없이 직접 commit. 사전 `git add`
# 도, `-a/--all` 도 없어 현재 fallback chain 모두 우회 → ci_passed_at 유지된 채 PR 통과.
WORK_REPO="/tmp/sazo-ci-invalidate-pathspec-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO"
(
    cd "$WORK_REPO"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    echo "package main" > foo.go
    git add foo.go
    git commit -q -m init
    # Modify tracked file but DO NOT stage. Pathspec commit will pick it up.
    echo "// edit" >> foo.go
)
mark_ci_passed "t11t" "$WORK_REPO"
run_hook_pre "{\"session_id\":\"t11t\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $WORK_REPO commit foo.go -m pathspec\"}}" >/dev/null
val=$(get_ci_passed_at "t11t" "$WORK_REPO")
assert_null "$val" "11t. ci_passed_at invalidated by 'git commit <pathspec>' (no add, no -a)"
rm -rf "$WORK_REPO"

# 11u. `git commit -i <pathspec>` (--include) — same risk as bare pathspec form
WORK_REPO="/tmp/sazo-ci-invalidate-pathspec-i-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO"
(
    cd "$WORK_REPO"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    echo "package main" > bar.go
    git add bar.go
    git commit -q -m init
    echo "// edit" >> bar.go
)
mark_ci_passed "t11u" "$WORK_REPO"
run_hook_pre "{\"session_id\":\"t11u\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $WORK_REPO commit -i bar.go -m include\"}}" >/dev/null
val=$(get_ci_passed_at "t11u" "$WORK_REPO")
assert_null "$val" "11u. ci_passed_at invalidated by 'git commit -i <pathspec>' (include)"
rm -rf "$WORK_REPO"

# 11v. chained `git commit <pathspec> && gh pr create` — opaque-chain guard 가
# pathspec commit 도 trigger 해야. 기존 guard 는 `git add|rm|mv|commit -a*` 만 매치.
WORK_REPO="/tmp/sazo-ci-invalidate-pathspec-prchain-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO"
(
    cd "$WORK_REPO"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    echo "package main" > foo.go
    git add foo.go
    git commit -q -m init
    echo "// edit" >> foo.go
)
mark_ci_passed "t11v" "$WORK_REPO"
run_hook_pre "{\"session_id\":\"t11v\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $WORK_REPO commit foo.go -m pathspec && gh pr create --title pathspec\"}}" >/dev/null 2>&1
val=$(get_ci_passed_at "t11v" "$WORK_REPO")
assert_null "$val" "11v. ci_passed_at invalidated by 'git commit <pathspec> && gh pr create' opaque-chain guard"
rm -rf "$WORK_REPO"

# 11w. False-positive guard: pathspec commit of docs-only path → ci_passed_at 유지
WORK_REPO="/tmp/sazo-ci-invalidate-pathspec-docs-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO"
(
    cd "$WORK_REPO"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    echo "# v1" > README.md
    git add README.md
    git commit -q -m init
    echo "# v2" >> README.md
)
mark_ci_passed "t11w" "$WORK_REPO"
run_hook_pre "{\"session_id\":\"t11w\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $WORK_REPO commit README.md -m doc\"}}" >/dev/null
val=$(get_ci_passed_at "t11w" "$WORK_REPO")
[ -n "$val" ] && [ "$val" != "null" ]
assert_exit "0" "$?" "11w. ci_passed_at preserved when 'git commit <docs-pathspec>' (false-positive guard)"
rm -rf "$WORK_REPO"

# 12. git commit + staged 비어있음 → ci_passed_at 유지
WORK_REPO="/tmp/sazo-ci-invalidate-commit3-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO"
(
    cd "$WORK_REPO"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    git commit -q --allow-empty -m init
)
mark_ci_passed "t12" "$WORK_REPO"
run_hook_pre "{\"session_id\":\"t12\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit --allow-empty -m empty\"}}" >/dev/null
val=$(get_ci_passed_at "t12" "$WORK_REPO")
[ -n "$val" ] && [ "$val" != "null" ]
assert_exit "0" "$?" "12. ci_passed_at preserved (empty staging)"
rm -rf "$WORK_REPO"

# 12b. PostToolUse `git commit -am` — pre-hook saw nothing staged but commit
# succeeded with code → post-hook reads HEAD diff-tree and invalidates
# (Codex PR #30 round 4 P2).
WORK_REPO_AM="/tmp/sazo-ci-invalidate-am-$$"
rm -rf "$WORK_REPO_AM"; mkdir -p "$WORK_REPO_AM"
(
    cd "$WORK_REPO_AM"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    echo 'package main' > existing.go
    git add existing.go
    git commit -q -m "seed"
    # Modify tracked file (so git commit -am will stage + commit it).
    echo 'package main // changed' > existing.go
)
mark_ci_passed "t12b" "$WORK_REPO_AM"
# Simulate the actual `git commit -am` happening — run it for real, then fire post-hook.
( cd "$WORK_REPO_AM" && git commit -q -am "inline stage + commit" )
run_hook_post "{\"session_id\":\"t12b\",\"cwd\":\"$WORK_REPO_AM\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -am 'inline stage + commit'\"},\"tool_response\":{\"exit_code\":0}}" >/dev/null
val=$(get_ci_passed_at "t12b" "$WORK_REPO_AM")
assert_null "$val" "12b. post-commit invalidate (git commit -am with code change)"
rm -rf "$WORK_REPO_AM"

# 12c. PostToolUse chained `echo > foo.go && git add foo.go && git commit`
WORK_REPO_CHAIN="/tmp/sazo-ci-invalidate-chain-$$"
rm -rf "$WORK_REPO_CHAIN"; mkdir -p "$WORK_REPO_CHAIN"
(
    cd "$WORK_REPO_CHAIN"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    git commit -q --allow-empty -m init
    # Chained: echo + add + commit
    echo 'package main' > foo.go
    git add foo.go
    git commit -q -m "chained"
)
mark_ci_passed "t12c" "$WORK_REPO_CHAIN"
# Pre-hook would see foo.go staged but actually it was already committed in our
# simulation. The interesting case is post-hook reading HEAD.
run_hook_post "{\"session_id\":\"t12c\",\"cwd\":\"$WORK_REPO_CHAIN\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo 'package main' > foo.go && git add foo.go && git commit -m chained\"},\"tool_response\":{\"exit_code\":0}}" >/dev/null
val=$(get_ci_passed_at "t12c" "$WORK_REPO_CHAIN")
assert_null "$val" "12c. post-commit invalidate (chained echo+add+commit)"
rm -rf "$WORK_REPO_CHAIN"

# 12d. PostToolUse `git commit` of docs-only change → ci_passed_at preserved
WORK_REPO_DOC="/tmp/sazo-ci-invalidate-postdoc-$$"
rm -rf "$WORK_REPO_DOC"; mkdir -p "$WORK_REPO_DOC"
(
    cd "$WORK_REPO_DOC"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    git commit -q --allow-empty -m init
    echo 'docs' > README.md
    git add README.md
    git commit -q -m "doc only"
)
mark_ci_passed "t12d" "$WORK_REPO_DOC"
run_hook_post "{\"session_id\":\"t12d\",\"cwd\":\"$WORK_REPO_DOC\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m 'doc only'\"},\"tool_response\":{\"exit_code\":0}}" >/dev/null
val=$(get_ci_passed_at "t12d" "$WORK_REPO_DOC")
[ -n "$val" ] && [ "$val" != "null" ]
assert_exit "0" "$?" "12d. post-commit docs-only → ci_passed_at preserved"
rm -rf "$WORK_REPO_DOC"

# 12e. PostToolUse `git commit` failed (exit_code != 0) → no invalidate
WORK_REPO_FAIL="/tmp/sazo-ci-invalidate-postfail-$$"
rm -rf "$WORK_REPO_FAIL"; mkdir -p "$WORK_REPO_FAIL"
(
    cd "$WORK_REPO_FAIL"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    git commit -q --allow-empty -m init
)
mark_ci_passed "t12e" "$WORK_REPO_FAIL"
run_hook_post "{\"session_id\":\"t12e\",\"cwd\":\"$WORK_REPO_FAIL\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m fail\"},\"tool_response\":{\"exit_code\":1}}" >/dev/null
val=$(get_ci_passed_at "t12e" "$WORK_REPO_FAIL")
[ -n "$val" ] && [ "$val" != "null" ]
assert_exit "0" "$?" "12e. post-commit failed → ci_passed_at preserved (exit_code != 0)"
rm -rf "$WORK_REPO_FAIL"

# 12f. PostToolUse multi-commit chain `commit code && commit docs` (Codex PR #30 round 9 P2)
# 같은 Bash 한 번에 코드 commit + docs commit. 마지막이 docs-only 여서 prior
# `diff-tree --root HEAD` 만 보던 fallback 은 code commit 을 누락 → ci_passed_at
# 유지된 채 PR create 통과. pre-hook HEAD marker → post-hook `<marker>..HEAD`
# 범위 검사로 모든 새 commit 을 본다.
WORK_REPO_MULTI="/tmp/sazo-ci-invalidate-multi-$$"
rm -rf "$WORK_REPO_MULTI"; mkdir -p "$WORK_REPO_MULTI"
(
    cd "$WORK_REPO_MULTI"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    git commit -q --allow-empty -m init
)
mark_ci_passed "t12f" "$WORK_REPO_MULTI"
# Pre-hook fires before the actual commits run. Marker captured.
run_hook_pre "{\"session_id\":\"t12f\",\"cwd\":\"$WORK_REPO_MULTI\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo 'package main' > $WORK_REPO_MULTI/foo.go && git -C $WORK_REPO_MULTI add foo.go && git -C $WORK_REPO_MULTI commit -m code && echo doc > $WORK_REPO_MULTI/README.md && git -C $WORK_REPO_MULTI add README.md && git -C $WORK_REPO_MULTI commit -m docs\"}}" >/dev/null
# Now actually create the two commits — code first, docs second.
(
    cd "$WORK_REPO_MULTI"
    echo 'package main' > foo.go
    git add foo.go
    git commit -q -m code
    echo doc > README.md
    git add README.md
    git commit -q -m docs
)
# Pre-hook (above) already invalidated via the chained `git add foo.go` path.
# Reset to isolate the post-hook fallback path under test.
bash -c "
    export SAZO_STATE_DIR='$SAZO_STATE_DIR'
    source '$LIB'
    state_set_str 't12f' '.ci_passed_at' '2026-05-09T10:00:00+0900' '$WORK_REPO_MULTI'
"
run_hook_post "{\"session_id\":\"t12f\",\"cwd\":\"$WORK_REPO_MULTI\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo 'package main' > $WORK_REPO_MULTI/foo.go && git -C $WORK_REPO_MULTI add foo.go && git -C $WORK_REPO_MULTI commit -m code && echo doc > $WORK_REPO_MULTI/README.md && git -C $WORK_REPO_MULTI add README.md && git -C $WORK_REPO_MULTI commit -m docs\"},\"tool_response\":{\"exit_code\":0}}" >/dev/null
val=$(get_ci_passed_at "t12f" "$WORK_REPO_MULTI")
assert_null "$val" "12f. post-commit multi-commit chain (code then docs) — earlier code commit detected via marker..HEAD range"
rm -rf "$WORK_REPO_MULTI"

# 12g. PostToolUse multi-commit, all docs → ci_passed_at preserved (false-positive guard)
WORK_REPO_MD="/tmp/sazo-ci-invalidate-multidocs-$$"
rm -rf "$WORK_REPO_MD"; mkdir -p "$WORK_REPO_MD"
(
    cd "$WORK_REPO_MD"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    git commit -q --allow-empty -m init
)
mark_ci_passed "t12g" "$WORK_REPO_MD"
run_hook_pre "{\"session_id\":\"t12g\",\"cwd\":\"$WORK_REPO_MD\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo 'a' > $WORK_REPO_MD/A.md && git -C $WORK_REPO_MD add A.md && git -C $WORK_REPO_MD commit -m a && echo 'b' > $WORK_REPO_MD/B.md && git -C $WORK_REPO_MD add B.md && git -C $WORK_REPO_MD commit -m b\"}}" >/dev/null
(
    cd "$WORK_REPO_MD"
    echo a > A.md && git add A.md && git commit -q -m a
    echo b > B.md && git add B.md && git commit -q -m b
)
# Restore ci_passed_at — pre-hook above was a no-op (no code in chain) so this
# is the fresh state we want post-hook to evaluate.
bash -c "
    export SAZO_STATE_DIR='$SAZO_STATE_DIR'
    source '$LIB'
    state_set_str 't12g' '.ci_passed_at' '2026-05-09T10:00:00+0900' '$WORK_REPO_MD'
"
run_hook_post "{\"session_id\":\"t12g\",\"cwd\":\"$WORK_REPO_MD\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo 'a' > $WORK_REPO_MD/A.md && git -C $WORK_REPO_MD add A.md && git -C $WORK_REPO_MD commit -m a && echo 'b' > $WORK_REPO_MD/B.md && git -C $WORK_REPO_MD add B.md && git -C $WORK_REPO_MD commit -m b\"},\"tool_response\":{\"exit_code\":0}}" >/dev/null
val=$(get_ci_passed_at "t12g" "$WORK_REPO_MD")
[ -n "$val" ] && [ "$val" != "null" ]
assert_exit "0" "$?" "12g. post-commit multi-commit all-docs — ci_passed_at preserved"
rm -rf "$WORK_REPO_MD"

# 12h. Marker-missing fallback — post-hook without prior pre-hook marker still
# detects HEAD commit (legacy single-commit safety net).
WORK_REPO_NM="/tmp/sazo-ci-invalidate-nomark-$$"
rm -rf "$WORK_REPO_NM"; mkdir -p "$WORK_REPO_NM"
(
    cd "$WORK_REPO_NM"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    git commit -q --allow-empty -m init
    echo 'package main' > foo.go
    git add foo.go
    git commit -q -m code
)
mark_ci_passed "t12h" "$WORK_REPO_NM"
# Skip pre-hook entirely — only post fires. Marker absent → HEAD-only fallback.
run_hook_post "{\"session_id\":\"t12h\",\"cwd\":\"$WORK_REPO_NM\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m code\"},\"tool_response\":{\"exit_code\":0}}" >/dev/null
val=$(get_ci_passed_at "t12h" "$WORK_REPO_NM")
assert_null "$val" "12h. post-commit marker-missing → HEAD-only fallback still invalidates"
rm -rf "$WORK_REPO_NM"

# 12i. PreToolUse multi-commit chain: first segment in unrelated repo,
# second commits code in SAZO_CWD repo. Old `head -1` only inspected the
# first segment → second commit's staged code missed (Codex PR #30 round 11 P2).
WORK_REPO_MAIN="/tmp/sazo-ci-invalidate-multi-pre-main-$$"
OTHER_REPO="/tmp/sazo-ci-invalidate-multi-pre-other-$$"
rm -rf "$WORK_REPO_MAIN" "$OTHER_REPO"
mkdir -p "$WORK_REPO_MAIN" "$OTHER_REPO"
(
    cd "$WORK_REPO_MAIN"
    git init -q -b main && git config user.email s@t && git config user.name s
    git commit -q --allow-empty -m init
    echo 'package main' > foo.go
    git add foo.go
)
(
    cd "$OTHER_REPO"
    git init -q -b main && git config user.email s@t && git config user.name s
    echo doc > README.md
    git add README.md
    git commit -q -m doc
)
mark_ci_passed "t12i" "$WORK_REPO_MAIN"
# Chain: first commit targets OTHER_REPO (docs), second commits foo.go in MAIN.
run_hook_pre "{\"session_id\":\"t12i\",\"cwd\":\"$WORK_REPO_MAIN\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $OTHER_REPO commit -m docs && git commit -m code\"}}" >/dev/null
val=$(get_ci_passed_at "t12i" "$WORK_REPO_MAIN")
assert_null "$val" "12i. multi-commit chain pre-hook scans every segment (other-repo docs + main-repo code)"
rm -rf "$WORK_REPO_MAIN" "$OTHER_REPO"

# 12j. PostToolUse multi-commit chain: same shape, post-hook side.
WORK_REPO_MAIN="/tmp/sazo-ci-invalidate-multi-post-main-$$"
OTHER_REPO="/tmp/sazo-ci-invalidate-multi-post-other-$$"
rm -rf "$WORK_REPO_MAIN" "$OTHER_REPO"
mkdir -p "$WORK_REPO_MAIN" "$OTHER_REPO"
(
    cd "$WORK_REPO_MAIN"
    git init -q -b main && git config user.email s@t && git config user.name s
    git commit -q --allow-empty -m init
)
(
    cd "$OTHER_REPO"
    git init -q -b main && git config user.email s@t && git config user.name s
    git commit -q --allow-empty -m init
)
mark_ci_passed "t12j" "$WORK_REPO_MAIN"
# Actually run the chain — first commit in OTHER (docs), second in MAIN (code).
(
    cd "$OTHER_REPO"
    echo doc > README.md && git add README.md && git commit -q -m docs
)
(
    cd "$WORK_REPO_MAIN"
    echo 'package main' > foo.go && git add foo.go && git commit -q -m code
)
# Restore ci_passed_at — we want to verify post-hook fallback isolated.
bash -c "
    export SAZO_STATE_DIR='$SAZO_STATE_DIR'
    source '$LIB'
    state_set_str 't12j' '.ci_passed_at' '2026-05-09T10:00:00+0900' '$WORK_REPO_MAIN'
"
run_hook_post "{\"session_id\":\"t12j\",\"cwd\":\"$WORK_REPO_MAIN\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $OTHER_REPO commit -m docs && git commit -m code\"},\"tool_response\":{\"exit_code\":0}}" >/dev/null
val=$(get_ci_passed_at "t12j" "$WORK_REPO_MAIN")
assert_null "$val" "12j. multi-commit chain post-hook scans every segment (other-repo docs + main-repo code via HEAD fallback)"
rm -rf "$WORK_REPO_MAIN" "$OTHER_REPO"

# 12k. PR-chain pathspec scan: first commit -m only, second commit pathspec
# (no -a, no add) — must trigger opaque-chain block before gh pr create.
WORK_REPO="/tmp/sazo-ci-invalidate-prchain-pathspec2-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO"
(
    cd "$WORK_REPO"
    git init -q -b main && git config user.email s@t && git config user.name s
    echo 'package main' > foo.go && git add foo.go && git commit -q -m init
    echo "// edit" >> foo.go
)
mark_ci_passed "t12k" "$WORK_REPO"
run_hook_pre "{\"session_id\":\"t12k\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $WORK_REPO commit --allow-empty -m wrap && git -C $WORK_REPO commit foo.go -m pathspec && gh pr create --title x\"}}" >/dev/null 2>&1
val=$(get_ci_passed_at "t12k" "$WORK_REPO")
assert_null "$val" "12k. PR-chain pathspec scan finds 2nd-segment pathspec commit (head -1 ignored 1st-only)"
rm -rf "$WORK_REPO"

# 12l. Quoted pathspec with internal space (Gemini PR #30 review #79):
# `git commit "my file.go" -m msg` — naive whitespace split would tokenize
# to `"my`, `file.go"`. quote-aware tokenizer must emit `my file.go` and
# detect `.go` extension.
WORK_REPO="/tmp/sazo-ci-invalidate-quoted-path-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO"
(
    cd "$WORK_REPO"
    git init -q -b main && git config user.email s@t && git config user.name s
    echo 'package main' > "my file.go"
    git add "my file.go"
    git commit -q -m init
    echo "// edit" >> "my file.go"
)
mark_ci_passed "t12l" "$WORK_REPO"
run_hook_pre "{\"session_id\":\"t12l\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $WORK_REPO commit \\\"my file.go\\\" -m msg\"}}" >/dev/null
val=$(get_ci_passed_at "t12l" "$WORK_REPO")
assert_null "$val" "12l. quoted pathspec 'my file.go' detected by quote-aware tokenizer"
rm -rf "$WORK_REPO"

# 12m. Compact chain operators `&&` (no surrounding whitespace) — Codex PR #30 round 12 P2 (#3215075171)
WORK_REPO="/tmp/sazo-ci-invalidate-compact-chain-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO"
(
    cd "$WORK_REPO"
    git init -q -b main && git config user.email s@t && git config user.name s
    git commit -q --allow-empty -m init
)
mark_ci_passed "t12m" "$WORK_REPO"
# Compact chain (no spaces around `&&`) — `python -c '...'&&git add .&&git commit -m x&&gh pr create`.
run_hook_pre "{\"session_id\":\"t12m\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo 'package main' > $WORK_REPO/foo.go&&git -C $WORK_REPO add foo.go&&git -C $WORK_REPO commit -m x&&gh pr create --title compact\"}}" >/dev/null 2>&1
val=$(get_ci_passed_at "t12m" "$WORK_REPO")
assert_null "$val" "12m. opaque-chain guard catches compact `&&` (no whitespace) chain"
rm -rf "$WORK_REPO"

# 12n. `git commit --all` (long form) in PR-create chain — Codex #3215075173
WORK_REPO="/tmp/sazo-ci-invalidate-commit-all-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO"
(
    cd "$WORK_REPO"
    git init -q -b main && git config user.email s@t && git config user.name s
    echo 'package main' > foo.go && git add foo.go && git commit -q -m init
    echo "// edit" >> foo.go
)
mark_ci_passed "t12n" "$WORK_REPO"
run_hook_pre "{\"session_id\":\"t12n\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $WORK_REPO commit --all -m x && gh pr create --title longform\"}}" >/dev/null 2>&1
val=$(get_ci_passed_at "t12n" "$WORK_REPO")
assert_null "$val" "12n. opaque-chain guard catches 'git commit --all' (long form, not just -a/-am)"
rm -rf "$WORK_REPO"

# 12o. Per-repo marker dict — multi-repo chain (Codex #3215083285)
# pre creates commit in repo A then repo B; legacy single marker overwritten by B.
# post for repo A must read dict and use A's marker (not fall back to HEAD-only).
REPO_A="/tmp/sazo-ci-invalidate-marker-a-$$"
REPO_B="/tmp/sazo-ci-invalidate-marker-b-$$"
rm -rf "$REPO_A" "$REPO_B"
mkdir -p "$REPO_A" "$REPO_B"
for r in "$REPO_A" "$REPO_B"; do (
    cd "$r"
    git init -q -b main && git config user.email s@t && git config user.name s
    git commit -q --allow-empty -m init
); done
mark_ci_passed "t12o" "$REPO_A"
# Pre: chain has commits in both A and B. dict gets A and B entries; legacy
# single marker = B (last write wins).
run_hook_pre "{\"session_id\":\"t12o\",\"cwd\":\"$REPO_A\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO_A commit -m a && git -C $REPO_B commit -m b\"}}" >/dev/null
# Now actually create the commits — A gets code, B gets docs.
( cd "$REPO_A" && echo 'package main' > foo.go && git add foo.go && git commit -q -m a-code )
( cd "$REPO_B" && echo doc > README.md && git add README.md && git commit -q -m b-docs )
# Restore ci_passed_at to isolate post-hook fallback.
bash -c "
    export SAZO_STATE_DIR='$SAZO_STATE_DIR'
    source '$LIB'
    state_set_str 't12o' '.ci_passed_at' '2026-05-09T10:00:00+0900' '$REPO_A'
"
run_hook_post "{\"session_id\":\"t12o\",\"cwd\":\"$REPO_A\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO_A commit -m a && git -C $REPO_B commit -m b\"},\"tool_response\":{\"exit_code\":0}}" >/dev/null
val=$(get_ci_passed_at "t12o" "$REPO_A")
assert_null "$val" "12o. per-repo marker dict survives multi-repo chain (A code commit detected even after B overwrites legacy marker)"
rm -rf "$REPO_A" "$REPO_B"

# 12p. Per-repo marker dict bootstrap when state lacks `.pre_commit_markers`
# (Codex round 13 #3215096087). Chain `commit-A-code && commit-A-docs && commit-B`:
#   - dict must record A's baseline so post-hook range covers BOTH A commits
#     (last is docs-only; without dict, HEAD-only fallback misses earlier code).
#   - legacy marker is overwritten by B; only the dict can save A.
REPO_A="/tmp/sazo-ci-invalidate-mdict-a-$$"
REPO_B="/tmp/sazo-ci-invalidate-mdict-b-$$"
rm -rf "$REPO_A" "$REPO_B"
mkdir -p "$REPO_A" "$REPO_B"
for r in "$REPO_A" "$REPO_B"; do (
    cd "$r"
    git init -q -b main && git config user.email s@t && git config user.name s
    git commit -q --allow-empty -m init
); done
mark_ci_passed "t12p" "$REPO_A"
# Pre fires once on the chain — must populate dict for repoA AND repoB.
run_hook_pre "{\"session_id\":\"t12p\",\"cwd\":\"$REPO_A\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO_A commit -m a-code && git -C $REPO_A commit -m a-docs && git -C $REPO_B commit -m b-docs\"}}" >/dev/null
# Verify dict populated (regression guard for empty-stdin jq bug).
DICT=$(bash -c "
    export SAZO_STATE_DIR='$SAZO_STATE_DIR'
    source '$LIB'
    state_get 't12p' '.pre_commit_markers' '$REPO_A'
")
if [ -n "$DICT" ] && [ "$DICT" != "null" ]; then
    PASS=$((PASS + 1)); echo "  ✓ 12p-dict. .pre_commit_markers dict populated on first segment (bootstrap from absent state)"
else
    FAIL=$((FAIL + 1)); echo "  ✗ 12p-dict. dict still null (Codex round 13 bug: empty-stdin jq pipeline)"
fi

# Now actually create the commits — repoA gets code FIRST then docs, repoB docs.
( cd "$REPO_A" && echo 'package main' > foo.go && git add foo.go && git commit -q -m a-code )
( cd "$REPO_A" && echo doc > A.md && git add A.md && git commit -q -m a-docs )
( cd "$REPO_B" && echo doc > B.md && git add B.md && git commit -q -m b-docs )
bash -c "
    export SAZO_STATE_DIR='$SAZO_STATE_DIR'
    source '$LIB'
    state_set_str 't12p' '.ci_passed_at' '2026-05-09T10:00:00+0900' '$REPO_A'
"
run_hook_post "{\"session_id\":\"t12p\",\"cwd\":\"$REPO_A\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO_A commit -m a-code && git -C $REPO_A commit -m a-docs && git -C $REPO_B commit -m b-docs\"},\"tool_response\":{\"exit_code\":0}}" >/dev/null
val=$(get_ci_passed_at "t12p" "$REPO_A")
assert_null "$val" "12p. multi-commit in same repo + cross-repo chain — dict-based marker covers earlier code commit (HEAD is docs-only)"
rm -rf "$REPO_A" "$REPO_B"

# 12q. Marker cleanup runs even when pre already invalidated (Codex #3215109919).
# Scenario: code commit invalidates ci, CI re-runs, then docs-only commit fires.
# Without cleanup the stale marker re-diffs the OLD code commit and re-invalidates
# the freshly-passed ci_passed_at.
WORK_REPO="/tmp/sazo-ci-invalidate-marker-stale-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO"
(
    cd "$WORK_REPO"
    git init -q -b main && git config user.email s@t && git config user.name s
    git commit -q --allow-empty -m init
)
mark_ci_passed "t12q" "$WORK_REPO"
# Round A: code commit. pre invalidates → cur_cp_post=null at post-hook.
run_hook_pre "{\"session_id\":\"t12q\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $WORK_REPO commit -m a-code\"}}" >/dev/null
( cd "$WORK_REPO" && echo 'package main' > foo.go && git add foo.go && git commit -q -m a-code )
run_hook_post "{\"session_id\":\"t12q\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $WORK_REPO commit -m a-code\"},\"tool_response\":{\"exit_code\":0}}" >/dev/null
# Verify marker cleared even though cur_cp_post was null at post.
MARKER=$(bash -c "
    export SAZO_STATE_DIR='$SAZO_STATE_DIR'
    source '$LIB'
    state_get 't12q' '.pre_commit_marker' '$WORK_REPO'
")
DICT=$(bash -c "
    export SAZO_STATE_DIR='$SAZO_STATE_DIR'
    source '$LIB'
    state_get 't12q' '.pre_commit_markers' '$WORK_REPO'
")
if { [ -z "$MARKER" ] || [ "$MARKER" = "null" ]; } && { [ -z "$DICT" ] || [ "$DICT" = "null" ]; }; then
    PASS=$((PASS + 1)); echo "  ✓ 12q-clean. marker + dict cleared after pre-invalidation (cleanup outside cur_cp guard)"
else
    FAIL=$((FAIL + 1)); echo "  ✗ 12q-clean. stale marker survives (Codex round 14 bug)"
fi
# Round B: CI re-runs. Then docs-only commit. Without round-14 fix the stale
# marker would diff round A's code commit and invalidate round B's ci_passed_at.
bash -c "
    export SAZO_STATE_DIR='$SAZO_STATE_DIR'
    source '$LIB'
    state_set_str 't12q' '.ci_passed_at' '2026-05-09T11:00:00+0900' '$WORK_REPO'
"
run_hook_pre "{\"session_id\":\"t12q\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $WORK_REPO commit -m b-docs\"}}" >/dev/null
( cd "$WORK_REPO" && echo doc > README.md && git add README.md && git commit -q -m b-docs )
run_hook_post "{\"session_id\":\"t12q\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $WORK_REPO commit -m b-docs\"},\"tool_response\":{\"exit_code\":0}}" >/dev/null
val=$(get_ci_passed_at "t12q" "$WORK_REPO")
if [ -n "$val" ] && [ "$val" != "null" ]; then
    PASS=$((PASS + 1)); echo "  ✓ 12q. fresh ci_passed_at preserved after stale-marker cleanup"
else
    FAIL=$((FAIL + 1)); echo "  ✗ 12q. stale marker invalidated fresh ci (Codex round 14 bug)"
fi
rm -rf "$WORK_REPO"

# 12r. go.mod recognized as code (Codex #3215109920)
WORK_REPO="/tmp/sazo-ci-invalidate-gomod-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO"
(
    cd "$WORK_REPO"
    git init -q -b main && git config user.email s@t && git config user.name s
    echo 'module foo' > go.mod
    git add go.mod && git commit -q -m init
    echo 'require example.com/dep v1.0.0' >> go.mod
    git add go.mod
)
mark_ci_passed "t12r" "$WORK_REPO"
run_hook_pre "{\"session_id\":\"t12r\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $WORK_REPO commit -m bump-dep\"}}" >/dev/null
val=$(get_ci_passed_at "t12r" "$WORK_REPO")
assert_null "$val" "12r. go.mod change invalidates ci_passed_at"
rm -rf "$WORK_REPO"

# 12r2. go.mod via Edit PostToolUse (file path detection)
reset_state
mark_ci_passed "t12r2" "/tmp"
run_hook_post "{\"session_id\":\"t12r2\",\"cwd\":\"/tmp\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/tmp/go.mod\"}}" >/dev/null
val=$(get_ci_passed_at "t12r2" "/tmp")
assert_null "$val" "12r2. Edit go.mod → ci_passed_at null"

# 12s. `git commit --pathspec-from-file=<file>` (Codex PR #30 round 15 #3215117950)
# 파일 안 path 목록은 hook 입장에서 opaque. working-tree 에 코드 파일이 있으면
# 보수적 invalidate.
WORK_REPO="/tmp/sazo-ci-invalidate-pathspec-file-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO"
(
    cd "$WORK_REPO"
    git init -q -b main && git config user.email s@t && git config user.name s
    echo 'package main' > foo.go
    git add foo.go
    git commit -q -m init
    echo "// edit" >> foo.go
    printf 'foo.go\n' > paths
)
mark_ci_passed "t12s" "$WORK_REPO"
run_hook_pre "{\"session_id\":\"t12s\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $WORK_REPO commit --pathspec-from-file=$WORK_REPO/paths -m x\"}}" >/dev/null
val=$(get_ci_passed_at "t12s" "$WORK_REPO")
assert_null "$val" "12s. ci_passed_at invalidated by 'git commit --pathspec-from-file' (file opaque, working-tree code present)"
rm -rf "$WORK_REPO"

# 12s2. PR-chain `--pathspec-from-file` opaque guard
WORK_REPO="/tmp/sazo-ci-invalidate-pathspec-file-prchain-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO"
(
    cd "$WORK_REPO"
    git init -q -b main && git config user.email s@t && git config user.name s
    echo 'package main' > foo.go && git add foo.go && git commit -q -m init
    echo "// edit" >> foo.go
    printf 'foo.go\n' > paths
)
mark_ci_passed "t12s2" "$WORK_REPO"
run_hook_pre "{\"session_id\":\"t12s2\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $WORK_REPO commit --pathspec-from-file=$WORK_REPO/paths -m x && gh pr create --title psf\"}}" >/dev/null 2>&1
val=$(get_ci_passed_at "t12s2" "$WORK_REPO")
assert_null "$val" "12s2. opaque-chain catches '--pathspec-from-file' commit + gh pr create"
rm -rf "$WORK_REPO"

# 12t. Quoted -C path with internal space (Codex round 16 #3215134953)
WORK_REPO="/tmp/sazo-ci-quoted-C path-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO"
(
    cd "$WORK_REPO"
    git init -q -b main && git config user.email s@t && git config user.name s
    echo 'package main' > foo.go
    git add foo.go
    git commit -q -m init
    echo "// edit" >> foo.go
    git add foo.go
)
mark_ci_passed "t12t" "$WORK_REPO"
run_hook_pre "{\"session_id\":\"t12t\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C \\\"$WORK_REPO\\\" commit -m x\"}}" >/dev/null
val=$(get_ci_passed_at "t12t" "$WORK_REPO")
assert_null "$val" "12t. quoted -C path with internal space resolves correctly via awk tokenizer"
rm -rf "$WORK_REPO"

# 12u. `--message <docs-only>` standalone form must NOT mark chain opaque
# (Codex round 16 #3215134956). Only docs staged → ci_passed_at preserved
# even though chain ends in `gh pr create`.
WORK_REPO="/tmp/sazo-ci-invalidate-longmsg-$$"
rm -rf "$WORK_REPO"; mkdir -p "$WORK_REPO"
(
    cd "$WORK_REPO"
    git init -q -b main && git config user.email s@t && git config user.name s
    echo 'docs init' > README.md && git add README.md && git commit -q -m init
    echo 'docs update' >> README.md && git add README.md
)
mark_ci_passed "t12u" "$WORK_REPO"
# `--message docs` (long form, standalone value) — value `docs` must NOT be
# treated as positional pathspec by has_pathspec scanner.
run_hook_pre "{\"session_id\":\"t12u\",\"cwd\":\"$WORK_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $WORK_REPO commit --message docs && gh pr create --title docs\"}}" >/dev/null 2>&1
val=$(get_ci_passed_at "t12u" "$WORK_REPO")
[ -n "$val" ] && [ "$val" != "null" ]
assert_exit "0" "$?" "12u. '--message docs' standalone — value 'docs' NOT misclassified as pathspec (false-positive guard)"
rm -rf "$WORK_REPO"

# 13. PreToolUse Task subagent_type=plan-executor + ci_passed_at!=null → invalidate
reset_state
mark_ci_passed "t13" "/tmp"
run_hook_pre "{\"session_id\":\"t13\",\"cwd\":\"/tmp\",\"tool_name\":\"Task\",\"tool_input\":{\"subagent_type\":\"plan-executor\"}}" >/dev/null
val=$(get_ci_passed_at "t13" "/tmp")
assert_null "$val" "13. plan-executor Task preemptive invalidate"

# 13b. ui-engineer same
reset_state
mark_ci_passed "t13b" "/tmp"
run_hook_pre "{\"session_id\":\"t13b\",\"cwd\":\"/tmp\",\"tool_name\":\"Task\",\"tool_input\":{\"subagent_type\":\"ui-engineer\"}}" >/dev/null
val=$(get_ci_passed_at "t13b" "/tmp")
assert_null "$val" "13b. ui-engineer Task preemptive invalidate"

# 13c. doc-writer (Codex PR #30 P2-2): inline code comment 추가 권한 보유 →
# .go/.ts 등 코드 파일 직접 Edit 가능. preemptive invalidate 대상.
reset_state
mark_ci_passed "t13c" "/tmp"
run_hook_pre "{\"session_id\":\"t13c\",\"cwd\":\"/tmp\",\"tool_name\":\"Task\",\"tool_input\":{\"subagent_type\":\"doc-writer\"}}" >/dev/null
val=$(get_ci_passed_at "t13c" "/tmp")
assert_null "$val" "13c. doc-writer Task preemptive invalidate"

# 14. PreToolUse Task subagent_type=code-searcher (read-only) → 유지
reset_state
mark_ci_passed "t14" "/tmp"
run_hook_pre "{\"session_id\":\"t14\",\"cwd\":\"/tmp\",\"tool_name\":\"Task\",\"tool_input\":{\"subagent_type\":\"code-searcher\"}}" >/dev/null
val=$(get_ci_passed_at "t14" "/tmp")
[ -n "$val" ] && [ "$val" != "null" ]
assert_exit "0" "$?" "14. code-searcher Task → ci_passed_at preserved (read-only agent)"

# 15. SAZO_DISABLE_CI_INVALIDATE=1 → 모든 case 에서 유지
reset_state
mark_ci_passed "t15" "/tmp"
SAZO_DISABLE_CI_INVALIDATE=1 echo "{\"session_id\":\"t15\",\"cwd\":\"/tmp\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/tmp/foo.go\"}}" \
    | SAZO_DISABLE_CI_INVALIDATE=1 bash "$STATE_HOOK" "post" >/dev/null 2>&1
val=$(get_ci_passed_at "t15" "/tmp")
[ -n "$val" ] && [ "$val" != "null" ]
assert_exit "0" "$?" "15. SAZO_DISABLE_CI_INVALIDATE=1 → preserve on Edit"

# 16. user-skipped ci stage (ci_passed_at null) → stage_is_passed true (override)
reset_state
bash -c "
    export SAZO_STATE_DIR='$SAZO_STATE_DIR'
    source '$LIB'
    state_init 't16' '/tmp' 'opus'
    stage_mark 't16' 'ci' 'skipped' 'user' 'SAZO_ALLOW_CI_SKIP' '/tmp'
"
rc=$(stage_passed_rc "t16" "ci" "/tmp")
assert_eq "0" "$rc" "16. user-skipped ci passes even with ci_passed_at=null (override)"

# 17. Audit log entry 형식 검증
reset_state
mark_ci_passed "t17" "/tmp"
run_hook_post "{\"session_id\":\"t17\",\"cwd\":\"/tmp\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/tmp/foo.go\"}}" >/dev/null
if grep -q "ci_invalidated.*src=edit.*path=/tmp/foo.go.*sid=t17" "$SAZO_STATE_DIR/audit.log" 2>/dev/null; then
    PASS=$((PASS + 1)); echo "  ✓ 17. audit log entry format (src=edit + path + sid)"
else
    FAIL=$((FAIL + 1)); echo "  ✗ 17. audit log entry missing"
fi

# ===== Self-review followups (PR #30 round 17) =====

# 18. N3/N6 — repo path with `"` and `\` does not break jq path interpolation.
# Pre-fix the marker dict update silently dropped the entry because
# `.pre_commit_markers["/path/with\"quote"]` is a malformed jq filter.
# Post-fix the dict must be written + the post-hook range must catch the
# code commit (= ci_passed_at invalidated).
QUOTE_REPO="/tmp/sazo-ci-invalidate-quote\"repo-$$"
rm -rf "$QUOTE_REPO"; mkdir -p "$QUOTE_REPO"
(
    cd "$QUOTE_REPO"
    git init -q -b main && git config user.email s@t && git config user.name s
    git commit -q --allow-empty -m init
)
mark_ci_passed "t18" "$QUOTE_REPO"
# repo_root resolves via `git rev-parse --show-toplevel` which returns realpath.
# On macOS `/tmp` symlinks to `/private/tmp`, so the dict key is the real path.
QUOTE_REPO_REAL=$(cd "$QUOTE_REPO" && pwd -P)
# Build payload via jq so paths with `"` are properly JSON-encoded.
PRE_PAYLOAD=$(jq -nc --arg sid t18 --arg cwd "$QUOTE_REPO" --arg cmd "git commit -m a-code" \
    '{session_id: $sid, cwd: $cwd, tool_name: "Bash", tool_input: {command: $cmd}}')
echo "$PRE_PAYLOAD" | bash "$STATE_HOOK" "pre" >/dev/null 2>&1
DICT=$(bash -c "
    export SAZO_STATE_DIR='$SAZO_STATE_DIR'
    source '$LIB'
    state_get 't18' '.pre_commit_markers' \"\$1\"
" _ "$QUOTE_REPO")
if [ -n "$DICT" ] && [ "$DICT" != "null" ] \
    && printf '%s' "$DICT" | jq -e --arg k "$QUOTE_REPO_REAL" 'has($k)' >/dev/null 2>&1; then
    PASS=$((PASS + 1)); echo "  ✓ 18-dict. repo path with quotes registered in marker dict (jq --arg lookup)"
else
    FAIL=$((FAIL + 1)); echo "  ✗ 18-dict. quote path dropped (jq path interpolation bug; DICT='$DICT')"
fi
( cd "$QUOTE_REPO" && echo 'package main' > foo.go && git add foo.go && git commit -q -m a-code )
POST_PAYLOAD=$(jq -nc --arg sid t18 --arg cwd "$QUOTE_REPO" --arg cmd "git commit -m a-code" \
    '{session_id: $sid, cwd: $cwd, tool_name: "Bash", tool_input: {command: $cmd}, tool_response: {exit_code: 0}}')
echo "$POST_PAYLOAD" | bash "$STATE_HOOK" "post" >/dev/null 2>&1
val=$(bash -c "
    export SAZO_STATE_DIR='$SAZO_STATE_DIR'
    source '$LIB'
    state_get 't18' '.ci_passed_at' \"\$1\"
" _ "$QUOTE_REPO")
assert_null "$val" "18-post. quote path post-hook range covers code commit"
rm -rf "$QUOTE_REPO"

# 19. N4 — Edit /tmp/random/foo.go (path outside SAZO_CWD's repo) → conservative
# invalidate (treated as code, no docs/* match). Documents the safe-default
# behavior for external code edits.
reset_state
mark_ci_passed "t19" "$TMP_REPO"
EXT_DIR="/tmp/sazo-ci-invalidate-ext-$$"
rm -rf "$EXT_DIR"; mkdir -p "$EXT_DIR"
echo "{\"session_id\":\"t19\",\"cwd\":\"$TMP_REPO\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$EXT_DIR/foo.go\"}}" \
    | bash "$STATE_HOOK" "post" >/dev/null 2>&1
val=$(get_ci_passed_at "t19" "$TMP_REPO")
assert_null "$val" "19. Edit external code file (outside cwd's repo) → conservative invalidate"
rm -rf "$EXT_DIR"

# 20. N5 — variable-indirection evasion (documented gap). The hook's regex
# matches the literal string `git commit` in the Bash cmd. Constructing the
# command at runtime via variable splitting (`G="git c"; ${G}ommit`) defeats
# detection. Negative test — pins the known limitation so a future fix
# flips the assertion.
reset_state
SUB_REPO="/tmp/sazo-ci-invalidate-evasion-$$"
rm -rf "$SUB_REPO"; mkdir -p "$SUB_REPO"
(
    cd "$SUB_REPO"
    git init -q -b main && git config user.email s@t && git config user.name s
    git commit -q --allow-empty -m init
    echo 'package main' > foo.go && git add foo.go
)
mark_ci_passed "t20" "$SUB_REPO"
# `${G}ommit` — `git commit` only materializes after variable expansion.
# String `git commit` never appears literally in the cmd payload.
run_hook_pre "{\"session_id\":\"t20\",\"cwd\":\"$SUB_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"G='git c'; cd $SUB_REPO && \\\${G}ommit -m x\"}}" >/dev/null 2>&1
val=$(get_ci_passed_at "t20" "$SUB_REPO")
# Negative test: ci_passed_at preserved (gap documented in PR README).
[ -n "$val" ] && [ "$val" != "null" ]
assert_exit "0" "$?" "20. variable-indirection evasion — documented gap (ci_passed_at preserved)"
rm -rf "$SUB_REPO"

# 21. A4 — SAZO_DOC_WRITER_NO_INVALIDATE=1 escape hatch for doc-writer Task.
reset_state
mark_ci_passed "t21" "/tmp"
SAZO_DOC_WRITER_NO_INVALIDATE=1 echo "{\"session_id\":\"t21\",\"cwd\":\"/tmp\",\"tool_name\":\"Task\",\"tool_input\":{\"subagent_type\":\"doc-writer\"}}" \
    | SAZO_DOC_WRITER_NO_INVALIDATE=1 bash "$STATE_HOOK" "pre" >/dev/null 2>&1
val=$(get_ci_passed_at "t21" "/tmp")
[ -n "$val" ] && [ "$val" != "null" ]
assert_exit "0" "$?" "21. SAZO_DOC_WRITER_NO_INVALIDATE=1 → doc-writer Task preserves ci_passed_at"

# 22. A4 sanity — same env var must NOT affect plan-executor / ui-engineer
# (escape hatch is doc-writer-specific).
reset_state
mark_ci_passed "t22" "/tmp"
SAZO_DOC_WRITER_NO_INVALIDATE=1 echo "{\"session_id\":\"t22\",\"cwd\":\"/tmp\",\"tool_name\":\"Task\",\"tool_input\":{\"subagent_type\":\"plan-executor\"}}" \
    | SAZO_DOC_WRITER_NO_INVALIDATE=1 bash "$STATE_HOOK" "pre" >/dev/null 2>&1
val=$(get_ci_passed_at "t22" "/tmp")
assert_null "$val" "22. SAZO_DOC_WRITER_NO_INVALIDATE=1 does NOT affect plan-executor invalidate"

# 23. A1 — pre + post double-invalidate guard. Single git commit Bash
# invocation must produce only ONE `ci_invalidated` audit entry, not two
# (`src=git_commit` + `src=git_commit_post`).
reset_state
DOUBLE_REPO="/tmp/sazo-ci-invalidate-double-$$"
rm -rf "$DOUBLE_REPO"; mkdir -p "$DOUBLE_REPO"
(
    cd "$DOUBLE_REPO"
    git init -q -b main && git config user.email s@t && git config user.name s
    git commit -q --allow-empty -m init
    echo 'package main' > foo.go && git add foo.go
)
mark_ci_passed "t23" "$DOUBLE_REPO"
> "$SAZO_STATE_DIR/audit.log"
run_hook_pre "{\"session_id\":\"t23\",\"cwd\":\"$DOUBLE_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $DOUBLE_REPO commit -m a-code\"}}" >/dev/null 2>&1
( cd "$DOUBLE_REPO" && git commit -q -m a-code )
run_hook_post "{\"session_id\":\"t23\",\"cwd\":\"$DOUBLE_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $DOUBLE_REPO commit -m a-code\"},\"tool_response\":{\"exit_code\":0}}" >/dev/null 2>&1
INV_COUNT=$(grep -c "ci_invalidated.*sid=t23" "$SAZO_STATE_DIR/audit.log" 2>/dev/null || echo 0)
if [ "$INV_COUNT" = "1" ]; then
    PASS=$((PASS + 1)); echo "  ✓ 23. pre+post double-invalidate guard — single audit entry per commit"
else
    FAIL=$((FAIL + 1)); echo "  ✗ 23. expected 1 ci_invalidated entry, got $INV_COUNT"
fi
rm -rf "$DOUBLE_REPO"

# 24. A3 — stale marker cleanup-on-init. PostToolUse failure can leak markers;
# fresh state_init on a new state file must not inherit stale markers from
# a separate (older) cwd. New state file is born without stale markers.
reset_state
bash -c "
    export SAZO_STATE_DIR='$SAZO_STATE_DIR'
    source '$LIB'
    state_init 't24' '/tmp' 'opus'
"
DICT=$(bash -c "
    export SAZO_STATE_DIR='$SAZO_STATE_DIR'
    source '$LIB'
    state_get 't24' '.pre_commit_markers' '/tmp'
")
if [ -z "$DICT" ] || [ "$DICT" = "null" ] || [ "$DICT" = "{}" ]; then
    PASS=$((PASS + 1)); echo "  ✓ 24. fresh state_init has no stale pre_commit_markers"
else
    FAIL=$((FAIL + 1)); echo "  ✗ 24. fresh state inherited markers: $DICT"
fi

# 25. A5 — schema_version bumped (signals pre_commit_markers schema change).
SV=$(bash -c "
    export SAZO_STATE_DIR='$SAZO_STATE_DIR'
    source '$LIB'
    state_init 't25' '/tmp2' 'opus'
    state_get 't25' '.schema_version' '/tmp2'
")
if [ "$SV" = "5" ]; then
    PASS=$((PASS + 1)); echo "  ✓ 25. schema_version=5 (P09 bumped from v3 — W2 v4 + P09 v5 fields)"
else
    FAIL=$((FAIL + 1)); echo "  ✗ 25. schema_version=$SV (expected 5)"
fi

# 26. A2 — state_set_dict_value helper bootstraps null dict + writes value.
# Must work whether `.foo` is absent (null) or already a dict.
reset_state
bash -c "
    export SAZO_STATE_DIR='$SAZO_STATE_DIR'
    source '$LIB'
    state_init 't26' '/tmp' 'opus'
    # bootstrap from null
    state_set_dict_value 't26' '.test_dict' 'k1' '\"v1\"' '/tmp'
    # add to existing
    state_set_dict_value 't26' '.test_dict' 'k2' '\"v2\"' '/tmp'
"
V1=$(bash -c "
    export SAZO_STATE_DIR='$SAZO_STATE_DIR'
    source '$LIB'
    state_get 't26' '.test_dict.k1' '/tmp'
")
V2=$(bash -c "
    export SAZO_STATE_DIR='$SAZO_STATE_DIR'
    source '$LIB'
    state_get 't26' '.test_dict.k2' '/tmp'
")
if [ "$V1" = "v1" ] && [ "$V2" = "v2" ]; then
    PASS=$((PASS + 1)); echo "  ✓ 26. state_set_dict_value bootstraps null dict + appends key"
else
    FAIL=$((FAIL + 1)); echo "  ✗ 26. state_set_dict_value broken (v1='$V1' v2='$V2')"
fi

# 26b. A2 — state_set_dict_value with key containing `"` (jq --arg safety).
reset_state
bash -c "
    export SAZO_STATE_DIR='$SAZO_STATE_DIR'
    source '$LIB'
    state_init 't26b' '/tmp' 'opus'
    state_set_dict_value 't26b' '.test_dict' '/path/with\"quote' '\"v\"' '/tmp'
"
V=$(bash -c "
    export SAZO_STATE_DIR='$SAZO_STATE_DIR'
    source '$LIB'
    state_get 't26b' '.test_dict' '/tmp' | jq -r --arg k '/path/with\"quote' '.[\$k] // \"\"'
")
if [ "$V" = "v" ]; then
    PASS=$((PASS + 1)); echo "  ✓ 26b. state_set_dict_value handles key with quote (jq --arg safe)"
else
    FAIL=$((FAIL + 1)); echo "  ✗ 26b. state_set_dict_value mishandles quoted key (got '$V')"
fi

echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
