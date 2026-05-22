# Noridoc: tools

Path: @/packages/ai-harness/tools

### Overview

- Convention-based directory where each subdirectory is a self-contained, independently installable tool
- The root installer at `@/packages/ai-harness/install.sh` discovers tools by globbing `tools/*/tool.sh`
- Currently contains one tool: `awake`

### How it fits into the larger codebase

- The root installer iterates over this directory to build its interactive menu and dispatch installs
- The root uninstaller iterates over this directory to find and run each tool's `uninstall.sh`
- Each tool sources the shared library at `@/packages/ai-harness/lib/installer-common.sh` for logging, receipts, locking, and platform checks
- Adding a new tool requires only creating a new subdirectory here with the correct structure — no changes to the root installer or any registry

### Core Implementation

Every tool must follow this directory convention:

```
tools/<name>/
├── tool.sh          # REQUIRED: manifest with metadata variables
├── install.sh       # REQUIRED: standalone installer (curl|bash compatible)
├── uninstall.sh     # REQUIRED: receipt-based uninstaller
├── scripts/         # Tool runtime scripts
├── commands/        # Claude/OpenCode command definitions
└── tests/           # Smoke tests
```

The `tool.sh` manifest must define these variables:

| Variable | Description | Example values |
|---|---|---|
| `TOOL_NAME` | Tool identifier (matches directory name) | `awake` |
| `TOOL_DESC` | Human-readable description | `macOS closed-lid execution persistence CLI` |
| `TOOL_VERSION` | Semver version string | `1.0.0` |
| `TOOL_PLATFORM` | Required OS: `any`, `darwin`, or `linux` | `darwin` |
| `TOOL_REQUIRES_SUDO` | `yes`, `no`, or `optional` | `optional` |

### Things to Know

- Tool discovery is purely convention-based: the root installer's `discover_tools()` scans for `tools/*/tool.sh` and ignores directories without a manifest
- Each tool's `install.sh` must be independently runnable via `curl | bash` — when `SAZO_ROOT_INSTALL` is not set, the tool installer performs its own sparse git clone
- Tool installers write receipts via `write_receipt()` from the shared library; tool uninstallers read and clear those receipts — this is the contract that makes uninstallation precise
- The root installer loads tool metadata by sourcing `tool.sh` in a subshell to avoid variable pollution

Created and maintained by Nori.
