# Noridoc: awake

Path: @/packages/ai-harness/tools/awake

### Overview

- macOS-only CLI tool that prevents the system from sleeping when the lid is closed
- First tool implemented under the modular installer system at `@/packages/ai-harness/tools/`
- Has optional root-owned helper and sudoers components for controlling system-level `pmset` settings

### How it fits into the larger codebase

- Follows the tool packaging convention defined in `@/packages/ai-harness/tools/` — includes `tool.sh`, `install.sh`, `uninstall.sh`, `scripts/`, `commands/`, and `tests/`
- Sources `@/packages/ai-harness/lib/installer-common.sh` for shared infrastructure (receipts, locking, platform checks, logging)
- The root installer at `@/packages/ai-harness/install.sh` discovers this tool by finding `tool.sh` and presents it in the interactive menu
- The `/awake` Claude command definition at `commands/awake.md` integrates with the Claude CLI environment

### Core Implementation

- **Installer** (`install.sh`): checks platform is darwin, acquires a process lock, creates a symlink at `~/.local/bin/awake` → `scripts/awake.sh`, optionally installs a root-owned helper binary at `/usr/local/libexec/sazo-ai-harness/awake-helper` and a passwordless sudoers entry at `/etc/sudoers.d/sazo-ai-harness-awake`. Writes all installed artifacts to a receipt file.
- **Uninstaller** (`uninstall.sh`): runs `awake off` or `awake reset` to restore sleep settings before removal, then proceeds through 6 ordered phases: stop awake process → remove CLI symlink → remove root helper/sudoers → receipt-based cleanup → leftover file cleanup → command symlink cleanup
- **State files**: runtime state is stored in `~/.config/sazo-ai-harness/` — `awake.pid`, `awake.expires`, `awake.state`

### Things to Know

- `tool.sh` declares `TOOL_PLATFORM="darwin"` — the installer exits with code 3 (`EXIT_PLATFORM_UNSUPPORTED`) on non-macOS systems
- `TOOL_REQUIRES_SUDO="optional"` — the core CLI symlink installs without sudo, but the closed-lid helper requires `sudo install` and the sudoers entry requires `sudo visudo -cf` + `sudo cp`
- The installer validates sudoers syntax via `visudo -cf` on a temp file before copying to `/etc/sudoers.d/` to prevent lockout
- The CLI symlink at `~/.local/bin/awake` is only created/replaced if the target is either absent or already a harness-managed symlink (checked via `grep -qE "sazo-ai-harness|sazo-ai-prompts"` on the readlink output); regular files or foreign symlinks are preserved
- The uninstaller actively calls `awake off` before removing artifacts because awake modifies system-level `pmset` settings that persist beyond process lifetime — removing files without resetting `pmset` would leave the system in a modified state

Created and maintained by Nori.
