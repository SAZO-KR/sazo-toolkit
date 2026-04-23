#!/bin/bash
# pre-worktree-gate.sh — PreToolUse hook.
#
# 첫 mutating tool 호출 전에 worktree 격리를 강제한다.
# - 보호 브랜치(main/master/dev/develop)에서 mutating 시도 → block
# - 이미 PR merged/closed된 worktree에서 새 작업 시도 → block
# - clean + origin 동기화된 worktree → soft 경고
# - 위 조건 충족 시 사용자가 `/skip worktree <reason>`로 override 가능
#
# CLAUDE.md "1. 워크트리 격리" 규칙을 행동 레벨로 강제.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/session-state.sh
source "$LIB_DIR/session-state.sh"

if ! workflow_hooks_enabled || [ "${SAZO_SKIP_WORKTREE_GATE:-0}" = "1" ]; then
    exit 0
fi

read_hook_payload

if [ -z "${SAZO_SESSION_ID:-}" ]; then
    # session_id 없음 → passthrough (claude code 외 호출 가능성)
    exit 0
fi

state_init "$SAZO_SESSION_ID" "$SAZO_CWD" "$SAZO_MODEL"

# 사용자 명시 skip (/skip worktree ...)만 early return. 자동 completed는 검사 반복 —
# 한 번 pass 후 session 중 main으로 checkout해서 mutating tool 쓸 여지 차단.
# (Codex V1 P1: early return이 session·cwd 단위 gate를 영구 disable)
# 추가 가드: by=auto skip(non-git repo 경로)도 fast-path 대상 아님 — non-git dir에서
# git init 후 main에서 mutating tool 시 bypass 방지 (Codex V3 P1).
LAST_WT_STATUS=$(state_get "$SAZO_SESSION_ID" '[.history[] | select(.stage == "worktree")] | last.status')
LAST_WT_BY=$(state_get "$SAZO_SESSION_ID" '[.history[] | select(.stage == "worktree")] | last.by')
if [ "$LAST_WT_STATUS" = "skipped" ] && [ "$LAST_WT_BY" = "user" ]; then
    exit 0
fi

# Bash tool은 mutating 명령만 필터. word-boundary regex로 false positive 최소화.
# Mutating 판정: git의 write subcommand, package install/add, redirection,
# rm/mv (read-only로 거의 사용 안 됨), make/build (실제로 파일 생성).
# read-only로 자주 쓰이는 ls/cat/cp는 제외 — gate 트리거 안 함.
if [ "$SAZO_TOOL_NAME" = "Bash" ]; then
    cmd=$(echo "$SAZO_TOOL_INPUT" | jq -r '.command // ""')
    is_mutating=0
    # git mutating subcommands (word-bounded).
    if echo "$cmd" | grep -qE '\bgit[[:space:]]+(commit|add|push|merge|rebase|reset|cherry-pick|stash|branch|restore|tag[[:space:]]+-|worktree[[:space:]]+(add|remove))'; then
        is_mutating=1
    fi
    # switch/checkout: compound `&&|||;`로 split, **각 segment 독립 평가**.
    # segment 내 git switch/checkout 있고 같은 segment 내 --detach 없으면 mutating.
    # 전체 string grep은 다른 segment의 --detach가 carve-out hijack 가능 (V5 reviewer #1).
    if [ "$is_mutating" = "0" ]; then
        # macOS sed는 replacement \n 미지원 — awk gsub 사용 (literal newline 안전).
        # script top-level이라 `local` 사용 안 됨 (V6 reviewer #1: bash stderr 에러).
        segments=$(printf '%s' "$cmd" | awk '{gsub(/&&|\|\||;/, "\n"); print}')
        while IFS= read -r seg; do
            seg=$(printf '%s' "$seg" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
            [ -z "$seg" ] && continue
            if echo "$seg" | grep -qE '\bgit[[:space:]]+(switch|checkout)\b' \
               && ! echo "$seg" | grep -qE '\bgit[[:space:]]+(switch|checkout)\b.*--detach(\b|$)'; then
                is_mutating=1
                break
            fi
        done <<< "$segments"
    fi
    # package managers — install/add/upgrade
    if echo "$cmd" | grep -qE '\b(yarn|npm|pnpm|pip|bundle|cargo|go)\b[[:space:]]+(install|add|upgrade|update|get)'; then
        is_mutating=1
    fi
    # build steps that emit artifacts
    if echo "$cmd" | grep -qE '\b(go|cargo)[[:space:]]+build\b'; then
        is_mutating=1
    fi
    # shell redirection (write/append) — heuristic. `>`, `>>` 모두 match.
    # Exclusion: `2>`, `&>`, fd redirect `N>` 등은 실제 write이지만 stderr 리디렉션이
    # 더 흔해 false positive 회피 위해 앞 문자가 word character면 mutating 아님.
    if echo "$cmd" | grep -qE '(^|[^<>&|0-9])>>?[^>&]'; then
        is_mutating=1
    fi
    # destructive fs ops
    if echo "$cmd" | grep -qE '\b(rm|mv)\b[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*[^[:space:]]'; then
        is_mutating=1
    fi
    [ "$is_mutating" = "0" ] && exit 0
fi

# git 정보 수집
cd "${SAZO_CWD:-.}" 2>/dev/null || exit 0

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    # git repo 아님 → passthrough
    stage_mark "$SAZO_SESSION_ID" "worktree" "skipped" "auto" "not a git repo"
    exit 0
fi

current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
is_protected=0
case "$current_branch" in
    main|master|dev|develop|trunk) is_protected=1 ;;
esac

# 보호 브랜치 → block
if [ "$is_protected" = "1" ]; then
    cat >&2 <<EOF
[worktree-gate] 보호 브랜치($current_branch)에서 mutating tool 호출 차단.
새 작업은 worktree 격리 필수. 다음 중 하나:

  1. worktree 생성: ~/.claude/skills/isolate/SKILL.md 참조 또는
     git worktree add -b <branch> ../$(basename "$PWD")-<branch> origin/main

  2. 설정/문서 긴급 수정이 의도면: /skip worktree <reason>

  3. 이 gate 일시 비활성: SAZO_SKIP_WORKTREE_GATE=1 (세션 단위)
EOF
    exit 2
fi

# worktree 상태 체크
uncommitted=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
ahead=$(git rev-list --count "@{u}..HEAD" 2>/dev/null || echo 0)
behind=$(git rev-list --count "HEAD..@{u}" 2>/dev/null || echo 0)

# PR 상태 조회 (gh 있으면)
pr_state=""
if command -v gh >/dev/null 2>&1; then
    pr_state=$(gh pr view --json state --jq '.state' 2>/dev/null || echo "")
fi

# 1) PR merged/closed + clean worktree → stale, 새 작업 위험 → block
if [ -n "$pr_state" ] && { [ "$pr_state" = "MERGED" ] || [ "$pr_state" = "CLOSED" ]; } \
   && [ "$uncommitted" = "0" ]; then
    cat >&2 <<EOF
[worktree-gate] 현재 worktree($current_branch) PR=$pr_state, clean 상태.
이전 작업 완료된 worktree. 새 작업이면 분리 필수.

  1. 새 worktree: git worktree add -b <new-branch> ../<new-dir> origin/main
  2. 계속 작업 의도면: /skip worktree <reason>
  3. 비활성: SAZO_SKIP_WORKTREE_GATE=1
EOF
    exit 2
fi

# 2) 통과. stage marker 기록.
stage_mark "$SAZO_SESSION_ID" "worktree" "completed" "auto" "branch=$current_branch uncommitted=$uncommitted ahead=$ahead"
exit 0
