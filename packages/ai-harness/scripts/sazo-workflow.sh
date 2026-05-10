#!/bin/bash
# sazo-workflow — CLI to inspect workflow state, history, and audit logs.
#
# Subcommands:
#   status [--session <id>] [--json]      현재 stage / 완료 시각 / soft warn / verdict
#   history [--last N] [--session <id>]   stage transition timeline
#   why-blocked [--session <id>]          최근 stage_block 사유 + 권장 action
#   audit [--last N] [--filter <event>]   audit.log 조회 (JSON Lines + freeform)
#   sessions [--days N]                   최근 N일 활성 세션 list
#   stats [--days N]                      Plan 12 promotion criteria 집계
#   recover                               degraded mode reset (Plan 05 stub)
#
# All subcommands accept --json for machine-readable output (default: human).
#
# Exit codes (per subcommand):
#   0   정상
#   1   에러 (잘못된 인자, jq/grep 실패 등)
#   2   "데이터 없음" 또는 "차단됨" (subcommand별 의미 — 표 참조)
#
# Source of truth: state file ($SAZO_STATE_DIR/$sid--$cwd_hash.json) + audit.log.

set -uo pipefail

# Resolve repo path from this script's location, then source session-state.sh.
# macOS BSD readlink 미지원 + python3 부재 환경 대응 (Codex PR #29 round 6 P2):
# 1) GNU `readlink -f` 시도 — Linux/coreutils.
# 2) 실패 시 shell loop 로 직접 symlink chain resolve — BSD/macOS 호환,
#    외부 dependency 없음. ~/.local/bin/sazo-workflow 같은 install symlink 도 정상 처리.
_resolve_script_path() {
    local target="$1"
    if command -v readlink >/dev/null 2>&1; then
        local r
        r=$(readlink -f "$target" 2>/dev/null) && [ -n "$r" ] && { printf '%s' "$r"; return 0; }
    fi
    # POSIX shell-only fallback. cd 로 디렉토리 정규화 후 basename → readlink 반복.
    local dir base link
    while [ -L "$target" ]; do
        link=$(readlink "$target" 2>/dev/null) || break
        dir=$(dirname "$target")
        case "$link" in
            /*) target="$link" ;;
            *)  target="$dir/$link" ;;
        esac
    done
    dir=$(cd "$(dirname "$target")" 2>/dev/null && pwd -P) || dir=$(dirname "$target")
    base=$(basename "$target")
    printf '%s/%s' "$dir" "$base"
}

SCRIPT_DIR="$(dirname "$(_resolve_script_path "${BASH_SOURCE[0]}")")"

LIB="$SCRIPT_DIR/hooks/lib/session-state.sh"
if [ ! -f "$LIB" ]; then
    echo "sazo-workflow: cannot find session-state.sh at $LIB" >&2
    exit 1
fi
# shellcheck source=hooks/lib/session-state.sh
source "$LIB"

JSON_MODE=0

# ----- helpers -----

# _file_mtime: print epoch mtime of $1, portable across GNU coreutils and BSD stat.
# CRITICAL: probe GNU first (`-c '%Y'`), then BSD (`-f '%m'`).
# GNU stat's `-f` means `--file-system` (multi-line filesystem info, exit 0),
# so a `stat -f '%m' || stat -c '%Y'` chain on Linux silently captures garbage
# instead of an integer and breaks every numeric comparison downstream
# (Codex P1 — `sessions` smoke fails on GNU with "integer expression expected").
_file_mtime() {
    local f="$1" mt
    mt=$(stat -c '%Y' "$f" 2>/dev/null) && [ -n "$mt" ] && { printf '%s' "$mt"; return 0; }
    mt=$(stat -f '%m' "$f" 2>/dev/null) && [ -n "$mt" ] && { printf '%s' "$mt"; return 0; }
    return 1
}

# ----- session resolution -----

list_active_sessions() {
    local since_ts now
    now=$(date +%s)
    since_ts=$((now - 86400))  # 24h
    local files
    files=$(find "$STATE_DIR" -maxdepth 1 -name '*--*.json' -type f 2>/dev/null) || return 0
    [ -z "$files" ] && return 0
    # Codex PR #29 round 8 P2: STATE_DIR 또는 user home 에 space 포함 시
    # `mtime path` row 가 awk space-split 으로 잘려 sid/path 가 깨짐.
    # delimiter 를 TAB 으로 통일 (path 에 등장 거의 없는 byte) + IFS 명시 분리.
    local rows="" tab
    tab=$(printf '\t')
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        local mt
        mt=$(_file_mtime "$f") || continue
        [ -z "$mt" ] && continue
        [ "$mt" -ge "$since_ts" ] || continue
        rows="$rows
$mt$tab$f"
    done <<EOF
$files
EOF
    printf '%s\n' "$rows" \
        | sed '/^$/d' \
        | sort -rn -k1,1 \
        | while IFS=$'\t' read -r _mt path; do
            [ -z "$path" ] && continue
            local base="${path##*/}"
            printf '%s\n' "${base%%--*}"
        done \
        | awk '!seen[$0]++'
}

