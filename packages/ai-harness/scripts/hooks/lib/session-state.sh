#!/bin/bash
# session-state.sh — workflow hook 공통 lib.
#
# Usage: `source scripts/hooks/lib/session-state.sh` 후 함수 호출.
# Hook 스크립트는 stdin으로 Claude Code payload JSON을 받는다.
# read_hook_payload로 session_id/cwd/tool_name/tool_input/model을 export.
#
# State 파일: ~/.claude/session-state/$SESSION_ID--$CWD_HASH.json
#   - cwd hash 포함 — 같은 session_id가 여러 worktree를 옮겨다닐 때 stage history leak 방지.
# Audit log: ~/.claude/session-state/audit.log (전 세션 공용 append-only)
#
# 동시성: hook들이 PreToolUse에서 병렬 실행될 수 있으므로 모든 mutation은 mkdir-lock
# 가드 (macOS는 flock 미지원). lock timeout/jq 실패는 audit.log에 기록.
#
# Schema versioning: state file에 schema_version 필드. 향후 migration 분기.
#
# Hook gate (Plan 06): narrow hooks default ON, broad hooks (workflow-state-machine) opt-in via SAZO_WORKFLOW_HOOKS_ENABLED=1.

set -uo pipefail

STATE_DIR="${SAZO_STATE_DIR:-$HOME/.claude/session-state}"
AUDIT_LOG="$STATE_DIR/audit.log"
SCHEMA_VERSION=3  # v3: added pre_commit_markers (per-repo HEAD baseline dict)
mkdir -p -m 700 "$STATE_DIR" 2>/dev/null || mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true

# ----- hook gate (Plan 06: narrow vs broad split) -----
#
# narrow_hooks_enabled — default ON. low-blast-radius hooks:
#   pre-worktree-gate, pre-commit-lint, pre-exploration-gate,
#   user-prompt-approval-detect.
#   Opt-out: SAZO_DISABLE_NARROW_HOOKS=1.
#
# workflow_hooks_enabled — default OFF (opt-in alpha). broad hook:
#   workflow-state-machine. Requires SAZO_WORKFLOW_HOOKS_ENABLED=1.
#   Opt-out: SAZO_DISABLE_WORKFLOW_HOOKS=1.

narrow_hooks_enabled() {
    [ "${SAZO_DISABLE_NARROW_HOOKS:-0}" != "1" ]
}

workflow_hooks_enabled() {
    [ "${SAZO_WORKFLOW_HOOKS_ENABLED:-0}" = "1" ] \
        && [ "${SAZO_DISABLE_WORKFLOW_HOOKS:-0}" != "1" ]
}

# ----- state file path (session_id + cwd hash) -----

cwd_hash() {
    local cwd="$1"
    # short hash to avoid filename length issues; collisions extremely unlikely per session.
    # shasum: macOS. sha1sum: Linux minimal install. md5sum 마지막 fallback.
    if [ -z "$cwd" ]; then
        echo "nocwd"
        return
    fi
    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "$cwd" | shasum -a 1 | cut -c1-12
    elif command -v sha1sum >/dev/null 2>&1; then
        printf '%s' "$cwd" | sha1sum | cut -c1-12
    elif command -v md5sum >/dev/null 2>&1; then
        printf '%s' "$cwd" | md5sum | cut -c1-12
    else
        # last resort: cwd를 그대로 사용 (slash를 underscore로 replace)
        printf '%s' "$cwd" | tr '/' '_' | cut -c1-40
    fi
}

state_file() {
    local sid="${1:-${SAZO_SESSION_ID:-}}"
    local cwd="${2:-${SAZO_CWD:-}}"
    [ -z "$sid" ] && return 1
    local h
    h=$(cwd_hash "$cwd")
    echo "$STATE_DIR/$sid--$h.json"
}

# ----- mutation guard (mkdir-based lock; macOS lacks flock) -----

# _with_lock <state-file> <command...>
# mkdir is atomic on POSIX FS — use as lock primitive.
# Retry budget: 50 × 100ms = 5s. Stale lock (≥60s) auto-cleared (only when mtime
# can be determined — undetermined mtime treated as fresh to avoid false stale).
# Lock timeout → caller fails with rc=99 + audit log entry. Mutation NOT executed
# without lock — prevents silent corruption.
_with_lock() {
    local f="$1"; shift
    local lockdir="$f.lockd"
    local i=0
    while ! mkdir "$lockdir" 2>/dev/null; do
        # stale lock detection — both stat variants must succeed
        # Self-review L1 (PR #29): GNU-first probe (`stat -c %Y`) — BSD-first
        # chain is unsafe on Linux because GNU stat's `-f` means
        # `--file-system` (multi-line filesystem report, exit 0), so the
        # chain captures garbage instead of an integer and breaks the
        # numeric `age` comparison. Same rationale as `_file_mtime` in
        # sazo-workflow.sh.
        local mtime
        mtime=$(stat -c %Y "$lockdir" 2>/dev/null || stat -f %m "$lockdir" 2>/dev/null || echo "")
        if [ -n "$mtime" ]; then
            local age=$(( $(date +%s) - mtime ))
            if [ "$age" -gt 60 ]; then
                rmdir "$lockdir" 2>/dev/null || true
                continue
            fi
        fi
        i=$((i + 1))
        if [ "$i" -gt 50 ]; then
            local ts
            ts=$(date +%Y-%m-%dT%H:%M:%S%z)
            printf '[%s] lock_timeout file=%s\n' "$ts" "$f" >> "$AUDIT_LOG" 2>/dev/null
            echo "[session-state] lock timeout for $f — mutation skipped" >&2
            return 99
        fi
        sleep 0.1
    done
    # 락 획득. cleanup은 outer rmdir 한 곳에서만 (subshell trap 제거 — 이전 V3에는
    # 둘 다 있어 다른 acquired lock을 가로채는 race 가능 (V3 reviewer #1)).
    local rc=0
    ( "$@" ) || rc=$?
    rmdir "$lockdir" 2>/dev/null || true
    return $rc
}

# ----- init -----

state_init() {
    local sid="$1" cwd="${2:-}" model="${3:-unknown}"
    local f
    f=$(state_file "$sid" "$cwd") || return 1
    [ -f "$f" ] && return 0
    _with_lock "$f" _state_init_inner "$f" "$sid" "$cwd" "$model"
}

