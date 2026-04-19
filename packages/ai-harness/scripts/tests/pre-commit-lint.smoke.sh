#!/bin/bash
# pre-commit-lint.sh smoke test
#
# 목적: PreToolUse hook의 분기 회귀 감지.
# - staged 없을 때 no-op
# - 캐시 hit → 커맨드 실행 + 수정된 파일 re-stage
# - 캐시 커맨드 실패 → exit 2로 commit 차단
# - 감지/캐시 모두 실패 → exit 0 + 안내 메시지
# - 자동 감지 (lint-staged, ruff, black, gofmt) 성공 → resolve 결과 정확
# - --set / --unset CLI → 캐시 파일 정확히 변경
#
# jq 필요. git 필요. 호스트 bash.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SCRIPT_DIR/pre-commit-lint.sh"
DETECT="$SCRIPT_DIR/lint-autofix-detect.sh"

for f in "$HOOK" "$DETECT"; do
    [ -x "$f" ] || { echo "FAIL: $f not executable"; exit 1; }
done

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git required"; exit 0; }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# detect_lint_autofix 가 `command -v <bin>` 체크를 하므로, host env에 따라
# yarn/pnpm/npx/ruff/black/gofmt 가 없으면 감지가 miss로 떨어진다. 테스트는
# 감지 로직 자체를 검증하는 것이므로 PATH에 no-op stub을 얹어 격리.
STUB_BIN="$SANDBOX/stub-bin"
mkdir -p "$STUB_BIN"
for bin in yarn pnpm npm npx ruff black gofmt; do
    cat > "$STUB_BIN/$bin" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$STUB_BIN/$bin"
done
export PATH="$STUB_BIN:$PATH"

FAIL=0

assert_eq() {
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

assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) echo "  OK   $label" ;;
        *)
            echo "  FAIL $label — '$needle' not in output"
            echo "       actual=<$haystack>"
            FAIL=$((FAIL + 1))
            ;;
    esac
}

make_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" config user.email t@t.t
    git -C "$dir" config user.name t
}

run_hook() {
    # $1 = cwd, $2 = command string
    local cwd="$1" command="$2"
    local input
    input=$(jq -n --arg c "$command" --arg d "$cwd" '{tool_input: {command: $c}, cwd: $d}')
    printf '%s' "$input" | SAZO_LINT_CACHE_FILE="$CACHE_FILE" "$HOOK"
}

# ───────────────────────────────────
echo "Case 1: staged 파일 없음 → exit 0, no-op"
CACHE_FILE="$SANDBOX/c1-cache.json"
REPO="$SANDBOX/c1"
make_repo "$REPO"

out=$(run_hook "$REPO" "git commit -m x" 2>&1); rc=$?
assert_eq "exit 0" "0" "$rc"
assert_eq "no stdout/stderr (no staged)" "" "$out"

# ───────────────────────────────────
echo ""
echo "Case 2: 캐시 hit + 성공 커맨드 (파일 인자 O) → re-stage, exit 0"
CACHE_FILE="$SANDBOX/c2-cache.json"
REPO="$SANDBOX/c2"
make_repo "$REPO"
echo "original" > "$REPO/file.txt"
git -C "$REPO" add file.txt

# fake lint: 파일을 'linted'로 수정
FAKE_LINT="$SANDBOX/c2-lint.sh"
cat > "$FAKE_LINT" <<'EOF'
#!/bin/bash
for f in "$@"; do
    echo "linted" > "$f"
done
exit 0
EOF
chmod +x "$FAKE_LINT"

SAZO_LINT_CACHE_FILE="$CACHE_FILE" "$HOOK" --set "$FAKE_LINT" --files-arg >/dev/null
(cd "$REPO" && SAZO_LINT_CACHE_FILE="$CACHE_FILE" "$HOOK" --set "$FAKE_LINT" --files-arg >/dev/null) || true

out=$(run_hook "$REPO" "git commit -m x" 2>&1); rc=$?
assert_eq "exit 0" "0" "$rc"

