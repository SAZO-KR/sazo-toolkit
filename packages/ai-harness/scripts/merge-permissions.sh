#!/bin/bash

# Merge skill-declared permissions into ~/.claude/settings.json
#
# 각 스킬 디렉토리의 permissions.json 을 수집하여,
# ~/.claude/settings.json 의 .permissions.allow 에 union(unique) 한다.
# 기존 사용자 커스텀 엔트리는 보존 (append-only).
#
# Usage:
#   source merge-permissions.sh
#   added=$(merge_skill_permissions "$HARNESS_DIR/skills" "$HOME/.claude/settings.json")
#
# Returns (stdout): 순 증가 entry 수 (기존 대비 새로 추가된 것만). 에러 시 "0".

merge_skill_permissions() {
    local skills_dir="$1"
    local settings_file="${2:-$HOME/.claude/settings.json}"

    if ! command -v jq >/dev/null 2>&1; then
        echo "0"
        return 0
    fi

    if [ ! -d "$skills_dir" ]; then
        echo "0"
        return 0
    fi

    if [ ! -f "$settings_file" ]; then
        # Fresh install — create an empty object to merge into.
        mkdir -p "$(dirname "$settings_file")"
        echo '{}' > "$settings_file"
    elif [ ! -s "$settings_file" ] || ! jq -e 'type == "object"' "$settings_file" >/dev/null 2>&1; then
        # File exists but is empty or not a JSON object — possibly a transient
        # write issue or a manual edit mistake. Do NOT reset (would wipe
        # user's hooks/custom settings). Back up and abort this merge.
        local backup="${settings_file}.broken-$(date +%s)"
        cp "$settings_file" "$backup"
        echo "  WARN: $settings_file is empty or not a JSON object — skill permissions merge aborted (backup: $backup)" >&2
        echo "0"
        return 0
    fi

    local all_bash='[]'
    local skill_count=0

    for perm_file in "$skills_dir"/*/permissions.json; do
        [ -f "$perm_file" ] || continue

        local dir_name=""
        dir_name=$(basename "$(dirname "$perm_file")")
        # Template 디렉토리 스킵
        case "$dir_name" in
            _*) continue ;;
        esac

        # Inspect `.bash` type explicitly so malformed declarations
        # (e.g., `"bash": "date:*"` as a plain string) surface as a
        # warning instead of being silently coerced to [] and dropped.
        local bash_type=""
        bash_type=$(jq -r '.bash | type' "$perm_file" 2>/dev/null)

        case "$bash_type" in
            array) ;;                       # good
            "null"|"")
                # Missing or unreadable — skip silently (file may only
                # declare other permission kinds in the future).
                continue
                ;;
            *)
                echo "  WARN: $perm_file — .bash must be an array of strings, got '$bash_type'. Skipped." >&2
                continue
                ;;
        esac

        local bash_perms=""
        bash_perms=$(jq -c '
            [.bash[] | select(type == "string") | "Bash(" + . + ")"]
        ' "$perm_file" 2>/dev/null)

        if [ -z "$bash_perms" ] || [ "$bash_perms" = "null" ]; then
            echo "  WARN: $perm_file — failed to extract .bash entries, skipped" >&2
            continue
        fi
        if [ "$bash_perms" = "[]" ]; then
            continue
        fi

        all_bash=$(echo "$all_bash" | jq -c --argjson new "$bash_perms" '. + $new')
        skill_count=$((skill_count + 1))
    done

    if [ "$skill_count" -eq 0 ]; then
        echo "0"
        return 0
    fi

    local before_count
    before_count=$(jq '(.permissions.allow // []) | length' "$settings_file" 2>/dev/null || echo "0")

    local tmp
    tmp=$(mktemp)
    if jq --argjson new "$all_bash" '
        .permissions = (.permissions // {})
        | .permissions.allow = ((.permissions.allow // []) + $new | unique)
    ' "$settings_file" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$settings_file"
    else
        rm -f "$tmp"
        echo "0"
        return 0
    fi

    local after_count
    after_count=$(jq '(.permissions.allow // []) | length' "$settings_file" 2>/dev/null || echo "0")

    echo "$((after_count - before_count))"
}
