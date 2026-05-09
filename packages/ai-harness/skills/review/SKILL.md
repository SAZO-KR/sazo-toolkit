---
name: review
description: Use after CI passes and before PR creation — launches independent multi-perspective code review with fresh context on every cycle until all reviewers pass
---

<required>
*CRITICAL* Add the following steps to your Todo list using TodoWrite:

1. Prepare review context (git diff, changed files list, original requirements)
2. Launch independent review agents (MUST be new sessions — no session_id)
3. Collect results — ALL must PASS to proceed
4. If any reviewer flags issues → fix → re-run CI → go back to step 2
5. All reviewers PASS → proceed to next workflow step
</required>

# Independent Code Review

## Core Principle

**Every review cycle MUST run in a fresh context.** The reviewer must not know what was previously flagged or fixed. This prevents confirmation bias ("they fixed what I said, so it's fine now") and ensures each review is a genuine independent assessment.

## Review Cycle

```
┌─────────────────────────────────────────────┐
│  CI passes (Step 5)                         │
│       ↓                                     │
│  Launch N independent review agents         │
│  (each in NEW session, no session_id)       │
│       ↓                                     │
│  Collect results                            │
│       ↓                                     │
│  ALL PASS? ──yes──→ Proceed to Step 7       │
│       │                                     │
│      no                                     │
│       ↓                                     │
│  Fix flagged issues                         │
│       ↓                                     │
│  Re-run CI (Step 5)                         │
│       ↓                                     │
│  Launch NEW review agents                   │
│  (fresh sessions again — NEVER reuse)       │
│       ↓                                     │
│  Repeat until ALL PASS                      │
└─────────────────────────────────────────────┘
```

## Aggregation gate vs. multi-perspective fan-out

There are TWO modes — choose explicitly:

**Mode A: Aggregation gate (DEFAULT, recommended)**
- Launch **2 Task calls**: one `code-reviewer` (with all 5 perspectives consolidated in the prompt) + one `architect-advisor`.
- Each call carries one nonce. Hook aggregates verdicts per agent.
- review_expected_set MUST be `["code-reviewer","architect-advisor"]` (unique agent names).
- This is what the verdict-footer aggregation gate is designed for.

**Mode B: Multi-perspective fan-out (advisory only, NOT aggregation-tracked)**
- Launch 5 parallel Task calls (4× code-reviewer + 1× architect-advisor) for prompt-cache savings.
- All 4 code-reviewer verdicts collapse into the same `last_verdicts.review["code-reviewer"]` slot under per-agent keying. The hook gate cannot distinguish individual perspectives — only the most-recently-arrived verdict survives.
- DO NOT use this mode as an aggregation gate. Use it only when the main loop manually evaluates each result and the user (not the hook) decides pass/fail.
- If you use this mode, set `SAZO_VERDICT_FOOTER_ENFORCE=warn` so hook fall-through to legacy stage_mark is preserved.

The remainder of this section describes the perspectives. In Mode A, consolidate them into a single code-reviewer prompt. In Mode B, fan them out across 4 calls (advisory).

## Review Agents (perspectives)

For Mode A consolidate all 5 perspectives in the single `code-reviewer` Task prompt. For Mode B, launch one Task per perspective. Each agent receives ONLY:

- The `git diff` of all changes
- The list of changed files
- The original task requirements
- The project's CLAUDE.md / AGENTS.md

Each agent does NOT receive:

- Previous review results
- Previous fix history
- Knowledge of what other reviewers are checking

### Prompt-caching discipline (CRITICAL for cost)

All 5 agents share ~90% of their input (diff + CLAUDE.md + requirements + common reviewer instructions). Structure each prompt so this shared payload sits at the **front**, and only the perspective-specific instructions go at the **end**. This lets Anthropic prompt caching (≥1024 tokens shared prefix, 5-min TTL) turn the first call into a cache write (~25% markup) and the remaining 4 into cache reads (~90% discount on input).

Required structure for every review prompt:

```
[shared prefix — cached]
1. Common reviewer system instructions (fresh-session discipline, PASS/FAIL criteria,
   output format — same across all 5 calls)
2. Project CLAUDE.md / AGENTS.md (verbatim)
3. Original task requirements
4. git diff of all changes
5. List of changed files

[perspective-specific tail — NOT cached, differs per call]
6. "Perspective: <correctness|architecture|security|performance|test-quality>"
7. Perspective-specific checklist (the bullets under each Perspective N below)
```

