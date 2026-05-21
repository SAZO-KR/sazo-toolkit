# installer-common.sh — shared utilities for sazo-ai-harness installers.
# Sourced by root and per-tool install/uninstall scripts.
# No external dependencies (jq etc); pure bash + coreutils.

set -uo pipefail

# --- Exit codes ---

EXIT_OK=0
EXIT_ALREADY_INSTALLED=0
EXIT_FAIL=1
EXIT_SUDO_DENIED=2
EXIT_PLATFORM_UNSUPPORTED=3

# --- Directories ---

SAZO_BASE_DIR="${SAZO_BASE_DIR:-$HOME/.config/sazo-ai-harness}"
SAZO_RECEIPT_DIR="${SAZO_BASE_DIR}/receipts"
SAZO_REPO_URL="https://github.com/SAZO-KR/sazo-toolkit.git"

# --- Logging ---

log_info()  { printf "\033[32m✓\033[0m %s\n" "$1"; }
log_warn()  { printf "\033[33m⚠\033[0m %s\n" "$1" >&2; }
log_error() { printf "\033[31m✗\033[0m %s\n" "$1" >&2; }

# --- Interactive prompt ---
# Usage: ask_yes_no "Prompt?" [y|n]
# Respects SAZO_NON_INTERACTIVE=1 (auto-accepts default).

ask_yes_no() {
    local prompt="$1"
    local default="${2:-y}"

    if [ "${SAZO_NON_INTERACTIVE:-0}" = "1" ]; then
        [ "$default" = "y" ] && return 0 || return 1
    fi

    local fd
    if [ ! -t 0 ] && [ -e /dev/tty ]; then
        exec 3</dev/tty
        fd=3
    elif [ -t 0 ]; then
        exec 3<&0
        fd=3
    else
        [ "$default" = "y" ] && return 0 || return 1
    fi

    local yn
    if [ "$default" = "y" ]; then
        printf "%s [Y/n] " "$prompt"
    else
        printf "%s [y/N] " "$prompt"
    fi
    read -r yn <&3 2>/dev/null || yn=""
    exec 3<&- 2>/dev/null || true

    case "$yn" in
        [Yy]*) return 0 ;;
        [Nn]*) return 1 ;;
        "") [ "$default" = "y" ] && return 0 || return 1 ;;
        *) [ "$default" = "y" ] && return 0 || return 1 ;;
    esac
}

# --- File operations ---

ensure_dir() {
    local dir="$1"
    mkdir -p "$dir" || { log_error "Failed to create directory: $dir"; return 1; }
}

safe_symlink() {
    local source="$1"
    local target="$2"

    if [ -L "$target" ]; then
        rm -f "$target"
    elif [ -e "$target" ]; then
        log_warn "Skip: $(basename "$target") (local file exists at $target)"
        return 1
    fi

    ln -s "$source" "$target"
}

