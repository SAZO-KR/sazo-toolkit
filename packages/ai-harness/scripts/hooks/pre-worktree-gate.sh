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

if ! narrow_hooks_enabled || [ "${SAZO_SKIP_WORKTREE_GATE:-0}" = "1" ]; then
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
    # `-C <path>` optional prefix 인식 (git -C path subcmd ... 패턴).
    # worktree subcommands: `add`만 mutating. `remove`/`prune`/`list`/`lock`/`unlock`/
    # `move`/`repair`는 cleanup/read-only이므로 차단에서 제외 (cleanup 자체 막힘 방지).
    # branch는 별도 분기 — `<name>` create / `-d/-D/-m/-M/-c/-C` 옵션만 mutating.
    # `git branch` 단독/`-l`/`-v`/`-r`/`-a`/`--show-current`는 read-only.
    if echo "$cmd" | grep -qE '\bgit[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?(commit|add|push|merge|rebase|reset|cherry-pick|stash|restore|worktree[[:space:]]+add)\b'; then
        is_mutating=1
    fi
    # git branch: 다음 중 하나면 mutating
    #   (1) <name> (non-dash positional) — create
    #   (2) -d/-D/-m/-M/-c/-C/-f short — delete/rename/copy/force
    #   (3) --delete/--move/--copy/--force/--track/--no-track/
    #       --set-upstream-to/--unset-upstream/--edit-description long
    # Read-only: 단독, -l/-v/-vv/-r/-a/-h, --list, --verbose, --remotes, --all,
    #            --show-current, --contains/--no-contains, --merged/--no-merged,
    #            --points-at, --column, --sort, --format.
    # git branch — segment 분리 후 각 segment 내에서만 검사 (Codex PR#39 round 3 P2).
    # 기존 cmd 전체에 적용한 regex `([^[:space:]]+[[:space:]]+)*` 는 `&&|||;` 가로질러
    # 다음 segment의 flag 매칭 (예: `git branch --show-current && echo -f` 가 차단됨).
    # switch/checkout carve-out 패턴 따라 segment 분리.
    # Gemini PR#39 medium: clustered short flag `-dr` 미탐지 회귀 → cluster 어디든 매칭.
    # Codex PR#39 round 2: `-u` short form (`--set-upstream-to`) 추가.
    if [ "$is_mutating" = "0" ]; then
        # Codex PR#39 round 5: pipe `|` 도 boundary. order: `\|\|` 먼저 매칭 후 single `\|`.
        branch_segments=$(printf '%s' "$cmd" | awk '{gsub(/&&|\|\||;|\|/, "\n"); print}')
        while IFS= read -r bseg; do
            bseg=$(printf '%s' "$bseg" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
            [ -z "$bseg" ] && continue
            # (1) non-dash positional 첫 인자 → create
            # 옵션 prefix 후의 positional은 검사 안 함 — `--contains HEAD`, `--merged <commit>` 등
            # 인자 받는 read-only 옵션과 구분 어려움. mutating 옵션은 (2)에서 명시적으로 catch.
            if echo "$bseg" | grep -qE '\bgit[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?branch[[:space:]]+[^-[:space:]]'; then
                is_mutating=1
                break
            fi
            # (2) mutating short/long flag — segment 안에서만 검사
            # short: cluster 어디든 dDmMcCfu 포함
            # long: --delete/--move/--copy/--force/--track/--no-track/
            #       --set-upstream-to/--unset-upstream/--edit-description/--create-reflog
            # Codex PR#39 round 4: `--create-reflog` 추가 (`git branch --create-reflog ...`는 mutating).
            if echo "$bseg" | grep -qE '\bgit[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?branch[[:space:]]+([^[:space:]]+[[:space:]]+)*(-[a-zA-Z]*[dDmMcCfu][a-zA-Z]*|--(delete|move|copy|force|track|no-track|set-upstream-to|unset-upstream|edit-description|create-reflog|no-create-reflog))(\b|=)'; then
                is_mutating=1
                break
            fi
        done <<< "$branch_segments"
    fi
    # Note: 안쪽 `[^[:space:]]+` (1글자 이상) — POSIX ERE backtracking 안전.
    # `*` (0글자 이상) 사용 시 nested quantifier로 catastrophic backtracking 위험 (critic v2).
    # git tag: `git tag <name>` (non-dash arg → create) 및 `-a`/`-d`/`-f` 옵션은
    # mutating. `git tag` 단독 / `-l` / `--list`는 read-only (Codex V6 P1).
    # `-C <path>` optional prefix 인식.
    if echo "$cmd" | grep -qE '\bgit[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?tag[[:space:]]+[^-[:space:]]'; then
        is_mutating=1
    fi
    if echo "$cmd" | grep -qE '\bgit[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?tag[[:space:]]+-[adf]'; then
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
            if echo "$seg" | grep -qE '\bgit[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?(switch|checkout)\b' \
               && ! echo "$seg" | grep -qE '\bgit[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?(switch|checkout)\b.*--detach(\b|$)'; then
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
    # shell redirection (write/append). `>`, `>>`, `1>`, `1>>` 전부 매치.
    # stdout fd(1) 명시 redirect도 실제 write (Codex V4 P2). stderr(`2>`) 등 다른
    # fd는 `2>/dev/null` 흔한 패턴 때문에 제외.
    if echo "$cmd" | grep -qE '(^|[^<>&|0-9])1?>>?[^>&]'; then
        is_mutating=1
    fi
    # destructive fs ops
    if echo "$cmd" | grep -qE '\b(rm|mv)\b[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*[^[:space:]]'; then
        is_mutating=1
    fi
    # file creation / mtime 변경 (Codex V8 P1). `touch`, `mkdir`, `ln` 파일/디렉토리/
    # symlink 생성. 이전엔 read-only 사용 가능성으로 제외했으나 실제 mutating이 맞고
    # 보호 브랜치에서 이들 사용하는 정당한 read-only 시나리오 없음.
    if echo "$cmd" | grep -qE '\b(touch|mkdir|ln)\b[[:space:]]+'; then
        is_mutating=1
    fi
    [ "$is_mutating" = "0" ] && exit 0
fi

# git 정보 수집
cd "${SAZO_CWD:-.}" 2>/dev/null || exit 0

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    # git repo 아님 → passthrough
    mark_skip_with_check "$SAZO_SESSION_ID" "worktree" "auto" "not a git repo"
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
