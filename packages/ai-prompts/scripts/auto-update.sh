#!/bin/bash

set -u

INSTALL_DIR="$HOME/.config/sazo-ai-prompts"
LOG_FILE="$HOME/.claude/logs/ai-prompts-update.log"

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

if [ ! -d "$INSTALL_DIR/.git" ]; then
    log "SKIP: Not installed at $INSTALL_DIR"
    exit 0
fi

cd "$INSTALL_DIR" || { log "ERROR: Cannot cd to $INSTALL_DIR"; exit 0; }

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ "$CURRENT_BRANCH" != "main" ]; then
    log "SKIP: Not on main branch (current: $CURRENT_BRANCH)"
    exit 0
fi

if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    log "SKIP: Local changes detected"
    exit 0
fi

LAST_FETCH_FILE="$INSTALL_DIR/.git/FETCH_HEAD"
if [ -f "$LAST_FETCH_FILE" ]; then
    LAST_FETCH=$(get_mtime "$LAST_FETCH_FILE")
    NOW=$(date +%s)
    DIFF=$((NOW - LAST_FETCH))
    if [ "$DIFF" -lt 3600 ]; then
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
            
            AI_PROMPTS_DIR="$INSTALL_DIR/packages/ai-prompts"
            CMD_LINKED=$(link_new_files "$AI_PROMPTS_DIR/commands" "$HOME/.claude/commands")
            SKILL_LINKED=$(link_new_files "$AI_PROMPTS_DIR/skills" "$HOME/.claude/skills")
            AGENT_LINKED=$(link_new_files "$AI_PROMPTS_DIR/agents" "$HOME/.claude/agents")
            
            TOTAL=$((CMD_LINKED + SKILL_LINKED + AGENT_LINKED))
            if [ "$TOTAL" -gt 0 ]; then
                log "Linked $TOTAL new files (commands:$CMD_LINKED skills:$SKILL_LINKED agents:$AGENT_LINKED)"
            fi
        else
            log "WARN: Pull failed"
        fi
    fi
else
    log "WARN: Fetch failed (network or auth issue)"
fi

exit 0