# staged 내용이 'linted'로 바뀌었는지 (re-stage 확인)
staged_content=$(git -C "$REPO" show :file.txt)
assert_eq "staged content replaced after re-stage" "linted" "$staged_content"

# ───────────────────────────────────
echo ""
echo "Case 3: 캐시 hit + 실패 커맨드 → exit 2 (commit 차단)"
CACHE_FILE="$SANDBOX/c3-cache.json"
REPO="$SANDBOX/c3"
make_repo "$REPO"
echo "hi" > "$REPO/a.txt"
git -C "$REPO" add a.txt

(cd "$REPO" && SAZO_LINT_CACHE_FILE="$CACHE_FILE" "$HOOK" --set "false" >/dev/null) || true

out=$(run_hook "$REPO" "git commit -m x" 2>&1); rc=$?
assert_eq "exit 2 on lint failure" "2" "$rc"
assert_contains "stderr mentions lint failure" "$out" "lint autofix 실패"

# ───────────────────────────────────
echo ""
echo "Case 4: 감지/캐시 모두 실패 → exit 0 + 안내 stderr"
CACHE_FILE="$SANDBOX/c4-cache.json"
REPO="$SANDBOX/c4"
make_repo "$REPO"
echo "x" > "$REPO/a.txt"
git -C "$REPO" add a.txt
# package.json, pyproject, go.mod 아무것도 없음

out=$(run_hook "$REPO" "git commit -m x" 2>&1); rc=$?
assert_eq "exit 0 (pass-through)" "0" "$rc"
assert_contains "stderr has detection miss notice" "$out" "자동 감지하지 못했습니다"
assert_contains "stderr has --set hint" "$out" "pre-commit-lint.sh --set"

# ───────────────────────────────────
echo ""
echo "Case 5: git commit이 아닌 커맨드 → exit 0, no-op (방어적 match)"
CACHE_FILE="$SANDBOX/c5-cache.json"
REPO="$SANDBOX/c5"
make_repo "$REPO"
echo "x" > "$REPO/a.txt"
git -C "$REPO" add a.txt

out=$(run_hook "$REPO" "git status" 2>&1); rc=$?
assert_eq "exit 0 on non-commit cmd" "0" "$rc"
assert_eq "no stderr" "" "$out"

# ───────────────────────────────────
echo ""
echo "Case 6: 감지 — lint-staged 의존성 존재 → yarn/npx/pnpm lint-staged"
REPO="$SANDBOX/c6"
mkdir -p "$REPO"
cat > "$REPO/package.json" <<'EOF'
{"devDependencies": {"lint-staged": "^15.0.0"}}
EOF
touch "$REPO/yarn.lock"

resolved=$(
    . "$DETECT"
    detect_lint_autofix "$REPO"
)
assert_eq "yarn lint-staged, no files-arg" "$(printf 'yarn lint-staged\tfalse')" "$resolved"

rm "$REPO/yarn.lock"; touch "$REPO/pnpm-lock.yaml"
resolved=$(
    . "$DETECT"
    detect_lint_autofix "$REPO"
)
assert_eq "pnpm lint-staged" "$(printf 'pnpm lint-staged\tfalse')" "$resolved"

rm "$REPO/pnpm-lock.yaml"  # fallback npm
resolved=$(
    . "$DETECT"
    detect_lint_autofix "$REPO"
)
assert_eq "npx lint-staged (fallback)" "$(printf 'npx lint-staged\tfalse')" "$resolved"

# ───────────────────────────────────
echo ""
echo "Case 7: 감지 — pyproject ruff → ruff check --fix (files-arg)"
REPO="$SANDBOX/c7"
mkdir -p "$REPO"
cat > "$REPO/pyproject.toml" <<'EOF'
[tool.ruff]
line-length = 100
EOF

resolved=$(
    . "$DETECT"
    detect_lint_autofix "$REPO"
)
assert_eq "ruff check --fix, files-arg" "$(printf 'ruff check --fix\ttrue')" "$resolved"

