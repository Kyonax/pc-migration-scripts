#!/usr/bin/env bash
# config.sh — Shared configuration for pc-migration-scripts
# Sourced by checker.sh and mover.sh

# --- Default Mount Points ---
DEFAULT_SOURCE="/mnt"
DEFAULT_TARGET="/mnt/recovery/backup-arch-2026-03-20"
DEFAULT_USER="kyonax"
DEFAULT_OUTPUT="."

# --- Directory Scan Tiers ---
# Priority 1: CRITICAL — Must Backup
# Priority 2: IMPORTANT — Should Backup
# Priority 3: SYSTEM — Backup Separately
#
# Format: "priority|relative_path|description"
# Paths under home use ~ prefix (expanded at runtime to $SOURCE/home/$USER/)
# Paths without ~ are relative to $SOURCE/

SCAN_DIRS=(
    # CRITICAL (priority 1)
    "1|~/.ssh|SSH keys"
    "1|~/.gnupg|GPG keys"
    "1|~/.brain.d|Org-roam knowledge base"
    "1|~/Documents/github-kyonax|Dotfiles repo and git projects"
    "1|~/.doom.d|Doom Emacs config"
    # IMPORTANT (priority 2)
    "2|~/.config|App configs"
    "2|~/Documents|User documents"
    "2|~/Pictures|User pictures"
    "2|~/Desktop|Desktop files"
    "2|~/Downloads|Downloaded files"
    "2|~/.local/share|App data"
    # SYSTEM (priority 3)
    "3|/etc|System configs"
    "3|/var/lib/pacman/local|Package database"
    "3|/var/spool/cron|Crontabs"
    "3|~/.config/systemd|User systemd services"
)

# --- Exclude Patterns ---
# Paths/patterns to skip during scanning (regenerable or waste space)
# Matched against the relative path from the scan root

EXCLUDE_PATTERNS=(
    ".cache"
    "node_modules"
    "__pycache__"
    ".npm"
    ".yarn/cache"
    ".pnpm-store"
    ".local/share/Trash"
    ".local/share/baloo"
    ".local/share/akonadi"
    ".cargo/registry"
    ".gradle/caches"
    "target"
    ".venv"
    "venv"
    ".thumbnails"
    ".local/share/recently-used.xbel"
    ".nvm/.cache"
    ".bundle/cache"
    ".gem/cache"
    ".composer/cache"
    ".m2/repository"
)

# --- NTFS-Incompatible Characters ---
NTFS_BAD_CHARS='[:<>?*"|\\]'

# --- Permission-Critical Directories ---
# These get additional tar archives in the mover
PERMISSION_CRITICAL_DIRS=(
    ".ssh"
    ".gnupg"
)

# --- Large File Threshold (bytes) ---
LARGE_FILE_THRESHOLD=$((1 * 1024 * 1024 * 1024))  # 1 GiB

# --- Helper Functions ---

# Human-readable size
human_size() {
    local bytes=$1
    if (( bytes >= 1073741824 )); then
        printf "%.1fG" "$(echo "scale=1; $bytes / 1073741824" | bc)"
    elif (( bytes >= 1048576 )); then
        printf "%.1fM" "$(echo "scale=1; $bytes / 1048576" | bc)"
    elif (( bytes >= 1024 )); then
        printf "%.1fK" "$(echo "scale=1; $bytes / 1024" | bc)"
    else
        printf "%dB" "$bytes"
    fi
}

# Resolve ~ prefix to actual home path
resolve_path() {
    local path="$1"
    local source="$2"
    local user="$3"

    if [[ "$path" == ~/* ]]; then
        echo "${source}/home/${user}/${path#\~/}"
    else
        echo "${source}${path}"
    fi
}

# Resolve ~ prefix to target path
resolve_target_path() {
    local path="$1"
    local target="$2"
    local source="$3"
    local user="$4"

    if [[ "$path" == ~/* ]]; then
        echo "${target}/home/${user}/${path#\~/}"
    else
        echo "${target}${path}"
    fi
}

# Get relative path for manifest (from source root)
get_relative_path() {
    local path="$1"
    local source="$2"
    local user="$3"

    if [[ "$path" == ~/* ]]; then
        echo "home/${user}/${path#\~/}"
    else
        echo "${path#/}"
    fi
}

# Check if a path matches any exclude pattern
is_excluded() {
    local filepath="$1"
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        # Match if any path component equals the pattern
        # or if the path ends with the pattern
        if [[ "$filepath" == *"/$pattern/"* ]] || \
           [[ "$filepath" == *"/$pattern" ]] || \
           [[ "$filepath" == "$pattern/"* ]] || \
           [[ "$filepath" == "$pattern" ]]; then
            return 0
        fi
    done
    return 1
}

# Check if filename has NTFS-incompatible characters
has_ntfs_bad_chars() {
    local filename="$1"
    [[ "$filename" =~ $NTFS_BAD_CHARS ]]
}

# Log message with timestamp
log_msg() {
    local level="$1"
    shift
    printf "%s [%-4s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
}
