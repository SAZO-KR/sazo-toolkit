#!/bin/bash
# merge-claude-md.sh — Managed block merge for ~/.claude/CLAUDE.md
# Used by install.sh (interactive) and auto-update.sh (silent)

set -euo pipefail

BLOCK_BEGIN="# BEGIN SAZO-AI-HARNESS MANAGED BLOCK (DO NOT EDIT)"
BLOCK_END="# END SAZO-AI-HARNESS MANAGED BLOCK"

CLAUDE_MD_FILE="$HOME/.claude/CLAUDE.md"

has_managed_block() {
    [ -f "$CLAUDE_MD_FILE" ] && grep -qF "$BLOCK_BEGIN" "$CLAUDE_MD_FILE"
}

replace_managed_block() {
    local source_file="$1"
    local tmp_file
    tmp_file=$(mktemp)

    local in_block=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$BLOCK_BEGIN" ]]; then
            in_block=1
            echo "$BLOCK_BEGIN" >> "$tmp_file"
            cat "$source_file" >> "$tmp_file"
            continue
        fi
        if [[ "$line" == "$BLOCK_END" ]]; then
            in_block=0
            echo "$BLOCK_END" >> "$tmp_file"
            continue
        fi
        if [ "$in_block" -eq 0 ]; then
            echo "$line" >> "$tmp_file"
        fi
    done < "$CLAUDE_MD_FILE"

    mv "$tmp_file" "$CLAUDE_MD_FILE"
}

append_managed_block() {
    local source_file="$1"

    {
        echo ""
        echo "$BLOCK_BEGIN"
        cat "$source_file"
        echo "$BLOCK_END"
    } >> "$CLAUDE_MD_FILE"
}

create_with_managed_block() {
    local source_file="$1"

    mkdir -p "$(dirname "$CLAUDE_MD_FILE")"
    {
        echo "$BLOCK_BEGIN"
        cat "$source_file"
        echo "$BLOCK_END"
    } > "$CLAUDE_MD_FILE"
}

replace_file_with_managed_block() {
    local source_file="$1"
    local backup_file="${CLAUDE_MD_FILE}.backup.$(date +%Y%m%d%H%M%S)"

    cp "$CLAUDE_MD_FILE" "$backup_file"
    echo "  Backup: $backup_file"

    {
        echo "$BLOCK_BEGIN"
        cat "$source_file"
        echo "$BLOCK_END"
    } > "$CLAUDE_MD_FILE"
}

show_current_content() {
    echo ""
    echo "--- Current ~/.claude/CLAUDE.md ---"
    cat "$CLAUDE_MD_FILE"
    echo "--- End ---"
    echo ""
}