_state_init_inner() {
    local f="$1" sid="$2" cwd="$3" model="$4"
    [ -f "$f" ] && return 0
    jq -n \
        --arg sid "$sid" --arg cwd "$cwd" --arg model "$model" \
        --arg ts "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        --argjson sv "$SCHEMA_VERSION" '{
            schema_version: $sv,
            session_id: $sid,
            cwd: $cwd,
            model: $model,
            started_at: $ts,
            stage: "init",
            history: [],
            explore_count: 0,
            plan_approved_at: null,
            approval_nonce: null,
            ci_passed_at: null,
            review_ts: null,
            verdict_nonces: {},
            last_verdicts: {review: {}, plan: {}},
            verdict_missing_count: {},
            verdict_errors: {},
            verdict_unset_expected_set_count: 0,
            review_expected_set: [],
            last_cycle_at: {},
            last_cycle_id: {},
            pre_commit_markers: {}
        }' > "$f"
}

# ----- read -----

state_get() {
    local sid="$1" path="$2" cwd="${3:-${SAZO_CWD:-}}"
    local f
    f=$(state_file "$sid" "$cwd") || return 1
    [ -f "$f" ] || return 1
    jq -r "$path // empty" "$f" 2>/dev/null
}

# ----- write -----

state_set_json() {
    local sid="$1" path="$2" json_value="$3" cwd="${4:-${SAZO_CWD:-}}"
    local f
    f=$(state_file "$sid" "$cwd") || return 1
    [ -f "$f" ] || { echo "[session-state] state missing for $sid; call state_init first" >&2; return 1; }
    _with_lock "$f" _state_set_json_inner "$f" "$path" "$json_value"
}

_state_set_json_inner() {
    local f="$1" path="$2" json_value="$3"
    local tmp
    tmp=$(mktemp)
    if jq --argjson v "$json_value" "$path = \$v" "$f" > "$tmp"; then
        mv "$tmp" "$f"
    else
        rm -f "$tmp"
        printf '[%s] jq_error file=%s op=set_json path=%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$f" "$path" >> "$AUDIT_LOG" 2>/dev/null
        return 1
    fi
}

state_set_str() {
    local sid="$1" path="$2" str_value="$3" cwd="${4:-${SAZO_CWD:-}}"
    local f
    f=$(state_file "$sid" "$cwd") || return 1
    [ -f "$f" ] || { echo "[session-state] state missing for $sid; call state_init first" >&2; return 1; }
    _with_lock "$f" _state_set_str_inner "$f" "$path" "$str_value"
}

_state_set_str_inner() {
    local f="$1" path="$2" str_value="$3"
    local tmp
    tmp=$(mktemp)
    if jq --arg v "$str_value" "$path = \$v" "$f" > "$tmp"; then
        mv "$tmp" "$f"
    else
        rm -f "$tmp"
        printf '[%s] jq_error file=%s op=set_str path=%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$f" "$path" >> "$AUDIT_LOG" 2>/dev/null
        return 1
    fi
}

# state_set_dict_value <sid> <dict_path> <key> <json_value> [cwd]
#
# Null-safe dict insertion. Atomically: read `<dict_path>` (`null` → `{}` bootstrap),
# set `[key]=value`, write back. Eliminates the manual bootstrap pattern that
# was duplicated across callsites (round 13 marker dict bug — empty stdin to
# jq pipeline silently dropped the write).
#
# `key` is passed via `--arg` so `"`/`\` in key cannot break the jq filter
# (self-review N3/N6).
# `json_value` must be valid JSON (`"str"`, `123`, `{...}`, etc).
# `dict_path` is interpolated into the jq source — caller MUST pass a
# trusted literal (e.g. `.pre_commit_markers`), never a user-controlled value.
state_set_dict_value() {
    local sid="$1" dict_path="$2" key="$3" json_value="$4" cwd="${5:-${SAZO_CWD:-}}"
    local f
    f=$(state_file "$sid" "$cwd") || return 1
    [ -f "$f" ] || { echo "[session-state] state missing for $sid; call state_init first" >&2; return 1; }
    _with_lock "$f" _state_set_dict_value_inner "$f" "$dict_path" "$key" "$json_value"
}

_state_set_dict_value_inner() {
    local f="$1" dict_path="$2" key="$3" json_value="$4"
    local tmp
    tmp=$(mktemp)
    # `($d // {})` bootstraps null → empty dict before .[k]=v assignment.
    if jq --arg k "$key" --argjson v "$json_value" \
        "$dict_path = (($dict_path // {}) | .[\$k] = \$v)" \
        "$f" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$f"
    else
        rm -f "$tmp"
        printf '[%s] jq_error file=%s op=set_dict_value path=%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$f" "$dict_path" >> "$AUDIT_LOG" 2>/dev/null
        return 1
    fi
}

state_increment() {
    local sid="$1" path="$2" cwd="${3:-${SAZO_CWD:-}}"
    local f
    f=$(state_file "$sid" "$cwd") || return 1
    [ -f "$f" ] || { echo "[session-state] state missing for $sid; call state_init first" >&2; return 1; }
    _with_lock "$f" _state_increment_inner "$f" "$path"
}

_state_increment_inner() {
    local f="$1" path="$2"
    local tmp
    tmp=$(mktemp)
    if jq "$path = ($path // 0) + 1" "$f" > "$tmp"; then
        mv "$tmp" "$f"
    else
        rm -f "$tmp"
        printf '[%s] jq_error file=%s op=increment path=%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$f" "$path" >> "$AUDIT_LOG" 2>/dev/null
        return 1
    fi
}

state_decrement() {
    local sid="$1" path="$2" cwd="${3:-${SAZO_CWD:-}}"
    local f
    f=$(state_file "$sid" "$cwd") || return 1
    [ -f "$f" ] || return 0
    _with_lock "$f" _state_decrement_inner "$f" "$path"
}

_state_decrement_inner() {
    local f="$1" path="$2"
    local tmp
    tmp=$(mktemp)
    if jq "$path = (if ($path // 0) > 0 then $path - 1 else 0 end)" "$f" > "$tmp"; then
        mv "$tmp" "$f"
    else
        rm -f "$tmp"
        printf '[%s] jq_error file=%s op=decrement path=%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$f" "$path" >> "$AUDIT_LOG" 2>/dev/null
        return 1
    fi
}

# ----- stage transitions -----

# stage_mark <sid> <stage> <status:completed|skipped> [by] [reason] [cwd]
stage_mark() {
    local sid="$1" stage="$2" status="$3" by="${4:-}" reason="${5:-}" cwd="${6:-${SAZO_CWD:-}}"
    local f
    f=$(state_file "$sid" "$cwd") || return 1
    [ -f "$f" ] || state_init "$sid" "$cwd" "${SAZO_MODEL:-unknown}"
    _with_lock "$f" _stage_mark_inner "$f" "$stage" "$status" "$by" "$reason" "$sid"
}