# ───────────────────────────────────
echo ""
echo "Case 8: 감지 — go.mod → gofmt -w (files-arg)"
REPO="$SANDBOX/c8"
mkdir -p "$REPO"
echo "module x" > "$REPO/go.mod"

resolved=$(
    . "$DETECT"
    detect_lint_autofix "$REPO"
)
assert_eq "gofmt -w, files-arg" "$(printf 'gofmt -w\ttrue')" "$resolved"

# ───────────────────────────────────
echo ""
echo "Case 9: --set/--unset CLI + 캐시 스키마"
CACHE_FILE="$SANDBOX/c9-cache.json"
REPO="$SANDBOX/c9"
make_repo "$REPO"

(cd "$REPO" && SAZO_LINT_CACHE_FILE="$CACHE_FILE" "$HOOK" --set 'npx lint-staged' >/dev/null)
# git rev-parse --show-toplevel은 canonical path를 돌려준다 (macOS /var → /private/var).
# hook 모드와 --set 모드 둘 다 같은 canonical을 쓰므로 캐시 일관성은 유지되지만,
# 테스트에선 그 canonical을 얻어 비교한다.
REPO_CANON=$(cd "$REPO" && git rev-parse --show-toplevel)
cmd=$(jq -r '.repos | to_entries[0].value.command' "$CACHE_FILE")
sf=$(jq -r '.repos | to_entries[0].value.supports_files_arg' "$CACHE_FILE")
path=$(jq -r '.repos | to_entries[0].value.path' "$CACHE_FILE")
assert_eq "cache command stored" "npx lint-staged" "$cmd"
assert_eq "cache supports_files_arg=false" "false" "$sf"
assert_eq "cache path matches repo (canonical)" "$REPO_CANON" "$path"

(cd "$REPO" && SAZO_LINT_CACHE_FILE="$CACHE_FILE" "$HOOK" --unset >/dev/null)
entries=$(jq -r '.repos | length' "$CACHE_FILE")
assert_eq "cache entries cleared after --unset" "0" "$entries"

# ───────────────────────────────────
# ───────────────────────────────────
echo ""
echo "Case 10: staged 파일명이 '--foo' 형태여도 옵션으로 해석되지 않도록 './' prefix"
CACHE_FILE="$SANDBOX/c10-cache.json"
REPO="$SANDBOX/c10"
make_repo "$REPO"
# 파일명 자체가 --option 모양. 실제 공격자가 저장소에 심을 수 있는 케이스.
ATTACK_NAME='--exec=pwned.txt'
echo "data" > "$REPO/$ATTACK_NAME"
git -C "$REPO" add -- "$ATTACK_NAME"

# fake lint: 인자로 받은 문자열을 파일에 기록. 옵션/파일 구분 확인용.
FAKE_LOG="$SANDBOX/c10-args.log"
FAKE_LINT="$SANDBOX/c10-lint.sh"
cat > "$FAKE_LINT" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$FAKE_LOG"
exit 0
EOF
chmod +x "$FAKE_LINT"

(cd "$REPO" && SAZO_LINT_CACHE_FILE="$CACHE_FILE" "$HOOK" --set "$FAKE_LINT" --files-arg >/dev/null)
run_hook "$REPO" "git commit -m x" >/dev/null 2>&1

received=$(cat "$FAKE_LOG")
assert_eq "attack filename passed with ./ prefix" "./--exec=pwned.txt" "$received"

# ───────────────────────────────────
echo ""
echo "Case 11: package.json에 devDependencies 키 자체가 없는 경우 감지 정상 fallthrough"
REPO="$SANDBOX/c11"
mkdir -p "$REPO"
echo '{"name":"x","version":"1.0.0"}' > "$REPO/package.json"
echo "module y" > "$REPO/go.mod"
# go.mod가 있으니 gofmt가 최종 선택돼야 함. devDeps null에서 jq 에러 없이 다음 분기로.

resolved=$(
    . "$DETECT"
    detect_lint_autofix "$REPO" 2>&1
)
assert_eq "no jq error, go.mod fallthrough → gofmt" "$(printf 'gofmt -w\ttrue')" "$resolved"

