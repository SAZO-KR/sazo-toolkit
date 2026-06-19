#!/bin/bash
#
# settings-hook.sh add|remove <settings_file> <cmd_or_match>
#
# Manage this tool's Claude Code "Stop" hook entry in a settings.json file.
#   add    <file> <cmd>    Register a Stop hook with command=<cmd> (idempotent).
#                          Creates <file> (and its parent dir) if absent.
#   remove <file> <match>  Remove Stop hook entries whose command matches the
#                          <match> regex (jq `test`). Prunes empty groups/keys.
#
# Writes <file> in place atomically (mktemp + validate + mv). jq is required.
# Exit 0 success | 1 failure (no jq / parse / empty output) | 2 bad usage.
set -uo pipefail

action="${1:-}"
file="${2:-}"
arg="${3:-}"

[ -n "$action" ] && [ -n "$file" ] && [ -n "$arg" ] || exit 2
command -v jq >/dev/null 2>&1 || exit 1

tmp_in="$(mktemp)"
tmp_out="$(mktemp)"
trap 'rm -f "$tmp_in" "$tmp_out"' EXIT

case "$action" in
    add)
        mkdir -p "$(dirname "$file")"
        if [ -f "$file" ]; then cp "$file" "$tmp_in"; else echo '{}' > "$tmp_in"; fi
        jq --arg c "$arg" '
            .hooks = (.hooks // {})
            | .hooks.Stop = (.hooks.Stop // [])
            | if ([.hooks.Stop[]?.hooks[]?.command] | index($c))
              then .
              else .hooks.Stop += [{"hooks": [{"type": "command", "command": $c}]}]
              end
        ' "$tmp_in" > "$tmp_out" 2>/dev/null || exit 1
        ;;
    remove)
        [ -f "$file" ] || exit 0
        cp "$file" "$tmp_in"
        jq --arg m "$arg" '
            if .hooks.Stop then
              .hooks.Stop |= [ .[]
                | .hooks = ((.hooks // []) | map(select((.command // "") | test($m) | not)))
                | select((.hooks | length) > 0) ]
              | if (.hooks.Stop | length) == 0 then del(.hooks.Stop) else . end
              | if (.hooks == {}) then del(.hooks) else . end
            else . end
        ' "$tmp_in" > "$tmp_out" 2>/dev/null || exit 1
        ;;
    *)
        exit 2
        ;;
esac

[ -s "$tmp_out" ] || exit 1
mv "$tmp_out" "$file"
exit 0