_stage_mark_inner() {
    local f="$1" stage="$2" status="$3" by="$4" reason="$5" sid="$6"
    local tmp ts
    tmp=$(mktemp)
    ts=$(date +%Y-%m-%dT%H:%M:%S%z)
    # Capture the current cycle_id for review/plan stages so a same-second
    # /skip+cycle_init race (Codex Round 14 P2) cannot let a stale skip
    # bypass the new cycle. cycle_id is read from the locked state; if no
    # cycle was ever initialized for this stage the value is "" — which
    # stage_is_passed treats as legacy mode.
    if jq --arg stage "$stage" --arg status "$status" --arg by "$by" \
        --arg reason "$reason" --arg ts "$ts" '
        ((.last_cycle_id // {})[$stage] // "") as $cid |
        .history += [{stage: $stage, status: $status, by: $by, reason: $reason, ts: $ts, cycle_id: $cid}]
        | .stage = $stage
    ' "$f" > "$tmp"; then
        mv "$tmp" "$f"
    else
        rm -f "$tmp"
        printf '[%s] jq_error file=%s op=stage_mark stage=%s\n' "$ts" "$f" "$stage" >> "$AUDIT_LOG" 2>/dev/null
        return 1
    fi
    printf '[%s] %s stage=%s status=%s by=%s reason=%q\n' \
        "$ts" "$sid" "$stage" "$status" "$by" "$reason" >> "$AUDIT_LOG"
}

# stage_is_passed <sid> <stage> [cwd]
# completed OR skipped 이면 passed.
# Validator (defense-in-depth):
# - approval: completed면 by="user" required (UserPromptSubmit→nonce 경로) AND
#             plan_approved_at not null. skipped는 절대 인정 안 함.
# - ci: completed면 by="user" or by="auto" (PostToolUse hook이 ci 매치 시 마킹).
#       skipped는 by="user" only (SAZO_ALLOW_CI_SKIP env 경로).
# 다른 stage: completed/skipped 어느 쪽이든 by 무관 (일반 stage).
stage_is_passed() {
    local sid="$1" stage="$2" cwd="${3:-${SAZO_CWD:-}}"
    local f
    f=$(state_file "$sid" "$cwd") || return 1
    [ -f "$f" ] || return 1
    case "$stage" in
        approval)
            jq -e '
                (.plan_approved_at != null)
                and (.history | any(
                    .stage == "approval"
                    and .status == "completed"
                    and (.by == "user" or .by == "bypass")
                ))
            ' "$f" >/dev/null 2>&1
            ;;
        ci)
            # ci_passed_at AND condition (Plan 04): completed-by-auto/user only
            # passes when ci_passed_at is non-null. Code mutation after CI clears
            # ci_passed_at via _is_code_file detection — forces re-run before PR.
            # user-skipped path remains unconditional override.
            # NOTE: jq pipe `.history | any(...)` binds tighter than `and` —
            # explicit parens required so the AND condition reads from root,
            # not from inside the array context.
            jq -e '
                (.history | any(
                    .stage == "ci"
                    and (
                        (
                            .status == "completed"
                            and (.by == "user" or .by == "auto")
                        )
                        or (.status == "skipped" and .by == "user")
                    )
                ))
                and (
                    (.ci_passed_at != null)
                    or (.history | any(.stage == "ci" and .status == "skipped" and .by == "user"))
                )
            ' "$f" >/dev/null 2>&1
            ;;
        review|plan)
            # Verdict-tracked stages.
            #
            # User /skip review or /skip plan is an authoritative override
            # — passes regardless of last_verdicts state (a user explicitly
            # accepting risk after a BLOCK verdict).
            #
            # Otherwise three conditions must all hold:
            #   1. history has a completed/skipped entry
            #   2. all currently-recorded verdicts are APPROVE
            #      (later BLOCK downgrades invalidate)
            #   3. if an expected_set is registered for this cycle, every
            #      expected reviewer must have a verdict in last_verdicts
            #      (prevents premature pass when stale verdicts are cleared
            #       and only some reviewers have responded in the new cycle)
            # Empty last_verdicts → vacuous-truth on (2) and skip (3) so
            # legacy Phase 1 history-only fallback still passes.
            jq -e --arg s "$stage" --argjson defaultPlan '["plan-critic","plan-auditor"]' '
                ((.last_verdicts // {})[$s] // {}) as $last |
                (if $s == "review" then (.review_expected_set // []) else $defaultPlan end) as $expected |
                ((.last_cycle_at // {})[$s] // null) as $cycle_at |
                ((.last_cycle_id // {})[$s] // "") as $cycle_id |
                # User /skip is an authoritative override. Same-second
                # cycle_init + user /skip races (Codex Round 14 P2):
                # second-precision .ts > $cycle_at fails when both timestamps
                # land on the same wall-clock second. cycle_id (random hex,
                # rotated every verdict_cycle_init) is the precision-independent
                # identity. stage_mark captures the current cycle_id into each
                # history entry, so we can match a /skip to its cycle directly.
                #
                # Acceptance rules (any one matches → skip is authoritative):
                #   a. legacy state with no cycle_id ever set ($cycle_id == ""):
                #      fall back to timestamp comparison (cycle_at can be null
                #      pre-cycle_init too — old state files).
                #   b. modern state with cycle_id: skip entry must carry the
                #      same cycle_id, which proves it was recorded under the
                #      currently-active cycle (or a later one). A skip from a
                #      prior cycle has a different cycle_id and is rejected.
                #      Skips lacking cycle_id (older entries before this fix)
                #      fall back to .ts >= $cycle_at — same-second tolerant.
                (.history | any(
                    .stage == $s
                    and .status == "skipped"
                    and (.by == "user" or .by == "bypass")
                    and (
                        ($cycle_id == "" and ($cycle_at == null or .ts > $cycle_at))
                        or
                        (
                            $cycle_id != ""
                            and (
                                ((.cycle_id // "") == $cycle_id)
                                or
                                ((.cycle_id // "") == "" and ($cycle_at == null or .ts >= $cycle_at))
                            )
                        )
                    )
                ))
                or
                (
                    ($last | to_entries | all(.value.verdict == "APPROVE"))
                    and
                    (.history | any(.stage == $s and (.status == "completed" or .status == "skipped")))
                    and
                    (
                        # Legacy mode: no aggregation cycle ever initialized
                        # (cycle_at == null). Trust history + any APPROVE
                        # verdicts present (Phase 1 backward compat — works
                        # whether last_verdicts is empty or synthetic).
                        ($cycle_at == null)
                        or
                        # Aggregation mode: cycle_init was called; every
                        # expected reviewer must have responded.
                        ($expected | length > 0 and ($expected | all(. as $a | $last | has($a))))
                    )
                )
            ' "$f" >/dev/null 2>&1
            ;;
        *)
            jq -e --arg s "$stage" '
                .history | any(.stage == $s and (.status == "completed" or .status == "skipped"))
            ' "$f" >/dev/null 2>&1
            ;;
    esac
}

# 가장 최근 history 끝부터 연속 skipped 개수
consecutive_skip_count() {
    local sid="$1" cwd="${2:-${SAZO_CWD:-}}"
    local f
    f=$(state_file "$sid" "$cwd") || { echo 0; return; }
    [ -f "$f" ] || { echo 0; return; }
    jq -r '[.history[].status] | reverse | .[]' "$f" 2>/dev/null | awk '
        /^skipped$/ { count++; next }
        { exit }
        END { print count+0 }
    '
}

# ----- approval nonce (UserPromptSubmit hook이 set, /approved가 consume) -----

approval_nonce_set() {
    local sid="$1" nonce="$2" cwd="${3:-${SAZO_CWD:-}}"
    local f
    f=$(state_file "$sid" "$cwd") || return 1
    [ -f "$f" ] || state_init "$sid" "$cwd" "${SAZO_MODEL:-unknown}"
    state_set_str "$sid" ".approval_nonce" "$nonce" "$cwd"
}

approval_nonce_consume() {
    local sid="$1" nonce="$2" cwd="${3:-${SAZO_CWD:-}}"
    local stored
    stored=$(state_get "$sid" ".approval_nonce" "$cwd")
    [ -n "$stored" ] && [ "$stored" = "$nonce" ] || return 1
    state_set_json "$sid" ".approval_nonce" "null" "$cwd"
    return 0
}

# ----- mark_approval_complete (Plan 13 Stage A0a) -----
# mark_approval_complete <sid> <by> <reason> [cwd]
# Atomic helper: sets plan_approved_at + appends history entry.
# by values: "user" (direct /approved), "bypass" (SAZO_ALLOW_APPROVAL_BYPASS=1).
# "auto" is not accepted by stage_is_passed validator — caller must not pass "auto".
mark_approval_complete() {
    local sid="$1" by="$2" reason="$3" cwd="${4:-${SAZO_CWD:-}}"
    local f
    f=$(state_file "$sid" "$cwd") || return 1
    [ -f "$f" ] || state_init "$sid" "$cwd" "${SAZO_MODEL:-unknown}"
    _with_lock "$f" _mark_approval_complete_inner "$f" "$by" "$reason"
}

_mark_approval_complete_inner() {
    local f="$1" by="$2" reason="$3"
    local now; now=$(date +%Y-%m-%dT%H:%M:%S%z)
    local tmp; tmp=$(mktemp "${f}.XXXXXX")
    if jq --arg now "$now" --arg by "$by" --arg reason "$reason" '
        .plan_approved_at = $now
        | .history += [{stage: "approval", status: "completed", by: $by, reason: $reason, ts: $now}]
    ' "$f" > "$tmp"; then mv "$tmp" "$f"; else rm -f "$tmp"; return 1; fi
}

# ----- hook payload reader -----

read_hook_payload() {
    local payload
    payload=$(cat)
    export SAZO_HOOK_PAYLOAD="$payload"
    export SAZO_SESSION_ID
    SAZO_SESSION_ID=$(echo "$payload" | jq -r '.session_id // ""')
    export SAZO_CWD
    SAZO_CWD=$(echo "$payload" | jq -r '.cwd // ""')
    export SAZO_TOOL_NAME
    SAZO_TOOL_NAME=$(echo "$payload" | jq -r '.tool_name // ""')
    export SAZO_TOOL_INPUT
    SAZO_TOOL_INPUT=$(echo "$payload" | jq -c '.tool_input // {}')
    export SAZO_TOOL_RESPONSE
    SAZO_TOOL_RESPONSE=$(echo "$payload" | jq -c '.tool_response // {}')
    export SAZO_MODEL
    SAZO_MODEL=$(echo "$payload" | jq -r '.model // env.CLAUDE_MODEL // ""')
    export SAZO_USER_PROMPT
    SAZO_USER_PROMPT=$(echo "$payload" | jq -r '.prompt // ""')
}

# simple_audit: legacy freeform audit log helper. Kept for backward compat;
# new call sites should prefer audit_log() (JSON Lines) for analyzability.
# CLI parser handles both formats.
simple_audit() {
    local event="$1"
    shift
    local extras=""
    while [ $# -gt 0 ]; do
        extras="$extras $1"
        shift
    done
    printf '[%s] %s%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$event" "$extras" >> "$AUDIT_LOG" 2>/dev/null || true
}

# audit_log: append a single JSON Lines entry to AUDIT_LOG.
# Args: event sid [stage] [status] [by] [reason]
# All optional fields default to "" for stable JSON shape.
# Timestamp format MUST match existing freeform entries (%Y-%m-%dT%H:%M:%S%z, local TZ)
# so legacy and new entries sort consistently lexicographically.
# Errors are silent — audit log is best-effort and must never abort callers.
audit_log() {
    local event="$1"
    local sid="${2:-}"
    local stage="${3:-}"
    local status="${4:-}"
    local by="${5:-}"
    local reason="${6:-}"
    local ts entry
    ts=$(date +%Y-%m-%dT%H:%M:%S%z)
    entry=$(jq -nc \
        --arg ts "$ts" \
        --arg event "$event" \
        --arg sid "$sid" \
        --arg stage "$stage" \
        --arg status "$status" \
        --arg by "$by" \
        --arg reason "$reason" \
        '{ts:$ts,event:$event,sid:$sid,stage:$stage,status:$status,by:$by,reason:$reason}' 2>/dev/null) \
        || return 0
    printf '%s\n' "$entry" >> "$AUDIT_LOG" 2>/dev/null || true
}

# process_verdict_tracked_post_task: end-to-end handler for verdict-tracked subagent
# Task PostToolUse. Parses footer, validates nonce, records verdict, evaluates
# stage completion. Honors SAZO_VERDICT_FOOTER_ENFORCE (warn|block).
#
# Args: sid cwd stage agent result_text
# Returns: 0 always (decisions encoded in audit log + state)
process_verdict_tracked_post_task() {
    local sid="$1" cwd="$2" stage="$3" agent="$4" result_text="$5"

    # Allowlist: caller (handle_post Task case statement) already filters, but
    # defense-in-depth — reject unknown agents to prevent shell injection via
    # agent name in env var lookup below.
    case "$agent" in
        code-reviewer|architect-advisor|plan-critic|plan-auditor) ;;
        *)
            simple_audit "verdict_unknown_agent" "agent=$agent"
            return 0
            ;;
    esac

    local parse status
    parse=$(parse_verdict_footer "$result_text")
    status=$(printf '%s\n' "$parse" | awk -F= '/^STATUS=/{print $2; exit}')

    case "$status" in
        truncated)
            simple_audit "verdict_truncated" "agent=$agent" "stage=$stage"
            return 0
            ;;
        missing)
            state_increment "$sid" ".verdict_missing_count[\"$agent\"]" "$cwd"
            local enforce_global enforce_agent enforce
            enforce_global="${SAZO_VERDICT_FOOTER_ENFORCE:-warn}"
            # Bash 3.2 compatible — no ${!var} (bash 4+) or eval.
            # agent already validated by allowlist above so this case is
            # exhaustive for verdict-tracked agents.
            case "$agent" in
                code-reviewer)
                    enforce_agent="${SAZO_VERDICT_FOOTER_ENFORCE_CODE_REVIEWER:-}"
                    ;;
                architect-advisor)
                    enforce_agent="${SAZO_VERDICT_FOOTER_ENFORCE_ARCHITECT_ADVISOR:-}"
                    ;;
                plan-critic)
                    enforce_agent="${SAZO_VERDICT_FOOTER_ENFORCE_PLAN_CRITIC:-}"
                    ;;
                plan-auditor)
                    enforce_agent="${SAZO_VERDICT_FOOTER_ENFORCE_PLAN_AUDITOR:-}"
                    ;;
                *)
                    enforce_agent=""
                    ;;
            esac
            enforce="${enforce_agent:-$enforce_global}"

            if [ "$enforce" = "block" ]; then
                simple_audit "verdict_missing_block" "agent=$agent" "stage=$stage"
                return 0
            fi
            # Phase 1 warn fallback. The behavior depends on whether an
            # aggregation cycle is active for this stage.
            simple_audit "verdict_missing_warn" "agent=$agent" "stage=$stage"

            local cycle_at
            cycle_at=$(state_get "$sid" ".last_cycle_at[\"$stage\"] // \"\"" "$cwd")

            if [ -n "$cycle_at" ] && [ "$cycle_at" != "null" ]; then
                # Aggregation cycle active. Caller (skill/command) explicitly
                # opted into nonce-aggregation by calling verdict_cycle_init.
                # A footer-missing response here is most likely a stale Task
                # from a prior cycle (no cycle_id to validate). Refuse to
                # populate last_verdicts with a synthetic APPROVE that could
                # combine with fresh approvals to bypass the gate. Log only.
                return 0
            fi

            # Legacy mode: no cycle_init ever called. Phase 1 warn promise =
            # existing reviewers without footer keep working via legacy
            # stage_mark + history-only stage_is_passed fallback.
            stage_is_passed "$sid" "$stage" \
                || stage_mark "$sid" "$stage" "completed" "auto" "subagent=$agent (Phase 1: footer missing)" "$cwd"
            return 0
            ;;
        ok)
            ;;
        *)
            simple_audit "verdict_parse_error" "agent=$agent" "stage=$stage" "status=$status"
            return 0
            ;;
    esac

    # status=ok — extract fields
    local nonce verdict issues
    nonce=$(printf '%s\n' "$parse" | awk -F= '/^NONCE=/{print $2; exit}')
    verdict=$(printf '%s\n' "$parse" | awk -F= '/^VERDICT=/{print $2; exit}')
    issues=$(printf '%s\n' "$parse" | awk -F= '/^ISSUES=/{print $2; exit}')

    # Atomic validate + record under single lock — no TOCTOU between
    # nonce consume and last_verdicts write. If a fresh cycle starts
    # between the parse here and the locked predicate, the cycle_id
    # mismatch causes rejection inside the same locked mutation that
    # would otherwise have written the stale verdict.
    if ! verdict_consume_and_record "$sid" "$cwd" "$nonce" "$agent" "$stage" "$verdict" "$issues"; then
        simple_audit "verdict_nonce_invalid" "agent=$agent" "stage=$stage" "nonce=$nonce"
        return 0
    fi

    # Evaluate stage completion
    if _evaluate_stage_completion "$sid" "$cwd" "$stage"; then
        stage_is_passed "$sid" "$stage" \
            || stage_mark "$sid" "$stage" "completed" "auto" "verdict aggregation: all APPROVE" "$cwd"
    fi

    # Cap state.json size (best-effort; failure is non-fatal).
    _maybe_truncate_state "$sid" "$cwd" || true

    return 0
}