# _require_arg_value: value-taking option 다음에 값이 실제로 있는지 확인.
# 인자 부재 시 stderr + rc=1. caller는 `|| return 1` 으로 escape.
# Codex PR #29 round 3 P2: `--session` 같은 옵션 뒤 값이 없을 때 `shift 2`가 실패해도
# bash가 args를 변경하지 않아 while loop가 무한 회전 (set -e 미사용 환경).
# 호출자는 shift 전에 이 helper 통과시켜야 함.
_require_arg_value() {
    local opt="$1"; shift
    if [ "$#" -lt 1 ]; then
        echo "sazo-workflow: option '$opt' requires a value" >&2
        return 1
    fi
    return 0
}

# Validate positive integer (defense-in-depth — prevents arithmetic injection
# via $days/$last reaching `date -d`, `awk` etc.).
_require_positive_int() {
    local label="$1" value="$2"
    case "$value" in
        ''|*[!0-9]*)
            echo "sazo-workflow: $label must be a positive integer, got '$value'" >&2
            return 1
            ;;
    esac
    # Codex PR #29 round 10 P2: leading-zero 전부 reject (one-shot policy).
    # - `0`/`00`/`000` (zero variants) → positive 명세 위반.
    # - `08`/`09`/`007` (non-octal-safe) → bash arithmetic `$((value * N))` 에서
    #   "value too great for base" 에러 후 호출자가 no-data 경로로 빠져
    #   bad-argument 의도가 묵살됨.
    # 정책: `^0` 매칭 = single-char `0` 이거나 leading-zero 다중 자릿수 — 모두
    # invalid. 사용자가 의도한 정수면 항상 leading zero 없이 표기 가능.
    case "$value" in
        0|0[0-9]*)
            echo "sazo-workflow: $label must be a positive integer (>= 1, no leading zeros), got '$value'" >&2
            return 1
            ;;
    esac
    return 0
}

list_active_sessions_with_days() {
    local days="${1:-1}"
    _require_positive_int "--days" "$days" || return 1
    local since_ts now
    now=$(date +%s)
    since_ts=$((now - days * 86400))
    local files
    files=$(find "$STATE_DIR" -maxdepth 1 -name '*--*.json' -type f 2>/dev/null) || return 0
    [ -z "$files" ] && return 0
    # Codex PR #29 round 8 P2: TAB delimiter (path 에 space 포함 시 안전).
    local rows="" tab
    tab=$(printf '\t')
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        local mt
        mt=$(_file_mtime "$f") || continue
        [ -z "$mt" ] && continue
        [ "$mt" -ge "$since_ts" ] || continue
        rows="$rows
$mt$tab$f"
    done <<EOF
$files
EOF
    printf '%s\n' "$rows" \
        | sed '/^$/d' \
        | sort -rn -k1,1
}

resolve_session() {
    local arg="${1:-}"
    if [ -n "$arg" ]; then
        if ls "$STATE_DIR/${arg}--"*.json >/dev/null 2>&1; then
            printf '%s' "$arg"
            return 0
        fi
        return 2
    fi
    if [ -n "${SAZO_SESSION_ID:-}" ]; then
        if ls "$STATE_DIR/${SAZO_SESSION_ID}--"*.json >/dev/null 2>&1; then
            printf '%s' "$SAZO_SESSION_ID"
            return 0
        fi
        # Codex PR #29 round 5 P2: SAZO_SESSION_ID 가 set 인데 state file 이
        # 사라졌으면 explicit miss 로 처리. fallback 으로 다른 사용자/세션의
        # 활성 state 를 surface 하면 안 됨 (cross-session leak).
        return 2
    fi
    local sessions count
    sessions=$(list_active_sessions)
    if [ -z "$sessions" ]; then
        return 2
    fi
    count=$(printf '%s\n' "$sessions" | wc -l | tr -d ' ')
    case "$count" in
        1) printf '%s' "$sessions"; return 0;;
        *)
            echo "Multiple active sessions detected (last 24h):" >&2
            printf '%s\n' "$sessions" | head -5 >&2
            echo "Using most recent (mtime). Specify --session <id> to disambiguate." >&2
            printf '%s' "$sessions" | head -1
            return 0
            ;;
    esac
}

