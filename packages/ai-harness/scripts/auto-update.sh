#!/bin/bash

set -u

INSTALL_DIR="$HOME/.config/sazo-ai-harness"
# Support migration from old install path
if [ ! -d "$INSTALL_DIR/.git" ] && [ -d "$HOME/.config/sazo-ai-prompts/.git" ]; then
    INSTALL_DIR="$HOME/.config/sazo-ai-prompts"
fi
LOG_FILE="$HOME/.claude/logs/ai-harness-update.log"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

get_file_size() {
    stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo "0"
}

get_mtime() {
    stat -f%m "$1" 2>/dev/null || stat -c%Y "$1" 2>/dev/null || echo "0"
}

if [ -f "$LOG_FILE" ] && [ "$(get_file_size "$LOG_FILE")" -gt 102400 ]; then
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
}

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
