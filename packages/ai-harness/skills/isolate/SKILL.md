---
name: isolate
description: Use this whenever you need to create an isolated workspace using git worktrees.
---

<required>
*CRITICAL* Add the following steps to your Todo list using TodoWrite:

1. Find the worktrees directory. Follow the priority **existing > CLAUDE.md/AGENTS.md > ask**:

- First, check for an existing worktree directory. Do **not** hardcode a single name — the project may use `.worktrees`, `_worktrees`, or anything else:
  ```bash
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

  # 1. If worktrees already exist, derive the shared root by stripping the
  #    FULL branch path (which may contain "/") from each worktree path.
  #    A naive single `dirname` would break for branch names like
  #    `feature/auth` — /repo/.worktrees/feature/auth → /repo/.worktrees/feature
  #    (wrong). The awk below strips the exact "/<branch>" suffix.
  EXISTING_WT_PARENT=$(git worktree list --porcelain | awk -v root="$REPO_ROOT" '
    /^worktree / { wt = substr($0, 10); next }
    /^branch refs\/heads\// {
      branch = substr($0, 19)
      suffix = "/" branch
      if (length(wt) > length(suffix) && \
          substr(wt, length(wt) - length(suffix) + 1) == suffix) {
        parent = substr(wt, 1, length(wt) - length(suffix))
        if (parent != root) { print parent; exit }
      }
    }
  ')

  if [ -n "$EXISTING_WT_PARENT" ]; then
    echo "Found existing worktree directory: $EXISTING_WT_PARENT"
  else
    # 2. No active worktrees — check common directory names at repo root
    for d in .worktrees _worktrees worktrees; do
      [ -d "$REPO_ROOT/$d" ] && echo "Found: $REPO_ROOT/$d" && break
    done
  fi
  ```
  If a directory is found, use it.
- If not found, check the project's `CLAUDE.md` and `AGENTS.md` for a project-specific worktree location before creating anything. **Walk from the current directory up to the git repo root** so the check works even when the skill is invoked from a subdirectory:
  ```bash
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  DIR=$(pwd)
  while :; do
    [ -f "$DIR/CLAUDE.md" ] && grep -iHE 'worktree' "$DIR/CLAUDE.md" 2>/dev/null
    [ -f "$DIR/AGENTS.md" ] && grep -iHE 'worktree' "$DIR/AGENTS.md" 2>/dev/null
    [ "$DIR" = "$REPO_ROOT" ] && break
    [ "$DIR" = "/" ] && break
    DIR=$(dirname "$DIR")
  done
  ```
  If any ancestor `CLAUDE.md` / `AGENTS.md` defines a worktree convention, follow it instead of `.worktrees`.
- Only if none of the above applies, ask me for permission to create a `.worktrees` directory, and create it if given permission.
- **Remember the chosen directory as `$WORKTREE_DIR`** (e.g., `.worktrees`, `_worktrees`, or whatever the project uses). Steps 2 and 3 reference this variable.

2. Verify .gitignore before creating a worktree using the Bash tool. **Only applies when `$WORKTREE_DIR` is inside the repo** — worktrees that live outside the repo do not need (and should not get) an entry in repo `.gitignore`, since adding the basename could accidentally ignore an unrelated in-repo directory with the same name:

```bash
# Resolve $WORKTREE_DIR to an absolute path so we can compare with $REPO_ROOT.
# Directory may not exist yet — handle both "exists but relative" and "doesn't
# exist" cases by resolving relative paths against $REPO_ROOT rather than
# leaving them as raw strings (which would be misclassified as outside-repo).
WT_ABS=$(cd "$WORKTREE_DIR" 2>/dev/null && pwd)
if [ -z "$WT_ABS" ]; then
  case "$WORKTREE_DIR" in
    /*) WT_ABS="$WORKTREE_DIR" ;;                # already absolute
    *)  WT_ABS="$REPO_ROOT/$WORKTREE_DIR" ;;     # relative → resolve against repo root
  esac
fi

# Only validate .gitignore when the worktree dir is inside the repo
case "$WT_ABS/" in
  "$REPO_ROOT"/*)
    # Use the REPO-RELATIVE path, not basename. Gitignore semantics:
    # a bare `worktrees/` pattern matches ANY directory named `worktrees`
    # at any depth, which can accidentally ignore unrelated paths. A path
    # anchored from the repo root (e.g., `tools/worktrees/`) matches only
    # that specific location.
    WT_REL="${WT_ABS#$REPO_ROOT/}"
    WT_REL_ESC=$(printf '%s' "$WT_REL" | sed 's/[.[\*^$()+?{|\\]/\\&/g')

    # Check if the exact repo-relative path (with or without leading slash /
    # trailing slash) is already ignored
    grep -qE "^/?${WT_REL_ESC}/?$" "$REPO_ROOT/.gitignore"
    ;;
  *)
    echo "Worktree dir is outside the repo — skipping .gitignore check"
    ;;
esac
```

