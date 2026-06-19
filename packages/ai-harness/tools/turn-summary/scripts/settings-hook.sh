#!/bin/bash
#
# settings-hook.sh add|remove <settings_file> <cmd_or_match>
#
# Manage this tool's Claude Code "Stop" hook entry in a settings.json file.
#   add    <file> <cmd>    Register a Stop hook with command=<cmd> (idempotent).
#                          Creates <file> (and its parent dir) if absent.
#   remove <file> <match>  Remove Stop hook entries whose command contains the
#                          <match> substring (jq `contains`). Prunes empty keys.
#
# Writes <file> in place atomically (mktemp + validate + mv). jq is required.
# Exit 0 success | 1 failure (no jq / parse / empty output) | 2 bad usage.
set -uo pipefail

action="${1:-}"
file="${2:-}"
arg="${3:-}"

[ -n "$action" ] && [ -n "$file" ] && [ -n "$arg" ] || exit 2

# If <file> is a symlink (e.g. settings.json kept in a dotfiles repo), resolve it
# to its canonical target so the atomic `mv` writes through the link instead of
# replacing it with a regular file. Portable (no `readlink -f`, which is GNU-only).
resolve_symlink() {
    local target="$1" link
    while [ -L "$target" ]; do
        link="$(readlink "$target")"
        case "$link" in
            /*) target="$link" ;;
            *)  target="$(dirname "$target")/$link" ;;
        esac
    done
    printf '%s' "$target"
}
if [ -L "$file" ]; then
    file="$(resolve_symlink "$file")"
fi

command -v jq >/dev/null 2>&1 || exit 1

tmp_in="$(mktemp)"
tmp_out="$(mktemp)"
trap 'rm -f "$tmp_in" "$tmp_out"' EXIT

case "$action" in
    add)
        mkdir -p "$(dirname "$file")"
        if [ -s "$file" ]; then cp "$file" "$tmp_in"; else echo '{}' > "$tmp_in"; fi
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
        [ -s "$file" ] || exit 0
        cp "$file" "$tmp_in"
        jq --arg m "$arg" '
            if .hooks.Stop then
              .hooks.Stop |= [ .[]
                | .hooks = ((.hooks // []) | map(select((.command // "") | contains($m) | not)))
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
