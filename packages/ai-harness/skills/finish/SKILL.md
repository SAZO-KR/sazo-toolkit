---
name: finish
description: Use when implementation and tests are complete and you are ready to push, create a PR, and verify CI.
---

<required>
*CRITICAL* Add the following steps to your Todo list using TodoWrite:

1. Use the Task tool to verify tests by using the project's test suite.

```bash
# Detect EVERY stack present in the repo and run each matching test suite.
# Must be additive (not if/elif) — polyglot repos with both package.json and
# go.mod would otherwise silently skip one language's tests before PR gating.
#
# Preserve exit codes across suites: a failing `npm test` must NOT be masked
# by a later-passing `cargo test`. We aggregate into $FAILED and check at the
# end, and we mark $RAN=1 ONLY after a real test command runs (not when
# detection fails) so the "No recognized test suite" guard stays meaningful.
RAN=0
FAILED=0
if [ -f package.json ]; then
  HAS_TEST=$(
    command -v jq >/dev/null 2>&1 \
      && jq -r '.scripts.test // empty' package.json \
      || node -e "console.log((require('./package.json').scripts||{}).test||'')" 2>/dev/null
  )
  if [ -n "$HAS_TEST" ]; then
    # Detect the declared package manager (mirrors isolate Step 4) — do NOT
    # hardcode `npm test` because bun/yarn/pnpm-managed repos would fail with
    # `command not found` even when the real test command would pass.
    PM_CMD=""
    if   [ -f pnpm-lock.yaml ] && command -v pnpm >/dev/null 2>&1; then PM_CMD="pnpm"
    elif [ -f yarn.lock ]      && command -v yarn >/dev/null 2>&1; then PM_CMD="yarn"
    elif { [ -f bun.lockb ] || [ -f bun.lock ]; } && command -v bun >/dev/null 2>&1; then PM_CMD="bun"
    elif [ -f package-lock.json ] && command -v npm >/dev/null 2>&1; then PM_CMD="npm"
    else
      PM=$(
        command -v jq >/dev/null 2>&1 \
          && jq -r '.packageManager // empty' package.json 2>/dev/null \
          || node -e "console.log(require('./package.json').packageManager||'')" 2>/dev/null
      )
      PM=$(echo "$PM" | cut -d@ -f1)
      if [ -n "$PM" ] && command -v "$PM" >/dev/null 2>&1; then PM_CMD="$PM"
      elif [ -z "$PM" ] && command -v npm >/dev/null 2>&1; then PM_CMD="npm"
      fi
    fi
    if [ -n "$PM_CMD" ]; then
      "$PM_CMD" test || FAILED=1
      RAN=1
    else
      echo "Node test runner not available — declared package manager missing and no safe default on PATH. Ask the user." >&2
      FAILED=1; RAN=1
    fi
  fi
fi
if [ -f Cargo.toml ]; then cargo test || FAILED=1; RAN=1; fi

# Python — detect the managed runner (same pattern as the Step 4 install
# detection in `isolate`). Plain `pytest` fails on repos that scope their
# environment through poetry/uv/pdm/hatch or run tox, even when the real
# test command succeeds.
if [ -f pyproject.toml ] || [ -f pytest.ini ] \
  || [ -f setup.py ]     || [ -f tox.ini ]; then
  # Each managed-runner branch requires BOTH (a) the marker/config and
  # (b) the tool binary present in PATH. Otherwise fall through to the
  # next candidate — CI-only metadata (e.g., tox.ini) shouldn't block PRs
  # on machines that rely on a different runner that IS installed.
  if   [ -f tox.ini ] && command -v tox >/dev/null 2>&1;                                       then tox                || FAILED=1; RAN=1
  elif [ -f pyproject.toml ] && grep -q '^\[tool\.poetry\]' pyproject.toml \
    && command -v poetry >/dev/null 2>&1;                                                      then poetry run pytest  || FAILED=1; RAN=1
  elif [ -f pyproject.toml ] && { grep -q '^\[tool\.uv\]'  pyproject.toml || [ -f uv.lock ]; } \
    && command -v uv     >/dev/null 2>&1;                                                      then uv run pytest      || FAILED=1; RAN=1
  elif [ -f pyproject.toml ] && { grep -q '^\[tool\.pdm\]' pyproject.toml || [ -f pdm.lock ]; } \
    && command -v pdm    >/dev/null 2>&1;                                                      then pdm run pytest     || FAILED=1; RAN=1
  elif [ -f pyproject.toml ] && grep -q '^\[tool\.hatch\]' pyproject.toml \
    && command -v hatch  >/dev/null 2>&1;                                                      then hatch run test     || FAILED=1; RAN=1
  elif command -v pytest >/dev/null 2>&1;                                                      then pytest             || FAILED=1; RAN=1
  else
    echo "Python test runner not available — configured tool(s) missing and pytest not on PATH. Ask the user."
    exit 1
  fi
fi

if [ -f go.mod ]; then go test ./... || FAILED=1; RAN=1; fi

if [ "$RAN" = "0" ]; then
  echo "No recognized test suite — ask the user which command to run"
  exit 1
fi
if [ "$FAILED" = "1" ]; then
  echo "One or more test suites failed — cannot proceed to PR creation"
  exit 1
fi
```