# Removes symlinks pointing to sazo-ai-harness or sazo-ai-prompts.
remove_harness_symlinks() {
    local dir="$1"
    local label="$2"
    local count=0

    if [ ! -d "$dir" ]; then
        return 0
    fi

    for item in "$dir"/*; do
        [ -L "$item" ] || continue
        local target
        target=$(readlink "$item" 2>/dev/null || true)
        if echo "$target" | grep -qE "sazo-ai-harness|sazo-ai-prompts"; then
            rm -f "$item"
            count=$((count + 1))
        fi
    done

    if [ "$count" -gt 0 ]; then
        log_info "$label: ${count} symlinks removed"
    fi
    return 0
}

# --- Platform ---

check_platform() {
    local required="$1"
    local current_os="${SAZO_UNAME:-$(uname -s)}"
    case "$required" in
        any) return 0 ;;
        darwin)
            if [ "$current_os" != "Darwin" ]; then
                log_error "This tool requires macOS."
                return "$EXIT_PLATFORM_UNSUPPORTED"
            fi
            return 0
            ;;
        linux)
            if [ "$current_os" != "Linux" ]; then
                log_error "This tool requires Linux."
                return "$EXIT_PLATFORM_UNSUPPORTED"
            fi
            return 0
            ;;
        *)
            log_warn "Unknown platform requirement: $required"
            return 0
            ;;
    esac
}

# --- Process locking (mkdir-based, from awake.sh) ---

SAZO_LOCK_DIR=""
SAZO_LOCK_PID_FILE=""

acquire_lock() {
    local lock_dir="$1"
    local lock_pid_file="$lock_dir/owner.pid"
    local attempt=0 lock_mtime now age owner_pid

    while ! mkdir "$lock_dir" 2>/dev/null; do
        attempt=$((attempt + 1))
        owner_pid="$(cat "$lock_pid_file" 2>/dev/null || true)"
        case "$owner_pid" in
            ''|*[!0-9]*) owner_pid="" ;;
        esac
        if [ -n "$owner_pid" ] && kill -0 "$owner_pid" 2>/dev/null; then
            [ "$attempt" -ge 50 ] && { log_error "Lock contention: another process holds $lock_dir"; return 1; }
            sleep 0.05 2>/dev/null || sleep 1
            continue
        fi
        lock_mtime="$(stat -f %m "$lock_dir" 2>/dev/null || stat -c %Y "$lock_dir" 2>/dev/null || echo 0)"
        now="$(date +%s)"
        age=$(( now - lock_mtime ))
        if [ "$age" -gt 30 ]; then
            rm -f "$lock_pid_file" 2>/dev/null || true
            rmdir "$lock_dir" 2>/dev/null || true
            if mkdir "$lock_dir" 2>/dev/null; then
                printf '%s\n' "$$" > "$lock_pid_file"
                SAZO_LOCK_DIR="$lock_dir"
                SAZO_LOCK_PID_FILE="$lock_pid_file"
                return 0
            fi
        fi
        [ "$attempt" -ge 50 ] && { log_error "Lock timeout: $lock_dir"; return 1; }
        sleep 0.05 2>/dev/null || sleep 1
    done
    printf '%s\n' "$$" > "$lock_pid_file"
    SAZO_LOCK_DIR="$lock_dir"
    SAZO_LOCK_PID_FILE="$lock_pid_file"
    return 0
}

release_lock() {
    [ -n "$SAZO_LOCK_PID_FILE" ] && rm -f "$SAZO_LOCK_PID_FILE" 2>/dev/null || true
    [ -n "$SAZO_LOCK_DIR" ] && rmdir "$SAZO_LOCK_DIR" 2>/dev/null || true
    SAZO_LOCK_DIR=""
    SAZO_LOCK_PID_FILE=""
}

# --- Sparse git clone ---

sparse_clone_tool() {
    local target_dir="$1"
    local repo_url="$2"
    local sparse_path="$3"

    if [ -d "$target_dir/.git" ]; then
        log_info "Updating existing installation..."
        cd "$target_dir"
        git pull --ff-only 2>/dev/null || log_warn "Could not update (local changes?)"
        cd - >/dev/null
    else
        log_info "Installing to $target_dir..."
        rm -rf "$target_dir"
        mkdir -p "$(dirname "$target_dir")"
        git clone --sparse --filter=blob:none --depth=1 --single-branch -b main "$repo_url" "$target_dir"
        cd "$target_dir"
        git sparse-checkout set "$sparse_path"
        cd - >/dev/null
    fi
}

# --- Receipt system ---
# Receipts track what was installed so uninstall can be precise.
# Format: one entry per line, "<type>:<path>"
# Types: symlink, file, sudo:file, dir, state
# Location: ~/.config/sazo-ai-harness/receipts/<tool-name>.receipt

receipt_path() {
    local tool_name="$1"
    printf '%s\n' "$SAZO_RECEIPT_DIR/${tool_name}.receipt"
}

write_receipt() {
    local tool_name="$1"
    shift
    local receipt_file
    receipt_file="$(receipt_path "$tool_name")"
    ensure_dir "$(dirname "$receipt_file")"

    local tmp
    tmp="$(mktemp "${receipt_file}.tmp.XXXXXX")" || return 1

    # Append new entries to existing receipt
    {
        [ -f "$receipt_file" ] && cat "$receipt_file"
        printf '%s\n' "$@"
    } > "$tmp"

    mv "$tmp" "$receipt_file"
}

read_receipt() {
    local tool_name="$1"
    local receipt_file
    receipt_file="$(receipt_path "$tool_name")"
    [ -f "$receipt_file" ] && cat "$receipt_file" || true
}

clear_receipt() {
    local tool_name="$1"
    local receipt_file
    receipt_file="$(receipt_path "$tool_name")"
    rm -f "$receipt_file"
}

# Check if a tool is installed (receipt exists and is non-empty).
is_tool_installed() {
    local tool_name="$1"
    local receipt_file
    receipt_file="$(receipt_path "$tool_name")"
    [ -f "$receipt_file" ] && [ -s "$receipt_file" ]
}

# Remove files/dirs listed in a receipt, by type.
# Processes entries in reverse order so dirs are emptied before removal.
remove_receipt_entries() {
    local tool_name="$1"
    local entries
    entries="$(read_receipt "$tool_name")"

    if [ -z "$entries" ]; then
        log_warn "No receipt entries for $tool_name"
        return 0
    fi

    # Reverse so deeper paths are hit first, then parent dirs
    local reversed
    reversed="$(printf '%s\n' "$entries" | tac 2>/dev/null || tail -r)"

    local removed=0 skipped=0
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        local type="${entry%%:*}"
        local path="${entry#*:}"
        path="${path/#\~/$HOME}"  # Expand ~ to $HOME

        case "$type" in
            symlink)
                if [ -L "$path" ]; then
                    rm -f "$path"
                    removed=$((removed + 1))
                elif [ ! -e "$path" ]; then
                    skipped=$((skipped + 1))
                else
                    log_warn "Not a symlink, skipping: $path"
                    skipped=$((skipped + 1))
                fi
                ;;
            file)
                if [ -f "$path" ]; then
                    rm -f "$path"
                    removed=$((removed + 1))
                else
                    skipped=$((skipped + 1))
                fi
                ;;
            sudo:file)
                if [ -f "$path" ] && sudo rm -f "$path" 2>/dev/null; then
                    removed=$((removed + 1))
                else
                    skipped=$((skipped + 1))
                fi
                ;;
            dir)
                if [ -d "$path" ]; then
                    rmdir "$path" 2>/dev/null && removed=$((removed + 1)) || skipped=$((skipped + 1))
                else
                    skipped=$((skipped + 1))
                fi
                ;;
            state)
                # State files — just remove if present
                if [ -e "$path" ]; then
                    rm -f "$path"
                    removed=$((removed + 1))
                else
                    skipped=$((skipped + 1))
                fi
                ;;
            *)
                log_warn "Unknown receipt entry type: $type"
                ;;
        esac
    done <<< "$reversed"

    log_info "$tool_name: removed $removed, skipped $skipped"
    return 0
}