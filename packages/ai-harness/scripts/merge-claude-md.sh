#!/bin/bash
# merge-claude-md.sh — Managed block merge for ~/.claude/CLAUDE.md
# Used by install.sh (interactive) and auto-update.sh (silent)

BLOCK_BEGIN="# BEGIN SAZO-AI-HARNESS MANAGED BLOCK (DO NOT EDIT)"
BLOCK_END="# END SAZO-AI-HARNESS MANAGED BLOCK"

CLAUDE_MD_FILE="$HOME/.claude/CLAUDE.md"

has_managed_block() {
    [ -f "$CLAUDE_MD_FILE" ] || return 1
    local begin_line end_line
    begin_line=$(grep -nF "$BLOCK_BEGIN" "$CLAUDE_MD_FILE" | head -1 | cut -d: -f1)
    end_line=$(grep -nF "$BLOCK_END" "$CLAUDE_MD_FILE" | tail -1 | cut -d: -f1)
    [ -n "$begin_line" ] && [ -n "$end_line" ] && [ "$begin_line" -lt "$end_line" ]
}

replace_managed_block() {
    local source_file="$1"
    local tmp_file
    tmp_file=$(mktemp)

    local in_block=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$BLOCK_BEGIN" ]]; then
            in_block=1
            printf "%s\n" "$BLOCK_BEGIN" >> "$tmp_file"
            cat "$source_file" >> "$tmp_file"
            continue
        fi
        if [[ "$line" == "$BLOCK_END" ]]; then
            in_block=0
            printf "%s\n" "$BLOCK_END" >> "$tmp_file"
            continue
        fi
        if [ "$in_block" -eq 0 ]; then
            printf "%s\n" "$line" >> "$tmp_file"
        fi
    done < "$CLAUDE_MD_FILE"

    mv "$tmp_file" "$CLAUDE_MD_FILE"
}

append_managed_block() {
    local source_file="$1"

    {
        printf "\n"
        printf "%s\n" "$BLOCK_BEGIN"
        cat "$source_file"
        printf "%s\n" "$BLOCK_END"
    } >> "$CLAUDE_MD_FILE"
}

create_with_managed_block() {
    local source_file="$1"

    mkdir -p "$(dirname "$CLAUDE_MD_FILE")"
    {
        printf "%s\n" "$BLOCK_BEGIN"
        cat "$source_file"
        printf "%s\n" "$BLOCK_END"
    } > "$CLAUDE_MD_FILE"
}

replace_file_with_managed_block() {
    local source_file="$1"
    local backup_file="${CLAUDE_MD_FILE}.backup.$(date +%Y%m%d%H%M%S)"

    cp -p "$CLAUDE_MD_FILE" "$backup_file"
    printf "  Backup: %s\n" "$backup_file"

    {
        printf "%s\n" "$BLOCK_BEGIN"
        cat "$source_file"
        printf "%s\n" "$BLOCK_END"
    } > "$CLAUDE_MD_FILE"
}

show_current_content() {
    printf "\n--- Current ~/.claude/CLAUDE.md ---\n"
    cat "$CLAUDE_MD_FILE"
    printf "--- End ---\n\n"
}