resolve_state_file() {
    local sid="$1"
    local files
    files=$(ls "$STATE_DIR/${sid}--"*.json 2>/dev/null) || return 1
    [ -z "$files" ] && return 1
    local count
    count=$(printf '%s\n' "$files" | wc -l | tr -d ' ')
    if [ "$count" = "1" ]; then
        printf '%s' "$files"
        return 0
    fi
    local newest=""
    local newest_mt=0
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        local mt
        mt=$(_file_mtime "$f") || continue
        if [ "$mt" -gt "$newest_mt" ]; then
            newest_mt="$mt"
            newest="$f"
        fi
    done <<EOF
$files
EOF
    echo "Multiple state files for session $sid (different cwd). Using newest." >&2
    printf '%s' "$newest"
}

# ----- subcommands -----

cmd_status() {
    local sid_arg=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --session) shift; _require_arg_value "--session" "$@" || return 1; sid_arg="$1"; shift;;
            --json) JSON_MODE=1; shift;;
            *) shift;;
        esac
    done
    local sid
    sid=$(resolve_session "$sid_arg") || return 2
    local sf
    sf=$(resolve_state_file "$sid") || return 2

    if [ "$JSON_MODE" = "1" ]; then
        cat "$sf"
        return 0
    fi

    cat <<EOF
Session: $sid
State file: $sf

Stage: $(jq -r '.stage // "—"' "$sf")
Started at: $(jq -r '.started_at // "—"' "$sf")
Plan approved at: $(jq -r '.plan_approved_at // "—"' "$sf")
CI passed at: $(jq -r '.ci_passed_at // "—"' "$sf")

History (last 10):
EOF
    jq -r '.history // [] | .[-10:][] | "  \(.ts) \(.stage) \(.status) by=\(.by) reason=\(.reason)"' "$sf"

    echo ""
    echo "Soft warn counts:"
    local warn_lines
    warn_lines=$(jq -r 'to_entries[] | select(.key | startswith("soft_warn_count_")) | "  \(.key | sub("soft_warn_count_"; "")): \(.value)"' "$sf" 2>/dev/null)
    if [ -z "$warn_lines" ]; then
        echo "  (none)"
    else
        printf '%s\n' "$warn_lines"
    fi

    echo ""
    echo "Verdict missing counts:"
    local vm_lines
    vm_lines=$(jq -r '.verdict_missing_count // {} | to_entries[] | "  \(.key): \(.value)"' "$sf" 2>/dev/null)
    if [ -z "$vm_lines" ]; then
        echo "  (none)"
    else
        printf '%s\n' "$vm_lines"
    fi

    echo ""
    echo "Active reviewers expected (review):"
    local exp
    exp=$(jq -r '.review_expected_set // [] | join(", ")' "$sf" 2>/dev/null)
    if [ -z "$exp" ]; then
        echo "  (none)"
    else
        echo "  $exp"
    fi

    return 0
}

cmd_history() {
    local sid_arg="" last=20
    while [ $# -gt 0 ]; do
        case "$1" in
            --session) shift; _require_arg_value "--session" "$@" || return 1; sid_arg="$1"; shift;;
            --last) shift; _require_arg_value "--last" "$@" || return 1; last="$1"; shift;;
            --json) JSON_MODE=1; shift;;
            *) shift;;
        esac
    done
    # Codex PR #29 round 4 P2: jq --argjson 에 비숫자 입력하면 에러를 stderr로 뱉지만
    # set -e 미사용이라 함수는 0 으로 종료해 자동화가 "성공인데 출력 없음" 으로 오인.
    # 다른 numeric subcommand 처럼 _require_positive_int 로 사전 검증.
    _require_positive_int "--last" "$last" || return 1
    local sid
    sid=$(resolve_session "$sid_arg") || return 2
    local sf
    sf=$(resolve_state_file "$sid") || return 2

    if [ "$JSON_MODE" = "1" ]; then
        jq --argjson n "$last" '.history // [] | .[-$n:]' "$sf"
        return 0
    fi
    jq -r --argjson n "$last" '.history // [] | .[-$n:][] | "\(.ts) \(.stage) \(.status) by=\(.by) reason=\(.reason)"' "$sf"
    return 0
}