Launch requirements for caching to hit:

- **Parallel, not sequential** — fire all 5 Task calls in a single assistant turn (single `POST /v1/messages` fan-out). Sequential launches still cache but risk TTL misses on large diffs.
- **Identical shared prefix byte-for-byte** — do not inject timestamps, UUIDs, or per-call decorations into steps 1–5.
- **No stale cache reuse across cycles** — when the diff changes (after a fix), steps 4–5 change, so the cache invalidates naturally. Do not try to reuse.

Expected economy (scope-limited):

- The **4 `code-reviewer` invocations** share the same agent system prompt — their user-prompt shared prefix is eligible for cache hits. Savings apply to the user-prompt portion only; agent system prompts and tool schemas are reloaded per subagent (not under the skill's control).
- The **1 `architect-advisor` invocation** uses a different agent system prompt, so it will NOT cache-hit with the 4 `code-reviewer` calls. Its user-prompt prefix may still cache on re-review cycles within the 5-min TTL.
- **Assumption**: Claude Code Task subagents issued in the same parent turn share a cache namespace (or at least hit Anthropic's auto-cache heuristic). If that's not the case, the caching benefit degrades to intra-cycle re-review only.

Realistic target: ~50–60% reduction in **user-prompt input tokens** across the 4 `code-reviewer` calls; ~0% on the single `architect-advisor` call; ~0% on system-level payload (agent system prompts + tool schemas) which is out of scope.

### Perspective 1: Correctness

- Requirements fulfilled? Edge cases handled?
- Error paths covered? Race conditions?
- Data integrity maintained?

### Perspective 2: Architecture

- Consistent with existing codebase patterns?
- Dependency direction correct?
- No interface breakage?
- Separation of concerns maintained?

### Perspective 3: Security

- Input validation present?
- Injection vulnerabilities?
- Authentication/authorization correct?
- Secrets exposure?

### Perspective 4: Performance

- N+1 queries?
- Unnecessary allocations?
- Missing indexes?
- Unbounded operations?

### Perspective 5: Test Quality

- Tests verify real behavior (not mock behavior)?
- Edge cases and error paths included?
- Tests are deterministic?
- Test type appropriate for what's being tested?

## PASS / FAIL Criteria

Each reviewer returns **PASS** or **FAIL**. The threshold:

**FAIL** — any of these:
- Bug that will be hit in production (logic error, race condition, data corruption)
- Security vulnerability (injection, auth bypass, secret exposure)
- Behavioral regression (existing functionality broken by the change)
- Missing error handling on a path that will be reached in production
- Test that tests mock behavior instead of real behavior
- Violation of project CLAUDE.md / AGENTS.md rules

**PASS** — all of these:
- No issues found, OR
- Only minor style/preference issues that don't affect correctness or security
- Pre-existing issues unrelated to this change (note them, but PASS)

**When uncertain:** FAIL. False negatives are worse than false positives.

## How to Launch Review Agents

### 1. Set the active reviewer set (verdict footer gate)

Before launching, declare which reviewers will participate so the harness
can aggregate verdicts correctly. The PostToolUse hook reads this to know
when stage completion can be evaluated.

**IMPORTANT — unique agent names only.** `_evaluate_stage_completion`
keys verdicts by agent name (`last_verdicts.review[<agent>]`). Listing
the same agent multiple times in `review_expected_set` collapses to one
key — it does NOT enforce N invocations. Use unique entries.

```bash
# Example: code-reviewer + architect-advisor (TWO unique reviewers).
# To get more breadth from code-reviewer, run multiple parallel Task
# calls with different perspective tails — but the gate only needs the
# unique agent names below.
SESSION_ID="${CLAUDE_SESSION_ID:-${SAZO_SESSION_ID:-}}"
CWD="$(pwd)"
bash -c "source $HOME/.claude/scripts/hooks/lib/session-state.sh && \
         state_set_json '$SESSION_ID' '.review_expected_set' \
         '[\"code-reviewer\",\"architect-advisor\"]' '$CWD'"
```

(In practice, the main loop invokes this via a small helper so it stays
inline with the Task launches. If you skip this step, the gate falls back
to fail-open and treats any single APPROVE as success — not what you want
for multi-perspective review.)

### 2. Mint nonces and inject into each prompt

Each Task call must end with a verdict footer carrying a session-issued
nonce. Mint one nonce per call from the harness, then append the footer
template to the prompt:

```bash
NONCE=$(bash -c "source $HOME/.claude/scripts/hooks/lib/session-state.sh && \
                 verdict_nonce_issue '$SESSION_ID' '$CWD' 'code-reviewer' 'review'")

NONCE_INSTRUCTION="

---
At the end of your response, append exactly this footer (do not omit, do
not modify the nonce):
---SAZO_FOOTER_BEGIN---
SAZO_VERDICT_NONCE: $NONCE
SAZO_VERDICT: APPROVE | BLOCK | NEEDS_REVISION
SAZO_BLOCKING_ISSUES: <integer>
---SAZO_FOOTER_END---
"
```

Append `$NONCE_INSTRUCTION` to the **end** of each Task `prompt` argument
(after the perspective-specific tail). The shared cached prefix is
unaffected — the per-call nonce sits in the per-call tail.

### 3. Launch the parallel Task calls

**Mode A (aggregation gate, default — 2 calls):**

```
Task(
  subagent_type="code-reviewer",
  run_in_background=true,
  load_skills=[],
  prompt="[shared prefix + ALL 5 perspectives consolidated + nonce footer for code-reviewer]"
)

Task(
  subagent_type="architect-advisor",
  run_in_background=true,
  load_skills=[],
  prompt="[shared prefix + Architecture perspective + nonce footer for architect-advisor]"
)
```

Two Task calls, each with its own nonce. Hook aggregates: stage marks `completed` only when both return APPROVE.

**Mode B (advisory, multi-perspective fan-out — 5 calls):**

```
For each of the 5 perspectives, use Task tool:
  Task(
    subagent_type="code-reviewer",            # architect-advisor for the Architecture perspective
    run_in_background=true,
    load_skills=[],
    prompt="[shared prefix + perspective tail + (optional) nonce footer instruction]"
  )
```

In Mode B, hook aggregation is unreliable (per-agent keying collapses 4 code-reviewer slots) — the main loop must evaluate each result manually and treat the gate as advisory.

**CRITICAL (both modes):**
  - Do NOT pass session_id — each review MUST be a fresh session
  - Do NOT include previous review results in the prompt
  - Each agent returns: PASS or FAIL with specific issues cited by file and line
  - Each agent ALSO returns the SAZO_VERDICT footer (machine-parseable)

Agent selection:
  - Correctness / Security / Performance / Test Quality → `code-reviewer` (diff-based, sonnet)
  - Architecture → `architect-advisor` (depth over breadth, sonnet — escalate to opus only when the main loop identifies architecturally sensitive changes; see CLAUDE.md §0)

### 4. Verdict aggregation (automatic)

The PostToolUse hook (workflow-state-machine.sh) parses each reviewer's
footer, validates the nonce against the issued pool, and records the
verdict in state. When **every** expected reviewer has responded with
`APPROVE`, the review stage is automatically marked complete. Any single
`BLOCK` keeps the stage incomplete — proceed to "Handling Review Results"
below.

If the SAZO_VERDICT_FOOTER_ENFORCE env is `warn` (Phase 1 default), a
missing footer falls back to legacy stage_mark — but the
`verdict_missing_count` metric increments, so callers omitting the footer
are detectable. Switch per-agent to `block` once dogfooding shows footer
compliance.

## Handling Review Results

**ALL PASS:** Proceed to the next workflow step.

**ANY FAIL:**

1. Collect all flagged issues from all reviewers
2. Fix the issues
3. Re-run CI to verify fixes don't break anything
4. Launch entirely NEW review agents (fresh sessions)
5. Repeat until all pass

**NEVER:**

- Skip a reviewer's feedback because "it's minor"
- Reuse a review session to "just check the fix"
- Proceed with any FAIL result
- Argue with the reviewer — fix the issue or escalate to the user

## When to Escalate to User

- Reviewer flags something that conflicts with the original requirements
- Two reviewers give contradictory feedback
- A fix would require significant scope change
- You disagree with the review but can't resolve it technically

In these cases: present the conflict to the user with both sides, let them decide.
