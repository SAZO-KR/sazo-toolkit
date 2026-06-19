#!/bin/bash
#
# gate.sh <transcript_path>
#
# Decides whether the just-finished turn warrants a summary. BOTH conditions
# must hold:
#   1. Real work — an Edit / MultiEdit / Write / NotebookEdit / Agent (subagent;
#      legacy Task) tool_use issued by the assistant since the last genuine user
#      (whose content is a string or text — NOT a tool_result, mid-turn plumbing).
#   2. Enough output — the turn's visible assistant text totals at least
#      SAZO_TURN_SUMMARY_MIN_CHARS chars (default 1500). A short answer is already
#      its own summary; re-summarizing it is just noise.
#
# Exit 0  -> summarize (work happened AND output is substantial)
# Exit 1  -> don't, or cannot determine (safe default: do NOT trigger)
#
# Stateless: derives the decision fresh from the transcript every time. No marker
# files, no git. jq is the JSON tool (optional — absent jq => exit 1, inert).
set -uo pipefail

TRANSCRIPT="${1:-}"

# Minimum visible-output length (chars) before a turn is worth summarizing.
# Tunable via env; non-numeric / unset falls back to the default.
MIN_CHARS="${SAZO_TURN_SUMMARY_MIN_CHARS:-1500}"
case "$MIN_CHARS" in ''|*[!0-9]*) MIN_CHARS=1500 ;; esac

# Safe defaults: missing/unreadable transcript or no jq => treat as "no work".
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 1
command -v jq >/dev/null 2>&1 || exit 1

# Slurp the JSONL transcript into an array, find the index of the last genuine
# user message, then over the assistant blocks after it check (a) a work tool_use
# is present and (b) the concatenated visible text meets the length threshold.
result="$(jq -s --argjson min "$MIN_CHARS" '
  def is_real_user:
    .type == "user"
    and .message != null
    and .message.content != null
    and ((.message.content | type) == "string"
         or (any(.message.content[]?; .type == "tool_result") | not));

  . as $arr
  | (reduce range(0; ($arr | length)) as $i (-1;
     if ($arr[$i] | is_real_user) then $i else . end)) as $start
  | [ $arr[($start + 1):][]
      | select(.type == "assistant" and .message != null and .message.content != null)
      | .message.content[]? ] as $blocks
  | ([ $blocks[] | select(.type == "tool_use") | .name ]
       | any(.[]; . == "Edit" or . == "MultiEdit" or . == "Write" or . == "NotebookEdit" or . == "Agent" or . == "Task")) as $did_work
  | ([ $blocks[] | select(.type == "text") | .text ] | join("\n") | length) as $textlen
  | ($did_work and ($textlen >= $min))
' "$TRANSCRIPT" 2>/dev/null)" || exit 1

[ "$result" = "true" ] && exit 0
exit 1
