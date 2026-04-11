---
name: document
description: Use after code changes to update docs.md files throughout the codebase.
---

# Updating Noridocs

## Overview

Noridocs are docs.md files throughout the codebase that document each folder's purpose, architecture, and implementation. Update them after code changes — preferably via the `nori-change-documenter` subagent when available, or manually when it isn't.

**Core principle:** Provide context → Update docs (subagent or manual) → Verify updates.

**Announce at start:** "I'm using the Updating Noridocs skill to update documentation."

## The Process

### Step 1: Gather Context

**Prepare the following context — this applies to both paths in Step 2 (whether you delegate to the `nori-change-documenter` subagent or update docs.md manually):**

- [ ] What changed? (feature added, bug fixed, refactor, etc.)
- [ ] Why was it changed? (motivation, problem being solved)
- [ ] Which folders/files were modified?
- [ ] Any architectural changes or new patterns?

### Step 2: Update docs.md Files

**Option A — nori-change-documenter subagent (if available):**

```bash
Task(subagent_type: nori-change-documenter)
```

**Option B — manual update (fallback):**

If `nori-change-documenter` is not installed, update the relevant `docs.md` files directly using the Noridocs Format below. Focus on architectural/system-level changes, not line-by-line diffs.

**In either case, provide/apply:**

- Clear description of what changed and why
- File paths that were modified
- Relevant context from PR/commits
- Any architectural implications
- Any out of date documentation that you noticed that is not directly related to your change

### Step 3: Verify Updates

**Check that documentation was updated:**

- [ ] Run `git status` to see which docs.md files changed
- [ ] Review the diffs to ensure updates are accurate
- [ ] Verify updates focus on system architecture, not minutiae

### Step 4: Sync Remote docs.md Files

- Check if a 'nori-sync-docs' skill exists in the project (e.g., `skills/nori-sync-docs/SKILL.md` or `.claude/skills/nori-sync-docs/SKILL.md`).
  - If it does not exist, skip this step.
- Ask the user if they want to sync all docs.md files to the remote server.
  - If the user declines, skip this step.
- Read and follow the nori-sync-docs skill to sync all noridocs to the remote server.

## Noridocs Format

Each docs.md follows this structure:

```
# Noridoc: [Folder Name]

Path: [Path to the folder from the repository root. Always start with @. For
  example, @/src/endpoints or @/docs ]

### Overview
[2-3 bullet summary of the folder]

### How it fits into the larger codebase

[2-10 bullet description of how the folder interacts with and fits into other
 parts of the codebase. Focus on system invariants, architecture, internal
 depenencies, places that call into this folder, and places that this folder
 calls out to]

### Core Implementation

[2-10 bullet description of entry points, data paths, key architectural
 details, state management]

### Things to Know

[2-10 bullet description of tricky implementation details, system invariants,
 or likely error surfaces]

Created and maintained by Nori.
```

Noridocs should NOT list files, maintain counts, or track line numbers. These
are brittle documentation patterns that will break very quickly.

## Common Mistakes

**Providing vague context**

- **Problem:** Subagent can't understand what changed
- **Fix:** Be specific about what/why/where

**Skipping verification**

- **Problem:** Inaccurate or missing documentation updates
- **Fix:** Always check git diff after subagent runs

**Documenting trivial changes**

- **Problem:** Noise in documentation, wasted effort
- **Fix:** Only update docs for significant architectural changes

## Red Flags

**Never:**

- Skip providing context (to the subagent or your own manual updates)
- Assume docs were updated without verifying
- Update docs.md files without understanding what changed in the code

**Always:**

- Provide detailed context about what changed and why
- Prefer the `nori-change-documenter` subagent when available; fall back to manual updates when it isn't
- Verify the final docs.md files are accurate (regardless of update method)
- Focus on architectural/system-level changes