# ───────────────────────────────────
echo ""
echo "Case 12: --set 에 --files-arg 대신 오타/알수 없는 옵션 → ERROR"
CACHE_FILE="$SANDBOX/c12-cache.json"
REPO="$SANDBOX/c12"
make_repo "$REPO"

(cd "$REPO" && SAZO_LINT_CACHE_FILE="$CACHE_FILE" "$HOOK" --set 'some-cmd' --file-arg >/dev/null 2>&1)
rc=$?
assert_eq "exit 1 on unknown option" "1" "$rc"

# ───────────────────────────────────
echo ""
echo "Case 13: staged에 심볼릭 링크/디렉토리(서브모듈 gitlink 유사)면 필터링"
CACHE_FILE="$SANDBOX/c13-cache.json"
REPO="$SANDBOX/c13"
make_repo "$REPO"
echo "real" > "$REPO/real.txt"
ln -s "real.txt" "$REPO/link.txt"
git -C "$REPO" add -- real.txt link.txt

FAKE_LOG="$SANDBOX/c13-args.log"
FAKE_LINT="$SANDBOX/c13-lint.sh"
cat > "$FAKE_LINT" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$FAKE_LOG"
exit 0
EOF
chmod +x "$FAKE_LINT"

(cd "$REPO" && SAZO_LINT_CACHE_FILE="$CACHE_FILE" "$HOOK" --set "$FAKE_LINT" --files-arg >/dev/null)
run_hook "$REPO" "git commit -m x" >/dev/null 2>&1

# -f 테스트로 심볼릭 링크도 "regular file"이 아니라 제외됨 (symlink-to-file은 -f true이지만
# macOS bash에서 -f는 symlink를 dereference. 여기선 regular file 모두 허용되는 게 기본.
# 핵심은 디렉토리/존재하지 않는 파일 제외. symlink-to-file은 허용이 안전한 기본값.)
# 이 케이스는 주로 실행 안 터지고 결과가 real.txt 최소 1개 포함되면 OK.
received=$(cat "$FAKE_LOG")
case "$received" in
    *"./real.txt"*) echo "  OK   real file included (./real.txt in args)" ;;
    *) echo "  FAIL real file not included. actual=<$received>"; FAIL=$((FAIL + 1)) ;;
esac

# ───────────────────────────────────
echo ""
echo "Case 14: --set 에 shell metachar 포함 시 거부 (RCE 방어)"
CACHE_FILE="$SANDBOX/c14-cache.json"
REPO="$SANDBOX/c14"
make_repo "$REPO"

for bad in 'rm -rf ~; true' 'good && evil' 'cat /etc/passwd | head' 'echo $(whoami)' 'echo `id`'; do
    (cd "$REPO" && SAZO_LINT_CACHE_FILE="$CACHE_FILE" "$HOOK" --set "$bad" >/dev/null 2>&1)
    rc=$?
    if [ "$rc" = "1" ]; then
        echo "  OK   rejected: $bad"
    else
        echo "  FAIL allowed metachar: $bad (rc=$rc)"
        FAIL=$((FAIL + 1))
    fi
done

# ───────────────────────────────────
echo ""
echo "Case 15: 'git commit-tree' / 'echo \"git commit\"' → matcher 재검증에서 제외"
CACHE_FILE="$SANDBOX/c15-cache.json"
REPO="$SANDBOX/c15"
make_repo "$REPO"
echo "x" > "$REPO/a.txt"
git -C "$REPO" add a.txt

# 캐시에 failing lint 넣어서 — hook이 오발동 시 exit 2로 차단하게 함
(cd "$REPO" && SAZO_LINT_CACHE_FILE="$CACHE_FILE" "$HOOK" --set "false" >/dev/null)

# commit-tree는 실제 git 명령이지만 hook은 무시해야 함
out=$(run_hook "$REPO" "git commit-tree HEAD^{tree}" 2>&1); rc=$?
assert_eq "exit 0 on git commit-tree (not real commit)" "0" "$rc"

