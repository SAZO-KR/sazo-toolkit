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

# 9. CI 재실행 → 다시 set + PR create 통과
# 모킹: invalidate 후 CI 통과 강제 마킹 → review도 마킹 → PR create pass
reset_state
mark_ci_passed "t9" "/tmp"
run_hook_post "{\"session_id\":\"t9\",\"cwd\":\"/tmp\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/tmp/foo.go\"}}" >/dev/null
val=$(get_ci_passed_at "t9" "/tmp")
assert_null "$val" "9-pre. invalidated"
# 재CI: 다시 mark
bash -c "
    export SAZO_STATE_DIR='$SAZO_STATE_DIR'
    source '$LIB'
    state_set_str 't9' '.ci_passed_at' '2026-05-09T11:00:00+0900' '/tmp'
    stage_mark 't9' 'ci' 'completed' 'auto' 'mock-rerun' '/tmp'
    stage_mark 't9' 'review' 'completed' 'auto' 'mock' '/tmp'
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

echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
