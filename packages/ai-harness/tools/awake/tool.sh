# tool.sh - awake tool metadata
# Sourced by the root installer to discover available tools.
# Convention: tools/*/tool.sh must exist and define these variables.

TOOL_NAME="awake"
TOOL_DESC="macOS closed-lid execution persistence CLI"
TOOL_VERSION="1.0.0"
TOOL_PLATFORM="darwin"       # "any" for cross-platform, or specific OS
TOOL_REQUIRES_SUDO="optional"  # "yes" | "no" | "optional"