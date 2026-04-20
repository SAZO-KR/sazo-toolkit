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
sync_sleep_guard() {
    local setup_script="$HARNESS_DIR/scripts/sleep-guard/setup.sh"
    [ -f "$setup_script" ] || return 0
    [ "$(uname -s)" = "Darwin" ] || return 0
    [ -f "$HOME/.config/sazo-ai-harness/.sleep-guard-optout" ] && return 0
    "$setup_script" --quiet >>"$LOG_FILE" 2>&1 || true
    notify_sleep_guard_sudoers_missing
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

    # sudoers 엔트리 유효성 검사.
    # 테스트 override: `_SLEEP_GUARD_SUDOERS_CHECK` 환경변수로 실제 체크를 우회
    # 가능 ("ok" | "missing"). 프로덕션에선 unset.
    #
    # `sudo -n -l` 출력을 grep으로 파싱해 NOPASSWD + pmset disablesleep 엔트리를
    # 직접 확인. pmset을 실제로 실행하지 않고 권한 선언만 조회하므로 부작용 없음.
    # `sudo -n <cmd>` 실행 방식은 NOPASSWD 있으면 실제로 pmset을 호출하는 부작용
    # 이 있고, `sudo -n -l <cmd>`의 exit code는 구현에 따라 NOPASSWD 필터링이
    # 모호한 경우가 있어 출력 파싱이 가장 신뢰할 수 있다.
    local status
    if [ -n "${_SLEEP_GUARD_SUDOERS_CHECK:-}" ]; then
        status="$_SLEEP_GUARD_SUDOERS_CHECK"
    elif sudo -n -l 2>/dev/null | grep -qE "NOPASSWD.*pmset.*disablesleep"; then
        status="ok"
    else
        status="missing"
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
    local user_suffix="${USER:-$(id -un)}"
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
    sync_sleep_guard
    exit 0
fi

cd "$INSTALL_DIR" || { log "ERROR: Cannot cd to $INSTALL_DIR"; sync_skill_permissions; sync_rtk_setup; sync_precommit_lint_hook; sync_sleep_guard; exit 0; }

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ "$CURRENT_BRANCH" != "main" ]; then
    log "SKIP: Not on main branch (current: $CURRENT_BRANCH)"
    sync_skill_permissions
    sync_rtk_setup
    sync_precommit_lint_hook
    sync_sleep_guard
    exit 0
fi

if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    log "SKIP: Local changes detected"
    sync_skill_permissions
    sync_rtk_setup
    sync_precommit_lint_hook
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
sync_sleep_guard

exit 0