# _maybe_truncate_state: cap state.json size to 1MB. Preserve invariants:
#   1. Last 50 history entries (recent activity)
#   2. ci/approval completed entries (stage_is_passed dependency — line 273-300)
#   3. ci/approval user-skipped entries (stage_is_passed accepts skipped+by=user)
# Drop oldest non-essential entries. audit.log untouched (separate file).
# Mutation runs under _with_lock to avoid races with concurrent state writes.
SAZO_STATE_MAX_BYTES="${SAZO_STATE_MAX_BYTES:-1048576}"  # 1MB

_maybe_truncate_state() {
    local sid="$1" cwd="$2"
    local f
    f=$(state_file "$sid" "$cwd") || return 1
    [ -f "$f" ] || return 0

    local sz
    sz=$(wc -c <"$f" | tr -d ' ')
    [ "$sz" -lt "$SAZO_STATE_MAX_BYTES" ] && return 0

    _with_lock "$f" _maybe_truncate_state_inner "$f"
}

_maybe_truncate_state_inner() {
    local f="$1"
    local tmp="$f.trunc.tmp"
    # Preserve every entry that stage_is_passed could reference:
    #   - ci/approval completed (auto or user)
    #   - ci/approval skipped by user (CI override path)
    #   - review/plan completed (verdict aggregation history requirement)
    #   - review/plan skipped by user (authoritative override path)
    # Plus the last 50 entries for recent activity. Anything else
    # (research, auto-skips, etc.) is droppable.
    if jq '
        .history |= (
            (
                ([.[-50:][]]) +
                ([.[]
                    | select(
                        (.stage == "ci" or .stage == "approval")
                        and (.status == "completed" or (.status == "skipped" and .by == "user"))
                      )
                ]) +
                ([.[]
                    | select(
                        (.stage == "review" or .stage == "plan")
                        and (.status == "completed" or (.status == "skipped" and .by == "user"))
                      )
                ])
            )
            | unique_by([.ts, .stage, .status, .by, .reason])
            | sort_by(.ts)
        )
    ' "$f" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$f"
    else
        rm -f "$tmp"
        return 1
    fi
}