# echo 'git commit' 같은 거짓 매칭도 무시
out=$(run_hook "$REPO" "echo 'git commit was done'" 2>&1); rc=$?
assert_eq "exit 0 on echo containing git commit" "0" "$rc"

# 진짜 git commit은 여전히 발동해서 false lint로 차단
out=$(run_hook "$REPO" "git commit -m x" 2>&1); rc=$?
assert_eq "exit 2 on real git commit (lint fails)" "2" "$rc"

# ───────────────────────────────────
echo ""
echo "Case 19: partial staging (unstaged hunk) 파일은 lint 대상에서 제외 (Codex R3 P1 회귀 방어)"
CACHE_FILE="$SANDBOX/c19-cache.json"
REPO="$SANDBOX/c19"
make_repo "$REPO"

# 초기 상태: v1 커밋 → working tree에 v2 수정 → 부분만 staging → working tree는 v3
echo "v1" > "$REPO/a.txt"
git -C "$REPO" add a.txt
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m init

echo "v2" > "$REPO/a.txt"
git -C "$REPO" add a.txt             # a.txt staged = v2
echo "v3-UNSTAGED-SECRET" > "$REPO/a.txt"  # working tree = v3 (unstaged hunk)

# fake lint: 인자로 받은 모든 파일명을 log에 기록
FAKE_LOG="$SANDBOX/c19-args.log"
FAKE_LINT="$SANDBOX/c19-lint.sh"
cat > "$FAKE_LINT" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$FAKE_LOG"
exit 0
EOF
chmod +x "$FAKE_LINT"

(cd "$REPO" && SAZO_LINT_CACHE_FILE="$CACHE_FILE" "$HOOK" --set "$FAKE_LINT" --files-arg >/dev/null)
out=$(run_hook "$REPO" "git commit -m x" 2>&1); rc=$?
assert_eq "exit 0 (partial-staged 파일 스킵 후 staged 0개라 no-op)" "0" "$rc"

# FAKE_LOG가 존재하지 않아야 함 (lint 안 돌았음)
if [ ! -f "$FAKE_LOG" ]; then
    echo "  OK   lint 실행 안 됨 (partial staged 파일은 제외되어 타겟 없음)"
else
    args=$(cat "$FAKE_LOG")
    echo "  FAIL lint가 partial-staged 파일에 실행됨: $args"
    FAIL=$((FAIL + 1))
fi

# staged blob은 v2 그대로 유지 (hook이 re-stage로 덮지 않음)
staged_content=$(git -C "$REPO" show :a.txt)
assert_eq "staged blob 보존 (v2 유지, v3-SECRET 안 새어들어감)" "v2" "$staged_content"

# ───────────────────────────────────
echo ""
echo "Case 20: --set 에 단일 '&' (background) 거부 (Codex R3 P2 회귀 방어)"
CACHE_FILE="$SANDBOX/c20-cache.json"
REPO="$SANDBOX/c20"
make_repo "$REPO"

(cd "$REPO" && SAZO_LINT_CACHE_FILE="$CACHE_FILE" "$HOOK" --set 'tool --fix & attacker-cmd' >/dev/null 2>&1)
rc=$?
assert_eq "exit 1 on bare ampersand" "1" "$rc"

# ───────────────────────────────────
echo ""
echo "Case 18: runner/executable 부재 시 감지 miss (Codex R2 P1/P2 회귀 방어)"
REPO="$SANDBOX/c18"
mkdir -p "$REPO"

# lint-staged devDep 선언됐지만 yarn/pnpm/npx 전부 PATH에 없음
echo '{"devDependencies":{"lint-staged":"^15"}}' > "$REPO/package.json"
touch "$REPO/yarn.lock"
resolved=$(
    PATH="/usr/bin:/bin"   # stub 배제
    . "$DETECT"
    detect_lint_autofix "$REPO" 2>&1
    echo "RC=$?"
)
case "$resolved" in
    *"RC=1"*) echo "  OK   runner 전부 부재 → lint-staged 감지 skip" ;;
    *) echo "  FAIL detected without runner: $resolved"; FAIL=$((FAIL + 1)) ;;
