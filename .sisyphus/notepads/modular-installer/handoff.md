# Handoff: modular-installer

## Status
- boulder.json switched to modular-installer plan
- Plan file: `.sisyphus/plans/modular-installer.md`
- **Implementation: 0% complete** — no code written yet
- extract-review-scripts has uncommitted changes in working tree (unrelated to this plan)

## What was done this session
1. Read the full plan (1064 lines, 10 tasks + 4 final reviews)
2. Read reference files: install.sh (278 lines), uninstall.sh (345 lines), awake.sh (first 60 lines)
3. Created todo tracker with 10 work items
4. Was about to start Wave 1 when context limit was reached

## Next steps (resume from here)
1. **Task 2** (quick, do directly): `git mv` awake files to `tools/awake/` structure, create `tool.sh`
   - `scripts/awake/awake.sh` → `tools/awake/scripts/awake.sh`
   - `scripts/awake/awake-helper.sh` → `tools/awake/scripts/awake-helper.sh`
   - `commands/awake.md` → `tools/awake/commands/awake.md`
   - `scripts/tests/awake.smoke.sh` → `tools/awake/tests/awake.smoke.sh`
   - `scripts/tests/awake-helper.smoke.sh` → `tools/awake/tests/awake-helper.smoke.sh`
   - Create `tools/awake/tool.sh` with TOOL_NAME/TOOL_DESC/TOOL_PLATFORM/TOOL_REQUIRES_SUDO

2. **Task 1+3** (delegate as one task): Create `lib/installer-common.sh` with:
   - Logging: log_info, log_warn, log_error
   - Prompts: ask_yes_no (with SAZO_NON_INTERACTIVE support)
   - Files: ensure_dir, safe_symlink
   - Platform: check_platform
   - Locking: acquire_lock, release_lock (mkdir-based)
   - Clone: sparse_clone_tool
   - Receipt: write_receipt, read_receipt, clear_receipt, receipt_exists
   - Exit codes: EXIT_OK=0, EXIT_ALREADY_INSTALLED=0, EXIT_FAIL=1, EXIT_SUDO_DENIED=2, EXIT_PLATFORM_UNSUPPORTED=3
   - Source patterns from existing install.sh (ask_yes_no at lines 25-52, cleanup trap at 18-23, sparse clone at 86-88)

3. Then proceed to Wave 2 (Tasks 4, 5, 6) → Wave 3 (Tasks 7, 8, 9) → Wave 4 (Task 10) → Final reviews

## Key reference files
- `packages/ai-harness/install.sh` — existing installer (278 lines), patterns to extract
- `packages/ai-harness/uninstall.sh` — existing uninstaller (345 lines), patterns to extract
- `packages/ai-harness/scripts/awake/awake.sh` — awake CLI (450 lines), lock pattern at top
- `packages/ai-harness/scripts/awake/awake-helper.sh` — root helper (346 lines)

## Important constraints
- Keep `sazo-ai-harness` naming (no path migration)
- Don't touch agents/, skills/, commands/weekly-report.md
- Receipt system is the source of truth for uninstall (not manifest)
- Convention-based tool discovery: `tools/*/tool.sh` exists = installable
