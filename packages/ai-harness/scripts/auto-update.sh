#!/bin/bash

set -u

INSTALL_DIR="$HOME/.config/sazo-ai-harness"
# Support migration from old install path
if [ ! -d "$INSTALL_DIR/.git" ] && [ -d "$HOME/.config/sazo-ai-prompts/.git" ]; then
    INSTALL_DIR="$HOME/.config/sazo-ai-prompts"
fi
LOG_FILE="$HOME/.claude/logs/ai-harness-update.log"

# 테스트가 `AUTOUPDATE_LOAD_ONLY=1 source` 로 호출하는 경우엔 사이드 이펙트
# (log 디렉토리 생성, rotation)을 건너뛴다. 함수 정의만 로드해야 함.
if [ "${AUTOUPDATE_LOAD_ONLY:-0}" != "1" ]; then
    mkdir -p "$(dirname "$LOG_FILE")"
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

get_file_size() {
    stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo "0"
}

get_mtime() {
    stat -f%m "$1" 2>/dev/null || stat -c%Y "$1" 2>/dev/null || echo "0"
}

if [ "${AUTOUPDATE_LOAD_ONLY:-0}" != "1" ] \
    && [ -f "$LOG_FILE" ] \
    && [ "$(get_file_size "$LOG_FILE")" -gt 102400 ]; then
    TMP_LOG=$(mktemp)
    tail -n 100 "$LOG_FILE" > "$TMP_LOG" && mv "$TMP_LOG" "$LOG_FILE"
fi

HARNESS_DIR="$INSTALL_DIR/packages/ai-harness"
# Fallback for old path
if [ ! -d "$HARNESS_DIR" ]; then
    HARNESS_DIR="$INSTALL_DIR/packages/ai-prompts"
fi

