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

if ! workflow_hooks_enabled || [ "${SAZO_SKIP_STATE_MACHINE:-0}" = "1" ]; then
    exit 0
fi

read_hook_payload

[ -z "${SAZO_SESSION_ID:-}" ] && exit 0

state_init "$SAZO_SESSION_ID" "$SAZO_CWD" "$SAZO_MODEL"

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
                    # 위임 보상: explore_count decay
                    state_decrement "$SAZO_SESSION_ID" ".explore_count"
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
                plan-executor|ui-engineer|doc-writer)
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
            if echo "$cmd" | grep -qE '(^|[[:space:]&|;()])git[[:space:]]+(-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?[[:space:]]+)*commit\b'; then
                if [ "${SAZO_DISABLE_CI_INVALIDATE:-0}" != "1" ]; then
                    local cur_cp
                    cur_cp=$(state_get "$SAZO_SESSION_ID" ".ci_passed_at" "$SAZO_CWD")
                    if [ -n "$cur_cp" ] && [ "$cur_cp" != "null" ]; then
                        # Codex PR #30 P2: `git -C <path> commit` runs git in <path>,
                        # not SAZO_CWD. Extract `-C <path>` from cmd and use that as
                        # the diff target. Without this, staged code in the actual
                        # target repo is invisible to our defense layer.
                        local git_target="$SAZO_CWD"
                        local c_path
                        c_path=$(printf '%s' "$cmd" \
                            | sed -E -n 's/.*[[:space:]]-C[[:space:]]+([^[:space:]]+).*/\1/p' \
                            | head -1)
                        if [ -n "$c_path" ]; then
                            # Resolve relative -C path against SAZO_CWD
                            case "$c_path" in
                                /*) git_target="$c_path" ;;
                                *) git_target="$SAZO_CWD/$c_path" ;;
                            esac
                        fi
                        local repo_root
                        repo_root=$(git -C "$git_target" rev-parse --show-toplevel 2>/dev/null)
                        if [ -n "$repo_root" ]; then
                            local has_code_staged=0
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
                            if [ "$has_code_staged" = "1" ]; then
                                ci_invalidate_unconditional "$SAZO_SESSION_ID" "$SAZO_CWD" "git_commit"
                            fi
                        fi
                    fi
                fi
                # commit 자체는 fall-through (block 안 함)
            fi
            # gh pr create — hard block
            if echo "$cmd" | grep -qE '\bgh[[:space:]]+pr[[:space:]]+create\b'; then
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
            ;;
    esac
    exit 0
}

case "$MODE" in
    pre) handle_pre ;;
    post) handle_post ;;
    *) echo "unknown mode: $MODE" >&2; exit 0 ;;
esac
