#!/usr/bin/env bash
# setup-labels.sh — Plan 08: create/update bot-review labels on the GitHub repo.
#
# Usage: setup-labels.sh [--config <path>]
#
# Idempotent via --force (create or update). Safe to call on every ROUND==1.
# Skips reviewers with _disabled=true.
#
# Exit codes:
#   0 — success
#   1 — error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="$(cd "$SCRIPT_DIR/.." && pwd)/config.json"

# ── argument parsing ──────────────────────────────────────
CONFIG_PATH="$DEFAULT_CONFIG"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG_PATH="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [[ ! -f "$CONFIG_PATH" ]]; then
    echo "ERROR: config not found: $CONFIG_PATH" >&2
    exit 1
fi

# ── load config ───────────────────────────────────────────
# Extract fields via jq
OVERRIDE_LABEL=$(jq -r '.override_label // "bot-review/override"' "$CONFIG_PATH")

# ── create labels per active reviewer × suffix ────────────
# Iterate over reviewers
jq -c '.active_reviewers | to_entries[]' "$CONFIG_PATH" | while IFS= read -r entry; do
    reviewer_key=$(echo "$entry" | jq -r '.key')
    disabled=$(echo "$entry" | jq -r '.value._disabled // false')
    if [[ "$disabled" == "true" ]]; then
        continue
    fi
    prefix=$(echo "$entry" | jq -r '.value.label_prefix')

    # Iterate over label suffixes
    jq -c '.labels | to_entries[]' "$CONFIG_PATH" | while IFS= read -r lentry; do
        suffix=$(echo "$lentry" | jq -r '.value.suffix')
        color=$(echo "$lentry" | jq -r '.value.color')
        label_name="${prefix}${suffix}"
        gh label create "$label_name" -c "$color" -d "Plan 08: bot-review label" --force
    done
done

# ── create override label ─────────────────────────────────
gh label create "$OVERRIDE_LABEL" -c "1d76db" -d "Plan 08: manual override" --force
