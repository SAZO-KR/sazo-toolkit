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

## Review Agents

Launch **5 parallel agents**, one per perspective below. Each agent receives ONLY:

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

Expected economy: ~70–75% reduction in review-step input tokens compared to naïve 5× duplication, while preserving 5 independent fresh sessions.

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

```
For each of the 5 perspectives, use Task tool:
  Task(
    subagent_type="code-reviewer",            # architect-advisor for the Architecture perspective
    run_in_background=true,
    load_skills=[],
    prompt="[Review perspective + git diff + requirements]"
  )

CRITICAL:
  - Do NOT pass session_id — each review MUST be a fresh session
  - Do NOT include previous review results in the prompt
  - Each agent returns: PASS or FAIL with specific issues cited by file and line

Agent selection:
  - Correctness / Security / Performance / Test Quality → `code-reviewer` (diff-based, sonnet)
  - Architecture → `architect-advisor` (depth over breadth, opus)
```

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