# Permission merge must run on EVERY session start, not just after a pull.
# Users may reset ~/.claude/settings.json or add local skill permissions
# between updates, and without this re-sync, required permissions.allow
# entries aren't restored until the next repo update — causing repeated
# runtime approval prompts despite the hook firing.
#
# Defined BEFORE the early-exit guards so every exit path (missing install,
# non-main branch, local changes, rate-limit, fetch failure, normal exit)
# runs the sync before returning.
sync_skill_permissions() {
    local merge_script="$HARNESS_DIR/scripts/merge-permissions.sh"
    [ -f "$merge_script" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    # shellcheck disable=SC1090
    source "$merge_script"
    local perm_added
    perm_added=$(merge_skill_permissions "$HARNESS_DIR/skills" "$HOME/.claude/settings.json" 2>>"$LOG_FILE")
    if [ "${perm_added:-0}" -gt 0 ] 2>/dev/null; then
        log "Merged $perm_added new skill permissions into settings.allow"
    fi
}

# RTK 셋업은 install.sh가 대화형으로 초기 등록하지만, 사용자가 settings.json을
# 리셋하거나 rtk를 수동으로 재설치한 경우 hook 등록이 풀릴 수 있다.
# --quiet 모드는 opt-out 마커가 있거나 rtk 부재 시 조용히 통과하며,
# hook이 빠진 경우에만 `rtk init --auto-patch --global`로 복구한다.
#
# sync_skill_permissions와 동일하게 early-exit 가드 이전에 정의하여
# 모든 exit path에서 호출되도록 한다.
# pre-commit lint hook도 install.sh에서 최초 등록하지만, 신규 hook 도입 이전에
# 설치한 기존 팀원은 install.sh 재실행 없이 auto-update만 받는 경우가 있다.
# 매 SessionStart마다 멱등 등록으로 커버 (merge_skill_permissions와 같은 정당화).
sync_precommit_lint_hook() {
    local settings="$HOME/.claude/settings.json"
    local hook="$HARNESS_DIR/scripts/pre-commit-lint.sh"
    local detect="$HARNESS_DIR/scripts/lint-autofix-detect.sh"
    local matcher="Bash(git commit:*)"
    [ -f "$hook" ] || return 0
    [ -f "$settings" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    # rebase/머지가 mode bit을 떨어뜨릴 수 있어 매번 보장.
    chmod +x "$hook" 2>/dev/null || true
    [ -f "$detect" ] && chmod +x "$detect" 2>/dev/null || true

    local existing
    existing=$(jq --arg cmd "$hook" '
      (.hooks.PreToolUse // []) | map(select(.hooks // [] | any(.command == $cmd))) | length
    ' "$settings" 2>/dev/null) || return 0

    if [ "${existing:-0}" -gt 0 ] 2>/dev/null; then
        # 이미 등록됨. matcher 갱신은 install.sh에서만 처리(여기서 mass-migrate 지양).
        return 0
    fi

    local new_hook tmp
    new_hook=$(jq -n --arg cmd "$hook" --arg m "$matcher" '{
        "matcher": $m,
        "hooks": [{"type": "command", "command": $cmd}]
    }')
    tmp=$(mktemp)
    if jq --argjson entry "$new_hook" '.hooks.PreToolUse = (.hooks.PreToolUse // []) + [$entry]' \
        "$settings" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$settings"
        log "Registered missing PreToolUse pre-commit-lint hook"
    else
        rm -f "$tmp"
    fi
}

sync_workflow_hooks() {
    local register_script="$HARNESS_DIR/scripts/register-workflow-hooks.sh"
    local settings="$HOME/.claude/settings.json"
    [ -f "$register_script" ] || return 0
    [ -f "$settings" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    # shellcheck disable=SC1090
    source "$register_script"
    register_workflow_hooks "$HARNESS_DIR" "$settings" >>"$LOG_FILE" 2>&1 || true
}

sync_rtk_setup() {
    local rtk_setup_script="$HARNESS_DIR/scripts/setup-rtk.sh"
    [ -f "$rtk_setup_script" ] || return 0
    # opt-out fast path — 가장 흔한 경우(거부한 사용자)에 fork+exec 비용 회피.
    # 매 SessionStart마다 호출되므로 ~10ms 절감이 누적적으로 의미 있다.
    [ -f "$HOME/.config/sazo-ai-harness/.rtk-optout" ] && return 0
    # 실패는 조용히 무시 — auto-update는 noise 없이 동작해야 함
    "$rtk_setup_script" --quiet >>"$LOG_FILE" 2>&1 || true
}

# Sleep guard도 install.sh가 대화형으로 초기 등록한다. quiet 모드는 init-done
# 마커가 이미 있는 경우에만 검증/복구 (settings.json 리셋, symlink/plist 삭제
# 대응). 아직 opt-in을 안 한 사용자에게 매 세션마다 질문하지 않기 위함.
#
# opt-in 미완료 상태(init-done 마커 없음, opt-out 마커도 없음)는 기존엔
# silent-skip이었는데, install.sh에서 opt-in 프롬프트를 놓친 사용자는 아무
# 신호를 못 받고 sleep-guard가 영구 미동작 상태로 방치됨. 이를 SessionStart
# 훅 stdout으로 한 번 알려서 사용자가 대화형 설치를 시작하도록 유도한다.
# 비대화형 환경(SessionStart 훅)에서 sudoers NOPASSWD 설치는 근본적으로
# 불가하므로 자동 설치는 하지 않는다.
sync_sleep_guard() {
    local setup_script="$HARNESS_DIR/scripts/sleep-guard/setup.sh"
    [ -f "$setup_script" ] || return 0
    [ "$(uname -s)" = "Darwin" ] || return 0
    [ -f "$HOME/.config/sazo-ai-harness/.sleep-guard-optout" ] && return 0
    "$setup_script" --quiet >>"$LOG_FILE" 2>&1 || true
    notify_sleep_guard_sudoers_missing
    notify_sleep_guard_opt_in_needed
}

# opt-in 자체를 한 적이 없는 상태에 대한 안내. install.sh 첫 실행 시
# 사용자가 프롬프트에 "y"를 누르지 않았거나 비대화형 환경(e.g. Claude Code
# 내부 Bash)에서 install.sh를 돌려 프롬프트가 스킵된 케이스. init-done /
# opt-out 마커가 둘 다 없으면 "결정 보류" 상태로 간주하고 24h throttle로
# 1회씩 안내.
notify_sleep_guard_opt_in_needed() {
    [ "$(uname -s)" = "Darwin" ] || return 0
    local init_done="$HOME/.config/sazo-ai-harness/.sleep-guard-init-done"
    local optout="$HOME/.config/sazo-ai-harness/.sleep-guard-optout"
    [ -f "$init_done" ] && return 0
    [ -f "$optout" ] && return 0

    local throttle_file="$HOME/.config/sazo-ai-harness/.sleep-guard-optin-notify-throttle"
    local now last
    now="$(date +%s)"
    mkdir -p "$(dirname "$throttle_file")" 2>/dev/null || true

    # 동일 set -C O_EXCL 패턴 — sudoers missing 알림과 같은 race 처리.
    if ! ( set -C; echo "$now" > "$throttle_file" ) 2>/dev/null; then
        last="$(cat "$throttle_file" 2>/dev/null || echo 0)"
        case "$last" in ''|*[!0-9]*) last=0 ;; esac
        [ $(( now - last )) -lt 86400 ] && return 0
        echo "$now" > "$throttle_file"
    fi

    local setup_script="$HARNESS_DIR/scripts/sleep-guard/setup.sh"
    # 경로 변수 주변 큰따옴표는 사용자가 메시지를 복사해 쉘에 붙일 때 공백이
    # 섞인 HOME (e.g. /Users/Full Name)에서도 안전하게 파싱되도록 유지한다.
    cat <<EOF
ℹ️  [sleep-guard] macOS sleep 방지 기능(opt-in)이 아직 설치되지 않았습니다.
Claude Code 작업 중 노트북 뚜껑을 닫아도 sleep 되지 않게 하려면 대화형 터미널에서
  bash "$setup_script"
(sudo 비밀번호 1회 필요). 관심 없으면 안내 영구 중지:
  touch "$optout"
EOF
}

# sudoers 엔트리만 --quiet 경로로 복구할 수 없다 (sudo 비밀번호 필요).
# init-done 마커는 있는데 sudoers 파일이 사라진 경우(OS 업그레이드 후 /etc
# 일부 초기화, 수동 삭제 등) watchdog의 `sudo -n pmset`이 silent fail 하면서
# sleep-guard가 조용히 작동 중단됨. 이 상태를 SessionStart 훅의 stdout으로
# 사용자에게 알려 복구 명령을 안내. 매 세션마다 알리면 스팸이므로 24시간
# throttle.
notify_sleep_guard_sudoers_missing() {
    [ "$(uname -s)" = "Darwin" ] || return 0
    local init_done="$HOME/.config/sazo-ai-harness/.sleep-guard-init-done"
    [ -f "$init_done" ] || return 0

    # sudoers 엔트리 유효성 검사 — 2단계 fallback으로 false alarm 최소화.
    # 테스트 override: `_SLEEP_GUARD_SUDOERS_CHECK` 환경변수 ("ok" | "missing").
    #
    # 1차: `sudo -n -l` 출력에서 두 NOPASSWD 규칙 모두 확인.
    #      - watchdog은 `pmset -a disablesleep 0`과 `... 1` 양쪽을 호출하므로
    #        두 엔트리가 모두 있어야 정상. `disablesleep`만 일반 매칭하면 부분
    #        손상(1개 규칙만 남은 상태)을 ok로 오판.
    # 2차(fallback): `/etc/sudoers.d/sazo-claude-pmset-$USER` 파일 존재 확인.
    #      - sudoers `Defaults listpw=all|always` 정책 환경에선 `sudo -n -l`이
    #        인증을 요구해 실패하므로 false missing이 발생. 이 경우 파일 존재로
    #        fallback하여 false alarm 방지. macOS 기본 /etc/sudoers.d 퍼미션(0755)
    #        에서 `test -f`는 일반 사용자도 가능.
    local status="missing"
    local user_suffix="${USER:-$(id -un)}"
    local sudoers_file="/etc/sudoers.d/sazo-claude-pmset-${user_suffix}"
    if [ -n "${_SLEEP_GUARD_SUDOERS_CHECK:-}" ]; then
        status="$_SLEEP_GUARD_SUDOERS_CHECK"
    else
        local sudo_list sudo_rc
        sudo_list="$(sudo -n -l 2>/dev/null)"
        sudo_rc=$?
        if [ "$sudo_rc" -eq 0 ]; then
            # `sudo -l` 조회 성공 — 출력만 신뢰. 파일 존재해도 내용/owner/mode
            # 문제로 sudo가 무시하는 경우가 있으므로 file fallback 금지.
            if echo "$sudo_list" | grep -qE "NOPASSWD.*pmset -a disablesleep 0" \
                && echo "$sudo_list" | grep -qE "NOPASSWD.*pmset -a disablesleep 1"; then
                status="ok"
            fi
        else
            # `sudo -l` 자체 실행 불가(listpw=all|always 정책, sudo daemon 장애,
            # 일시적 권한 문제 등). 이 케이스에 한해 파일 존재로 fallback.
            [ -f "$sudoers_file" ] && status="ok"
        fi
    fi
    [ "$status" = "ok" ] && return 0

    local throttle_file="$HOME/.config/sazo-ai-harness/.sleep-guard-notify-throttle"
    local now last
    now="$(date +%s)"
    mkdir -p "$(dirname "$throttle_file")" 2>/dev/null || true

    # 단일 원자 연산으로 throttle 획득 + expired 판정을 한 번에 처리.
    # `set -C` (O_EXCL) write가 성공하면 = "파일 없었음 → 내가 첫 알림 주자".
    # 실패하면 = "파일 이미 있음"이므로 expired 여부 확인:
    #   - 24h 이내 → return 0 (다른 프로세스가 이미 최근 알림)
    #   - 24h 초과 → 덮어쓰기로 시각 갱신 후 알림. 이 만료 경로에서는 여러
    #     프로세스가 동시에 여기 도달할 수 있어 이론상 N회 출력 가능하나,
    #     auto-update는 SessionStart 훅이라 "24h 넘어간 바로 그 순간 동시 세션
    #     여러 개가 기동"하는 상황은 실질 발생하지 않아 허용 trade-off.
    # 이 구조는 신규 파일 경로의 `rm`+`set -C` 2단계 race window를 원천 제거한다.
    if ! ( set -C; echo "$now" > "$throttle_file" ) 2>/dev/null; then
        last="$(cat "$throttle_file" 2>/dev/null || echo 0)"
        case "$last" in ''|*[!0-9]*) last=0 ;; esac
        [ $(( now - last )) -lt 86400 ] && return 0
        echo "$now" > "$throttle_file"
    fi

    local setup_script="$HARNESS_DIR/scripts/sleep-guard/setup.sh"
    # user_suffix와 sudoers_file은 위에서 이미 선언됨.
    # SessionStart 훅의 stdout은 Claude 세션 컨텍스트에 주입되므로, 사용자가
    # 다음 프롬프트 응답에서 이 안내를 볼 수 있다.
    cat <<EOF
⚠️  [sleep-guard] NOPASSWD sudoers 엔트리(/etc/sudoers.d/sazo-claude-pmset-${user_suffix})가 없거나 잘못되어 pmset 제어가 작동하지 않습니다.
대화형 터미널에서 아래 명령으로 복구하세요 (sudo 비밀번호 1회 필요):
  bash $setup_script
영구 비활성화하려면: touch $HOME/.config/sazo-ai-harness/.sleep-guard-optout
EOF
}

# 테스트 전용: `AUTOUPDATE_LOAD_ONLY=1 source auto-update.sh` 로 호출하면 함수
# 정의만 로드하고 실행 본문은 건너뛴다. smoke test가 shim 복제가 아니라 실제
# 함수를 호출해 검증하기 위한 훅.
if [ "${AUTOUPDATE_LOAD_ONLY:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

if [ ! -d "$INSTALL_DIR/.git" ]; then
    log "SKIP: Not installed at $INSTALL_DIR"
    sync_skill_permissions
    sync_rtk_setup
    sync_precommit_lint_hook
    sync_workflow_hooks
    sync_sleep_guard
    exit 0
fi

cd "$INSTALL_DIR" || { log "ERROR: Cannot cd to $INSTALL_DIR"; sync_skill_permissions; sync_rtk_setup; sync_precommit_lint_hook; sync_workflow_hooks; sync_sleep_guard; exit 0; }

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ "$CURRENT_BRANCH" != "main" ]; then
    log "SKIP: Not on main branch (current: $CURRENT_BRANCH)"
    sync_skill_permissions
    sync_rtk_setup
    sync_precommit_lint_hook
    sync_workflow_hooks
    sync_sleep_guard
    exit 0
fi

if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    log "SKIP: Local changes detected"
    sync_skill_permissions
    sync_rtk_setup
    sync_precommit_lint_hook
    sync_workflow_hooks
    sync_sleep_guard
    exit 0
fi

LAST_FETCH_FILE="$INSTALL_DIR/.git/FETCH_HEAD"
if [ -f "$LAST_FETCH_FILE" ]; then
    LAST_FETCH=$(get_mtime "$LAST_FETCH_FILE")
    NOW=$(date +%s)
    DIFF=$((NOW - LAST_FETCH))
    if [ "$DIFF" -lt 3600 ]; then
        # Rate-limited from fetching, but auxiliary syncs still run.
        sync_skill_permissions
        sync_rtk_setup
        sync_precommit_lint_hook
        sync_workflow_hooks
        sync_sleep_guard
        exit 0
    fi
fi

link_new_files() {
    local source_dir="$1"
    local target_dir="$2"
    local linked=0
    
    [ -d "$source_dir" ] || { echo "0"; return 0; }
    mkdir -p "$target_dir"
    
    for file in "$source_dir"/*; do
        [ -e "$file" ] || continue
        
        local filename
        filename=$(basename "$file")
        
        [[ "$filename" == _* ]] && continue
        
        local target="$target_dir/$filename"
        
        if [ ! -e "$target" ] && [ ! -L "$target" ]; then
            ln -s "$file" "$target"
            linked=$((linked + 1))
        fi
    done
    
    echo "$linked"
}

if git fetch origin main --quiet 2>/dev/null; then
    LOCAL=$(git rev-parse HEAD)
    REMOTE=$(git rev-parse origin/main)
    
    if [ "$LOCAL" != "$REMOTE" ]; then
        LOCAL_SHORT=$(echo "$LOCAL" | cut -c1-7)
        REMOTE_SHORT=$(echo "$REMOTE" | cut -c1-7)
        log "Updating from $LOCAL_SHORT to $REMOTE_SHORT"
        if git pull --ff-only --quiet 2>/dev/null; then
            log "SUCCESS: Updated"

            CMD_LINKED=$(link_new_files "$HARNESS_DIR/commands" "$HOME/.claude/commands")
            SKILL_LINKED=$(link_new_files "$HARNESS_DIR/skills" "$HOME/.claude/skills")
            AGENT_LINKED=$(link_new_files "$HARNESS_DIR/agents" "$HOME/.claude/agents")

            TOTAL=$((CMD_LINKED + SKILL_LINKED + AGENT_LINKED))
            if [ "$TOTAL" -gt 0 ]; then
                log "Linked $TOTAL new files (commands:$CMD_LINKED skills:$SKILL_LINKED agents:$AGENT_LINKED)"
            fi

            MERGE_SCRIPT="$HARNESS_DIR/scripts/merge-claude-md.sh"
            CLAUDE_MD_SOURCE="$HARNESS_DIR/claude-md/CLAUDE.md"
            if [ -f "$MERGE_SCRIPT" ] && [ -f "$CLAUDE_MD_SOURCE" ]; then
                source "$MERGE_SCRIPT"
                if has_managed_block; then
                    replace_managed_block "$CLAUDE_MD_SOURCE"
                    log "Updated CLAUDE.md managed block"
                fi
            fi
        else
            log "WARN: Pull failed"
        fi
    fi
else
    log "WARN: Fetch failed (network or auth issue)"
fi

# Always run auxiliary syncs at the end — whether or not a pull happened,
# whether or not the fetch succeeded. This keeps settings.allow and the
# RTK hook in sync on sessions with no upstream changes.
sync_skill_permissions
sync_rtk_setup
sync_precommit_lint_hook
sync_workflow_hooks
sync_sleep_guard

exit 0
