#!/bin/bash
# workflow-state-machine.sh — PreToolUse + PostToolUse hook.
#
# Usage: workflow-state-machine.sh {pre|post}
#
# Stage: init → worktree → research → plan → approval → implementation → ci → review → done
#
# 정책 (재설계 후):
# - Write/Edit gate (research/plan/approval): **soft warn** 3회까지, 4회부터 hard block.
#   approval은 항상 soft (architecturally unenforceable; UserPromptSubmit hook이 보조).
# - `gh pr create` gate (ci/review): **hard block**. 실제 PR 생성은 의도적으로 막을 가치.
# - SAZO_ALLOW_CI_SKIP=1 환경변수로 ci block 우회 가능 (메시지대로 실제 enforce).
#
# PostToolUse:
# - Task subagent 호출 → stage 자동 완료 마킹 (research/plan/review)
# - Task 호출 시 explore_count -1 decay (위임 보상)
# - Bash CI 명령 exit 0 시 ci_cmd_hash 기록 — 프로젝트 CI 커맨드 정확 매치 시만 ci 마킹
# - TodoWrite는 신호로 사용 안 함 (3개 dummy로 bypass되는 약한 신호)

set -uo pipefail

MODE="${1:-}"
[ -z "$MODE" ] && { echo "usage: $0 {pre|post}" >&2; exit 0; }

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/session-state.sh
source "$LIB_DIR/session-state.sh"

# Plan 06: narrow-only explore_count decay path.
# pre-exploration-gate (narrow, default ON) increments .explore_count on each
# direct Opus grep. Task delegation to code-searcher/docs-researcher 등은 그
# 보상(decay)을 받아야 narrow gate가 3회 block을 풀어준다. broad gate
# (workflow-state-machine 전체)가 비활성이어도 narrow 사용자에게 decay 보장.
#
# read_hook_payload는 stdin을 cat 으로 한 번만 읽으므로, broad block 전에
# 위치시켜 두 번 호출되지 않도록 한다.
read_hook_payload

if [ "$MODE" = "post" ] && narrow_hooks_enabled \
   && [ -n "${SAZO_SESSION_ID:-}" ] && [ "$SAZO_TOOL_NAME" = "Task" ]; then
    # Codex P2 (round 2): is_error/interrupted Task는 decay 안 함.
    # 실패한 위임은 "성공적 위임" 보상을 받으면 안 됨 — 3-grep block을
    # aborted Task로 우회 가능해짐. handle_post의 같은 가드와 일치.
    decay_subagent=$(echo "$SAZO_TOOL_INPUT" | jq -r '.subagent_type // ""' 2>/dev/null)
    decay_task_error=$(echo "$SAZO_TOOL_RESPONSE" | jq -r '.is_error // false' 2>/dev/null)
    decay_task_interrupted=$(echo "$SAZO_TOOL_RESPONSE" | jq -r '.interrupted // false' 2>/dev/null)
    if [ "$decay_task_error" != "true" ] && [ "$decay_task_interrupted" != "true" ]; then
        case "$decay_subagent" in
            code-searcher|docs-researcher|explore|Explore|\
            nori-codebase-locator|nori-codebase-analyzer|nori-codebase-pattern-finder|\
            nori-web-search-researcher|image-analyzer|multimodal-looker)
                state_init "$SAZO_SESSION_ID" "$SAZO_CWD" "$SAZO_MODEL"
                state_decrement "$SAZO_SESSION_ID" ".explore_count"
                ;;
        esac
    fi
fi

if ! workflow_hooks_enabled || [ "${SAZO_SKIP_STATE_MACHINE:-0}" = "1" ]; then
    exit 0
fi

[ -z "${SAZO_SESSION_ID:-}" ] && exit 0

state_init "$SAZO_SESSION_ID" "$SAZO_CWD" "$SAZO_MODEL"

# ----- shared regex: git invocation chain before subcommand -----
#
# Codex PR #30 round 10 P2: prior precision regex `[^-[:space:]][^[:space:]]*`
# only matched whitespace-free option values, so `git -c user.name='Bot User'
# commit` (quoted value with internal spaces) split into multiple whitespace
# tokens and the chain never reached `commit`/`add`/`rm`/`mv`. Real shells
# accept quoted values (`git -h` documents `-c <name>=<value>`), so the
# trigger silently missed them and a same-line `gh pr create` saw stale
# `ci_passed_at`. ERE cannot model balanced quoting cleanly, so instead of
# precision-modeling each option/value pair we accept any sequence of tokens
# between `git` and the target subcommand. Chain segmentation (`tr ';|&'
# '\n'`) at the call sites already constrains matches to a single git
# invocation, and over-matching here is fail-safe (extra invalidate vs.
# silent bypass). Use `[[:space:]].*` rather than `.*` to ensure at least one
# token (i.e. at least one option) sits between `git` and the subcommand —
# `git commit` already matches via the leading `[[:space:]]+(.*[[:space:]]+)?`
# zero-token alternation in the build below.
GIT_OPTS_RE="(.*[[:space:]]+)?"

# Codex PR #30 round 16 P2 (#3215134953): quote-aware `-C <path>` extractor.
# Prior `sed -E 's/.*-C[[:space:]]+([^[:space:]]+).*/\1/p'` captured only
# the first whitespace-delimited fragment of a quoted target (`'/tmp/my`
# from `git -C '/tmp/my repo' commit`), so `git -C` failed and the staged
# code in `/tmp/my repo` escaped detection. Use the same awk tokenizer
# that pathspec parsers use so quoted/escaped runs survive intact.
_extract_dash_C_path() {
    printf '%s' "$1" | awk '
        function tokenize(s,   i, n, c, q, esc, buf, tcount) {
            n = length(s)
            q = ""; esc = 0; buf = ""; tcount = 0
            for (i = 1; i <= n; i++) {
                c = substr(s, i, 1)
                if (esc) { buf = buf c; esc = 0; continue }
                if (c == "\\") { esc = 1; continue }
                if (q != "") {
                    if (c == q) { q = "" } else { buf = buf c }
                    continue
                }
                if (c == "\047" || c == "\"") { q = c; continue }
                if (c == " " || c == "\t") {
                    if (buf != "") { TOK[tcount++] = buf; buf = "" }
                    continue
                }
                buf = buf c
            }
            if (buf != "") TOK[tcount++] = buf
            return tcount
        }
        {
            n = tokenize($0)
            for (i = 0; i < n; i++) {
                if (TOK[i] == "-C" && i + 1 < n) { print TOK[i+1]; exit }
            }
        }'
}

# ----- soft warn helper -----
# stage별 카운터 분리 — research/plan/approval 동시 fail 시 한 Write 호출에서
# 카운터가 3번 증가해 즉시 block되는 버그 방지.

soft_warn_or_block() {
    local stage="$1" msg="$2" warn_threshold="${3:-3}"
    local path=".soft_warn_count_${stage}"
    state_increment "$SAZO_SESSION_ID" "$path"
    local count
    count=$(state_get "$SAZO_SESSION_ID" "$path")
    count=${count:-0}
    if [ "$count" -le "$warn_threshold" ]; then
        cat >&2 <<EOF
[workflow-warn $count/$warn_threshold] stage=$stage 미통과.
$msg
$((warn_threshold + 1))회부터 hard block. Override:
  - skip: /skip $stage <reason>
  - 전체 비활성: SAZO_SKIP_STATE_MACHINE=1
EOF
        return 0
    fi
    audit_log "stage_block" "${SAZO_SESSION_ID:-}" "$stage" "blocked" "hook" \
        "soft_warn_count=$count exceeded threshold $warn_threshold; tool=$SAZO_TOOL_NAME"
    cat >&2 <<EOF
[workflow-block] stage=$stage 미통과 $count회 — $SAZO_TOOL_NAME 차단.
$msg
Override:
  - skip: /skip $stage <reason>
  - 전체 비활성: SAZO_SKIP_STATE_MACHINE=1
EOF
    return 2
}

hard_block() {
    local stage="$1" msg="$2"
    audit_log "stage_block" "${SAZO_SESSION_ID:-}" "$stage" "blocked" "hook" \
        "tool=$SAZO_TOOL_NAME; ${msg%%$'\n'*}"
    cat >&2 <<EOF
[workflow-block] stage=$stage 미통과 → $SAZO_TOOL_NAME 차단.
$msg
EOF
    exit 2
}

# ----- consecutive skip warning -----

emit_skip_warning_if_needed() {
    local n
    n=$(consecutive_skip_count "$SAZO_SESSION_ID")
    if [ "${n:-0}" -ge 3 ]; then
        cat >&2 <<EOF
[workflow-warn] 연속 ${n} stage skip 감지. 워크플로우 전체 bypass 의도가 맞나? 사용자 추가 확인 권장.
EOF
    fi
}

