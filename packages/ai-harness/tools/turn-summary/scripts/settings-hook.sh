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
set -euo pipefail

action="${1:-}"
file="${2:-}"
arg="${3:-}"

[ -n "$action" ] && [ -n "$file" ] && [ -n "$arg" ] || exit 2

# If <file> is a symlink (e.g. settings.json kept in a dotfiles repo), resolve it
# to its canonical target so the atomic `mv` writes through the link instead of
# replacing it with a regular file. Portable (no `readlink -f`, which is GNU-only).
resolve_symlink() {
    local target="$1" link depth=0
    while [ -L "$target" ]; do
        depth=$((depth + 1))
        if [ "$depth" -gt 40 ]; then
            echo "settings-hook: symlink chain too deep (loop?): $1" >&2
            return 1
        fi
        link="$(readlink "$target")" || {
            echo "settings-hook: failed to read symlink: $target" >&2
            return 1
        }
        [ -n "$link" ] || {
            echo "settings-hook: empty symlink target: $target" >&2
            return 1
        }
        case "$link" in
            /*) target="$link" ;;
            *)  target="$(dirname "$target")/$link" ;;
        esac
    done
    printf '%s' "$target"
}
if [ -L "$file" ]; then
    file="$(resolve_symlink "$file")" || exit 1
fi

command -v jq >/dev/null 2>&1 || exit 1

case "$action" in add|remove) ;; *) exit 2 ;; esac

# Init before the trap so a failed mktemp under `set -u` doesn't trip an
# unbound-variable error inside the EXIT handler.
tmp_in=""
tmp_out=""
trap 'rm -f "$tmp_in" "$tmp_out"' EXIT

# Nothing to remove from a missing/empty file — skip before any temp I/O.
if [ "$action" = "remove" ] && [ ! -s "$file" ]; then
    exit 0
fi

# Create temps in the TARGET dir so the final `mv` is an atomic same-filesystem
# rename (a system-temp dir may be on a different filesystem). jq stderr is left
# visible so a corrupt settings.json surfaces a real error instead of silent exit.
mkdir -p "$(dirname "$file")"
tmp_in="$(mktemp "$(dirname "$file")/.settings.tmp.XXXXXX")"
tmp_out="$(mktemp "$(dirname "$file")/.settings.tmp.XXXXXX")"

case "$action" in
    add)
        if [ -s "$file" ]; then cp "$file" "$tmp_in"; else echo '{}' > "$tmp_in"; fi
        jq --arg c "$arg" --arg s "turn-summary/scripts/stop-summary.sh" '
            .hooks = (.hooks // {})
            | .hooks.Stop = (.hooks.Stop // [])
            # Drop any existing turn-summary hook by stable suffix first, then append
            # the current command. This stays correct even when the install path
            # (SAZO_BASE_DIR) changes between installs — no stale duplicate is left.
            | .hooks.Stop |= [ .[]
                | .hooks = ((.hooks // []) | map(select((.command // "") | contains($s) | not)))
                | select((.hooks | length) > 0) ]
            | .hooks.Stop += [{"hooks": [{"type": "command", "command": $c}]}]
        ' "$tmp_in" > "$tmp_out" || exit 1
        ;;
    remove)
        cp "$file" "$tmp_in"
        jq --arg m "$arg" '
            if .hooks.Stop then
              .hooks.Stop |= [ .[]
                | .hooks = ((.hooks // []) | map(select((.command // "") | contains($m) | not)))
                | select((.hooks | length) > 0) ]
              | if (.hooks.Stop | length) == 0 then del(.hooks.Stop) else . end
              | if (.hooks == {}) then del(.hooks) else . end
            else . end
        ' "$tmp_in" > "$tmp_out" || exit 1
        ;;
esac

[ -s "$tmp_out" ] || exit 1
mv "$tmp_out" "$file"
exit 0