# _record_reviewer_error: increment per-agent error counter; emit user escalation
# at threshold 3. Stage gate stays incomplete (no stage_mark). Called by hook when
# subagent Task returned is_error/interrupted.
_record_reviewer_error() {
    local sid="$1" cwd="$2" agent="$3"
    state_increment "$sid" ".verdict_errors[\"$agent\"]" "$cwd"
    local count
    count=$(state_get "$sid" ".verdict_errors[\"$agent\"]" "$cwd")
    if [ -n "$count" ] && [ "$count" -ge 3 ] 2>/dev/null; then
        cat >&2 <<EOF
[workflow-block] reviewer $agent stuck ($count consecutive errors).
Action required:
  - Inspect last reviewer Task output
  - Rerun reviewer Task with same expected output, OR
  - User: /skip review <reason>
EOF
    fi
}

# _evaluate_stage_completion: returns 0 if stage can be marked completed based on
# verdict aggregation, 1 otherwise. Reads review_expected_set (or fixed plan set),
# checks all expected reviewers responded with APPROVE.
# Honors SAZO_VERDICT_EMPTY_EXPECTED (fail_open|fail_closed, default fail_open)
# when expected_set is empty.
_evaluate_stage_completion() {
    local sid="$1" cwd="$2" stage="$3"

    local expected_json
    case "$stage" in
        review)
            expected_json=$(state_get "$sid" '.review_expected_set // []' "$cwd")
            [ -z "$expected_json" ] && expected_json='[]'
            ;;
        plan)
            expected_json='["plan-critic","plan-auditor"]'
            ;;
        *)
            return 1
            ;;
    esac

    local expected_count
    expected_count=$(printf '%s' "$expected_json" | jq 'length')

    if [ "$expected_count" -eq 0 ]; then
        # Empty expected_set — caller (skill/command) didn't declare reviewer set.
        state_increment "$sid" ".verdict_unset_expected_set_count" "$cwd"

        local mode="${SAZO_VERDICT_EMPTY_EXPECTED:-fail_open}"
        if [ "$mode" = "fail_closed" ]; then
            return 1
        fi
        # fail_open: pass if any received verdict is APPROVE
        local any_approve
        any_approve=$(state_get "$sid" ".last_verdicts[\"$stage\"] // {} | to_entries | map(.value.verdict) | any(. == \"APPROVE\")" "$cwd")
        # state_get strips false→empty; treat "true" string as success
        [ "$any_approve" = "true" ]
        return $?
    fi

    # Normal path: every expected agent must have APPROVE in last_verdicts.<stage>
    local sf
    sf=$(state_file "$sid" "$cwd")
    local result
    result=$(jq -r --argjson exp "$expected_json" --arg stage "$stage" '
        (.last_verdicts[$stage] // {}) as $last |
        ($exp | map($last[.]?.verdict)) as $vs |
        if ($vs | any(. == null)) then "false"
        elif ($vs | all(. == "APPROVE")) then "true"
        else "false"
        end
    ' "$sf")
    [ "$result" = "true" ]
}

# verdict_cycle_init: start a fresh review/plan aggregation cycle. Atomically
# clears any stale verdicts from a previous cycle and sets review_expected_set
# to the supplied list. Without this, a prior all-APPROVE cycle could
# combine with the first new APPROVE to mark the stage passed before
# remaining reviewers have responded.
#
# Args: sid cwd stage expected_set_json
# Example: verdict_cycle_init "$SID" "$CWD" "review" '["code-reviewer","architect-advisor"]'
verdict_cycle_init() {
    local sid="$1" cwd="$2" stage="$3" expected_json="$4"
    local f
    f=$(state_file "$sid" "$cwd") || return 1
    [ -f "$f" ] || state_init "$sid" "$cwd" "${SAZO_MODEL:-unknown}"
    _with_lock "$f" _verdict_cycle_init_inner "$f" "$stage" "$expected_json"
}

_verdict_cycle_init_inner() {
    local f="$1" stage="$2" expected_json="$3"
    local tmp="$f.cycle.tmp"
    local ts; ts=$(date +%Y-%m-%dT%H:%M:%S%z)
    # cycle_id is a random hex per cycle — independent of timestamp
    # precision. nonces are tagged with the issuing cycle's id so
    # consume can reject same-second restarts that timestamp comparison
    # alone would miss.
    local cycle_id
    if command -v openssl >/dev/null 2>&1; then
        cycle_id=$(openssl rand -hex 8)
    else
        cycle_id=$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 16)
    fi
    if jq --arg s "$stage" --argjson exp "$expected_json" --arg ts "$ts" --arg cid "$cycle_id" '
        .last_verdicts[$s] = {} |
        .last_cycle_at[$s] = $ts |
        .last_cycle_id[$s] = $cid |
        (if $s == "review" then .review_expected_set = $exp else . end)
    ' "$f" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$f"
        return 0
    else
        rm -f "$tmp"
        return 1
    fi
}

