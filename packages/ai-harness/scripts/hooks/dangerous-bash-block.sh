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

cmd=$(printf '%s\n' "$SAZO_TOOL_INPUT" | jq -r '.command // ""')
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
# Use POSIX ERE char classes instead of \b (not portable on BSD/macOS grep).
_HOME_SUFFIX='(\$HOME([[:space:]/&>]|$)|~([[:space:]/&>]|$))'

check_dangerous() {
    local c="$1"
    local segments
    # Pre-process: join backslash-continued lines (e.g. "rm -rf \<newline>/")
    # before splitting on shell operators, to prevent bypass via line continuation.
    # Uses awk (BSD+GNU portable) to join lines ending with `\`; sed ':a;N;$!ba'
    # is BSD-incompatible (N fails on last line, silences output).
    local joined
    joined=$(printf '%s' "$c" \
        | awk '{if (/\\$/) {sub(/\\$/, ""); printf "%s", $0} else {print}}')

    # 8-pre. sql_destructive_pipe — whole-command check for SQL piped into a client.
    # `printf 'DROP TABLE;' | psql` splits into benign segments per-segment,
    # but the pipeline as a whole executes destructive SQL. Check the joined command
    # for: SQL keyword present AND a SQL client appears in a pipe-RHS segment.
    # SQL clients: psql, mysql, mysql5, mariadb, sqlite3, cockroach, pgcli, mycli.
    # Wrapped invocations supported (R13/R14):
    #   `| sudo -u postgres psql`    — sudo prefix
    #   `| PGPASS=x psql`            — bare env-var prefix
    #   `| env PGPASS=x psql`        — env(1) wrapper (R14: Codex P2 fix)
    #   `| env -i PGPASS=x psql`     — env with options
    #   `| env --ignore-environment PGPASS=x psql`  — env long option
    _SQL_CLIENT_RE='(psql|mysql[0-9]*|mariadb|sqlite3|cockroach|pgcli|mycli)'
    # _SQL_CLIENT_PREFIX: bare-VAR= prefix, sudo prefix, or env(1) prefix (with optional flags and VAR= args)
    _SQL_CLIENT_PREFIX='([[:alpha:]_][[:alnum:]_]*=[^[:space:]]*[[:space:]]+|sudo([[:space:]]+-[a-zA-Z0-9-]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+|env([[:space:]]+-[a-zA-Z][a-zA-Z0-9-]*([=[:space:]][^[:space:]]*)?)*([[:space:]]+[[:alpha:]_][[:alnum:]_]*=[^[:space:]]*)*[[:space:]]+)*'
    _SQL_CLIENT_WRAPPED='\|[[:space:]]*'"${_SQL_CLIENT_PREFIX}${_SQL_CLIENT_RE}"'([[:space:]]|$)'
    if printf '%s' "$joined" | grep -qiE '(DROP[[:space:]]+TABLE|DROP[[:space:]]+DATABASE|TRUNCATE[[:space:]]+TABLE)'; then
        if printf '%s' "$joined" | grep -qE "${_SQL_CLIENT_WRAPPED}"; then
            echo "sql_destructive"; return 0
        fi
    fi

    segments=$(printf '%s' "$joined" \
        | awk '{gsub(/&&|\|\||;|\|/, "\n"); print}')
    while IFS= read -r seg; do
        seg=$(printf '%s' "$seg" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
        [ -z "$seg" ] && continue

        # _GIT_GLOBAL_OPTS: optional git global options between `git` and the subcommand.
        # Covers `git -C <path> push --force`, `git -c key=val push`, `git --no-pager push`,
        # etc. Each option group: single-char flag with optional arg, or long flag.
        # R13: added to cover `git -C /repo push --force` and similar bypass attempts.
        _GIT_GLOBAL_OPTS='([[:space:]]+(-[a-zA-Z]([[:space:]]+[^-[:space:]][^[:space:]]*)?|--[a-zA-Z][a-zA-Z0-9-]*(=[^[:space:]]*|[[:space:]]+[^-[:space:]][^[:space:]]*)?))*'

        # 1. git_push_force
        # The outer ERE already excludes --force-with-lease by requiring --force
        # to be followed by space/=/EOL/redirect/background — so --force-with-lease
        # (no space after --force) does not match. The previous inner carve-out was
        # removed because it allowed `git push --force-with-lease --force` through.
        # R13: _GIT_GLOBAL_OPTS allows global flags between `git` and `push`.
        if echo "$seg" | grep -qE "${_ENV_PREFIX}git${_GIT_GLOBAL_OPTS}[[:space:]]+push.*(--force([[:space:]=]|&|>|$)|[[:space:]]-f([[:space:]]|&|>|$))"; then
            echo "git_push_force"; return 0
        fi
        # 2. git_reset_hard_protected
        # Use explicit terminators instead of \b to avoid false positives on branch
        # names like origin/main-feature (\b matches between 'n' and '-').
        # R13: _GIT_GLOBAL_OPTS allows global flags between `git` and `reset`.
        if echo "$seg" | grep -qE "${_ENV_PREFIX}git${_GIT_GLOBAL_OPTS}[[:space:]]+reset.*--hard.*[[:space:]]origin/(main|master|dev|develop|trunk)([[:space:]]|&|>|$)"; then
            echo "git_reset_hard_protected"; return 0
        fi
        # 3. git_branch_force_delete_protected
        # Use explicit terminators instead of \b (same false-positive risk as pattern 2).
        # R13: added split-flag forms: `-d -f`, `-d --force`, `--delete --force`, `-Df` etc.
        # `git branch -d -f main` is equivalent to `git branch -D main` (git documents this).
        # Pattern covers both combined (-D) and split (-d + -f or --force) flag forms.
        _GBD_FLAGS='(-[a-zA-Z]*D[a-zA-Z]*|(-[a-zA-Z]*d[a-zA-Z]*[[:space:]].*(--force|-[a-zA-Z]*f)|(-[a-zA-Z]*f[a-zA-Z]*[[:space:]].*|--force[[:space:]].*)-[a-zA-Z]*d|(--delete[[:space:]].*--force|--force[[:space:]].*--delete)))'
        if echo "$seg" | grep -qE "${_ENV_PREFIX}git${_GIT_GLOBAL_OPTS}[[:space:]]+branch[[:space:]]+${_GBD_FLAGS}[[:space:]]+(.*[[:space:]]+)?(main|master|dev|develop|trunk)([[:space:]]|&|>|$)"; then
            echo "git_branch_force_delete"; return 0
        fi
        # 4. git_checkout_discard — covers `git checkout -- .` and `git checkout .`
        # `--` is optional: LLMs often omit it (e.g. `git checkout .` to discard all).
        # Boundary ([[:space:]]|&|>|/|$) ensures only literal `.` (cwd) is matched,
        # not arbitrary dotfiles like `git checkout .gitignore` or `git checkout file.txt`.
        # R13: _GIT_GLOBAL_OPTS allows global flags between `git` and `checkout`.
        if echo "$seg" | grep -qE "${_ENV_PREFIX}git${_GIT_GLOBAL_OPTS}[[:space:]]+checkout[[:space:]]+(--[[:space:]]+)?\\.([[:space:]]|&|>|/|$)"; then
            echo "git_checkout_discard"; return 0
        fi
        # _RM_RECURSIVE_FLAG: matches short or long recursive flag, usable standalone.
        _RM_RECURSIVE_FLAG='(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)'

        # 5. rm_rf_root — match root `/` and root globs (`/*`, `/**`).
        # Covers short flags (-rf, -r, -R) and GNU long option (--recursive).
        # Trailing group includes `&`, `>`, `/`, `*` to catch:
        #   rm -rf / /tmp  (multi-path), rm -rf />file (redirect),
        #   rm -rf /*      (root glob contents).
        # R13: also matches flag-after-path form (rm /* -r, rm / -rf).
        # Form A: recursive flag before path (original):  rm .* -r .* /
        # Form B: path directly after rm, recursive flag after: rm[space]/<boundary> .* -r
        if echo "$seg" | grep -qE "${_ENV_PREFIX}rm[[:space:]]+.*${_RM_RECURSIVE_FLAG}.*[[:space:]]+/[[:space:]]*([[:space:]]|&|>|/|\*|$)"; then
            echo "rm_rf_root"; return 0
        fi
        if echo "$seg" | grep -qE "${_ENV_PREFIX}rm[[:space:]]+(.*[[:space:]]+)?/[[:space:]]*([[:space:]]|&|>|/|\*|$).*${_RM_RECURSIVE_FLAG}"; then
            echo "rm_rf_root"; return 0
        fi
        # 6. rm_rf_home — uses _HOME_SUFFIX (single-quoted var) to keep $HOME as ERE literal
        # Covers short flags and --recursive. Uses .*(-r|--recursive).* to allow
        # interleaved options (e.g. rm -v -rf ~/, rm -f -r ~) consistent with
        # rm_rf_root/rm_rf_abs_system_path. The `.*` before the recursive flag spans
        # interleaved flags like `-f` so `rm -f -r ~` and `rm --force --recursive $HOME`
        # are both caught.
        # R13: also matches flag-after-path form (rm $HOME -r, rm ~ -rf).
        if echo "$seg" | grep -qE "${_ENV_PREFIX}rm[[:space:]]+.*${_RM_RECURSIVE_FLAG}.*[[:space:]]+${_HOME_SUFFIX}"; then
            echo "rm_rf_home"; return 0
        fi
        if echo "$seg" | grep -qE "${_ENV_PREFIX}rm[[:space:]]+(.*[[:space:]]+)?${_HOME_SUFFIX}.*${_RM_RECURSIVE_FLAG}"; then
            echo "rm_rf_home"; return 0
        fi
        # 7. rm_rf_abs_system_path — restrict to sensitive system directories only.
        # Covers short flags and --recursive. Trailing boundary includes `&` and `>`
        # to catch redirection/backgrounding bypasses (`rm -rf /usr>file`, `rm -rf /usr&`).
        # R13: also matches flag-after-path form (rm /usr -r, rm /etc -rf).
        if echo "$seg" | grep -qE "${_ENV_PREFIX}rm[[:space:]]+.*${_RM_RECURSIVE_FLAG}.*[[:space:]]+/(usr|etc|bin|sbin|var|opt|lib|boot|root|dev|proc|sys)([[:space:]]|&|>|/|$)"; then
            echo "rm_rf_abs_system_path"; return 0
        fi
        if echo "$seg" | grep -qE "${_ENV_PREFIX}rm[[:space:]]+(.*[[:space:]]+)?/(usr|etc|bin|sbin|var|opt|lib|boot|root|dev|proc|sys)([[:space:]]|&|>|/|$).*${_RM_RECURSIVE_FLAG}"; then
            echo "rm_rf_abs_system_path"; return 0
        fi
        # 8. sql_destructive — 패턴은 segment 전체 텍스트 대상 (here-string body 포함)
        # Use portable word-boundary simulation: ([^[:alnum:]_]|^) and ([^[:alnum:]_]|$)
        # instead of \b which is not POSIX ERE and fails on BSD grep (macOS).
        #
        # False-positive guard: skip segments whose first token is a safe search/output
        # command (echo, grep, cat, printf, rg, etc.) — these contain SQL keywords as
        # string arguments, not actual execution. This preserves `psql -c "DROP TABLE"`
        # and here-string paths while avoiding `grep "DROP TABLE" file.sql` false positives.
        if echo "$seg" | grep -qiE '(^|[^[:alnum:]_])(DROP[[:space:]]+TABLE|DROP[[:space:]]+DATABASE|TRUNCATE[[:space:]]+TABLE)([^[:alnum:]_]|$)'; then
            # Carve-out: first token is a benign search/output command → skip.
            _first_tok=$(printf '%s' "$seg" | awk '{print $1}')
            case "$_first_tok" in
                echo|printf|cat|head|tail|grep|rg|ripgrep|sed|awk|less|more|bat|hexdump) ;;
                *) echo "sql_destructive"; return 0 ;;
            esac
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
