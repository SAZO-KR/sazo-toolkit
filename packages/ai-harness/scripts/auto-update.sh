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

# awake CLI는 명시적 사용자 제어 모델 — auto hook 없음. 매 SessionStart마다
# `~/.local/bin/awake` 심볼릭 링크가 awake.sh 를 가리키는지 멱등 갱신만 한다.
# 옵션 변경/스크립트 위치 이동 시 자동 복구. 알림/opt-in 흐름 없음.
sync_awake() {
    [ "$(uname -s)" = "Darwin" ] || return 0
    local awake_script="$HARNESS_DIR/scripts/awake/awake.sh"
    [ -f "$awake_script" ] || return 0
    # rebase/git checkout 으로 mode bit 떨어질 수 있어 매번 보장.
    chmod +x "$awake_script" 2>/dev/null || true
    local awake_symlink="$HOME/.local/bin/awake"
    mkdir -p "$HOME/.local/bin" 2>/dev/null || true
    # symlink target이 이미 정확하면 ln 호출 자체 skip — noise 감소.
    if [ -L "$awake_symlink" ] && [ "$(readlink "$awake_symlink")" = "$awake_script" ]; then
        sync_awake_cleanup_legacy
        return 0
    fi
    ln -sfn "$awake_script" "$awake_symlink" 2>>"$LOG_FILE" || true
    sync_awake_cleanup_legacy
}

# 구 sleep-guard 잔재 자동 정리 — 다른 팀원이 새 버전을 auto-update로 받았을 때
# 이전 launchd plist + hook symlink + 마커가 silent하게 남아 있는 문제를 self-heal.
# - sudoers 파일은 sudo 필요 → 건드리지 않음 (사용자가 수동 처리)
# - settings.json hook은 sudo 불필요 → jq로 정리
# 멱등. 이미 정리된 환경에서는 비용 거의 0 (파일 존재 체크만).
sync_awake_cleanup_legacy() {
    local plist="$HOME/Library/LaunchAgents/shop.sazo.claude-sleep-guard.plist"
    if [ -f "$plist" ]; then
        launchctl unload "$plist" >/dev/null 2>&1 || true
        rm -f "$plist" 2>/dev/null || true
    fi
    rm -f "$HOME/.claude/hooks/sazo-caffeinate-session.sh" 2>/dev/null || true
    rm -f "$HOME/.claude/hooks/sazo-sleep-watchdog.sh" 2>/dev/null || true
    local marker
    for marker in \
        "$HOME/.config/sazo-ai-harness/.sleep-guard-init-done" \
        "$HOME/.config/sazo-ai-harness/.sleep-guard-optout" \
        "$HOME/.config/sazo-ai-harness/.sleep-guard-notify-throttle" \
        "$HOME/.config/sazo-ai-harness/.sleep-guard-optin-notify-throttle"
    do
        # `set -u` 환경에서 rm 실패가 함수를 중단시키지 않도록 `|| true` 명시.
        [ -e "$marker" ] && { rm -f "$marker" 2>/dev/null || true; }
    done
    # /tmp 디렉토리는 본인 소유만 정리 (다른 사용자 디렉토리 권한 충돌 방지).
    # 구 caffeinate-session.sh가 사용하던 경로와 동일 — `/tmp/claude-awake-$USER`.
    rm -rf "/tmp/claude-awake-${USER:-$(id -un)}" 2>/dev/null || true
    # settings.json hook 정리 — jq 있을 때만, 본인 사용자 hook만.
    if command -v jq >/dev/null 2>&1; then
        local settings="$HOME/.claude/settings.json"
        # dotfiles 관리(symlink) 환경 대비: mv가 link 자체를 덮어쓰지 않도록 실제
        # 파일 경로로 resolve. `readlink -f`는 GNU 옵션이며 일부 BSD/구버전 macOS
        # 에선 미지원이라, symlink 명시 체크 + 단일 단계 readlink + 상대경로 정규화.
        local real_settings
        if [ -L "$settings" ]; then
            local link_target
            link_target=$(readlink "$settings" 2>/dev/null || printf '%s' "")
            if [ -z "$link_target" ]; then
                real_settings="$settings"
            else
                case "$link_target" in
                    /*) real_settings="$link_target" ;;
                    *)  real_settings="$(dirname "$settings")/$link_target" ;;
                esac
            fi
        else
            real_settings="$settings"
        fi
        if [ -f "$real_settings" ] && grep -q "sazo-caffeinate-session.sh" "$real_settings" 2>/dev/null; then
            local tmp
            tmp=$(mktemp)
            # 헬퍼 함수로 hook type별 정리 — 원래 없던 키는 그대로 두고, hook 제거
            # 결과 빈 array 매처는 매처에서 제거, 결과 빈 array 키는 키째 제거.
            # 이전 패턴 `.hooks //= {}` + `.hooks.X = ((... // []) | ...)` 은 원래
            # 없던 키를 `[]`로 삽입하는 부작용이 있었음.
            if jq '
                def clean_hook_type(k):
                    if has("hooks") and (.hooks | type) == "object" and (.hooks | has(k)) then
                        .hooks[k] = (.hooks[k] | map(
                            .hooks = ((.hooks // []) | map(select(.command | test("sazo-caffeinate-session.sh") | not)))
                          ) | map(select((.hooks // []) | length > 0)))
                        | if (.hooks[k] | length) == 0 then del(.hooks[k]) else . end
                    else . end;
                clean_hook_type("UserPromptSubmit")
                | clean_hook_type("PostToolUse")
                | clean_hook_type("Stop")
            ' "$real_settings" > "$tmp" 2>/dev/null; then
                mv "$tmp" "$real_settings"
                log "Cleaned up legacy sleep-guard hooks from settings.json"
            else
                rm -f "$tmp"
            fi
        fi
    fi
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
    sync_awake
    exit 0
fi

cd "$INSTALL_DIR" || { log "ERROR: Cannot cd to $INSTALL_DIR"; sync_skill_permissions; sync_rtk_setup; sync_precommit_lint_hook; sync_workflow_hooks; sync_awake; exit 0; }

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ "$CURRENT_BRANCH" != "main" ]; then
    log "SKIP: Not on main branch (current: $CURRENT_BRANCH)"
    sync_skill_permissions
    sync_rtk_setup
    sync_precommit_lint_hook
    sync_workflow_hooks
    sync_awake
    exit 0
fi

if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    log "SKIP: Local changes detected"
    sync_skill_permissions
    sync_rtk_setup
    sync_precommit_lint_hook
    sync_workflow_hooks
    sync_awake
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
        sync_awake
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
sync_awake

exit 0