# verdict_nonce_issue: mint a random nonce bound to (agent, stage). Caller embeds
# the nonce into the Task prompt so subagent must echo it in its footer.
# Returns the nonce on stdout (32-hex chars).
verdict_nonce_issue() {
    local sid="$1" cwd="$2" agent="$3" stage="$4"
    local nonce
    if command -v openssl >/dev/null 2>&1; then
        nonce=$(openssl rand -hex 16)
    else
        nonce=$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 32)
    fi
    # Tag nonce with the current cycle_id (if any) so consume can reject
    # same-second stale-cycle restarts that timestamp comparison would miss.
    local cycle_id
    cycle_id=$(state_get "$sid" ".last_cycle_id[\"$stage\"] // \"\"" "$cwd")
    local entry
    entry=$(jq -nc \
        --arg agent "$agent" \
        --arg stage "$stage" \
        --arg ts "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        --arg cid "$cycle_id" \
        '{agent: $agent, stage: $stage, issued_at: $ts, cycle_id: $cid, consumed: false}')
    state_set_json "$sid" ".verdict_nonces[\"$nonce\"]" "$entry" "$cwd" || return 1
    printf '%s' "$nonce"
}

# verdict_nonce_consume: atomic check-and-set on nonce. Validates (nonce exists,
# agent matches, not yet consumed) AND flips consumed=true within a single
# _with_lock guard so two concurrent hooks cannot both observe consumed=false
# and both pass — single-use defense holds under parallel reviewer flow.
# Returns 0 on success, 1 on rejection.
verdict_nonce_consume() {
    local sid="$1" cwd="$2" nonce="$3" agent="$4"

    # Validate nonce format defensively (no I/O — safe outside lock).
    case "$nonce" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
        *) return 1 ;;
    esac

    local f
    f=$(state_file "$sid" "$cwd") || return 1
    [ ! -f "$f" ] && return 1

    _with_lock "$f" _verdict_nonce_consume_inner "$f" "$nonce" "$agent"
}

