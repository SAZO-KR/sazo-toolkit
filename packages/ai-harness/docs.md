# Noridoc: ai-harness

Path: @/packages/ai-harness

### Overview

- Modular installer system that lets team members install only the AI-agent tools they need
- Two-tier architecture: a root installer offers an interactive menu, each tool under `tools/<name>/` is a self-contained package with its own install/uninstall
- Also houses shared Claude/OpenCode artifacts (agents, skills, commands) that are symlinked into user dotfiles on install

### How it fits into the larger codebase

- One of several independent packages under `@/packages/`; shares no code with the Go-based Slack bot packages
- The root `CLAUDE.md` references this package for CI validation: `bash -n install.sh && bash -n uninstall.sh && bash tests/installer.smoke.sh`
- At install time, the entire `packages/ai-harness` subtree is sparse-cloned into `~/.config/sazo-ai-harness/` on the user's machine — this cloned copy becomes the source of truth for symlinks and tool scripts
- The installer creates symlinks from the cloned repo into `~/.claude/{commands,skills,agents}/` and optionally `~/.config/opencode/commands/`

### Core Implementation

- **Root installer** (`install.sh`): parses CLI flags (`--tools`, `--yes`, `--help`), sparse-clones the repo, sources `@/packages/ai-harness/lib/installer-common.sh`, discovers tools via `tools/*/tool.sh` convention, presents an interactive numbered menu, then delegates to each selected tool's `install.sh`
- **Root uninstaller** (`uninstall.sh`): supports `--tool <name>` for per-tool removal or full teardown; during full uninstall it runs every tool's uninstaller, then cleans symlinks, `settings.json` hooks, `CLAUDE.md` managed blocks, OpenCode config entries, and finally removes the installation directory
- **Tool discovery** happens by globbing `tools/*/tool.sh` — no central registry; adding a new tool only requires placing it under `tools/<name>/`
- **Environment variable contracts** coordinate between root and child installers:

| Variable | Purpose |
|---|---|
| `SAZO_ROOT_INSTALL=1` | Set by root installer; child installers skip the sparse-clone step when this is set |
| `SAZO_NON_INTERACTIVE=1` | Suppresses all interactive prompts (auto-accepts defaults); set by `--tools` or `--yes` flags |
| `SAZO_UNAME` | Overrides `uname -s` for platform detection in tests |
| `SAZO_BASE_DIR` | Overrides the default base directory (`~/.config/sazo-ai-harness`) |

### Things to Know

- The root installer sets `SAZO_ROOT_INSTALL=1` and `export`s it before invoking tool installers; this is the mechanism that prevents each tool from re-cloning the repo when invoked as a child process
- `install.sh` includes legacy agent cleanup: it checks for a hardcoded list of old agent filenames in `~/.claude/agents/` and offers to remove them interactively
- The cleanup trap in `install.sh` only removes `$INSTALL_DIR` on failure if the directory was freshly created during this run (`CREATED_INSTALL_DIR=1`), avoiding destruction of existing installations on partial failures
- The uninstaller gracefully degrades when `installer-common.sh` is missing (e.g., if the install directory was already partially deleted) by defining fallback `info`/`skip`/`warn` functions inline
- Full uninstall performs 8 ordered phases: per-tool uninstallers → awake legacy process cleanup → LaunchAgent cleanup → symlink removal → settings.json hook cleanup → CLAUDE.md managed block cleanup → OpenCode config cleanup → installation directory removal

Created and maintained by Nori.