esac

# pyproject.toml만 있고 ruff 실행 파일 없으면 감지 miss
REPO2="$SANDBOX/c18b"
mkdir -p "$REPO2"
echo '[tool.ruff]' > "$REPO2/pyproject.toml"
resolved=$(
    PATH="/usr/bin:/bin"
    . "$DETECT"
    detect_lint_autofix "$REPO2" 2>&1
    echo "RC=$?"
)
case "$resolved" in
    *"RC=1"*) echo "  OK   ruff 부재 → ruff 감지 skip" ;;
    *) echo "  FAIL detected without ruff: $resolved"; FAIL=$((FAIL + 1)) ;;
esac

# go.mod만 있고 gofmt 부재
REPO3="$SANDBOX/c18c"
mkdir -p "$REPO3"
echo "module x" > "$REPO3/go.mod"
resolved=$(
    PATH="/usr/bin:/bin"
    . "$DETECT"
    detect_lint_autofix "$REPO3" 2>&1
    echo "RC=$?"
)
case "$resolved" in
    *"RC=1"*) echo "  OK   gofmt 부재 → gofmt 감지 skip" ;;
    *) echo "  FAIL detected without gofmt: $resolved"; FAIL=$((FAIL + 1)) ;;
esac

# ───────────────────────────────────
echo ""
echo "Case 16: Python repo + .md만 staged → lint 스킵 (P1 회귀 방어)"
CACHE_FILE="$SANDBOX/c16-cache.json"
REPO="$SANDBOX/c16"
make_repo "$REPO"
# pyproject.toml은 ruff 감지 트리거, 커밋은 Markdown만
cat > "$REPO/pyproject.toml" <<'EOF'
[tool.ruff]
line-length = 100
EOF
echo "# hi" > "$REPO/README.md"
git -C "$REPO" add pyproject.toml README.md
# HEAD를 만들어서 이후 커밋의 staged가 README.md만이 되게 함
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m "init"
echo "# hi v2" > "$REPO/README.md"
git -C "$REPO" add README.md

# 감지는 ruff로 될 것. 실제 ruff 없어도 필터로 FILTERED 비어서 skip되어야 함.
out=$(run_hook "$REPO" "git commit -m x" 2>&1); rc=$?
assert_eq "exit 0 — ruff 감지됐지만 .md만 staged이므로 skip" "0" "$rc"

# ───────────────────────────────────
echo ""
echo "Case 17: lint-staged dependency 없고 top-level config key만 있는 repo → 감지 miss (P2 회귀 방어)"
REPO="$SANDBOX/c17"
mkdir -p "$REPO"
cat > "$REPO/package.json" <<'EOF'
{"name":"x","version":"1.0.0","lint-staged":{"*.js":"eslint --fix"}}
EOF

resolved=$(
    . "$DETECT"
    detect_lint_autofix "$REPO" 2>&1
    echo "RC=$?"
)
# 감지 실패 (return 1) → stdout 없고 RC=1
case "$resolved" in
    *"RC=1"*) echo "  OK   top-level lint-staged config 무시 (dependency 선언 없음)" ;;
    *) echo "  FAIL config-only detected: $resolved"; FAIL=$((FAIL + 1)) ;;
esac

# 반면 devDependency로 선언되면 정상 감지
echo '{"name":"x","devDependencies":{"lint-staged":"^15"}}' > "$REPO/package.json"
resolved=$(
    . "$DETECT"
    detect_lint_autofix "$REPO"
)
assert_eq "devDependency 선언 시 정상 감지" "$(printf 'npx lint-staged\tfalse')" "$resolved"

# ───────────────────────────────────
echo ""
echo "─────────────────────"
if [ "$FAIL" -eq 0 ]; then
    echo "OK: All pre-commit-lint smoke tests passed"
    exit 0
else
    echo "FAIL: $FAIL assertion(s) failed"
    exit 1
fi