# verdict_consume_and_record: atomic check-and-record. Validates the nonce AND
# writes last_verdicts[stage][agent] entry under a single _with_lock — eliminates
# TOCTOU window between consume() and a separate state_set_json. If a fresh
# cycle starts between the two operations, the late stale verdict cannot bleed
# into the new cycle. Returns 0 on success, 1 on rejection.
verdict_consume_and_record() {
    local sid="$1" cwd="$2" nonce="$3" agent="$4" stage="$5" verdict="$6" issues="$7"

    case "$nonce" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
        *) return 1 ;;
    esac

    local f
    f=$(state_file "$sid" "$cwd") || return 1
    [ ! -f "$f" ] && return 1

    _with_lock "$f" _verdict_consume_and_record_inner "$f" "$nonce" "$agent" "$stage" "$verdict" "$issues"
}

_verdict_consume_and_record_inner() {
    local f="$1" nonce="$2" agent="$3" stage="$4" verdict="$5" issues="$6"
    local ts; ts=$(date +%Y-%m-%dT%H:%M:%S%z)

    local before
    before=$(jq -r --arg n "$nonce" --arg a "$agent" --arg s "$stage" '
        (.verdict_nonces[$n] // null) as $entry |
        if $entry == null then "missing"
        elif $entry.agent != $a then "wrong_agent"
        elif $entry.stage != $s then "wrong_stage"
        elif $entry.consumed != false then "already_consumed"
        else
          ((.last_cycle_id // {})[$s] // null) as $current_cid |
          ($entry.cycle_id // null) as $entry_cid |
          ((.last_cycle_at // {})[$s] // null) as $cycle_at |
          if ($current_cid != null and $entry_cid != null and $current_cid != $entry_cid) then "stale_cycle"
          elif ($cycle_at != null and $entry.issued_at < $cycle_at) then "stale_cycle"
          else "ok"
          end
        end
    ' "$f" 2>/dev/null)

    case "$before" in
        ok) ;;
        *) return 1 ;;
    esac

    # Atomic flip + record under same locked write.
    local tmp="$f.car.tmp"
    if jq --arg n "$nonce" --arg s "$stage" --arg a "$agent" \
          --arg v "$verdict" --argjson i "${issues:-0}" --arg ts "$ts" '
        .verdict_nonces[$n].consumed = true
        | .last_verdicts[$s][$a] = {verdict: $v, issues: $i, ts: $ts}
    ' "$f" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$f"
        return 0
    else
        rm -f "$tmp"
        return 1
    fi
}

_verdict_nonce_consume_inner() {
    local f="$1" nonce="$2" agent="$3"

    # Read + validate + flip within a single jq invocation against the locked file.
    # Stale-cycle defense: reject nonces whose cycle_id no longer matches
    # the current last_cycle_id[stage]. cycle_id is independent of timestamp
    # precision so same-second cycle restarts are correctly rejected.
    # Timestamp comparison is kept as a backstop for nonces issued before
    # cycle_id existed (legacy state files / no cycle_init ever called).
    local before
    before=$(jq -r --arg n "$nonce" --arg a "$agent" '
        (.verdict_nonces[$n] // null) as $entry |
        if $entry == null then "missing"
        elif $entry.agent != $a then "wrong_agent"
        elif $entry.consumed != false then "already_consumed"
        else
          ($entry.stage // null) as $st |
          ((.last_cycle_id // {})[$st] // null) as $current_cid |
          ($entry.cycle_id // null) as $entry_cid |
          ((.last_cycle_at // {})[$st] // null) as $cycle_at |
          if ($current_cid != null and $entry_cid != null and $current_cid != $entry_cid) then
            "stale_cycle"
          elif ($cycle_at != null and $entry.issued_at < $cycle_at) then
            "stale_cycle"
          else "ok"
          end
        end
    ' "$f" 2>/dev/null)

    case "$before" in
        ok) ;;
        *) return 1 ;;
    esac

    # Atomic flip — same locked write that established "ok".
    local tmp="$f.consume.tmp"
    if jq --arg n "$nonce" '.verdict_nonces[$n].consumed = true' "$f" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$f"
        return 0
    else
        rm -f "$tmp"
        return 1
    fi
}

# parse_verdict_footer: extract last SAZO verdict envelope from subagent output text.
# Robust against JSONL leak (GH #20531): only the LAST complete envelope is parsed.
# Outputs key=value lines on stdout. Fields: STATUS, NONCE, VERDICT, ISSUES.
# STATUS values:
#   ok        - envelope complete and well-formed
#   truncated - BEGIN marker found but END missing, or envelope present but missing required fields
#   missing   - no BEGIN marker found
parse_verdict_footer() {
    local text="$1"

    # Extract last complete BEGIN..END block via awk sentinel pattern.
    local envelope
    envelope=$(printf '%s\n' "$text" | awk '
        /^---SAZO_FOOTER_BEGIN---$/{ buf=""; flag=1; next }
        /^---SAZO_FOOTER_END---$/{
            if (flag) { last=buf; have=1 }
            flag=0; next
        }
        flag{ buf = buf $0 "\n" }
        END{ if (have) printf "%s", last }
    ')

    if [ -z "$envelope" ]; then
        # Distinguish truncated (BEGIN seen, no END) vs fully missing.
        if printf '%s\n' "$text" | grep -q '^---SAZO_FOOTER_BEGIN---$'; then
            printf 'STATUS=truncated\n'
            return 0
        fi
        printf 'STATUS=missing\n'
        return 0
    fi

    # Parse fields from envelope. Strict regex — anything else = malformed.
    local nonce verdict issues
    nonce=$(printf '%s\n' "$envelope" | grep -oE '^SAZO_VERDICT_NONCE: [0-9a-f]{32}$' | awk '{print $2}')
    verdict=$(printf '%s\n' "$envelope" | grep -oE '^SAZO_VERDICT: (APPROVE|BLOCK|NEEDS_REVISION)$' | awk '{print $2}')
    issues=$(printf '%s\n' "$envelope" | grep -oE '^SAZO_BLOCKING_ISSUES: [0-9]+$' | awk '{print $2}')

    if [ -z "$nonce" ] || [ -z "$verdict" ]; then
        printf 'STATUS=truncated\n'
        return 0
    fi

    printf 'STATUS=ok\nNONCE=%s\nVERDICT=%s\nISSUES=%s\n' \
        "$nonce" "$verdict" "${issues:-0}"
}

# ----- ci invalidate helpers (Plan 04) -----

# _is_doc_only_path: doc/markdown 전용 경로면 0 (skip 대상). 우선 평가 — 호출자는
# _is_doc_only_path 먼저 → true면 invalidate skip. 그래야 docs/foo.go 처럼
# 코드 확장자라도 docs 경로에 있으면 docs로 다룸 (Risk R2 완화).
#
# Codex PR #30 round 2 P2: Edit/Write payload는 absolute path. 절대 경로에서
# `*/docs/*`만 매치하면 `/home/me/docs/proj/src/foo.go` 같은 워크스페이스 상위에
# `docs` 디렉토리가 있는 경우 코드 파일도 docs로 오인되어 invalidate가 누락된다.
# 따라서 입력 경로가 absolute면 가능한 한 repo root(또는 SAZO_CWD) 기준 relative로
# 정규화 후 매칭한다. 호출자는 file_path만 넘기고 SAZO_CWD/SAZO_REPO_ROOT 환경
# 변수로 base를 추론.
_is_doc_only_path() {
    local p="$1"
    # extension은 위치 무관 — 먼저 처리.
    case "$p" in
        *.md) return 0 ;;
    esac
    # absolute path → repo root 기준 relative로 변환.
    # Codex PR #30 round 2 P2: SAZO_CWD가 repo 안의 임의 subdir(또는 repo의
    # parent)일 수 있어 SAZO_CWD를 base로 쓰면 `~/docs/proj/src/foo.go`
    # (cwd=`~`) 같은 경로가 `docs/proj/src/foo.go`로 normalize되어 docs/*에
    # 잘못 매칭됨. git rev-parse로 실제 repo root를 우선 사용한다.
    if [ "${p#/}" != "$p" ]; then
        local base="${SAZO_REPO_ROOT:-}"
        if [ -z "$base" ]; then
            # SAZO_REPO_ROOT 미지정 → SAZO_CWD에서 git repo root 추론.
            base=$(git -C "${SAZO_CWD:-.}" rev-parse --show-toplevel 2>/dev/null || true)
        fi
        if [ -z "$base" ]; then
            base="${SAZO_CWD:-}"  # 마지막 fallback
        fi
        if [ -n "$base" ] && [ -d "$base" ]; then
            local resolved_base
            resolved_base=$(cd "$base" 2>/dev/null && pwd -P) || resolved_base="$base"
            case "$p" in
                "$resolved_base"/*) p="${p#$resolved_base/}" ;;
                "$base"/*) p="${p#$base/}" ;;
                *)
                    # path가 base 밖 → 다른 repo 또는 외부 파일. 보수적으로
                    # absolute path 그대로 두면 docs/* 매칭 안 됨 → 코드 취급
                    # (invalidate). 안전 default.
                    ;;
            esac
        fi
    fi
    # relative 경로 기준 매칭 — repo root에서 출발하는 docs/* 만 doc-only로 인정.
    case "$p" in
        docs/*) return 0 ;;
        *) return 1 ;;
    esac
}

# _is_code_file: 코드/설정/lockfile 파일이면 0. _is_doc_only_path 가 먼저 평가됐다고 가정.
# Lockfile (.lock/.sum) 은 CI 영향 있어 코드 취급. README는 _is_doc_only_path가 잡음.
_is_code_file() {
    case "$1" in
        *.go|*.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.py|*.rs|*.sh) return 0 ;;
        *.bash|*.zsh|*.rb|*.java|*.kt|*.swift|*.c|*.h|*.cpp|*.hpp) return 0 ;;
        *.json|*.yml|*.yaml|*.toml|*.ini|*.lock|*.sum) return 0 ;;
        Dockerfile|*/Dockerfile|Makefile|*/Makefile) return 0 ;;
        # Codex PR #30 round 14 P2: Go module manifest (`go.mod`) is build
        # input — dependency edits change resolution and can break build
        # without touching .go sources. `go.sum` already covered by `*.sum`.
        # Same intent for other language manifests with similar coverage gap.
        go.mod|*/go.mod) return 0 ;;
        *) return 1 ;;
    esac
}

# ci_invalidate_if_code_changed <sid> <cwd> <file_path> [source]
# 호출자: PostToolUse Edit/Write/NotebookEdit, Bash git commit defense, Task preemptive.
# ci_passed_at != null 일 때만 null 로 설정 + audit log. doc-only 또는 비-code 파일은
# noop. SAZO_DISABLE_CI_INVALIDATE=1 면 전체 우회.
ci_invalidate_if_code_changed() {
    local sid="$1" cwd="$2" path="$3" src="${4:-edit}"
    [ -z "$path" ] && return 0
    if _is_doc_only_path "$path"; then
        return 0
    fi
    if ! _is_code_file "$path"; then
        return 0
    fi
    [ "${SAZO_DISABLE_CI_INVALIDATE:-0}" = "1" ] && return 0

    local cur
    cur=$(state_get "$sid" ".ci_passed_at" "$cwd")
    [ -z "$cur" ] || [ "$cur" = "null" ] && return 0

    state_set_json "$sid" ".ci_passed_at" "null" "$cwd" || return 1
    simple_audit "ci_invalidated" "src=$src" "path=$path" "sid=$sid"
}

# state_dir: return STATE_DIR value (used by hook_healthy check 3)
state_dir() {
    echo "$STATE_DIR"
}

# ci_invalidate_unconditional <sid> <cwd> <source>
# git commit / Task preemptive 처럼 file_path 가 없는 경로용. 호출자가 staged file
# 또는 subagent type 으로 이미 mutating 판정한 후 호출. ci_passed_at != null 일 때만
# 처리. SAZO_DISABLE_CI_INVALIDATE 존중.
ci_invalidate_unconditional() {
    local sid="$1" cwd="$2" src="$3"
    [ "${SAZO_DISABLE_CI_INVALIDATE:-0}" = "1" ] && return 0
    local cur
    cur=$(state_get "$sid" ".ci_passed_at" "$cwd")
    [ -z "$cur" ] || [ "$cur" = "null" ] && return 0
    state_set_json "$sid" ".ci_passed_at" "null" "$cwd" || return 1
    simple_audit "ci_invalidated" "src=$src" "sid=$sid"
}

# ----- bottom-source: child libs (bottom-source pattern; children never source parent) -----
_SAZO_LIB_DIR="${BASH_SOURCE[0]%/*}"
# shellcheck source=skip-control.sh
source "$_SAZO_LIB_DIR/skip-control.sh"
# shellcheck source=metrics.sh
source "$_SAZO_LIB_DIR/metrics.sh"
unset _SAZO_LIB_DIR