# ----- PostToolUse: stage 자동 완료 -----

handle_post() {
    case "$SAZO_TOOL_NAME" in
        Task)
            # Task 성공 여부 확인 — failed task는 stage 마킹 안 함 (Codex V5 P1).
            # Claude Code PostToolUse payload의 tool_response에 is_error 또는
            # interrupted=true면 실패. 둘 다 없는 경우(이전 스키마) subagent_type만
            # 보고 진행.
            local task_error task_interrupted subagent_type
            task_error=$(echo "$SAZO_TOOL_RESPONSE" | jq -r '.is_error // false' 2>/dev/null)
            task_interrupted=$(echo "$SAZO_TOOL_RESPONSE" | jq -r '.interrupted // false' 2>/dev/null)
            subagent_type=$(echo "$SAZO_TOOL_INPUT" | jq -r '.subagent_type // ""')

            if [ "$task_error" = "true" ] || [ "$task_interrupted" = "true" ]; then
                # For verdict-tracked agents, record error toward 3-strike escalation.
                case "$subagent_type" in
                    code-reviewer|architect-advisor|plan-critic|plan-auditor)
                        _record_reviewer_error "$SAZO_SESSION_ID" "$SAZO_CWD" "$subagent_type"
                        ;;
                esac
                echo "[workflow] Task failed/interrupted — stage not marked" >&2
                exit 0
            fi

            case "$subagent_type" in
                code-searcher|docs-researcher|explore|Explore|\
                nori-codebase-locator|nori-codebase-analyzer|nori-codebase-pattern-finder|\
                nori-web-search-researcher|image-analyzer|multimodal-looker)
                    stage_is_passed "$SAZO_SESSION_ID" "research" \
                        || stage_mark "$SAZO_SESSION_ID" "research" "completed" "auto" "subagent=$subagent_type"
                    # 위임 보상(explore_count decay)은 narrow path에서 이미 처리됨 (파일 상단 참조).
                    ;;
                plan-drafter|Plan)
                    # plan-drafter not verdict-tracked (produces plan content, not verdict).
                    # Phase 1 (warn): legacy mark on drafter alone.
                    # Phase 2 (block): plan-critic + plan-auditor verdict required — drafter alone insufficient.
                    if [ "${SAZO_VERDICT_FOOTER_ENFORCE:-warn}" != "block" ]; then
                        stage_is_passed "$SAZO_SESSION_ID" "plan" \
                            || stage_mark "$SAZO_SESSION_ID" "plan" "completed" "auto" "subagent=$subagent_type"
                    fi
                    ;;
                plan-auditor|plan-critic)
                    # Verdict-tracked. parse footer + validate nonce + record + evaluate.
                    local result_text
                    result_text=$(echo "$SAZO_TOOL_RESPONSE" | jq -r '.result // ""' 2>/dev/null)
                    process_verdict_tracked_post_task "$SAZO_SESSION_ID" "$SAZO_CWD" "plan" "$subagent_type" "$result_text"
                    ;;
                code-reviewer|architect-advisor)
                    # Verdict-tracked.
                    local result_text
                    result_text=$(echo "$SAZO_TOOL_RESPONSE" | jq -r '.result // ""' 2>/dev/null)
                    process_verdict_tracked_post_task "$SAZO_SESSION_ID" "$SAZO_CWD" "review" "$subagent_type" "$result_text"
                    ;;
                nori-code-reviewer)
                    # Not verdict-tracked (separate domain). Legacy mark.
                    stage_is_passed "$SAZO_SESSION_ID" "review" \
                        || stage_mark "$SAZO_SESSION_ID" "review" "completed" "auto" "subagent=$subagent_type"
                    ;;
            esac
            ;;
        Edit|Write|NotebookEdit)
            # Plan 04: CI 통과 후 코드 파일 변경되면 ci_passed_at invalidate.
            # 호출자가 file_path 인자를 jq에서 추출. notebook_path 도 cover.
            local edit_file_path
            edit_file_path=$(echo "$SAZO_TOOL_INPUT" | jq -r '.file_path // .notebook_path // ""' 2>/dev/null)
            # Codex PR #30 round 2 P2: _is_doc_only_path 가 absolute path를 repo
            # root 기준 relative로 변환하기 위해 SAZO_REPO_ROOT export.
            local _edit_repo_root
            _edit_repo_root=$(git -C "$SAZO_CWD" rev-parse --show-toplevel 2>/dev/null)
            SAZO_REPO_ROOT="${_edit_repo_root:-$SAZO_CWD}" \
                ci_invalidate_if_code_changed "$SAZO_SESSION_ID" "$SAZO_CWD" "$edit_file_path" "edit"
            ;;
        Bash)
            # CI detection: 프로젝트 CLAUDE.md의 CI 커맨드와 정확 매치 시만 ci 마킹.
            # 단순 부분 명령(`yarn lint` 단독)은 무시.
            local cmd exit_code
            cmd=$(echo "$SAZO_TOOL_INPUT" | jq -r '.command // ""')
            exit_code=$(echo "$SAZO_TOOL_RESPONSE" | jq -r '.exit_code // .success // -1' 2>/dev/null)
            # success bool 처리: true → 0, false → 1
            case "$exit_code" in
                true) exit_code=0 ;;
                false) exit_code=1 ;;
            esac
            if [ "$exit_code" = "0" ] && _is_full_ci_command "$cmd"; then
                if ! stage_is_passed "$SAZO_SESSION_ID" "ci"; then
                    # ci_passed_at 실패하면 stage_mark 호출 안 함 (rc=99 lock timeout
                    # 등으로 inconsistent state 방지).
                    if state_set_str "$SAZO_SESSION_ID" ".ci_passed_at" "$(date +%Y-%m-%dT%H:%M:%S%z)"; then
                        stage_mark "$SAZO_SESSION_ID" "ci" "completed" "auto" "ci-cmd matched"
                    else
                        echo "[workflow] ci_passed_at write failed (lock timeout?); ci not marked" >&2
                    fi
                fi
            fi
            # Codex PR #30 round 4 P2: post-commit invalidate.
            # PreToolUse defense missed cases where the same Bash command staged
            # files inline (`echo > foo.go && git add foo.go && git commit`,
            # `git commit -am ...`). After-the-fact: inspect HEAD's last commit
            # for code files and invalidate if any.
            if [ "$exit_code" = "0" ] \
                && [ "${SAZO_DISABLE_CI_INVALIDATE:-0}" != "1" ] \
                && echo "$cmd" | grep -qE "(^|[[:space:]&|;()])git[[:space:]]+${GIT_OPTS_RE}commit\b"; then
                local cur_cp_post
                cur_cp_post=$(state_get "$SAZO_SESSION_ID" ".ci_passed_at" "$SAZO_CWD")
                # Self-review A1: clear the pre-invalidate flag if pre fired in
                # this same Bash invocation. The flag exists for future hooks
                # that may want to dedup audit entries; the existing post-hook
                # already short-circuits via `cur_cp_post != null` so no extra
                # gate is needed today (audit emits only when pre saw a passed
                # state). Clearing prevents leak across separate `git commit`
                # invocations within the same session.
                local _pre_invalidated_pending
                _pre_invalidated_pending=$(state_get "$SAZO_SESSION_ID" \
                    ".pre_commit_invalidate_pending" "$SAZO_CWD" 2>/dev/null)
                if [ "$_pre_invalidated_pending" = "1" ]; then
                    state_set_json "$SAZO_SESSION_ID" \
                        ".pre_commit_invalidate_pending" "null" "$SAZO_CWD" 2>/dev/null || true
                fi
                # Codex PR #30 round 14 P2 (#3215109919): marker cleanup must
                # run regardless of `ci_passed_at` state. If pre-hook already
                # invalidated (cur_cp_post=null) and we skip cleanup, the
                # marker survives across CI re-runs — a later docs-only commit
                # then re-uses the stale marker, diff-trees the OLD code commit,
                # and re-invalidates the freshly-passed ci_passed_at.
                local _do_marker_cleanup=1
                if [ -n "$cur_cp_post" ] && [ "$cur_cp_post" != "null" ]; then
                    # Codex PR #30 round 11 P2: iterate **every** `git commit`
                    # segment in the Bash chain. Prior `head -1` made the
                    # defense inspect only the first commit invocation; if that
                    # one targeted an unrelated repo (`git -C /tmp/other commit
                    # -m docs`) or was docs-only, a later in-repo code commit
                    # (`&& git commit -m code && gh pr create`) bypassed the
                    # invalidation entirely.
                    local invalidated_post=0
                    # Codex PR #30 round 12 P2: look up marker from per-repo dict
                    # first, fall back to legacy single marker. Multi-repo chains
                    # need the dict so repo A's commit detection survives a later
                    # repo B commit overwriting the legacy single marker.
                    local markers_dict
                    markers_dict=$(state_get "$SAZO_SESSION_ID" ".pre_commit_markers" "$SAZO_CWD" 2>/dev/null)
                    local legacy_marker_json legacy_marker_head legacy_marker_repo
                    legacy_marker_json=$(state_get "$SAZO_SESSION_ID" ".pre_commit_marker" "$SAZO_CWD" 2>/dev/null)
                    if [ -n "$legacy_marker_json" ] && [ "$legacy_marker_json" != "null" ]; then
                        legacy_marker_head=$(echo "$legacy_marker_json" | jq -r '.head // ""' 2>/dev/null)
                        legacy_marker_repo=$(echo "$legacy_marker_json" | jq -r '.repo_root // ""' 2>/dev/null)
                    fi

                    # Iterate every commit segment. tr-newline split keeps each
                    # `git ... commit ...` invocation on its own line so we can
                    # extract its own `-C` and inspect its own target repo.
                    local commit_segment_post
                    while IFS= read -r commit_segment_post; do
                        [ -z "$commit_segment_post" ] && continue
                        local git_target_post="$SAZO_CWD" c_path_post
                        c_path_post=$(_extract_dash_C_path "$commit_segment_post")
                        if [ -n "$c_path_post" ]; then
                            case "$c_path_post" in
                                /*) git_target_post="$c_path_post" ;;
                                *) git_target_post="$SAZO_CWD/$c_path_post" ;;
                            esac
                        fi
                        local repo_root_post
                        repo_root_post=$(git -C "$git_target_post" rev-parse --show-toplevel 2>/dev/null)
                        [ -z "$repo_root_post" ] && continue

                        # Codex PR #30 round 9 P2: scan every new commit created
                        # by this Bash invocation, not just HEAD. Pre-hook stored
                        # repo HEAD before the cmd ran; range `<marker>..HEAD`
                        # covers all commits even when the last is docs-only.
                        # Marker is per-session-state and recorded once per pre,
                        # so it's only authoritative for its own repo. For other
                        # repos in the chain (e.g. `git -C /tmp/other commit`),
                        # fall back to HEAD-only — that's the legacy behavior and
                        # is sufficient for the common single-commit-per-repo case.
                        local commit_range="" segment_marker_head=""
                        # 1) Try per-repo dict (preferred — survives multi-repo
                        # chains where legacy single marker gets overwritten).
                        if [ -n "$markers_dict" ] && [ "$markers_dict" != "null" ]; then
                            segment_marker_head=$(echo "$markers_dict" \
                                | jq -r --arg k "$repo_root_post" '.[$k] // ""' 2>/dev/null)
                        fi
                        # 2) Legacy single-marker fallback for single-repo chains.
                        if [ -z "$segment_marker_head" ] \
                            && [ -n "${legacy_marker_head:-}" ] \
                            && [ "${legacy_marker_repo:-}" = "$repo_root_post" ]; then
                            segment_marker_head="$legacy_marker_head"
                        fi
                        if [ -n "$segment_marker_head" ] \
                            && git -C "$repo_root_post" cat-file -e "$segment_marker_head" 2>/dev/null; then
                            commit_range="${segment_marker_head}..HEAD"
                        fi
                        local diff_args
                        if [ -n "$commit_range" ]; then
                            diff_args=("diff-tree" "--no-commit-id" "--name-only" "-r" "$commit_range")
                        else
                            diff_args=("diff-tree" "--no-commit-id" "--name-only" "-r" "--root" "HEAD")
                        fi
                        local has_code_committed=0
                        while IFS= read -r p; do
                            [ -z "$p" ] && continue
                            if _is_doc_only_path "$p"; then continue; fi
                            if _is_code_file "$p"; then has_code_committed=1; break; fi
                        done < <(git -C "$repo_root_post" "${diff_args[@]}" 2>/dev/null)
                        if [ "$has_code_committed" = "1" ]; then
                            ci_invalidate_unconditional "$SAZO_SESSION_ID" "$SAZO_CWD" "git_commit_post"
                            invalidated_post=1
                            break
                        fi
                    done < <(printf '%s\n' "$cmd" | tr ';|&' '\n' \
                        | grep -E "(^|[[:space:]])git[[:space:]]+${GIT_OPTS_RE}commit\b")

                    : "$invalidated_post"  # reserved for future audit
                fi  # cur_cp_post != null
                # Codex PR #30 round 14 P2: cleanup outside the cur_cp guard
                # so stale markers don't survive across CI re-runs after pre
                # already invalidated. `_do_marker_cleanup` is always 1 in this
                # branch — the var name is for readability/future skip-conditions.
                if [ "$_do_marker_cleanup" = "1" ]; then
                    state_set_json "$SAZO_SESSION_ID" ".pre_commit_marker" "null" "$SAZO_CWD" 2>/dev/null || true
                    state_set_json "$SAZO_SESSION_ID" ".pre_commit_markers" "null" "$SAZO_CWD" 2>/dev/null || true
                fi
            fi
            ;;
    esac
    exit 0
}

# 프로젝트 CI 커맨드 정확 매치 검사. CLAUDE.md/AGENTS.md의 백틱 fenced 모든
# 커맨드를 후보로 수집해 정확 매치 여부 판정.
_is_full_ci_command() {
    local cmd="$1"
    local proj_md=""

    # 1) SAZO_CWD부터 **repo root까지만** upward walk. filesystem `/`까지 올라가면
    # $HOME/.claude/CLAUDE.md 같은 global metadata의 CI snippet이 매치돼 다른
    # repo에서 실행한 명령이 현재 repo ci stage 통과시키는 bypass 발생 (Codex V7 P1).
    # git rev-parse는 realpath 반환하므로 SAZO_CWD도 normalize 필요 (macOS /tmp =
    # /private/tmp symlink 등 불일치 회피).
    local cwd_real repo_root
    cwd_real=$(cd "$SAZO_CWD" 2>/dev/null && pwd -P)
    cwd_real="${cwd_real:-$SAZO_CWD}"
    repo_root=$(git -C "$cwd_real" rev-parse --show-toplevel 2>/dev/null)
    local proj_mds=""
    local dir="$cwd_real"
    while [ -n "$dir" ]; do
        for candidate in "$dir/CLAUDE.md" "$dir/AGENTS.md" "$dir/.claude/CLAUDE.md"; do
            if [ -f "$candidate" ]; then
                if [ -z "$proj_mds" ]; then
                    proj_mds="$candidate"
                else
                    proj_mds="$proj_mds
$candidate"
                fi
            fi
        done
        # repo boundary 도달 시 중단. repo_root 미감지(non-git)면 $SAZO_CWD 에서만
        # 조회 후 중단 — ancestor 디렉토리 traverse 금지.
        if [ -n "$repo_root" ] && [ "$dir" = "$repo_root" ]; then
            break
        fi
        if [ -z "$repo_root" ]; then
            break
        fi
        local parent
        parent=$(dirname "$dir")
        [ "$parent" = "$dir" ] && break
        dir="$parent"
    done
    [ -z "$proj_mds" ] && return 1

    # 2) 수집된 모든 proj_md에서 백틱 fenced 중 CI-verb 포함 or chained command 추출.
    # 모든 백틱 토큰 허용 시 CLAUDE.md 본문의 `date`, `echo`, 파일 경로 등이
    # candidate가 되어 ci bypass 가능 (Codex round2 P1).
    local ci_cmds=""
    # newline-iteration으로 경로 공백 안전. `$proj_mds`를 그대로 iterate하면
    # shell word-split이 공백 포함 path를 쪼갬 (Codex V5 P2 fix).
    while IFS= read -r md; do
        [ -z "$md" ] && continue
        local md_cmds
        # awk ERE는 `\b` 미지원 — POSIX-safe (^|[^a-zA-Z0-9_]) 경계 사용 (Codex V7 P2).
        # 이전 \b 패턴은 awk에서 literal b로 해석돼 매치 실패 → `npm ci`/`pnpm install`
        # 같은 정상 CI command가 candidate에서 누락됐음.
        md_cmds=$(grep -oE '`[^`]+`' "$md" 2>/dev/null | sed 's/^`//;s/`$//' | awk '
            /&&/ { print; next }
            /(^|[^a-zA-Z0-9_])(test|build|lint|type-check|typecheck|check|validate|verify|tsc|pytest)([^a-zA-Z0-9_]|$)/ { print; next }
            /(^|[^a-zA-Z0-9_])(go|cargo)[[:space:]]+(test|build|vet|check)([^a-zA-Z0-9_]|$)/ { print; next }
            /(^|[^a-zA-Z0-9_])(yarn|npm|pnpm|npx)[[:space:]]+/ { print; next }
            /(^|[^a-zA-Z0-9_])make[[:space:]]+/ { print; next }
            /(^|[^a-zA-Z0-9_])bash[[:space:]]+-n([^a-zA-Z0-9_]|$)/ { print; next }
        ')
        [ -n "$md_cmds" ] && ci_cmds="$ci_cmds
$md_cmds"
    done <<< "$proj_mds"
    ci_cmds=$(printf '%s' "$ci_cmds" | sed '/^$/d')
    [ -z "$ci_cmds" ] && return 1

    # Package scope 필터: SAZO_CWD가 `packages/X/` 내부면 X와 관련된 CI 커맨드만
    # 후보로. 다른 package의 CI가 현재 package의 ci stage 통과시키는 bypass 차단
    # (Codex V8 P1: 모노레포 root CLAUDE.md에 package별 CI 여러 개 나열된 케이스).
    local pkg_name=""
    case "$cwd_real" in
        */packages/*)
            pkg_name=$(printf '%s' "$cwd_real" | sed -E 's|.*/packages/([^/]+).*|\1|')
            ;;
    esac
    if [ -n "$pkg_name" ]; then
        # 다른 package 경로 (packages/<other>) 포함 cmd 제외. 현재 pkg 경로 포함하거나
        # 어떤 packages/ 경로도 참조하지 않는 cmd는 유지.
        local filtered=""
        while IFS= read -r ci_cmd; do
            [ -z "$ci_cmd" ] && continue
            # cmd가 packages/<X>를 참조하는데 현재 pkg이 아니면 제외
            if echo "$ci_cmd" | grep -qE "packages/[^/[:space:]]+"; then
                if ! echo "$ci_cmd" | grep -qE "packages/${pkg_name}([/[:space:]&|;]|$)"; then
                    continue
                fi
            fi
            filtered="$filtered
