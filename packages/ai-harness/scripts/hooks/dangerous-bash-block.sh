#!/bin/bash
# dangerous-bash-block.sh — PreToolUse Bash hook (narrow, default ON).
# Plan 10. CLAUDE.md "금지 사항" 패턴을 hook으로 hard-block.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/session-state.sh
source "$LIB_DIR/session-state.sh"

# Gate: narrow off → passthrough. 또는 SAZO_DISABLE_DANGEROUS_BLOCK=1.
if ! narrow_hooks_enabled || [ "${SAZO_DISABLE_DANGEROUS_BLOCK:-0}" = "1" ]; then
    exit 0
fi

read_hook_payload
[ -z "${SAZO_SESSION_ID:-}" ] && exit 0
[ "$SAZO_TOOL_NAME" != "Bash" ] && exit 0

cmd=$(echo "$SAZO_TOOL_INPUT" | jq -r '.command // ""')
[ -z "$cmd" ] && exit 0

# state init (migration 자동 적용 by _state_schema_upgrade)
state_init "$SAZO_SESSION_ID" "$SAZO_CWD" "${SAZO_MODEL:-unknown}"

# 8 patterns + segment split (PR #39 awk 재사용).
# 각 segment에 grep -E. 매칭 시 label 반환.
#
# Anchor prefix (patterns 1-7): 패턴을 segment 시작에 고정해 false positive 방지.
# `echo "git push --force"` 또는 `grep "rm -rf /" file` 같이 위험 패턴이
# 인자 문자열 안에 포함된 명령이 오탐되는 것을 차단.
# `^(ENV=val )*` 접두사: `GIT_DIR=x git push --force` 같은 env-prefix 명령 지원 (R7 test).
# `sudo ` 선택: `sudo git push --force` 패턴 지원.
# Pattern 8(sql_destructive)은 heredoc body 전체 대상이라 anchor 제외.
#
# _HOME_SUFFIX: single-quoted so `$HOME` is a literal ERE `$HOME` (not shell-expanded).
# Combining with double-quoted ${_ENV_PREFIX} via "${_ENV_PREFIX}...${_HOME_SUFFIX}".
_ENV_PREFIX='^([[:alpha:]_][[:alnum:]_]*=[^[:space:]]*[[:space:]]+|sudo([[:space:]]+-[a-zA-Z0-9-]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+)*'
# shellcheck disable=SC2016  # intentional: $HOME is not a shell variable here
_HOME_SUFFIX='(\$HOME(\b|/)|~(\b|/))'

check_dangerous() {
    local c="$1"
    local segments
    segments=$(printf '%s' "$c" | awk '{gsub(/&&|\|\||;|\|/, "\n"); print}')
    while IFS= read -r seg; do
        seg=$(printf '%s' "$seg" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
        [ -z "$seg" ] && continue

        # 1. git_push_force (carve-out: --force-with-lease)
        if echo "$seg" | grep -qE "${_ENV_PREFIX}git[[:space:]]+push.*(--force([[:space:]=]|$)|[[:space:]]-f([[:space:]]|$))"; then
            if ! echo "$seg" | grep -qE '\-\-force-with-lease(\b|=)'; then
                echo "git_push_force"
                return 0
            fi
        fi
        # 2. git_reset_hard_protected
        if echo "$seg" | grep -qE "${_ENV_PREFIX}git[[:space:]]+reset.*--hard.*\borigin/(main|master|dev|develop|trunk)\b"; then
            echo "git_reset_hard_protected"; return 0
        fi
        # 3. git_branch_force_delete_protected
        if echo "$seg" | grep -qE "${_ENV_PREFIX}git[[:space:]]+branch[[:space:]]+(-[a-zA-Z]*D[a-zA-Z]*|--delete[[:space:]]+--force)[[:space:]]+(main|master|dev|develop|trunk)\b"; then
            echo "git_branch_force_delete"; return 0
        fi
        # 4. git_checkout_discard (NEW — 8th pattern, v2 critic 1 fix)
        if echo "$seg" | grep -qE "${_ENV_PREFIX}git[[:space:]]+checkout[[:space:]]+--[[:space:]]+.+"; then
            echo "git_checkout_discard"; return 0
        fi
        # 5. rm_rf_root — match trailing chars (backgrounding, redirect, extra args)
        # Covers short flags (-rf, -r, -R) and GNU long option (--recursive).
        if echo "$seg" | grep -qE "${_ENV_PREFIX}rm[[:space:]]+.*(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive).*[[:space:]]+/[[:space:]]*([[:space:]]|&|\|[|>]?|>|$)"; then
            echo "rm_rf_root"; return 0
        fi
        # 6. rm_rf_home — uses _HOME_SUFFIX (single-quoted var) to keep $HOME as ERE literal
        # Covers short flags and --recursive.
        if echo "$seg" | grep -qE "${_ENV_PREFIX}rm[[:space:]]+(-[a-zA-Z]*[rRf][a-zA-Z]*|--recursive)[[:space:]]+${_HOME_SUFFIX}"; then
            echo "rm_rf_home"; return 0
        fi
        # 7. rm_rf_abs_system_path — restrict to sensitive system directories only
        # Covers short flags and --recursive.
        if echo "$seg" | grep -qE "${_ENV_PREFIX}rm[[:space:]]+.*(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive).*[[:space:]]+/(usr|etc|bin|sbin|var|opt|lib|boot|root|dev|proc|sys)([[:space:]]|/|$)"; then
            echo "rm_rf_abs_system_path"; return 0
        fi
        # 8. sql_destructive — 패턴은 segment 전체 텍스트 대상 (here-string body 포함)
        if echo "$seg" | grep -qiE '\b(DROP[[:space:]]+TABLE|DROP[[:space:]]+DATABASE|TRUNCATE[[:space:]]+TABLE)\b'; then
            echo "sql_destructive"; return 0
        fi
    done <<< "$segments"
    return 1
}

matched=$(check_dangerous "$cmd")
[ -z "$matched" ] && exit 0

# matched. nonce consume 시도.
if dangerous_nonce_consume "$SAZO_SESSION_ID" "$matched" "$SAZO_CWD"; then
    simple_audit "dangerous_override_consumed" "sid=$SAZO_SESSION_ID" "pattern=$matched" "cmd=$(printf '%s' "$cmd" | tr '\n' ' ' | head -c 200)"
    exit 0
fi

# nonce 없음 → block.
cat >&2 <<EOF
[dangerous-block] 위험 명령 차단 (pattern=$matched)
명령: $(printf '%s' "$cmd" | head -c 200)

CLAUDE.md "금지 사항" hook whitelist 매칭. 의도적이라면:
  /allow-dangerous <reason>  ← 사용자 직접 입력 (1회용 nonce)

긴급 비활성: SAZO_DISABLE_DANGEROUS_BLOCK=1 (세션 단위)
EOF
simple_audit "dangerous_blocked" "sid=$SAZO_SESSION_ID" "pattern=$matched" "cmd=$(printf '%s' "$cmd" | tr '\n' ' ' | head -c 200)"
exit 2
