---
name: plan
description: Use when design is complete and you need detailed implementation tasks — creates comprehensive plans with exact file paths, code examples, and verification steps.
---

<required>
*CRITICAL* Add the following steps to your Todo list using TodoWrite:

- Read the 'Guidelines'.
- Create a comprehensive plan that a senior engineer can follow.
<system-reminder>Any absolute paths in your plan MUST take into account any worktrees that may have been created</system-reminder>
- Think about edge cases. Add them to the plan.
- Think about questions or areas that require clarity. Add them to the plan.
- Emphasize how you will test your plan.
- Present plan to user.
</required>

# Guidelines

## Overview

Create a comprehensive implementation plan assuming the engineer has zero context for our codebase and questionable taste. Document everything they need to know: which files to touch for each task, code, testing, docs they might need to check, how to test it. Give them the whole plan as bite-sized tasks. DRY. YAGNI. TDD.

Assume they are a talented developer. However, assume that they know almost nothing about our toolset or problem domain. Assume they don't know good test design very well.

Do not add code, but include enough detail that the necessary code is obvious.

Do not write a file to disk unless explicitly asked.

## Bite-Sized Task Granularity

**Each step is one action (2-5 minutes):**

- "Write the failing test for `behavior`" - step
- "Write the failing test for `other behavior`"
- "Run it to make sure it fails" - step
- "Implement the minimal code to make the test pass" - step
- "Run the tests and make sure they pass" - step
- "Commit" - step

## Plan Document Header

**Every plan MUST start with this header:**

```markdown
# [Feature Name] Implementation Plan

**Goal:** [One sentence describing what this builds]

**Architecture:** [2-3 sentences about approach]

**Tech Stack:** [Key technologies/libraries]

---
```

## Test Section

Every plan MUST have a test section. This should be written first, and should
document how you plan to test the *behavior*.

```markdown

**Testing Plan**

I will add an integration test that ensures foo behaves like blah. The
integration test will mock A/B/C. The test will then call function/cli/etc.

I will add a unit test that ensures baz behaves like qux...
```

You should end EVERY testing plan section by writing:

```markdown
NOTE: The list above enumerates every test I expect to write so the reader can judge coverage up-front. During implementation I will follow the `develop` skill's Kent Beck TDD loop — writing these tests **incrementally, one at a time**, RED → GREEN → REFACTOR — rather than batch-writing all of them before any implementation.
```

<system-reminder>Your tests should NOT contain tests for datastructures or
types. Your tests should NOT simply test mocks. Always test actual behavior.</system-reminder>

## Plan Document Footer

**Every plan MUST end with this footer:**

```markdown
**Testing Details** [Brief description of what tests are being added and how they specifically test BEHAVIOR and NOT just implementation]

**Implementation Details** [maximum 10 bullets about key details]

**Question** [any questions or concerns that may be relevant that need answers]

---
```

## Plan-stage gate (verdict footer)

When the main loop invokes `plan-critic` or `plan-auditor` as a plan-stage
gate, mint a verdict nonce per call and inject the footer instruction
into each Task prompt:

```bash
SESSION_ID="${CLAUDE_SESSION_ID:-${SAZO_SESSION_ID:-}}"
CWD="$(pwd)"
NONCE_CRITIC=$(bash -c "source ${SAZO_HARNESS_DIR:-$HOME/.config/sazo-ai-harness/packages/ai-harness}/scripts/hooks/lib/session-state.sh && \
                        verdict_nonce_issue '$SESSION_ID' '$CWD' 'plan-critic' 'plan'")
NONCE_AUDITOR=$(bash -c "source ${SAZO_HARNESS_DIR:-$HOME/.config/sazo-ai-harness/packages/ai-harness}/scripts/hooks/lib/session-state.sh && \
                         verdict_nonce_issue '$SESSION_ID' '$CWD' 'plan-auditor' 'plan'")
```

Append to each Task prompt the corresponding footer template (see
`agents/plan-critic.md` and `agents/plan-auditor.md` for the exact
envelope format).

The PostToolUse hook aggregates: plan stage marks `completed` only when
**both** plan-critic AND plan-auditor return `SAZO_VERDICT: APPROVE`.
Plan-auditor `NEEDS_REVISION` indicates a route-back to `plan-drafter`
(main loop responsibility).

When invoking plan-critic/auditor for purposes outside the gate
(advisory, exploration), omit the nonce — agent then omits the footer
and the hook records nothing.