$ci_cmd"
        done <<< "$ci_cmds"
        ci_cmds=$(printf '%s' "$filtered" | sed '/^$/d')
        [ -z "$ci_cmds" ] && return 1
    fi

    # 정확 매치 우선. 더불어 `{placeholder}` 템플릿 지원 — 예:
    # `cd packages/{name} && go build ./...` → 실제 호출 `cd packages/translate-bot && go build ./...`
    # 매치 (Codex V3 P2). 단 `{`/`}` 없는 명령은 literal 비교만 유지 (prefix
    # injection 차단 V2 M3 유지).
    while IFS= read -r ci_cmd; do
        [ -z "$ci_cmd" ] && continue
        if [ "$cmd" = "$ci_cmd" ]; then
            return 0
        fi
        # 템플릿 포함 시 regex 매치. 각 `{name}` → `[^/[:space:]&|;]+` (단일 토큰).
        # 순서: placeholder를 임시 마커로 치환 → 다른 regex 메타문자 escape →
        # 마커를 token class로 복구. placeholder를 먼저 escape하면 `\{` `\}`가 되어
        # 복구 매치가 실패함.
        if echo "$ci_cmd" | grep -q '{[^}]*}'; then
            regex=$(printf '%s' "$ci_cmd" | awk '{
                gsub(/\{[^}]*\}/, "\001MARK\001")
                gsub(/[\\.^$*+?()\[\]|]/, "\\\\&")
                gsub(/\001MARK\001/, "[^/[:space:]\\&|;]+")
                print
            }')
            if echo "$cmd" | grep -qE "^${regex}$"; then
                return 0
            fi
        fi
    done <<< "$ci_cmds"
    return 1
}