- If the worktree dir is inside the repo and the pattern is not found, add a repo-relative entry (e.g., `/tools/worktrees/` or `/.worktrees/`) to `$REPO_ROOT/.gitignore` immediately. Do not use the basename alone.

3. Create the worktree

- Come up with a good branch name based on the request and assign it to `$BRANCH_NAME`.
- Handle four scenarios (existing worktree → local branch → remote branch → new branch):

```bash
# Assign the branch name you picked above
BRANCH_NAME="feature/your-branch-name"
# $WORKTREE_DIR was already determined in Step 1 (may be .worktrees,
# _worktrees, or a project-specific path). Only set a fallback if unset —
# do NOT overwrite the value Step 1 derived.
: "${WORKTREE_DIR:=.worktrees}"

# Normalize to an absolute path anchored at $REPO_ROOT so that the
# `git worktree add` commands below work correctly regardless of the
# current working directory. A bare relative $WORKTREE_DIR would be
# resolved against $PWD, which breaks when the skill is invoked from
# a subdirectory (e.g., `src/foo/.worktrees/...` instead of the
# discovered project worktree directory).
case "$WORKTREE_DIR" in
  /*) WT_PATH="$WORKTREE_DIR" ;;
  *)  WT_PATH="$REPO_ROOT/$WORKTREE_DIR" ;;
esac

# 1. Check if a worktree for this branch already exists.
#    Use awk with a literal string compare so branch names containing regex
#    metacharacters (e.g., `release/1.0`) aren't matched against siblings.
EXISTING_WT=$(git worktree list --porcelain \
  | awk -v b="refs/heads/$BRANCH_NAME" '
      /^worktree / { wt = substr($0, 10) }
      $0 == "branch " b { print wt; exit }
    ')

if [ -n "$EXISTING_WT" ]; then
  # Worktree already exists for this branch — reuse it
  echo "Reusing existing worktree at: $EXISTING_WT"
elif git show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
  # Local branch exists, no worktree — attach
  git worktree add "$WT_PATH/$BRANCH_NAME" "$BRANCH_NAME"
elif git ls-remote --exit-code --heads origin "$BRANCH_NAME" >/dev/null 2>&1; then
  # Remote branch exists but no local — fetch and track origin to preserve history
  git fetch origin "$BRANCH_NAME"
  git worktree add "$WT_PATH/$BRANCH_NAME" -b "$BRANCH_NAME" "origin/$BRANCH_NAME"
else
  # Branch does not exist anywhere — create new from current HEAD
  git worktree add "$WT_PATH/$BRANCH_NAME" -b "$BRANCH_NAME"
fi
```

**Why check existing worktree first:** If the branch is already checked out in another worktree, `git worktree add` will error. Detecting and reusing the existing path lets agents resume prior work without manual cleanup.

