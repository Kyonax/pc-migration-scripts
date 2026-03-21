#!/usr/bin/env bash
# config.sh — Shared configuration for pc-migration-scripts
# Sourced by checker.sh and mover.sh

# --- Default Mount Points ---
# /mnt/source  = broken system root (read-only)
# /mnt/recovery = Storage disk (read-write)
# These MUST be separate paths — never mount the source at /mnt directly,
# because that makes /mnt read-only and prevents creating /mnt/recovery.
DEFAULT_SOURCE="/mnt/source"
DEFAULT_TARGET="/mnt/recovery/backup-arch-2026-03-20"
DEFAULT_USER="kyonax"
DEFAULT_OUTPUT="."

# --- Scan Strategy ---
# Instead of listing specific directories, we scan the ENTIRE source disk
# and exclude system/OS directories. Everything that is not excluded = backup.
# This ensures nothing user-related is missed.

# Top-level directories to SKIP entirely (system/OS — not user data)
SYSTEM_DIRS=(
    "bin"
    "boot"
    "dev"
    "etc"
    "lib"
    "lib64"
    "mnt"
    "opt"
    "proc"
    "root"
    "run"
    "sbin"
    "srv"
    "sys"
    "tmp"
    "usr"
    "var"
    "lost+found"
    "snap"
    "swapfile"
)

# Subdirectories within home that are CRITICAL (priority 1)
# Everything else under home = priority 2
CRITICAL_PATHS=(
    ".ssh"
    ".gnupg"
    ".brain.d"
    "Documents/github-kyonax"
    ".doom.d"
)

# --- Exclude Patterns ---
# Matched against relative path from source root — skips caches and junk
EXCLUDE_PATTERNS=(
    # Caches (regenerable)
    ".cache"
    ".thumbnails"
    # Package manager caches
    "node_modules"
    "__pycache__"
    ".npm"
    ".yarn/cache"
    ".pnpm-store"
    ".cargo/registry"
    ".gradle/caches"
    ".m2/repository"
    ".nvm/.cache"
    ".nvm/versions"
    ".bundle/cache"
    ".gem/cache"
    ".composer/cache"
    # Build output
    ".venv"
    "venv"
    # Desktop/app junk
    ".local/share/Trash"
    ".local/share/baloo"
    ".local/share/akonadi"
    ".local/share/recently-used.xbel"
    ".local/share/gvfs-metadata"
    # Large regenerable data
    ".local/share/Steam"
    ".local/share/lutris"
    ".wine"
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

# --- Colors (auto-detect terminal support) ---
if [[ -t 1 ]] && command -v tput &>/dev/null && [[ $(tput colors 2>/dev/null) -ge 8 ]]; then
    C_RESET="\033[0m"
    C_BOLD="\033[1m"
    C_DIM="\033[2m"
    C_GREEN="\033[32m"
    C_YELLOW="\033[33m"
    C_RED="\033[31m"
    C_CYAN="\033[36m"
    C_MAGENTA="\033[35m"
    C_BLUE="\033[34m"
    C_WHITE="\033[97m"
    C_BG_GREEN="\033[42m"
    C_BG_RED="\033[41m"
    C_BG_YELLOW="\033[43m"
    C_BG_BLUE="\033[44m"
else
    C_RESET="" C_BOLD="" C_DIM="" C_GREEN="" C_YELLOW="" C_RED=""
    C_CYAN="" C_MAGENTA="" C_BLUE="" C_WHITE=""
    C_BG_GREEN="" C_BG_RED="" C_BG_YELLOW="" C_BG_BLUE=""
fi

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

# Check if a top-level directory is a system dir
is_system_dir() {
    local dirname="$1"
    for sysdir in "${SYSTEM_DIRS[@]}"; do
        [[ "$dirname" == "$sysdir" ]] && return 0
    done
    return 1
}

# Check if a file path falls under a critical subdirectory
is_critical_path() {
    local rel_path="$1"
    local user="$2"
    for crit in "${CRITICAL_PATHS[@]}"; do
        if [[ "$rel_path" == "home/${user}/${crit}/"* ]] || \
           [[ "$rel_path" == "home/${user}/${crit}" ]]; then
            return 0
        fi
    done
    return 1
}

# Check if a path matches any exclude pattern
is_excluded() {
    local filepath="$1"
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
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

# Progress bar (width 30 chars)
progress_bar() {
    local pct=$1
    local width=30
    local filled=$(( (pct * width) / 100 ))
    local empty=$(( width - filled ))
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    echo "$bar"
}

# Elapsed time from epoch seconds
elapsed_since() {
    local start=$1
    local now
    now=$(date +%s)
    local diff=$(( now - start ))
    local mins=$(( diff / 60 ))
    local secs=$(( diff % 60 ))
    printf "%dm %02ds" "$mins" "$secs"
}

# Print a section header
print_header() {
    local title="$1"
    local width=60
    local pad=$(( (width - ${#title} - 2) / 2 ))
    printf "\n${C_BOLD}${C_CYAN}"
    printf '%*s' "$width" '' | tr ' ' '═'
    printf "\n"
    printf '%*s' "$pad" ''
    printf " %s " "$title"
    printf "\n"
    printf '%*s' "$width" '' | tr ' ' '═'
    printf "${C_RESET}\n\n"
}

# Print a sub-header
print_subheader() {
    local title="$1"
    printf "${C_BOLD}${C_BLUE}── %s ──${C_RESET}\n" "$title"
}

# Print a status line with icon
print_status() {
    local icon="$1" color="$2" label="$3"
    shift 3
    printf "  ${color}%s${C_RESET} %-16s %s\n" "$icon" "$label" "$*"
}