# ----- PreToolUse: stage gate -----

handle_pre() {
    local rc
    case "$SAZO_TOOL_NAME" in
        Write|Edit|NotebookEdit)
            # Gate는 **첫 번째 unmet stage만 평가**. research/plan 동시 counter 증가
            # 방지 — research 3회 warn 후 research 완료하면 plan도 이미 소진돼 즉시
            # block되는 staged-recovery 깨짐 (Codex V9 P1).
            if ! stage_is_passed "$SAZO_SESSION_ID" "research"; then
                soft_warn_or_block "research" "리서치 subagent 위임 권장.
  Task(subagent_type=\"code-searcher\", ...) 또는 Task(subagent_type=\"docs-researcher\", ...)
파일/라인 직접 지정됐으면: /skip research <reason>"
                rc=$?
                [ "$rc" = "2" ] && exit 2
                exit 0
            fi

            # plan — soft warn (3회 후 block). research 통과 후에만 평가.
            if ! stage_is_passed "$SAZO_SESSION_ID" "plan"; then
                soft_warn_or_block "plan" "플랜 제시 권장.
  Task(subagent_type=\"plan-drafter\", ...) 또는 plan 메시지 + 사용자 승인
≤5줄 단일파일 typo 수정: /skip plan <reason>"
                rc=$?
                [ "$rc" = "2" ] && exit 2
                exit 0
            fi

            # approval — 항상 soft warn (architecturally unenforceable)
            if ! stage_is_passed "$SAZO_SESSION_ID" "approval"; then
                cat >&2 <<EOF
[workflow-warn] approval marker 없음. 사용자가 직접 /approved 입력해야 정식 통과 (Claude 자동 호출은 차단됨).
플랜 제시 후 사용자에게 승인 요청 권장.
EOF
            fi
            ;;
        Task)
            # Plan 04 §6 (B): subagent fallback for GH #34692. Subagent 내부의
            # Edit/Write/Bash 호출은 parent hook 미발동 — Task PreToolUse 시점에
            # mutating 가능 agent 검출 시 ci_passed_at preemptive invalidate.
            #
            # 대상: Write/Edit tools를 보유하고 코드 파일을 수정할 가능성이 있는
            # subagent 전체. doc-writer도 inline code comment 추가 권한이 있어
            # .go/.ts 등에 직접 Edit 가능 (`agents/doc-writer.md` §3 Code Comments).
            local subagent_pre
            subagent_pre=$(echo "$SAZO_TOOL_INPUT" | jq -r '.subagent_type // ""' 2>/dev/null)
            case "$subagent_pre" in
                doc-writer)
                    # Self-review A4: escape hatch for doc-writer Tasks that
                    # only touch markdown. Default behavior remains conservative
                    # invalidate (doc-writer has Edit on .go/.ts via inline
                    # comment policy). Set SAZO_DOC_WRITER_NO_INVALIDATE=1 in
                    # the session env when doc-writer is doing pure prose work
                    # to keep ci_passed_at intact.
                    if [ "${SAZO_DOC_WRITER_NO_INVALIDATE:-0}" != "1" ]; then
                        ci_invalidate_unconditional "$SAZO_SESSION_ID" "$SAZO_CWD" "task_preemptive:$subagent_pre"
                    fi
                    ;;
                plan-executor|ui-engineer)
                    ci_invalidate_unconditional "$SAZO_SESSION_ID" "$SAZO_CWD" "task_preemptive:$subagent_pre"
                    ;;
            esac
            ;;
        Bash)
            local cmd
            cmd=$(echo "$SAZO_TOOL_INPUT" | jq -r '.command // ""')
            # Plan 04 §3: git commit defense layer. staged 코드 파일 + ci_passed_at!=null
            # → invalidate. commit 자체는 차단 안 함 (PR create 시점에 ci 미통과로 잡힘).
            # 매칭: `git commit`, 그리고 `git -C <path> commit`, `git -c k=v commit`,
            # `git --git-dir=... commit` 등 global options(-* / --*)가 subcommand 앞에
            # 끼는 케이스 (Codex PR #30 P2 — 누락 시 해당 commit이 invalidate path를 우회).
            if echo "$cmd" | grep -qE "(^|[[:space:]&|;()])git[[:space:]]+${GIT_OPTS_RE}commit\b"; then
                if [ "${SAZO_DISABLE_CI_INVALIDATE:-0}" != "1" ]; then
                    local cur_cp
                    cur_cp=$(state_get "$SAZO_SESSION_ID" ".ci_passed_at" "$SAZO_CWD")
                    if [ -n "$cur_cp" ] && [ "$cur_cp" != "null" ]; then
                        # Codex PR #30 round 11 P2: iterate **every** `git commit`
                        # segment in the Bash chain. Prior `head -1` only inspected
                        # the first commit invocation, so a chain like
                        #   git -C /tmp/other commit -m docs && git commit -m code && gh pr create
                        # let the second (in-repo, code-bearing) commit slip past
                        # both the staged check and the pathspec check.
                        #
                        # Each iteration resolves its own `-C <path>` and inspects
                        # that segment's repo. Chain-wide analysis (rm/add tokens,
                        # redirect/tee targets) is shared because those primitives
                        # are not commit-segment-bound; they're run against the
                        # SAZO_CWD repo on the first iteration that finds a valid
                        # repo_root and short-circuit on first match.
                        local has_code_staged=0
                        local marker_repo_root="" marker_pre_head=""
                        local commit_segment
                        while IFS= read -r commit_segment; do
                            [ -z "$commit_segment" ] && continue
                            local git_target="$SAZO_CWD" c_path
                            c_path=$(_extract_dash_C_path "$commit_segment")
                            if [ -n "$c_path" ]; then
                                case "$c_path" in
                                    /*) git_target="$c_path" ;;
                                    *) git_target="$SAZO_CWD/$c_path" ;;
                                esac
                            fi
                            local repo_root
                            repo_root=$(git -C "$git_target" rev-parse --show-toplevel 2>/dev/null)
                            if [ -n "$repo_root" ]; then
                            # Codex PR #30 round 9 P2: pre-commit HEAD marker.
                            # 한 Bash invocation 내 multi-commit (`commit code &&
                            # commit docs`) 의 마지막이 docs-only 면 PostToolUse
                            # fallback 이 HEAD 만 검사해 중간 code commit 을 누락 →
                            # ci_passed_at 유지된 채 PR create 통과. 사전 발동 시점에
                            # HEAD oid 를 marker 로 저장해 두면 post-hook 이
                            # `<marker>..HEAD` 범위로 모든 새 commit 검사 가능.
                            local pre_commit_head
                            pre_commit_head=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo "")
                            # Codex PR #30 round 12 P2 (#3215083285): marker
                            # must be per-target-repo. A single `.pre_commit_marker`
                            # got overwritten by the last segment in a chain like
                            # `commit-in-A && commit-in-A && commit-in-B`, so
                            # post-hook lookup for repo A fell back to HEAD-only
                            # and missed the earlier in-A code commit.
                            # Store as a dict: `.pre_commit_markers[repo_root] = head`.
                            # Only the FIRST segment in each repo writes (preserves
                            # baseline before the cmd ran). Subsequent segments in
                            # the same repo are redundant since `marker..HEAD`
                            # range still covers all new commits.
                            if [ -n "$pre_commit_head" ]; then
                                # Codex PR #30 round 13 P2 (#3215096087): when
                                # `.pre_commit_markers` is absent on a fresh
                                # state, `state_get` emits no stdin to jq, and
                                # the piped `// {} | .[k]=v` produces empty
                                # output → state_set_json silently fails and
                                # the dict stays null forever. Bootstrap with
                                # `{}` literal when reader returns empty/null.
                                #
                                # Self-review N3/N6: previously interpolated
                                # `.pre_commit_markers[\"$repo_root\"]` into
                                # the jq path string — repo_root containing
                                # `"` or `\` produced a malformed jq filter
                                # and silently dropped that entry. Refactored:
                                # read full dict, use `--arg k` for lookup +
                                # set, never embed repo_root in jq source.
                                local _markers_current
                                _markers_current=$(state_get "$SAZO_SESSION_ID" \
                                    ".pre_commit_markers" "$SAZO_CWD" 2>/dev/null)
                                if [ -z "$_markers_current" ] || [ "$_markers_current" = "null" ]; then
                                    _markers_current="{}"
                                fi
                                local _marker_existing
                                _marker_existing=$(printf '%s' "$_markers_current" \
                                    | jq -r --arg k "$repo_root" '.[$k] // ""' 2>/dev/null)
                                if [ -z "$_marker_existing" ]; then
                                    local _markers_next
                                    _markers_next=$(printf '%s' "$_markers_current" \
                                        | jq -c --arg k "$repo_root" --arg v "$pre_commit_head" \
                                            '. + {($k): $v}')
                                    if [ -n "$_markers_next" ]; then
                                        state_set_json "$SAZO_SESSION_ID" \
                                            ".pre_commit_markers" \
                                            "$_markers_next" \
                                            "$SAZO_CWD" 2>/dev/null || true
                                    fi
                                fi
                                # Legacy single-marker write for back-compat with
                                # post-hook fallback (kept for transition; post-hook
                                # prefers dict but reads legacy if dict empty).
                                # Self-review N3/N6: build JSON via jq --arg
                                # so `"`/`\` in head or repo_root cannot
                                # break the literal.
                                local _legacy_marker
                                _legacy_marker=$(jq -nc \
                                    --arg head "$pre_commit_head" \
                                    --arg repo "$repo_root" \
                                    '{head: $head, repo_root: $repo}')
                                if [ -n "$_legacy_marker" ]; then
                                    state_set_json "$SAZO_SESSION_ID" \
                                        ".pre_commit_marker" \
                                        "$_legacy_marker" \
                                        "$SAZO_CWD" 2>/dev/null || true
                                fi
                            fi
                            # `--name-status -M`: 각 라인 = `<status>\t<path>` 또는
                            # rename/copy의 경우 `R<score>\t<old>\t<new>` (`C<score>` 동일).
                            # `--name-only`만 쓰면 destination만 보여 `git mv src/foo.go
                            # docs/foo.md` 같은 code→doc rename에서 source(.go) 삭제가
                            # _is_doc_only_path에 걸려 invalidate가 누락됨 (Codex PR #30 P2).
                            # 따라서 R/C 라인은 old + new 모두 검사한다.
                            while IFS= read -r line; do
                                [ -z "$line" ] && continue
                                local status path1 path2
                                status=$(printf '%s' "$line" | cut -f1)
                                path1=$(printf '%s' "$line" | cut -f2)
                                path2=$(printf '%s' "$line" | cut -f3)
                                local check_paths=()
                                case "$status" in
                                    R*|C*)
                                        [ -n "$path1" ] && check_paths+=("$path1")
                                        [ -n "$path2" ] && check_paths+=("$path2")
                                        ;;
                                    *)
                                        [ -n "$path1" ] && check_paths+=("$path1")
                                        ;;
                                esac
                                local p
                                for p in "${check_paths[@]}"; do
                                    if _is_doc_only_path "$p"; then continue; fi
                                    if _is_code_file "$p"; then has_code_staged=1; break 2; fi
                                done
                            done < <(git -C "$repo_root" diff --cached --name-status -M --diff-filter=ACMRD 2>/dev/null)
                            # diff-filter ACMRD: Added/Copied/Modified/Renamed/**Deleted**.
                            # 코드 파일 삭제도 CI 결과를 무효화할 수 있음 (build break,
                            # missing import 등). D 빠지면 `git rm foo.go && git commit`
                            # 후 ci_passed_at 그대로 남아 PR create가 통과 (Codex PR #30 P2).

                            # Codex PR #30 round 3 P2 — Pre-hook은 Bash 명령 실행 *전*에
                            # 발동되므로 다음 두 케이스는 staged set이 비어있어 우회됨:
                            #   (a) 같은 cmd chain 내 staging — `echo ... >> foo.go &&
                            #       git add foo.go && git commit -m x`. cmd 자체에서
                            #       추가될 코드 파일을 토큰 분석으로 추출.
                            #   (b) `git commit -a` / `-am` / `--all` — tracked 파일의
                            #       unstaged 변경을 commit이 자동 stage. `git diff`
                            #       (working tree, w/o --cached)로 검사.
                            if [ "$has_code_staged" != "1" ]; then
                                # (a-rm) chained `git rm <path>` — 코드 파일 삭제도
                                # build break/missing import 가능 → invalidate.
                                # Codex PR #30 round 5 P2.
                                local rm_args_block rm_tokens
                                rm_args_block=$(printf '%s\n' "$cmd" | tr ';|&' '\n' \
                                    | grep -E "(^|[[:space:]])git[[:space:]]+${GIT_OPTS_RE}rm\b" \
                                    | sed -E 's/.*\brm\b[[:space:]]+//')
                                rm_tokens=$(printf '%s\n' "$rm_args_block" \
                                    | tr ' ' '\n' \
                                    | grep -v '^$')
                                local rt2
                                while IFS= read -r rt2; do
                                    [ -z "$rt2" ] && continue
                                    case "$rt2" in
                                        -*) : ;;  # 옵션 (-r/-f/--cached 등) skip
                                        *)
                                            if _is_doc_only_path "$rt2"; then continue; fi
                                            if _is_code_file "$rt2"; then
                                                has_code_staged=1
                                                break
                                            fi
                                            # 디렉토리 rm: 보수적 — repo 디렉토리이면 invalidate.
                                            if [ -d "$repo_root/$rt2" ]; then
                                                has_code_staged=1
                                                break
                                            fi
                                            ;;
                                    esac
                                done <<EOF_RM
$rm_tokens
EOF_RM
                            fi
                            if [ "$has_code_staged" != "1" ]; then
                                # (a) chained `git add <path>` 인자 추출.
                                # cmd 안 모든 'git add <args> ;|&|&&|||' 까지 캡처. 단순화:
                                # `git add` 토큰 뒤 단어들을 옵션 제외하고 path로 취급.
                                local add_args_block
                                add_args_block=$(printf '%s\n' "$cmd" | tr ';|&' '\n' \
                                    | grep -E "(^|[[:space:]])git[[:space:]]+${GIT_OPTS_RE}add\b" \
                                    | sed -E 's/.*\badd\b[[:space:]]+//')
                                local add_tokens
                                add_tokens=$(printf '%s\n' "$add_args_block" \
                                    | tr ' ' '\n' \
                                    | grep -v '^$')
                                # Codex PR #30 round 4 P2: ambiguous pathspec (`.`/`-A`/
                                # `--all`/`-u`/디렉토리/glob) 은 단일 path로 매핑되지
                                # 않아 _is_code_file 만으로는 우회됨. ambiguous 검출 시
                                # 동일 chain 의 `>`/`>>`/`tee` redirect target 또는
                                # working-tree untracked file 중 코드 파일이 있으면
                                # invalidate (보수적이지만 stale CI 차단 우선).
                                local ambiguous_add=0
                                local at
                                while IFS= read -r at; do
                                    [ -z "$at" ] && continue
                                    case "$at" in
                                        # path-modifying flags
                                        -A|--all|-u|--update|.) ambiguous_add=1 ;;
                                        # trailing slash → directory
                                        */) ambiguous_add=1 ;;
                                        # glob meta → shell expand → uncertain
                                        *\**|*\?*|*\[*) ambiguous_add=1 ;;
                                        -*) : ;;  # 다른 -옵션은 path 아님
                                        *)
                                            # explicit path 케이스: doc/code 분류 가능.
                                            if _is_doc_only_path "$at"; then continue; fi
                                            if _is_code_file "$at"; then
                                                has_code_staged=1
                                                break
                                            fi
                                            # explicit path 인데 _is_code_file 도 false면
                                            # 디렉토리일 수 있음 (확장자 없음). 보수적
                                            # 처리 — repo 안 디렉토리로 존재하면 ambiguous.
                                            if [ -d "$repo_root/$at" ]; then
                                                ambiguous_add=1
                                            fi
                                            ;;
                                    esac
                                done <<EOF_AT
