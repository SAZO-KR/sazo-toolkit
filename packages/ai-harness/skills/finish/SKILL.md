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
  # Require at least one parser AND require that parse actually succeeds.
  # A malformed package.json or missing parser must escalate, not silently
  # skip the Node branch (polyglot repo could mark PR gate clean otherwise).
  HAS_TEST=""
  PARSE_FAIL=""
  if command -v jq >/dev/null 2>&1; then
    if ! HAS_TEST=$(jq -r '.scripts.test // empty' package.json 2>/dev/null); then
      PARSE_FAIL="jq failed to parse package.json (invalid JSON?)"
    fi
  elif command -v node >/dev/null 2>&1; then
    if ! HAS_TEST=$(node -e "console.log((require('./package.json').scripts||{}).test||'')" 2>/dev/null); then
      PARSE_FAIL="node failed to read/parse package.json"
    fi
  else
    PARSE_FAIL="neither jq nor node on PATH"
  fi
  if [ -n "$PARSE_FAIL" ]; then
    echo "Cannot determine scripts.test — $PARSE_FAIL. Ask the user." >&2
    FAILED=1; RAN=1
    HAS_TEST=""
  fi
  if [ -n "$HAS_TEST" ]; then
    # Detect the declared package manager (mirrors isolate Step 4) — do NOT
    # hardcode `npm test`, and do NOT fall back to a different tool when a
    # lockfile is present. Running tests under the wrong resolver produces
    # misleading PR-gate results (false pass/fail) and can mutate lockfiles.
    PM_CMD=""
    PM_ERR=""
    if   [ -f pnpm-lock.yaml ]; then
      if command -v pnpm >/dev/null 2>&1; then PM_CMD="pnpm"
      else PM_ERR="pnpm-lock.yaml found but pnpm is not installed"
      fi
    elif [ -f yarn.lock ]; then
      if command -v yarn >/dev/null 2>&1; then PM_CMD="yarn"
      else PM_ERR="yarn.lock found but yarn is not installed"
      fi
    elif [ -f bun.lockb ] || [ -f bun.lock ]; then
      if command -v bun >/dev/null 2>&1; then PM_CMD="bun"
      else PM_ERR="bun lockfile found but bun is not installed"
      fi
    elif [ -f package-lock.json ]; then
      if command -v npm >/dev/null 2>&1; then PM_CMD="npm"
      else PM_ERR="package-lock.json found but npm is not installed"
      fi
    else
      # No lockfile — packageManager field or npm default
      PM=$(
        command -v jq >/dev/null 2>&1 \
          && jq -r '.packageManager // empty' package.json 2>/dev/null \
          || node -e "console.log(require('./package.json').packageManager||'')" 2>/dev/null
      )
      PM=$(echo "$PM" | cut -d@ -f1)
      if [ -n "$PM" ]; then
        if command -v "$PM" >/dev/null 2>&1; then PM_CMD="$PM"
        else PM_ERR="packageManager=$PM declared but $PM is not installed"
        fi
      elif command -v npm >/dev/null 2>&1; then
        PM_CMD="npm"   # no declared manager, safe default
      fi
    fi
    if [ -n "$PM_CMD" ]; then
      # Bun gotcha: `bun test` runs Bun's native test runner, NOT
      # scripts.test — use `bun run test` for package scripts.
      if [ "$PM_CMD" = "bun" ]; then bun run test || FAILED=1
      else "$PM_CMD" test || FAILED=1
      fi
      RAN=1
    else
      echo "Node test runner not available — ${PM_ERR:-no manager on PATH}. Ask the user." >&2
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
# Gate each language's lint command on (a) project-marker presence and
# (b) tool availability. Single-stack repos must not run `cargo clippy`
# when no `Cargo.toml` exists, and a missing Node runner must be a hard
# stop — not a soft warning — or PRs can bypass the linter gate entirely.
#
# Aggregate exit codes like Step 1 tests — an earlier lint failure must
# NOT be masked by a later-passing one in polyglot repos.
LINT_FAILED=0