cmd_why_blocked() {
    local sid_arg=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --session) shift; _require_arg_value "--session" "$@" || return 1; sid_arg="$1"; shift;;
            --json) JSON_MODE=1; shift;;
            *) shift;;
        esac
    done
    [ -f "$AUDIT_LOG" ] || {
        if [ "$JSON_MODE" = "1" ]; then
            echo '{"blocked":false}'
        else
            echo "Not blocked."
        fi
        return 0
    }

    # Session scoping policy (Codex PR #29 round 2 P2):
    #   - explicit --session <id>: ALWAYS scope to that id (resolve_session 실패해도
    #     `$sid_arg`로 raw filter). 다른 세션의 블록을 surfacing하면 안 됨.
    #     state file이 사라졌어도 audit.log엔 과거 stage_block이 남아있을 수 있다.
    #   - implicit (no --session): 환경/단일 활성 세션으로 resolve. 실패하면
    #     글로벌 fallback (기존 동작 유지).
    local sid
    if [ -n "$sid_arg" ]; then
        sid="$sid_arg"
    else
        sid=$(resolve_session "" 2>/dev/null) || sid=""
    fi

    # Codex PR #29 round 13 P2: grep | tail 단독으론 truncated JSONL 라인이 매칭 +
    # 마지막일 때 raw byte 가 emit 되어 `--json` 결과가 invalid. audit/stats 의
    # `fromjson?` 패턴과 통일 — grep 은 후보 좁히기로만 쓰고 jq 가 valid 라인만 통과.
    # `--arg sid "$sid"` 로 사용자 입력을 안전 전달 (regex meta 영향 없음).
    local last_block
    if [ -n "$sid" ]; then
        # 1차 grep 으로 stage_block 라인 좁힌 뒤, jq 가 parse + sid 정확 매칭 +
        # 마지막 라인 픽업. malformed/missing-sid 라인은 자동 drop.
        last_block=$(grep '"event":"stage_block"' "$AUDIT_LOG" 2>/dev/null \
            | jq -cR --arg sid "$sid" \
                'fromjson? | select(. != null and .sid == $sid)' 2>/dev/null \
            | tail -1)
    else
        last_block=$(grep '"event":"stage_block"' "$AUDIT_LOG" 2>/dev/null \
            | jq -cR 'fromjson? | select(. != null)' 2>/dev/null \
            | tail -1)
    fi

    if [ -z "$last_block" ]; then
        if [ "$JSON_MODE" = "1" ]; then
            echo '{"blocked":false}'
        else
            echo "Not blocked."
        fi
        return 0
    fi

    if [ "$JSON_MODE" = "1" ]; then
        printf '%s\n' "$last_block"
        return 2
    fi

    local stage reason ts
    stage=$(printf '%s' "$last_block" | jq -r '.stage // "—"' 2>/dev/null)
    reason=$(printf '%s' "$last_block" | jq -r '.reason // "—"' 2>/dev/null)
    ts=$(printf '%s' "$last_block" | jq -r '.ts // "—"' 2>/dev/null)

    cat <<EOF
Blocked at stage: $stage
Time: $ts
Reason: $reason

EOF
    case "$stage" in
        research)
            echo "To proceed: invoke code-searcher or docs-researcher subagent (Task)."
            ;;
        plan)
            echo "To proceed: invoke plan-drafter subagent (Task) and produce a plan."
            ;;
        approval)
            echo "To proceed: get user approval, user types '/approved'."
            ;;
        ci)
            echo "To proceed: run project CI command (per CLAUDE.md) until exit 0."
            ;;
        review)
            echo "To proceed: invoke code-reviewer (and architect-advisor if needed) Task with verdict APPROVE."
            ;;
        *)
            echo "To proceed: complete stage '$stage' before retrying."
            ;;
    esac
    return 2
}