$add_tokens
EOF_AT

                                if [ "$has_code_staged" != "1" ] && [ "$ambiguous_add" = "1" ]; then
                                    # (a-i) chain 안 redirect/tee target 검사.
                                    # `>file.go` / `> file.go` / `>>file.go` / `tee file.go` / `tee -a file.go`
                                    local redir_targets
                                    redir_targets=$(printf '%s' "$cmd" \
                                        | grep -oE '(>>?[[:space:]]*[^[:space:]&|;<>]+|\btee([[:space:]]+-[a-zA-Z]+)*[[:space:]]+[^[:space:]&|;<>]+)' \
                                        | sed -E 's/^>>?[[:space:]]*//; s/^tee([[:space:]]+-[a-zA-Z]+)*[[:space:]]+//')
                                    local rt
                                    while IFS= read -r rt; do
                                        [ -z "$rt" ] && continue
                                        # strip basename only path 안 살피고 _is_*에 그대로.
                                        if _is_doc_only_path "$rt"; then continue; fi
                                        if _is_code_file "$rt"; then has_code_staged=1; break; fi
                                    done <<EOF_RT
$redir_targets
EOF_RT
                                fi

                                if [ "$has_code_staged" != "1" ] && [ "$ambiguous_add" = "1" ]; then
                                    # (a-ii) repo 안 untracked/modified working-tree 코드 파일.
                                    # ambiguous pathspec 가 어떤 코드 파일이든 잡아 stage 할 수
                                    # 있으므로 working tree 의 변경/untracked 코드 한 건이라도
                                    # 있으면 invalidate. CI 무효화 보수성 우선.
                                    while IFS= read -r line; do
                                        [ -z "$line" ] && continue
                                        # porcelain: `XY path` (3 chars + path); rename은 `R  old -> new`
                                        local p="${line:3}"
                                        # arrow 처리 (rename)
                                        case "$p" in
                                            *' -> '*) p="${p##* -> }" ;;
                                        esac
                                        if _is_doc_only_path "$p"; then continue; fi
                                        if _is_code_file "$p"; then has_code_staged=1; break; fi
                                    done < <(git -C "$repo_root" status --porcelain --untracked-files=all 2>/dev/null)
                                fi
                            fi
                            if [ "$has_code_staged" != "1" ]; then
                                # (b) `git commit -a` / `-am` / `--all` 감지.
                                # cmd 분석: commit 토큰 이후 단어 중 -a/-am/-aXY/--all 매치.
                                local commit_tail
                                commit_tail=$(printf '%s' "$commit_segment" | sed -E 's/.*\bcommit\b//')
                                if printf '%s' "$commit_tail" | grep -qE '(^|[[:space:]])(-a([^-=[:space:]]*)?|--all)\b'; then
                                    # working tree (tracked, unstaged) 검사.
                                    while IFS= read -r line; do
                                        [ -z "$line" ] && continue
                                        local status path1 path2
                                        status=$(printf '%s' "$line" | cut -f1)
                                        path1=$(printf '%s' "$line" | cut -f2)
                                        path2=$(printf '%s' "$line" | cut -f3)
                                        local check_paths=()
                                        case "$status" in
                                            R*|C*)
                                                [ -n "$path1" ] && check_paths+=("$path1")
                                                [ -n "$path2" ] && check_paths+=("$path2")
                                                ;;
                                            *) [ -n "$path1" ] && check_paths+=("$path1") ;;
                                        esac
                                        local p
                                        for p in "${check_paths[@]}"; do
                                            if _is_doc_only_path "$p"; then continue; fi
                                            if _is_code_file "$p"; then has_code_staged=1; break 2; fi
                                        done
                                    done < <(git -C "$repo_root" diff --name-status -M --diff-filter=ACMRD 2>/dev/null)
                                fi
                            fi

                            if [ "$has_code_staged" != "1" ]; then
                                # (c) Pathspec commit form (Codex PR #30 round 8 P2).
                                # `git commit foo.go -m x` / `git commit -i foo.go -m x` /
                                # `git commit -o foo.go -m x` — git docs:
                                #   `git commit [-i | -o] [--] [<pathspec>...]`
                                # 사전 `git add` 없이, 또한 `-a/--all` 없이도 working-tree
                                # 변경이 commit 되므로 (a)/(b)/staged-set 모두 우회됨.
                                # commit 토큰 뒤를 토큰화 → value-bearing flag 의 값 skip →
                                # `--` 이후 또는 non-flag 토큰을 pathspec 으로 간주.
                                # Codex PR #30 round 12 P2 (Gemini high #79):
                                # quote-aware tokenizer. Prior `split(/[[:space:]]+/)`
                                # broke on quoted filenames containing spaces
                                # (`git commit "my file.go" -m msg` → tokens
                                # `"my`, `file.go"`), causing `_is_code_file` to
                                # miss the `.go` path. New tokenizer walks the
                                # string char-by-char, honouring `'`/`"` runs and
                                # backslash escapes; emits each token stripped of
                                # surrounding quotes/escapes so downstream
                                # `_is_code_file` sees the raw path.
                                local pathspec_tokens
                                pathspec_tokens=$(printf '%s' "$commit_segment" | awk '
                                    function tokenize(s,   i, n, c, q, esc, buf, tcount) {
                                        n = length(s)
                                        q = ""; esc = 0; buf = ""; tcount = 0
                                        for (i = 1; i <= n; i++) {
                                            c = substr(s, i, 1)
                                            if (esc) { buf = buf c; esc = 0; continue }
                                            if (c == "\\") { esc = 1; continue }
                                            if (q != "") {
                                                if (c == q) { q = "" } else { buf = buf c }
                                                continue
                                            }
                                            if (c == "\047" || c == "\"") { q = c; continue }
                                            if (c == " " || c == "\t") {
                                                if (buf != "") { TOK[tcount++] = buf; buf = "" }
                                                continue
                                            }
                                            buf = buf c
                                        }
                                        if (buf != "") TOK[tcount++] = buf
                                        return tcount
                                    }
                                    {
                                        n = tokenize($0)
                                        in_commit = 0
                                        in_pathspec = 0
                                        skip_next = 0
                                        for (i = 0; i < n; i++) {
                                            t = TOK[i]
                                            if (t == "") continue
                                            if (!in_commit) {
                                                if (t == "commit") in_commit = 1
                                                continue
                                            }
                                            if (skip_next) { skip_next = 0; continue }
                                            if (in_pathspec) { print t; continue }
                                            if (t == "--") { in_pathspec = 1; continue }
                                            # Codex PR #30 round 15 P2 (#3215117950):
                                            # --pathspec-from-file is an opaque
                                            # pathspec source (file lists paths).
                                            # Treat as positional pathspec by
                                            # emitting a sentinel so the caller
                                            # marks the segment opaque.
                                            if (t == "--pathspec-from-file" || t ~ /^--pathspec-from-file=/) {
                                                if (t == "--pathspec-from-file") skip_next = 1
                                                print "__OPAQUE_PATHSPEC_FROM_FILE__"
                                                continue
                                            }
                                            # Codex PR #30 round 16 P2 (#3215134956):
                                            # value-bearing long opts standalone form.
                                            if (t == "--message" || t == "--file" || t == "--reuse-message" \
                                                || t == "--reedit-message" || t == "--squash" || t == "--fixup" \
                                                || t == "--gpg-sign" || t == "--cleanup" || t == "--date" \
                                                || t == "--author" || t == "--template" || t == "--pathspec-file-nul") {
                                                skip_next = 1
                                                continue
                                            }
                                            # value-bearing short opts: next token = value
                                            if (t == "-m" || t == "-F" || t == "-c" || t == "-C" || t == "-t" || t == "-T" || t == "--trailer") {
                                                skip_next = 1
                                                continue
                                            }
                                            # other flags (long `--foo=bar` or `-x`)
                                            if (substr(t, 1, 1) == "-") continue
                                            # first non-flag → pathspec
                                            in_pathspec = 1
                                            print t
                                        }
                                    }')
                                if [ -n "$pathspec_tokens" ]; then
                                    local pst
                                    while IFS= read -r pst; do
                                        [ -z "$pst" ] && continue
                                        # Codex PR #30 round 15 P2: sentinel from
                                        # awk = `--pathspec-from-file`. File contents
                                        # opaque to us → conservatively scan the
                                        # repo's working tree for any code path
                                        # that could be referenced.
                                        if [ "$pst" = "__OPAQUE_PATHSPEC_FROM_FILE__" ]; then
                                            while IFS= read -r line; do
                                                [ -z "$line" ] && continue
                                                local _p="${line:3}"
                                                case "$_p" in
                                                    *' -> '*) _p="${_p##* -> }" ;;
                                                esac
                                                if _is_doc_only_path "$_p"; then continue; fi
                                                if _is_code_file "$_p"; then has_code_staged=1; break 2; fi
                                            done < <(git -C "$repo_root" status --porcelain --untracked-files=all 2>/dev/null)
                                            continue
                                        fi
                                        if _is_doc_only_path "$pst"; then continue; fi
                                        if _is_code_file "$pst"; then
                                            has_code_staged=1
                                            break
                                        fi
                                        # 디렉토리 pathspec: working-tree 변경 중 해당 디렉토리
                                        # 안 코드 파일 있으면 invalidate.
                                        if [ -d "$repo_root/$pst" ]; then
                                            while IFS= read -r line; do
                                                [ -z "$line" ] && continue
                                                local p="${line:3}"
                                                case "$p" in
                                                    *' -> '*) p="${p##* -> }" ;;
                                                esac
                                                if _is_doc_only_path "$p"; then continue; fi
                                                if _is_code_file "$p"; then has_code_staged=1; break 2; fi
                                            done < <(git -C "$repo_root" status --porcelain --untracked-files=all -- "$pst" 2>/dev/null)
                                        fi
                                    done <<EOF_PST