# Node.js — detect the declared package manager (mirrors Step 1 test detection).
# Hardcoding `npm run lint` fails on bun/yarn/pnpm-managed repos where npm
# is unavailable.
if [ -f package.json ]; then
  # Only run lint if a `lint` script is actually defined. Require the
  # parser to SUCCEED (not just exist) — a malformed package.json with jq
  # installed would otherwise silently skip the lint gate.
  HAS_LINT=""
  PARSE_FAIL=""
  if command -v jq >/dev/null 2>&1; then
    if ! HAS_LINT=$(jq -r '.scripts.lint // empty' package.json 2>/dev/null); then
      PARSE_FAIL="jq failed to parse package.json (invalid JSON?)"
    fi
  elif command -v node >/dev/null 2>&1; then
    if ! HAS_LINT=$(node -e "console.log((require('./package.json').scripts||{}).lint||'')" 2>/dev/null); then
      PARSE_FAIL="node failed to read/parse package.json"
    fi
  else
    PARSE_FAIL="neither jq nor node on PATH"
  fi
  if [ -n "$PARSE_FAIL" ]; then
    echo "Cannot determine scripts.lint — $PARSE_FAIL. Ask the user." >&2
    LINT_FAILED=1
    HAS_LINT=""
  fi
  if [ -n "$HAS_LINT" ]; then
    PM_CMD=""
    PM_ERR=""
    if   [ -f pnpm-lock.yaml ]; then
      command -v pnpm >/dev/null 2>&1 && PM_CMD="pnpm" || PM_ERR="pnpm-lock.yaml found but pnpm is not installed"
    elif [ -f yarn.lock ]; then
      command -v yarn >/dev/null 2>&1 && PM_CMD="yarn" || PM_ERR="yarn.lock found but yarn is not installed"
    elif [ -f bun.lockb ] || [ -f bun.lock ]; then
      command -v bun  >/dev/null 2>&1 && PM_CMD="bun"  || PM_ERR="bun lockfile found but bun is not installed"
    elif [ -f package-lock.json ]; then
      command -v npm  >/dev/null 2>&1 && PM_CMD="npm"  || PM_ERR="package-lock.json found but npm is not installed"
    else
      PM=$(
        command -v jq >/dev/null 2>&1 \
          && jq -r '.packageManager // empty' package.json 2>/dev/null \
          || node -e "console.log(require('./package.json').packageManager||'')" 2>/dev/null
      )
      PM=$(echo "$PM" | cut -d@ -f1)
      if [ -n "$PM" ]; then
        command -v "$PM" >/dev/null 2>&1 && PM_CMD="$PM" || PM_ERR="packageManager=$PM declared but $PM is not installed"
      elif command -v npm >/dev/null 2>&1; then
        PM_CMD="npm"
      fi
    fi

    if [ -n "$PM_CMD" ]; then
      # Bun gotcha: `bun run lint` not `bun lint` (bun lint is not a thing).
      "$PM_CMD" run lint || LINT_FAILED=1
    else
      echo "Node lint gate cannot run — ${PM_ERR:-no manager on PATH}. Install the declared package manager or ask the user." >&2
      LINT_FAILED=1
    fi
  fi
fi

# Rust — gate by Cargo.toml presence AND clippy availability.
if [ -f Cargo.toml ]; then
  if command -v cargo >/dev/null 2>&1; then
    cargo clippy --fix --allow-dirty --allow-staged || LINT_FAILED=1
  else
    echo "Cargo.toml found but cargo is not installed — ask the user." >&2
    LINT_FAILED=1
  fi
fi