**If tests fail:**

```
Tests failing (<N> failures). Must fix before creating PR:

[Show failures]

Cannot proceed until tests pass.
```

2. Confirm that there is some formatting/lint/typechecking in the project. If NONE of these exist, ask me if there was something that you missed.

3. Use the Task tool to run any formatters and fix issues in a subagent.

```bash
# Node.js/JavaScript/TypeScript
ls package.json 2>/dev/null && \
  { command -v jq >/dev/null 2>&1 \
      && jq -r '.scripts | keys[]' package.json \
      || node -e "console.log(Object.keys(require('./package.json').scripts||{}).join('\n'))"; } \
  | grep -E 'format|lint'

# Rust
ls rustfmt.toml .rustfmt.toml 2>/dev/null

# Python
ls .flake8 pyproject.toml setup.cfg 2>/dev/null

# Go
ls .golangci.yml .golangci.yaml 2>/dev/null
```

4. Use the Task tool to run any linters and fix issues in a subagent.

```bash
# Node.js - check package.json scripts
npm run lint  # or: npm run lint:fix, npm run eslint

# Rust
cargo clippy --fix --allow-dirty --allow-staged

# Python
ruff check --fix .
# or: flake8 ., pylint .

# Go
golangci-lint run --fix
```

5. Use the Task tool to run type checking and fix issues in a subagent.

6. Self-review — run a multi-perspective code review and **treat its verdict as a gating check, not a casual "fresh pair of eyes"**:

   - **Preferred:** use the `/review-work` command. ALL reviewers must PASS to proceed.
   - **Fallback 1:** follow the `review` skill (`~/.claude/skills/review/SKILL.md`), which launches 5 independent agents (correctness / architecture / security / performance / test quality) under the same PASS/FAIL gate.
   - **Fallback 2 (last resort):** consult an Oracle agent with the full `git diff`, then apply the same PASS/FAIL criteria manually.

   **Do NOT proceed to push/PR creation while any reviewer reports a correctness, security, or behavioral-regression FAIL.** Minor style/preference suggestions may be deferred at your discretion, but known bugs, security issues, behavioral regressions, or CLAUDE.md / AGENTS.md rule violations MUST be fixed (or explicitly escalated to the user) before Step 7.

7. Confirm that you are not on the main branch. If you are, ask me before proceeding. NEVER push to main without permission.

8. Push and create a PR.

```bash
# Push branch
git push -u origin <feature-branch>

# Create PR — use --body-file with a temp file (safer than inline --body for
# bodies containing quotes, backticks, or other shell metachars).
PR_BODY_FILE=$(mktemp)
cat <<'EOF' > "$PR_BODY_FILE"
## Summary
🤖 Generated with [Nori](https://www.npmjs.com/package/nori-ai)

<2-3 bullets of what changed>

## Test Plan
- [ ] <verification steps>

Share Nori with your team: https://www.npmjs.com/package/nori-ai
EOF

gh pr create --title "<title>" --body-file "$PR_BODY_FILE"
rm -f "$PR_BODY_FILE"
```

9. Merge the remote default branch and resolve conflicts if necessary, then push the merge before checking CI.

```bash
# Detect the remote default branch (handles main, master, develop, etc.)
DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)

git fetch origin "$DEFAULT_BRANCH"

# Merge the fetched remote default branch into the feature branch
git merge "origin/$DEFAULT_BRANCH"

# If the merge created a commit (merge commit or conflict resolution),
# the remote PR HEAD is now stale. Push so that gh pr checks in step 10
# reflects the actual state we want CI to verify.
git push
```

**Why push before CI check:** `gh pr checks` reads the remote PR HEAD. If you merge locally but don't push, step 10 will report CI status for the OLD PR HEAD (possibly passing) while your local branch has new unreviewed merge content — defeating the purpose of the post-merge CI verification.

**If conflict resolution required substantive code changes** (logic changes, API adjustments, new conditional branches — anything beyond trivial import reordering or whitespace), **re-run Step 6 (self-review)** before proceeding to Step 10. The review gate only covered the pre-merge state; conflict-resolution edits that introduce new logic can harbor regressions or security issues that CI alone may not catch. Trivial mechanical merges (no logic changes) do not require re-review.

10. Make sure the PR branch CI succeeds.

```bash
# Check if the PR CI succeeded
gh pr checks
```

If CI is still running, do **NOT** block the bash tool with `sleep` — long blocking sleeps waste the agent's wall-clock and can hit infrastructure timeouts. Instead, continue with other work (or pause and resume the session) and re-run `gh pr checks` after a short interval until CI reports a final result.

If CI did not pass, examine why and fix the issue.

- Make changes as needed, push a new commit, and repeat the process.
<system-reminder> It is *critical* that you fix any ci issues, EVEN IF YOU DID NOT CAUSE THEM. </system-reminder>

11. Tell me: "I can automatically get review comments, just let me know when to do so."
</required>
