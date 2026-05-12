#!/usr/bin/env bash
# slash-commands.sh — slash command parsing helpers (Plan 13 Stage A0b)
#
# Provides:
#   is_known_slash "$cmd"        — returns 0 if $cmd is a recognized slash command
#   trim_leading "$str"          — strips leading whitespace (sed -E, bash 3.2 safe)
#   parse_slash_command "$input" — parses /approved or /skip ... input; rejects mixed
#
# Bash 3.2 compatible (ADR D2). No associative arrays, no ${!var}, no mapfile.

# is_known_slash: returns 0 if $1 is a recognized slash command token.
is_known_slash() {
    case "$1" in
        /approved|/skip|/override-skip-streak) return 0 ;;
    esac
    return 1
}

# trim_leading: strips leading whitespace from $1.
# Uses sed -E (bash 3.2 safe) instead of ${var#[[:space:]]*} glob which has
# environment-dependent behavior across bash versions (integrator plan v6 blocker #6).
trim_leading() {
    printf '%s' "$1" | sed -E 's/^[[:space:]]+//'
}

# parse_slash_command: validates and parses a (possibly trimmed) slash command input.
# Returns the command payload on stdout (without leading slash) if valid.
# Returns empty string and rc=0 if input is a rejected mixed-slash command.
#
# Rules:
#   /approved [optional extra text]    → outputs "approved [extra text]"
#   /skip <stage> <reason...>          → outputs "skip <stage> <reason...>"
#   /approved /skip ...                → rejected (mixed slash) → empty output
#   /skip /approved ...                → rejected (mixed slash) → empty output
parse_slash_command() {
    local input="$1"

    # Extract first and second tokens
    local first_token rest
    first_token="${input%%[[:space:]]*}"
    rest="${input#"$first_token"}"
    rest=$(trim_leading "$rest")

    # Reject mixed slash: if rest starts with another slash command
    if is_known_slash "$first_token"; then
        local second_token
        second_token="${rest%%[[:space:]]*}"
        if is_known_slash "$second_token" && [ -n "$second_token" ]; then
            printf ''
            return 0
        fi
        # Valid: strip leading slash from first_token and output
        printf '%s' "${first_token#/}${rest:+ $rest}"
        return 0
    fi

    # Not a known slash command
    printf ''
    return 0
}
