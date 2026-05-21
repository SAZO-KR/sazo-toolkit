# Noridoc: lib

Path: @/packages/ai-harness/lib

### Overview

- Single-file shared library (`installer-common.sh`) sourced by all install/uninstall scripts across the ai-harness system
- Pure bash + coreutils with zero external dependencies (no jq, no python)
- Provides logging, interactive prompts, file operations, platform detection, process locking, sparse git clone, and the receipt system

### How it fits into the larger codebase

- Sourced by `@/packages/ai-harness/install.sh` (root installer) and `@/packages/ai-harness/uninstall.sh` (root uninstaller)
- Sourced by every tool-level installer and uninstaller under `@/packages/ai-harness/tools/*/`
- Defines the receipt file format and storage location (`~/.config/sazo-ai-harness/receipts/`) that tool uninstallers depend on
- Defines exit code constants that tool installers return to the root installer
- The smoke tests at `@/packages/ai-harness/tests/installer.smoke.sh` verify that all public functions are properly defined and that key behaviors (platform check, receipt CRUD, non-interactive mode) work correctly

### Core Implementation

- **Receipt system**: Tracks every installed artifact as `<type>:<path>` lines in `~/.config/sazo-ai-harness/receipts/<tool>.receipt`. Entry types: `symlink`, `file`, `sudo:file`, `dir`, `state`. `remove_receipt_entries()` processes entries in reverse order so deeper paths are cleaned before parent directories. Receipts are append-only during install; `clear_receipt()` deletes the entire file.
- **Process locking**: `acquire_lock()` uses `mkdir`-based atomic locking with a PID file inside the lock directory. Stale locks (owner PID dead or lock older than 30 seconds) are automatically reclaimed. Up to 50 attempts with 50ms sleep between retries.
- **Interactive prompts**: `ask_yes_no()` reads from `/dev/tty` when stdin is piped (curl|bash scenario), falls back to stdin when interactive, and auto-accepts the default when `SAZO_NON_INTERACTIVE=1`.
- **Platform detection**: `check_platform()` compares against `uname -s` (overridable via `SAZO_UNAME`) and returns `EXIT_PLATFORM_UNSUPPORTED` (3) on mismatch. Accepts `any`, `darwin`, `linux`.
- **Sparse clone**: `sparse_clone_tool()` does a shallow, filtered, sparse git clone of the repo, checking out only the specified path. On re-run, it `git pull --ff-only` instead.

### Things to Know

- The script sets `set -uo pipefail` (not `-e`) because it's sourced, not executed — the sourcing script controls `set -e` behavior
- `safe_symlink()` refuses to overwrite regular files (only replaces existing symlinks), logging a skip warning — this prevents clobbering user-customized files
- `remove_harness_symlinks()` only removes symlinks whose targets contain `sazo-ai-harness` or `sazo-ai-prompts` in the path, leaving unrelated symlinks untouched
- Exit codes are defined as named constants (`EXIT_OK=0`, `EXIT_FAIL=1`, `EXIT_SUDO_DENIED=2`, `EXIT_PLATFORM_UNSUPPORTED=3`) and `EXIT_ALREADY_INSTALLED=0` is intentionally the same as success

Created and maintained by Nori.
