#!/bin/bash
# PreToolUse hook: git commit 직전에 **스테이징된 파일만** 대상으로 lint autofix 실행.
#
# ~/.claude/settings.json hooks.PreToolUse, matcher: Bash(git commit:*)
#
# 동작:
#   stdin JSON: { tool_input: { command: "git commit ..." }, cwd: "/path/to/repo" }
#   1. cwd가 git repo인지 확인 (아니면 통과)
#   2. staged 파일(ACMR) 추출. 비었으면 통과 (--allow-empty 등)
#   3. lint 커맨드 해결: 캐시 → 자동 감지. 실패 시 stderr 안내 + 통과 (커밋은 허용)
#   4. lint 실행. exit != 0 → exit 2로 commit 차단 (stderr이 Claude에게 피드백)
#   5. 성공 시 원래 staged 목록 중 실존 파일만 re-stage (스코프 유출 방지 핵심)
#
# CLI 모드:
#   pre-commit-lint.sh --set <command> [--files-arg]
#     → 현재 cwd의 git repo에 lint 커맨드를 전역 캐시에 등록
#   pre-commit-lint.sh --unset
#     → 현재 cwd의 git repo를 캐시에서 제거

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lint-autofix-detect.sh
. "$SCRIPT_DIR/lint-autofix-detect.sh"

# --- CLI 모드 ---

if [ "${1:-}" = "--set" ]; then
    shift
    if [ $# -lt 1 ]; then
        echo "usage: $0 --set <command> [--files-arg]" >&2
        exit 1
    fi
    CMD="$1"; shift
    SUPPORTS=false
    if [ $# -gt 0 ]; then
        if [ "$1" = "--files-arg" ]; then
            SUPPORTS=true
        else
            echo "ERROR: unknown option '$1' (expected --files-arg or nothing)" >&2
            exit 1
        fi
    fi

    # 등록 값은 이후 매 커밋마다 `bash -c`로 평가된다. shell metachar가 들어오면
    # prompt injection을 통한 영구 RCE로 이어질 수 있으므로 거부.
    # 복잡한 로직은 저장소 내 스크립트 경로로만 허용.
    case "$CMD" in
        *';'*|*'&&'*|*'||'*|*'|'*|*'$('*|*'`'*|*'>'*|*'<'*|$'\n'*|*$'\n'*)
            echo "ERROR: command contains shell metacharacter (;, &&, ||, |, \$(), \`, redirect, newline)" >&2
            echo "  registered value would be evaluated by bash -c on every commit." >&2
            echo "  use a single binary + flags, or a script path inside your repo." >&2
            exit 1
            ;;
    esac

    REPO=$(git rev-parse --show-toplevel 2>/dev/null) || {
        echo "ERROR: cwd is not inside a git repo ($PWD)" >&2
        exit 1
    }
    if lint_cache_set "$REPO" "$CMD" "$SUPPORTS"; then
        echo "Registered lint autofix command for $REPO"
        echo "  command:            $CMD"
        echo "  supports_files_arg: $SUPPORTS"
        echo "  cache:              $LINT_CACHE_FILE"
    else
        echo "ERROR: failed to write $LINT_CACHE_FILE" >&2
        exit 1
    fi
    exit 0
fi

if [ "${1:-}" = "--unset" ]; then
    REPO=$(git rev-parse --show-toplevel 2>/dev/null) || {
        echo "ERROR: cwd is not inside a git repo ($PWD)" >&2
        exit 1
    }
    lint_cache_unset "$REPO"
    echo "Removed $REPO from $LINT_CACHE_FILE"
    exit 0
fi

# --- Hook 모드 ---

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)

# 방어적 재검증 — matcher가 좁혀주지만, `git commit-tree` / `git commit-graph`,
# 혹은 `echo "git commit"` 같은 substring 매칭 함정을 배제한다.
# `git commit` 또는 `git commit <whitespace>` 또는 `git commit<EOL>`만 통과.
if [[ ! "$COMMAND" =~ (^|[[:space:];\&\|]+)git[[:space:]]+commit([[:space:]]|$) ]]; then
    exit 0
fi

[ -n "$CWD" ] || CWD="$PWD"

REPO_ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null) || exit 0

STAGED=()
while IFS= read -r -d '' f; do
    # regular file만 포함 — 서브모듈(gitlink)은 디렉토리로 잡혀 recursive lint로 이어질 수 있고,
    # 심볼릭 링크는 autofix 대상으로 부적절. git이 이미 삭제로 제외했으니 -f로 충분.
    [ -f "$REPO_ROOT/$f" ] || continue
    STAGED+=("$f")
done < <(git -C "$REPO_ROOT" diff --cached --name-only --diff-filter=ACMR -z 2>/dev/null)

[ "${#STAGED[@]}" -gt 0 ] || exit 0

if ! RESOLVED=$(resolve_lint_command "$REPO_ROOT" 2>/dev/null); then
    # stderr 메시지는 self-contained — Claude가 CLAUDE.md를 맥락에 안 들고 있을 수도 있다.
    cat >&2 <<EOF
[sazo-ai-harness pre-commit-lint] lint autofix 커맨드를 자동 감지하지 못했습니다.
  repo: $REPO_ROOT