cmd_audit() {
    local last=50 filter=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --last) shift; _require_arg_value "--last" "$@" || return 1; last="$1"; shift;;
            --filter) shift; _require_arg_value "--filter" "$@" || return 1; filter="$1"; shift;;
            --json) JSON_MODE=1; shift;;
            *) shift;;
        esac
    done
    _require_positive_int "--last" "$last" || return 1
    [ -f "$AUDIT_LOG" ] || return 2
    local lines
    lines=$(tail -n "$last" "$AUDIT_LOG")
    [ -z "$lines" ] && return 2

    if [ -n "$filter" ]; then
        # JSON entries: filter by event field; freeform: substring match.
        lines=$(printf '%s\n' "$lines" | awk -v f="$filter" '
            /^\{/ {
                if (index($0, "\"event\":\"" f "\"") > 0) print
                next
            }
            { if (index($0, f) > 0) print }
        ')
    fi

    if [ -z "$lines" ]; then
        return 2
    fi

    if [ "$JSON_MODE" = "1" ]; then
        # Codex PR #29 round 12 P2: prefix-only filter (`grep '^{'`) emits
        # truncated/malformed lines too → automation piping `audit --json | jq`
        # parse-fails despite rc=0. Validate per-line via `fromjson?`.
        # `?` swallows parse errors → null → `select(. != null)` drops.
        # `-c` keeps single-line per record. emit count check via wc -l.
        local out
        out=$(printf '%s\n' "$lines" | grep '^{' \
            | jq -cR 'fromjson? | select(. != null)' 2>/dev/null)
        if [ -z "$out" ]; then
            return 2
        fi
        printf '%s\n' "$out"
        return 0
    fi
    printf '%s\n' "$lines"
    return 0
}

cmd_sessions() {
    local days=7
    while [ $# -gt 0 ]; do
        case "$1" in
            --days) shift; _require_arg_value "--days" "$@" || return 1; days="$1"; shift;;
            --json) JSON_MODE=1; shift;;
            *) shift;;
        esac
    done
    _require_positive_int "--days" "$days" || return 1
    local rows
    rows=$(list_active_sessions_with_days "$days")
    if [ -z "$rows" ]; then
        return 2
    fi
    # Codex PR #29 round 8 P2: TAB delimiter (path 안 space 보호).
    if [ "$JSON_MODE" = "1" ]; then
        # Gemini PR #29 round 10 P2: awk 수동 escape → jq -R 슬러프로 변경.
        # awk gsub 으로 `\` / `"` 만 escape 하면 path 에 control character (NUL 외
        # \b, \f, \n, \r, \t 등) 가 들어올 때 raw byte 가 그대로 emit 되어 JSON spec
        # 위반(파서가 자동 복원도 못 함). jq -R 가 line 을 string 으로 받아 모든 JSON
        # spec escape 를 자동 처리.
        # 입력: TAB 구분 `mtime\tpath` 라인. jq 내부에서 split → base → sid/cwd_hash 분해.
        printf '%s\n' "$rows" | jq -Rc '
            select(length > 0) |
            split("\t") as $p |
            ($p[1] | split("/") | last | sub("\\.json$"; "") | split("--")) as $id |
            {sid: $id[0], cwd_hash: $id[1], mtime: ($p[0] | tonumber), path: $p[1]}
        '
        return 0
    fi
    printf '%s\n' "$rows" | awk -F'\t' '{
        mt=$1; path=$2;
        n=split(path,parts,"/"); base=parts[n];
        sub(/\.json$/, "", base);
        split(base, sb, "--");
        sid=sb[1]; cwd_hash=sb[2];
        cmd="date -r " mt " +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || date -d @" mt " +%Y-%m-%dT%H:%M:%S%z 2>/dev/null"
        cmd | getline ts; close(cmd)
        printf "%s  sid=%s  cwd_hash=%s  state=%s\n", ts, sid, cwd_hash, path
    }'
    return 0
}

