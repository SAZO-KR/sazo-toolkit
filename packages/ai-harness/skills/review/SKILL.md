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

## Review modes

**Mode A (DEFAULT, recommended):**
- **2 Task calls**: `code-reviewer` (5개 관점 통합) + `architect-advisor`.
- 양쪽 모두 PASS 반환 시 통과.

**Mode B (advisory):**
- 5 parallel Task calls (4× code-reviewer + 1× architect-advisor).
- Main loop이 각 결과를 직접 판단.

Mode A에서는 5개 관점을 하나의 code-reviewer 프롬프트에 통합. Mode B에서는 관점별로 분리.

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

### 1. Launch the parallel Task calls

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

Two Task calls. 양쪽 모두 APPROVE 반환 시 통과.

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

Mode B에서는 main loop이 각 결과를 직접 평가.

**CRITICAL (both modes):**
  - Do NOT pass session_id — each review MUST be a fresh session
  - Do NOT include previous review results in the prompt
  - Each agent returns: PASS or FAIL with specific issues cited by file and line
  - Each agent ALSO returns the SAZO_VERDICT footer (machine-parseable)

Agent selection:
  - Correctness / Security / Performance / Test Quality → `code-reviewer` (diff-based, sonnet)
  - Architecture → `architect-advisor` (depth over breadth, sonnet — escalate to opus only when the main loop identifies architecturally sensitive changes; see CLAUDE.md §0)

### 2. Handling Review Results

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