감지 규칙(package.json의 lint-staged, pyproject.toml의 ruff/black, go.mod) 모두에 해당하지 않는 저장소입니다.

AI는 먼저 **사용자에게** 다음을 질문하세요:

  "이 저장소에서 staged 파일만 autofix하는 정확한 커맨드는 무엇인가요?
   (예: 'npx lint-staged', 'yarn lint --fix', 직접 만든 스크립트 등)
   그리고 그 커맨드가 파일 경로를 인자로 받아 실행해야 하는 형태인가요?"

답변을 받으면 아래 절대경로로 등록하세요. \$SCRIPT_DIR은 변수가 아니라 실제 경로로 출력된 것입니다:

  $SCRIPT_DIR/pre-commit-lint.sh --set '<command>' [--files-arg]

예시:
  $SCRIPT_DIR/pre-commit-lint.sh --set 'npx lint-staged'             # lint-staged 계열: --files-arg 없음
  $SCRIPT_DIR/pre-commit-lint.sh --set 'yarn lint --fix' --files-arg # 파일 경로 인자 필요

--files-arg 판단 기준:
  - 커맨드 뒤에 파일 경로를 공백 구분으로 붙여 실행해야 한다 → --files-arg 추가
  - 커맨드가 내부에서 staged를 스스로 감지한다 (lint-staged 등) → 추가하지 않음
  - 잘못 선택하면 전체 프로젝트 lint로 확장되어 스코프 유출 발생.

이번 커밋은 lint 없이 통과시켰습니다. 이 안내는 등록 전까지 매 커밋마다 다시 뜹니다 — 반복을 피하려면 지금 등록하세요.
EOF
    exit 0
fi

LINT_CMD=$(printf '%s' "$RESOLVED" | cut -f1)
SUPPORTS_FILES=$(printf '%s' "$RESOLVED" | cut -f2)

cd "$REPO_ROOT" || {
    echo "[sazo-ai-harness pre-commit-lint] WARN: cd '$REPO_ROOT' failed — repo moved? lint skipped." >&2
    exit 0
}

START=$(date +%s)
if [ "$SUPPORTS_FILES" = "true" ]; then
    # 커맨드별 확장자 필터 — 자동 감지된 언어별 도구(ruff/black/gofmt)가 대상 외 파일
    # (예: 문서 repo에 `pyproject.toml`만 있고 커밋은 README만)을 파싱하다 실패해 commit을
    # 차단하는 문제를 차단. 사용자가 `--set`으로 등록한 임의 커맨드는 필터 없이 그대로
    # 전달 (사용자 책임 + 매칭 패턴 예측 불가).
    FILTER_RE=''
    case "$LINT_CMD" in
        ruff*|*' ruff '*|black*|*' black '*) FILTER_RE='\.pyi?$' ;;
        gofmt*|*' gofmt '*)                  FILTER_RE='\.go$' ;;
    esac

    FILTERED=()
    for f in "${STAGED[@]}"; do
        if [ -n "$FILTER_RE" ]; then
            [[ "$f" =~ $FILTER_RE ]] || continue
        fi
        FILTERED+=("$f")
    done

    # 필터 후 아무것도 없으면 lint 스킵 — commit 통과.
    # (예: Python repo에서 Markdown만 수정한 커밋)
    if [ "${#FILTERED[@]}" -eq 0 ]; then
        LINT_RC=0
    else
        # 파일명이 '--foo' 같은 옵션으로 해석되는 것을 방지하기 위해 './' prefix.
        # gofmt는 `--` 구분자를 지원하지 않으므로 경로 정규화가 가장 범용적.
        SAFE_STAGED=()
        for f in "${FILTERED[@]}"; do
            case "$f" in
                ./*|/*) SAFE_STAGED+=("$f") ;;
                *)      SAFE_STAGED+=("./$f") ;;
            esac
        done
        bash -c "$LINT_CMD \"\$@\"" _ "${SAFE_STAGED[@]}"
        LINT_RC=$?
    fi
else
    bash -c "$LINT_CMD"
    LINT_RC=$?
fi
ELAPSED=$(( $(date +%s) - START ))

if [ "$ELAPSED" -gt 60 ]; then
    echo "[sazo-ai-harness pre-commit-lint] WARN: lint 실행에 ${ELAPSED}s 소요 (60s 초과). 저장소 lint 설정 최적화 검토 권장." >&2
fi

if [ "$LINT_RC" -ne 0 ]; then
    echo "[sazo-ai-harness pre-commit-lint] lint autofix 실패 (exit $LINT_RC, cmd='$LINT_CMD'). git commit 차단됨. lint 출력을 확인해 문제를 수정 후 재시도하세요." >&2
    exit 2
fi

# 원래 staged 파일만 re-stage — autofix가 파일을 수정했을 수 있음.
# 주의: 스테이징되지 않은 다른 파일은 건드리지 않는다 (스코프 유출 방지).
# lint-staged는 내부적으로 이미 re-add하지만, 공통 경로로 단순화.
for f in "${STAGED[@]}"; do
    [ -e "$REPO_ROOT/$f" ] || continue
    git -C "$REPO_ROOT" add -- "$f" 2>/dev/null || true
done

exit 0