$pathspec_tokens
EOF_PST
                                fi
                            fi

                            fi  # if [ -n "$repo_root" ]
                            # Short-circuit outer loop on first hit.
                            [ "$has_code_staged" = "1" ] && break
                        done < <(printf '%s\n' "$cmd" | tr ';|&' '\n' \
                            | grep -E "(^|[[:space:]])git[[:space:]]+${GIT_OPTS_RE}commit\b")

                        if [ "$has_code_staged" = "1" ]; then
                            ci_invalidate_unconditional "$SAZO_SESSION_ID" "$SAZO_CWD" "git_commit"
                            # Self-review A1: flag the pre-invalidate so the
                            # post-hook can short-circuit and avoid emitting a
                            # second `ci_invalidated` audit entry + redundant
                            # diff-tree work for the same commit.
                            state_set_str "$SAZO_SESSION_ID" \
                                ".pre_commit_invalidate_pending" "1" "$SAZO_CWD" 2>/dev/null || true
                        fi
                        : "$marker_repo_root $marker_pre_head"  # silence unused
                    fi
                fi
                # commit 자체는 fall-through (block 안 함)
            fi
            # gh pr create — hard block
            if echo "$cmd" | grep -qE '\bgh[[:space:]]+pr[[:space:]]+create\b'; then
                # Codex PR #30 round 5 P2: chain `... && gh pr create` can stage
                # newly-created code BEFORE pr create runs (e.g., python -c
                # 'open(...)write(...)' && git add . && git commit && gh pr create).
                # PreToolUse defense's git status sees nothing yet; PostToolUse
                # commit invalidate fires AFTER PR create already passed.
                # Conservative: if `gh pr create` is preceded in the same Bash
                # by ANY chain operator (`&&`, `;`, `||`) AND the chain contains
                # opaque-stage primitives (`git add`, `git commit -a`), force
                # invalidate ci_passed_at before the gate so PR is blocked.
                if [ "${SAZO_DISABLE_CI_INVALIDATE:-0}" != "1" ]; then
                    local pre_chain
                    pre_chain=$(printf '%s' "$cmd" | sed -E 's/\bgh[[:space:]]+pr[[:space:]]+create.*$//')
                    # Codex PR #30 round 5/6 P2: opaque-stage primitives — `git add`,
                    # `git rm`, `git mv`, `git commit -a`. 코드 파일 추가/삭제/이동
                    # 모두 build break 또는 stale CI 위험. `git -C <path> ...`,
                    # `git -c k=v ...` 처럼 global option 끼는 케이스도 매치.
                    # Codex PR #30 round 8 P2: pathspec commit form (`git commit foo.go -m x`)
                    # 도 opaque — 사전 add 없이 working-tree 코드 파일을 commit. 매치
                    # 추가: `commit` 토큰 뒤가 옵션만이 아니라 positional pathspec 포함
                    # 케이스 (commit_segment 안에 -- 또는 non-flag 토큰 존재).
                    # Codex PR #30 round 12 P2 (#3215075171, #3215075173):
                    # - chain operator regex allowed only spaced forms (`a && b`),
                    #   missing compact `a&&b&&c`. Bash accepts both. Drop the
                    #   surrounding `[[:space:]]` requirements.
                    # - opaque commit-flag regex matched `-a`/`-am` only; missed
                    #   the long form `git commit --all` documented in `git
                    #   commit -h`. Add `--all` alternative.
                    local has_opaque=0
                    if echo "$pre_chain" | grep -qE '(&&|\|\||;)' \
                        && echo "$pre_chain" | grep -qE "\bgit[[:space:]]+${GIT_OPTS_RE}(add\b|rm\b|mv\b|commit[[:space:]]+(-[aA-Za-z]*[aA]\b|--all\b))"; then
                        has_opaque=1
                    fi
                    if [ "$has_opaque" != "1" ] \
                        && echo "$pre_chain" | grep -qE '(&&|\|\||;)'; then
                        # Codex PR #30 round 11 P2: scan **every** commit segment
                        # for pathspec form, not just the first. A chain like
                        # `git commit -m docs && git commit foo.go && gh pr create`
                        # had its second (pathspec) commit ignored when only the
                        # first was inspected.
                        local pre_commit_segment
                        while IFS= read -r pre_commit_segment; do
                            [ -z "$pre_commit_segment" ] && continue
                            local has_pathspec
                            has_pathspec=$(printf '%s' "$pre_commit_segment" | awk '
                                function tokenize(s,   i, n, c, q, esc, buf, tcount) {
                                    n = length(s)
                                    q = ""; esc = 0; buf = ""; tcount = 0
                                    for (i = 1; i <= n; i++) {
                                        c = substr(s, i, 1)
                                        if (esc) { buf = buf c; esc = 0; continue }
                                        if (c == "\\") { esc = 1; continue }
                                        if (q != "") {
                                            if (c == q) { q = "" } else { buf = buf c }
                                            continue
                                        }
                                        if (c == "\047" || c == "\"") { q = c; continue }
                                        if (c == " " || c == "\t") {
                                            if (buf != "") { TOK[tcount++] = buf; buf = "" }
                                            continue
                                        }
                                        buf = buf c
                                    }
                                    if (buf != "") TOK[tcount++] = buf
                                    return tcount
                                }
                                {
                                    n = tokenize($0)
                                    in_commit = 0
                                    skip_next = 0
                                    for (i = 0; i < n; i++) {
                                        t = TOK[i]
                                        if (t == "") continue
                                        if (!in_commit) {
                                            if (t == "commit") in_commit = 1
                                            continue
                                        }
                                        if (skip_next) { skip_next = 0; continue }
                                        if (t == "--") { print "1"; exit }
                                        # Codex PR #30 round 15 P2 (#3215117950):
                                        # --pathspec-from-file=<file> is opaque
                                        # pathspec source — flag it like positional.
                                        if (t == "--pathspec-from-file" || t ~ /^--pathspec-from-file=/) {
                                            print "1"; exit
                                        }
                                        # Codex PR #30 round 16 P2 (#3215134956):
                                        # value-bearing long opts whose value can
                                        # otherwise be misclassified as positional
                                        # pathspec. `--key=value` form already
                                        # skipped by `substr == "-"` below; only
                                        # the standalone `--key value` form needs
                                        # explicit skip-next.
                                        if (t == "--message" || t == "--file" || t == "--reuse-message" \
                                            || t == "--reedit-message" || t == "--squash" || t == "--fixup" \
                                            || t == "--gpg-sign" || t == "--cleanup" || t == "--date" \
                                            || t == "--author" || t == "--template" || t == "--pathspec-file-nul") {
                                            skip_next = 1
                                            continue
                                        }
                                        if (t == "-m" || t == "-F" || t == "-c" || t == "-C" || t == "-t" || t == "-T" || t == "--trailer") {
                                            skip_next = 1
                                            continue
                                        }
                                        if (substr(t, 1, 1) == "-") continue
                                        print "1"; exit
                                    }
                                }')
                            if [ "$has_pathspec" = "1" ]; then
                                has_opaque=1
                                break
                            fi
                        done < <(printf '%s\n' "$pre_chain" | tr ';|&' '\n' \
                            | grep -E "(^|[[:space:]])git[[:space:]]+${GIT_OPTS_RE}commit\b")
                    fi
                    if [ "$has_opaque" = "1" ]; then
                        local cur_cp_chain
                        cur_cp_chain=$(state_get "$SAZO_SESSION_ID" ".ci_passed_at" "$SAZO_CWD")
                        if [ -n "$cur_cp_chain" ] && [ "$cur_cp_chain" != "null" ]; then
                            ci_invalidate_unconditional "$SAZO_SESSION_ID" "$SAZO_CWD" "pr_create_chain_opaque"
                        fi
                    fi
                fi
                # Stage B: approval hard block — PR create requires approval completed.
                # SAZO_ALLOW_APPROVAL_BYPASS=1 → mark_approval_complete by="bypass" then pass (warn metric).
                if ! stage_is_passed "$SAZO_SESSION_ID" "approval"; then
                    if [ "${SAZO_ALLOW_APPROVAL_BYPASS:-0}" = "1" ]; then
                        audit_log "approval_bypass_warn" "${SAZO_SESSION_ID:-}" "approval" "completed" "bypass" \
                            "SAZO_ALLOW_APPROVAL_BYPASS=1; tool=gh_pr_create"
                        mark_approval_complete "$SAZO_SESSION_ID" "bypass" "SAZO_ALLOW_APPROVAL_BYPASS=1" "$SAZO_CWD"
                    else
                        emit_skip_warning_if_needed
                        hard_block "approval" "PR 생성 전 플랜 승인 필수.
플랜 제시 후 /approved 입력하거나 사용자가 직접 승인해야 합니다.
긴급 예외: SAZO_ALLOW_APPROVAL_BYPASS=1"
                    fi
                fi
                if ! stage_is_passed "$SAZO_SESSION_ID" "ci"; then
                    if [ "${SAZO_ALLOW_CI_SKIP:-0}" = "1" ]; then
                        stage_mark "$SAZO_SESSION_ID" "ci" "skipped" "user" "SAZO_ALLOW_CI_SKIP=1"
                    else
                        emit_skip_warning_if_needed
                        hard_block "ci" "PR 생성 전 CI 통과 확인 필수. 프로젝트 CI 커맨드(CLAUDE.md/AGENTS.md 명시) 정확 실행.
극단 예외: SAZO_ALLOW_CI_SKIP=1"
                    fi
                fi
                if ! stage_is_passed "$SAZO_SESSION_ID" "review"; then
                    emit_skip_warning_if_needed
                    hard_block "review" "독립 리뷰 필수.
  Task(subagent_type=\"code-reviewer\", ...) 또는 architect-advisor
문서/주석만 수정: /skip review <reason>"
                fi
            fi
            # gh pr merge — review stage hard block (Plan 13 follow-up)
            # PR 생성 후 별도 머지 사이클. review (Step 6)가 verdict aggregation
            # 통과 상태여야 머지 허용. approval/ci는 PR 생성 시점에 이미 통과돼 있어
            # normal flow에서 추가 검사 불필요. 우회 경로(approval/ci bypass)로 PR 생성한
            # 케이스에서도 review만큼은 강제 — 이게 본 fix의 핵심 의도.
            #
            # Codex PR#39 P2 회귀 방어: `gh pr merge` substring 매치만 하면
            # `echo gh pr merge` / `rg 'gh pr merge' docs` 같은 무해 명령도 차단됨.
            # shell command boundary 강제 — segment 분리 후 각 segment의 첫 토큰이
            # `gh` 일 때만 매칭. compound 명령 (`a && gh pr merge`) 도 지원.
            gh_merge_invoked=0
            if echo "$cmd" | grep -qE '\bgh[[:space:]]+pr[[:space:]]+merge\b'; then
                # Codex PR#39 round 4: pipe(`|`) 도 command separator로 추가.
                # `yes | gh pr merge` 같은 pipeline. order 중요 — `\|\|` 먼저 매칭 후 single `\|`.
                # awk regex alternation은 leftmost match라 `\|\|`를 single `\|`보다 먼저 배치.
                merge_segments=$(printf '%s' "$cmd" | awk '{gsub(/&&|\|\||;|\|/, "\n"); print}')
                while IFS= read -r seg; do
                    seg=$(printf '%s' "$seg" | sed -E 's/^[[:space:]]+//')
                    [ -z "$seg" ] && continue
                    # Codex PR#39 round 2 P2: leading shell variable assignments
                    # (`VAR=value cmd args`, e.g. `GH_TOKEN=xxx gh pr merge`) skip.
                    # POSIX simple command 문법: `[NAME=word]... command [args]`.
                    # NAME은 `[a-zA-Z_][a-zA-Z0-9_]*` (POSIX 3.231).
                    seg=$(printf '%s' "$seg" | sed -E 's/^([a-zA-Z_][a-zA-Z0-9_]*=[^[:space:]]*[[:space:]]+)+//')
                    # Codex PR#39 round 3 P2: `env [VAR=val]... cmd` wrapper도 strip.
                    # `env GH_TOKEN=xxx gh pr merge` 같은 패턴.
                    if echo "$seg" | grep -qE '^env[[:space:]]+'; then
                        seg=$(printf '%s' "$seg" | sed -E 's/^env[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*=[^[:space:]]*[[:space:]]+)*//')
                    fi
                    # Codex PR#39 round 5 P2: `command [-pVv] cmd` Bash builtin wrapper도 strip.
                    # `command gh pr merge` 같은 alias/function bypass 패턴.
                    if echo "$seg" | grep -qE '^command[[:space:]]+'; then
                        seg=$(printf '%s' "$seg" | sed -E 's/^command[[:space:]]+(-[pVv]+[[:space:]]+)?//')
                    fi
                    # 첫 토큰이 gh 이고 그 다음이 pr merge 인지 확인
                    if echo "$seg" | grep -qE '^gh[[:space:]]+pr[[:space:]]+merge\b'; then
                        gh_merge_invoked=1
                        break
                    fi
                done <<< "$merge_segments"
            fi
            if [ "$gh_merge_invoked" = "1" ]; then
                if ! stage_is_passed "$SAZO_SESSION_ID" "review"; then
                    if [ "${SAZO_ALLOW_MERGE_BYPASS:-0}" = "1" ]; then
                        audit_log "merge_bypass_warn" "${SAZO_SESSION_ID:-}" "review" "bypassed" "bypass" \
                            "SAZO_ALLOW_MERGE_BYPASS=1; tool=gh_pr_merge"
                        # approval/ci bypass 패턴과 일관 — stage_mark로 영속화하여
                        # 후속 stage_is_passed review 호출도 통과. idempotency 보장.
                        stage_mark "$SAZO_SESSION_ID" "review" "skipped" "bypass" "SAZO_ALLOW_MERGE_BYPASS=1"
                    else
                        emit_skip_warning_if_needed
                        hard_block "review" "PR 머지 전 독립 리뷰 완료 필수.
  Step 6 (code-reviewer / architect-advisor verdict APPROVE) 또는
  문서/주석만 수정: /skip review <reason>
극단 예외: SAZO_ALLOW_MERGE_BYPASS=1"
                    fi
                fi
            fi
            ;;
    esac
    exit 0
}

case "$MODE" in
    pre) handle_pre ;;
    post) handle_post ;;
    *) echo "unknown mode: $MODE" >&2; exit 0 ;;
esac