cmd_stats() {
    local days=30
    while [ $# -gt 0 ]; do
        case "$1" in
            --days) shift; _require_arg_value "--days" "$@" || return 1; days="$1"; shift;;
            --json) JSON_MODE=1; shift;;
            *) shift;;
        esac
    done
    _require_positive_int "--days" "$days" || return 1

    local since=""
    since=$(date -d "$days days ago" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null) \
        || since=$(date -v"-${days}d" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null) \
        || since=""

    # Codex PR #29 round 11 P2: 단일 jq invocation 으로 stream 처리 시 한 줄이라도
    # malformed JSON 이면 jq rc≠0 → `|| entries=""` 가 valid 라인까지 전부 폐기.
    # truncated append + 후속 valid JSONL 시나리오에서 stage_block count=0 으로 보고.
    # 해결: line-by-line 평가 (`-cR fromjson?`) — `?` operator 가 parse 실패 라인을
    # null 로 만들고 `select(. != null)` 로 drop. jq 단일 호출 유지하면서 robust.
    local entries=""
    if [ -f "$AUDIT_LOG" ]; then
        if [ -n "$since" ]; then
            entries=$(grep -h '^{' "$AUDIT_LOG" 2>/dev/null \
                | jq -cR --arg since "$since" \
                    'fromjson? | select(. != null and (.ts // "") >= $since)' \
                    2>/dev/null) || entries=""
        else
            entries=$(grep -h '^{' "$AUDIT_LOG" 2>/dev/null \
                | jq -cR 'fromjson? | select(. != null)' 2>/dev/null) || entries=""
        fi
    fi

    # `grep -c` returns rc=1 when 0 matches, which would trigger `|| echo 0`
    # AND emit grep's own "0" → "0\n0" string corrupting numeric comparisons
    # downstream. Use explicit count function that always emits a single
    # integer line.
    _count_pattern() {
        local pat="$1" file="$2"
        [ -f "$file" ] || { printf '0'; return 0; }
        local n
        n=$(grep -c "$pat" "$file" 2>/dev/null) || n=0
        # Strip newlines/whitespace, default to 0 on non-numeric.
        n=$(printf '%s' "$n" | tr -d '[:space:]')
        case "$n" in
            ''|*[!0-9]*) printf '0' ;;
            *) printf '%s' "$n" ;;
        esac
    }

    local total_blocks=0 lock_timeouts=0 jq_errors=0 verdict_missing=0 state_corruptions=0
    if [ -n "$entries" ]; then
        local n
        n=$(printf '%s\n' "$entries" | grep -c '"event":"stage_block"') || n=0
        n=$(printf '%s' "$n" | tr -d '[:space:]')
        case "$n" in ''|*[!0-9]*) n=0 ;; esac
        total_blocks="$n"
    fi
    lock_timeouts=$(_count_pattern 'lock_timeout' "$AUDIT_LOG")
    jq_errors=$(_count_pattern 'jq_error' "$AUDIT_LOG")
    verdict_missing=$(_count_pattern 'verdict_missing' "$AUDIT_LOG")
    state_corruptions=$(_count_pattern 'state_corruption' "$AUDIT_LOG")

    # Gemini PR #29 round 10 P2: 다중 state file 마다 jq 프로세스 spawn → 단일 호출 합산.
    # `*.json` no-match 시 glob literal 이 jq 인자로 들어가 stat error 가 stderr 로 새므로
    # 2>/dev/null 로 silence. awk 가 빈 입력에서도 `s+0`=0 emit.
    local verdict_unset
    verdict_unset=$(jq -r '.verdict_unset_expected_set_count // 0' \
        "$STATE_DIR"/*.json 2>/dev/null \
        | awk '{s+=$1} END {print s+0}')
    case "$verdict_unset" in
        ''|*[!0-9]*) verdict_unset=0 ;;
    esac

    local top_stage="—"
    if [ -n "$entries" ]; then
        top_stage=$(printf '%s\n' "$entries" \
            | jq -r 'select(.event=="stage_block") | .stage // empty' 2>/dev/null \
            | sort | uniq -c | sort -rn | head -1 | awk '{if (NF>=2) print $2 " (" $1 ")"}')
        [ -z "$top_stage" ] && top_stage="—"
    fi

    local promotion="not_met"
    if [ "$state_corruptions" -eq 0 ] \
        && [ "$lock_timeouts" -lt 5 ] \
        && [ "$jq_errors" -lt 5 ] \
        && [ "$verdict_unset" -lt 10 ]; then
        promotion="numeric_met"
    fi

    if [ "$JSON_MODE" = "1" ]; then
        jq -nc \
            --argjson days "$days" \
            --argjson total_blocks "$total_blocks" \
            --argjson state_corruptions "$state_corruptions" \
            --argjson lock_timeouts "$lock_timeouts" \
            --argjson jq_errors "$jq_errors" \
            --argjson verdict_unset "$verdict_unset" \
            --argjson verdict_missing "$verdict_missing" \
            --arg top_stage "$top_stage" \
            --arg promotion "$promotion" \
            '{days:$days, total_blocks:$total_blocks, top_stage:$top_stage,
              cumulative:{state_corruption_count:$state_corruptions,
                          lock_timeout_count:$lock_timeouts,
                          jq_error_count:$jq_errors,
                          verdict_unset_expected_set_count:$verdict_unset,
                          verdict_missing_count:$verdict_missing},
              promotion:$promotion}'
    else
        cat <<EOF
Stats (last $days days):
  Total stage_block events: $total_blocks
  Most blocked stage: $top_stage

Cumulative (Plan 12 promotion criteria):
  state_corruption_count:        $state_corruptions  (target == 0)
  lock_timeout_count:            $lock_timeouts  (target < 5)
  jq_error_count:                $jq_errors  (target < 5)
  verdict_unset_expected_set:    $verdict_unset  (target < 10)
  verdict_missing_count:         $verdict_missing  (informational)

EOF
        if [ "$promotion" = "numeric_met" ]; then
            cat <<EOF
[OK] Phase 2 promotion: all numeric criteria met.
     (Time criteria — 14일 dogfood — manual check)
EOF
        else
            echo "[--] Phase 2 promotion: numeric criteria NOT met yet."
        fi
    fi

    # Codex PR #29 round 5 P2: no-data 판정에 state-derived metric 도 포함.
    # `entries`/`lock_timeouts`/`jq_errors` 만 검사하면 audit.log 가 비어도 state
    # file 에서 verdict_unset/state_corruption/verdict_missing 가 nonzero 일 때
    # 의미 있는 stats 결과가 출력되었는데 exit 2 ("no analyzable data") 로
    # 분류되어 자동화가 결과를 무시함. 표시되는 모든 metric 이 0 일 때만 no-data.
    if [ -z "$entries" ] \
        && [ "$lock_timeouts" -eq 0 ] \
        && [ "$jq_errors" -eq 0 ] \
        && [ "$state_corruptions" -eq 0 ] \
        && [ "$verdict_unset" -eq 0 ] \
        && [ "$verdict_missing" -eq 0 ]; then
        return 2
    fi
    return 0
}

cmd_recover() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) JSON_MODE=1; shift;;
            *) shift;;
        esac
    done
    # Plan 05 stub: degraded marker file does not yet exist. Real recovery
    # logic lands with state-corruption recovery plan.
    local marker="$STATE_DIR/.degraded"
    if [ ! -f "$marker" ]; then
        if [ "$JSON_MODE" = "1" ]; then
            echo '{"degraded":false}'
        else
            echo "No degraded state to recover (Plan 05 marker absent)."
        fi
        return 2
    fi
    rm -f "$marker"
    audit_log "recovery_acknowledged" "" "" "" "user" "manual recover"
    if [ "$JSON_MODE" = "1" ]; then
        echo '{"degraded":false,"recovered":true}'
    else
        echo "Degraded marker cleared."
    fi
    return 0
}

usage() {
    cat <<'EOF'
Usage: sazo-workflow <subcommand> [options]

Subcommands:
  status [--session <id>] [--json]              Show current session state.
  history [--last N] [--session <id>] [--json]  Show stage transition timeline.
  why-blocked [--session <id>] [--json]         Show last block reason + next action.
  audit [--last N] [--filter <event>] [--json]  Show audit.log entries.
  sessions [--days N] [--json]                  List recent active sessions.
  stats [--days N] [--json]                     Aggregated metrics + promotion check.
  recover [--json]                              Reset degraded mode (Plan 05).

Environment:
  SAZO_STATE_DIR  Override state directory (default: ~/.claude/session-state).
  SAZO_SESSION_ID Pre-select session id (overridden by --session).

Exit codes:
  0  ok
  1  error (bad args, missing tools)
  2  no data, blocked, or session not found
EOF
}

# ----- main -----

main() {
    local sub="${1:-}"
    [ -n "$sub" ] || { usage; exit 1; }
    shift
    case "$sub" in
        status)       cmd_status "$@";;
        history)      cmd_history "$@";;
        why-blocked)  cmd_why_blocked "$@";;
        audit)        cmd_audit "$@";;
        sessions)     cmd_sessions "$@";;
        stats)        cmd_stats "$@";;
        recover)      cmd_recover "$@";;
        -h|--help|help) usage; exit 0;;
        *) echo "sazo-workflow: unknown subcommand '$sub'" >&2; usage; exit 1;;
    esac
}

main "$@"