**Why check remote:** If `$BRANCH_NAME` only exists on `origin` (e.g., resuming a teammate's work or an earlier session), creating with just `-b` branches from current HEAD and diverges from the real history — later `git push` fails as non-fast-forward.

- cd into the worktree path: `cd "$EXISTING_WT"` (reuse case) or `cd "$WT_PATH/$BRANCH_NAME"` (new worktree case)

4. Auto-detect and run project setup.

```bash
# Node.js
if [ -f package.json ]; then npm install; fi

# Rust
if [ -f Cargo.toml ]; then cargo build; fi

# Python
if [ -f requirements.txt ]; then pip install -r requirements.txt; fi
if [ -f pyproject.toml ]; then poetry install; fi

# Go
if [ -f go.mod ]; then go mod download; fi
```

- If there is no obvious project setup, you _MUST_ ask me.

5. Run tests to ensure the worktree is clean.

```bash
# Examples - use project-appropriate command
npm test
cargo test
pytest
go test ./...
```

**If tests fail:** Report failures, ask whether to proceed or investigate.

**If tests pass:** Report ready.

6. Report Location

```
New working directory: <full-path>
Tests passing (<N> tests, 0 failures)
All commands and tools will now refer to: <full-path>
```

7. Understand that you are now in a new working directory. Your Bash tool instructions from here on out should refer to the worktree directory, NOT your original directory. This is ABSOLUTELY CRITICAL.

</required>

# Maintaining Working Directory in Worktree

CRITICAL: Once you create and enter a worktree, you must stay within
it for the entire session.

Rules:

1. Never use cd .. from within a worktree - It will eventually take
   you outside the worktree boundary
2. Always use absolute paths for commands - Use npm run lint from
   within the worktree, not cd .. && npm run lint
3. If you need to run root-level commands, use the full worktree path:
   <bad-example>
   cd .. && npm run lint
   </bad-example>
   <good-example>
   npm run lint # (from worktree root)
   </good-example>

<good-example>
cd /home/$USER/code/project/.worktrees/branch-name && npm run lint
</good-example>

4. Verify your location frequently:

```bash
pwd  # Should show .worktrees/branch-name in path
git branch  # Should show * on your feature branch, not main
```

5. If you accidentally exit the worktree:

- Immediately recognize it (check if you're on main branch)
- Navigate back: cd /full/path/to/.worktrees/your-branch
- Verify: git branch should show your branch, not main

Red Flags:

- Running git status and seeing "On branch main" when you should be on a feature branch
- Running pwd and NOT seeing .worktrees/ in the path
- Any cd .. command while in a worktree

# Quick Reference

| Situation                         | Action                                                                       |
| --------------------------------- | ---------------------------------------------------------------------------- |
| Project worktree dir exists       | Use it (verify .gitignore)                                                   |
| Project worktree dir missing      | Check `CLAUDE.md` / `AGENTS.md` (current dir up to repo root) → else ask user |
| Directory not in .gitignore       | Add it immediately                                                           |
| Tests fail during baseline        | Report failures + ask                                                        |
| No package.json/Cargo.toml        | Skip dependency install                                                      |

# Common Mistakes

**Skipping .gitignore verification**

- **Problem:** Worktree contents get tracked, pollute git status
- **Fix:** Always grep .gitignore before creating project-local worktree

**Assuming directory location**

- **Problem:** Creates inconsistency, violates project conventions
- **Fix:** Follow priority: existing > `CLAUDE.md` / `AGENTS.md` (including ancestors) > ask

**Missing project installation**

- **Problem:** Tests and lint will fail, breaking the project
- **Fix:** Always install the project when creating a new worktree

**Proceeding with failing tests**

- **Problem:** Can't distinguish new bugs from pre-existing issues
- **Fix:** Report failures, get explicit permission to proceed

**Hardcoding setup commands**

- **Problem:** Breaks on projects using different tools
- **Fix:** Auto-detect from project files (package.json, etc.)

# Example Workflow

```
You: I'm using the Using Git Worktrees skill to set up an isolated workspace.

[Check .worktrees/ - exists]
[Verify .gitignore - contains .worktrees/]
[Create worktree: git worktree add .worktrees/auth -b feature/auth]
[Run npm install]
[Run npm test - 47 passing]

Worktree ready at myproject/.worktrees/auth
Tests passing (47 tests, 0 failures)
Ready to implement auth feature
```

# Red Flags

**Never:**

- Create worktree without .gitignore verification (project-local)
- Skip baseline test verification
- Proceed with failing tests without asking
- Assume directory location when ambiguous
- Skip `CLAUDE.md` / `AGENTS.md` check (including ancestor directories up to the repo root)

**Always:**

- Follow directory priority: existing > `CLAUDE.md` / `AGENTS.md` (including ancestors) > ask
- Verify .gitignore for project-local
- Auto-detect and run project setup
- Verify clean test baseline
