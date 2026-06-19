#!/bin/bash
#
# gate.sh <transcript_path>
#
# Decides whether the just-finished turn did real work that warrants a summary.
# "Real work" = an Edit / Write / NotebookEdit / Task (subagent) tool_use issued
# by the assistant since the last genuine user message (a user message whose
# content is a string or text — NOT a tool_result, which is mid-turn plumbing).
#
# Exit 0  -> work happened this turn (caller should trigger the summary)
# Exit 1  -> no work, or cannot determine (safe default: do NOT trigger)
#
# Stateless: derives the decision fresh from the transcript every time. No marker
# files, no git. jq is the JSON tool (optional — absent jq => exit 1, inert).
set -uo pipefail

TRANSCRIPT="${1:-}"

# Safe defaults: missing/unreadable transcript or no jq => treat as "no work".
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 1
command -v jq >/dev/null 2>&1 || exit 1

# Slurp the JSONL transcript into an array, find the index of the last genuine
# user message, then check assistant tool_use names after it.
result="$(jq -s '
  def is_real_user:
    .type == "user"
    and ((.message.content | type) == "string"
         or (([.message.content[]?.type] | index("tool_result")) | not));

  . as $arr
  | (reduce range(0; ($arr | length)) as $i (-1;
     if ($arr[$i] | is_real_user) then $i else . end)) as $start
  | [ $arr[($start + 1):][]
      | select(.type == "assistant")
      | (.message.content // [])[]?
      | select(.type == "tool_use")
      | .name ]
  | any(.[]; . == "Edit" or . == "Write" or . == "NotebookEdit" or . == "Task")
' "$TRANSCRIPT" 2>/dev/null)" || exit 1

[ "$result" = "true" ] && exit 0
exit 1