# Python — gate by project markers AND tool availability. In managed
# environments (poetry/uv/pdm/hatch), linters may only be installed inside
# the venv, so try `<manager> run <linter>` before declaring lint unavailable.
if [ -f pyproject.toml ] || [ -f setup.py ] || [ -f setup.cfg ] \
  || [ -f .flake8 ]     || [ -f ruff.toml ]; then
  PY_LINT_RAN=false
  # 1. Try globally-available linters first (fastest, no venv overhead)
  if   command -v ruff   >/dev/null 2>&1; then ruff check --fix . || LINT_FAILED=1; PY_LINT_RAN=true
  elif command -v flake8 >/dev/null 2>&1; then flake8 . || LINT_FAILED=1; PY_LINT_RAN=true
  elif command -v pylint >/dev/null 2>&1; then pylint . || LINT_FAILED=1; PY_LINT_RAN=true
  fi

  # 2. Not found globally — try via managed-env runner (mirrors test detection).
  #    Fall back between tools only based on AVAILABILITY (--version succeeds),
  #    not on exit code — a genuine ruff lint violation must NOT be masked by
  #    trying flake8 next.
  if [ "$PY_LINT_RAN" = false ] && [ -f pyproject.toml ]; then
    # Accept the runner as separate words via "$@" — NEVER quote it as a
    # single "poetry run" string, or the shell looks for a literal binary
    # named "poetry run" and the lint detection silently always fails.
    run_managed_lint() {
      if "$@" ruff --version >/dev/null 2>&1; then
        "$@" ruff check --fix . || LINT_FAILED=1
      elif "$@" flake8 --version >/dev/null 2>&1; then
        "$@" flake8 . || LINT_FAILED=1
      elif "$@" pylint --version >/dev/null 2>&1; then
        "$@" pylint . || LINT_FAILED=1
      else
        return 1  # no supported linter (ruff/flake8/pylint) in this env
      fi
      return 0
    }
    if   grep -q '^\[tool\.poetry\]' pyproject.toml && command -v poetry >/dev/null 2>&1; then
      run_managed_lint poetry run && PY_LINT_RAN=true
    elif { grep -q '^\[tool\.uv\]'  pyproject.toml || [ -f uv.lock ]; } && command -v uv >/dev/null 2>&1; then
      run_managed_lint uv run && PY_LINT_RAN=true
    elif { grep -q '^\[tool\.pdm\]' pyproject.toml || [ -f pdm.lock ]; } && command -v pdm >/dev/null 2>&1; then
      run_managed_lint pdm run && PY_LINT_RAN=true
    elif grep -q '^\[tool\.hatch\]' pyproject.toml && command -v hatch >/dev/null 2>&1; then
      hatch run lint 2>/dev/null || LINT_FAILED=1; PY_LINT_RAN=true
    fi
    unset -f run_managed_lint 2>/dev/null
  fi

  if [ "$PY_LINT_RAN" = false ]; then
    echo "Python project detected but no linter available (globally or in managed env) — ask the user." >&2
    LINT_FAILED=1
  fi
fi

# Go — only lint when the project explicitly uses golangci-lint (config file
# present), not just because go.mod exists. Many Go projects don't use it.
# golangci-lint auto-detects .yml/.yaml/.toml/.json formats.
if [ -f go.mod ] && { [ -f .golangci.yml ] || [ -f .golangci.yaml ] \
  || [ -f .golangci.toml ] || [ -f .golangci.json ]; }; then
  if command -v golangci-lint >/dev/null 2>&1; then
    golangci-lint run --fix || LINT_FAILED=1
  else
    echo "golangci-lint config found but golangci-lint is not installed — ask the user." >&2
    LINT_FAILED=1
  fi
fi

if [ "$LINT_FAILED" = "1" ]; then
  echo "One or more lint steps failed — fix issues before proceeding to PR creation." >&2
  exit 1
fi
```

5. Use the Task tool to run type checking and fix issues in a subagent.

6. Self-review — run a multi-perspective code review and **treat its verdict as a gating check, not a casual "fresh pair of eyes"**:

   - **Preferred:** use the `/review-work` command. ALL reviewers must PASS to proceed.
   - **Fallback 1:** follow the `review` skill (`~/.claude/skills/review/SKILL.md`), which launches 5 independent agents (correctness / architecture / security / performance / test quality) under the same PASS/FAIL gate.
   - **Fallback 2 (last resort):** consult the `architect-advisor` subagent with the full `git diff`, then apply the same PASS/FAIL criteria manually.

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
