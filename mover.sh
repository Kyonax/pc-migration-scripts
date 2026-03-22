#!/usr/bin/env bash
# mover.sh — Backup Transfer with Progress (TUI Dashboard)
# Reads the JSON manifest produced by checker.sh and transfers all NEEDS_BACKUP
# and PARTIAL entries to the Storage disk with verbose progress.
#
# Usage:
#   ./mover.sh --manifest /tmp/recovery-scripts/backup_manifest.json \
#              --source /mnt/source --target /mnt/recovery/backup-arch-2026-03-20

set -euo pipefail

trap 'tput rmcup 2>/dev/null; printf "\033[;r"; tput cup 999 0 2>/dev/null; echo ""; echo "ERROR: mover.sh failed at line $LINENO (exit code $?)"; echo "Last command: $BASH_COMMAND"; exit 1' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "${SCRIPT_DIR}/config.sh" ]]; then
    echo "ERROR: config.sh not found at ${SCRIPT_DIR}/config.sh"
    exit 1
fi
source "${SCRIPT_DIR}/config.sh"

# --- Argument Parsing ---
MANIFEST_FILE=""
SOURCE="$DEFAULT_SOURCE"
TARGET="$DEFAULT_TARGET"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --manifest) MANIFEST_FILE="$2"; shift 2 ;;
        --source)   SOURCE="$2"; shift 2 ;;
        --target)   TARGET="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 --manifest FILE [--source DIR] [--target DIR]"
            echo ""
            echo "  --manifest  Path to backup_manifest.json from checker.sh (required)"
            echo "  --source    Root of the broken system (default: $DEFAULT_SOURCE)"
            echo "  --target    Backup destination directory (default: $DEFAULT_TARGET)"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "$MANIFEST_FILE" ]]; then
    echo "ERROR: --manifest is required"
    echo "Run: $0 --help"
    exit 1
fi

LOG_FILE="${SCRIPT_DIR}/mover_log.txt"
NTFS_TAR="${TARGET}/ntfs-incompatible.tar.gz"
TRANSFER_START=$(date +%s)

# --- Validation (before TUI) ---
if [[ ! -f "$MANIFEST_FILE" ]]; then
    echo "ERROR: Manifest file not found: $MANIFEST_FILE"
    exit 1
fi
if [[ ! -d "$SOURCE" ]]; then
    echo "ERROR: Source directory does not exist: $SOURCE"
    exit 1
fi
if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required — pacman -S --noconfirm jq"
    exit 1
fi

# --- Parse manifest (before TUI) ---
total_entries=$(jq 'length' "$MANIFEST_FILE")
transfer_count=$(jq '[.[] | select(.status == "NEEDS_BACKUP" or .status == "PARTIAL")] | length' "$MANIFEST_FILE")
transfer_bytes=$(jq '[.[] | select(.status == "NEEDS_BACKUP" or .status == "PARTIAL") | .size_bytes] | add // 0' "$MANIFEST_FILE")
transfer_human=$(human_size "$transfer_bytes")

if [[ "$transfer_count" -eq 0 ]]; then
    echo "Nothing to transfer — all files already saved."
    exit 0
fi

# Space check
target_dir="$TARGET"
[[ ! -d "$target_dir" ]] && target_dir="$(dirname "$TARGET")"
avail_bytes=$(df -B1 "$target_dir" 2>/dev/null | tail -1 | awk '{print $4}')

if [[ "$transfer_bytes" -gt "$avail_bytes" ]]; then
    echo "ERROR: Not enough space! Need $(human_size "$transfer_bytes") but only $(human_size "$avail_bytes") available."
    exit 1
fi

mkdir -p "$TARGET"

# --- Counters ---
current=0
transferred_bytes=0
error_count=0
success_count=0
ntfs_incompatible_files=()
last_file=""
last_status=""

# --- Initialize log ---
{
    echo "# Backup Mover Log"
    echo "# Started: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# Source: $SOURCE"
    echo "# Target: $TARGET"
    echo "# Files: $transfer_count, Size: $transfer_human"
    echo ""
} > "$LOG_FILE"

# ═══════════════════════════════════════
#   TUI SETUP
# ═══════════════════════════════════════
TERM_LINES=$(tput lines 2>/dev/null || echo 24)
TERM_COLS=$(tput cols 2>/dev/null || echo 80)
DASHBOARD_HEIGHT=14
LOG_START=$((DASHBOARD_HEIGHT + 1))

cleanup_tui() {
    printf '\033[;r'
    tput cup "$TERM_LINES" 0 2>/dev/null || true
    echo ""
}
trap cleanup_tui EXIT

clear

draw_dashboard() {
    tput sc 2>/dev/null || true
    tput cup 0 0 2>/dev/null || true

    printf "${C_BOLD}${C_CYAN}══════════════════════════════════════════════════════════════${C_RESET}\n"
    printf "${C_BOLD}${C_CYAN}  BACKUP MOVER — Transferring Files${C_RESET}%*s\n" 26 ""
    printf "${C_BOLD}${C_CYAN}══════════════════════════════════════════════════════════════${C_RESET}\n"

    # Line 3: Progress bar
    pct=0
    [[ $transfer_bytes -gt 0 ]] && pct=$(( (transferred_bytes * 100) / transfer_bytes ))
    bar=$(progress_bar "$pct")
    elapsed=$(elapsed_since "$TRANSFER_START")
    printf "  [${C_CYAN}%s${C_RESET}] ${C_BOLD}%3d%%${C_RESET}  %d/%d files  %s\033[K\n" \
        "$bar" "$pct" "$current" "$transfer_count" "$elapsed"

    # Line 4: Transfer size
    transferred_h=$(human_size "$transferred_bytes")
    printf "  Transferred: ${C_BOLD}%s${C_RESET} / %s\033[K\n" "$transferred_h" "$transfer_human"

    # Line 5: Speed & ETA
    speed="--"
    eta="--:--"
    elapsed_secs=$(( $(date +%s) - TRANSFER_START ))
    if [[ $elapsed_secs -gt 0 ]] && [[ $transferred_bytes -gt 0 ]]; then
        bps=$(( transferred_bytes / elapsed_secs ))
        speed="$(human_size "$bps")/s"
        remaining=$(( transfer_bytes - transferred_bytes ))
        if [[ $bps -gt 0 ]]; then
            eta_s=$(( remaining / bps ))
            eta=$(printf "%dm %02ds" "$(( eta_s / 60 ))" "$(( eta_s % 60 ))")
        fi
    fi
    printf "  Speed: ${C_BOLD}%s${C_RESET}  ETA: ${C_BOLD}%s${C_RESET}\033[K\n" "$speed" "$eta"

    # Line 6: separator
    printf "  ${C_DIM}──────────────────────────────────────────────────────────${C_RESET}\n"

    # Line 7-8: Counters
    printf "  ${C_GREEN}✓${C_RESET} Copied:  %'6d    ${C_RED}✗${C_RESET} Errors:  %'6d    ${C_YELLOW}⚠${C_RESET} NTFS:  %'d\033[K\n" \
        "$success_count" "$error_count" "${#ntfs_incompatible_files[@]}"
    avail_now=$(df -B1 "$target_dir" 2>/dev/null | tail -1 | awk '{print $4}')
    printf "  ${C_DIM}Disk free: %s${C_RESET}\033[K\n" "$(human_size "$avail_now")"

    # Line 9: separator
    printf "  ${C_DIM}──────────────────────────────────────────────────────────${C_RESET}\n"

    # Line 10: Last file + status
    if [[ -n "$last_file" ]]; then
        display_file="$last_file"
        max_len=$(( TERM_COLS - 12 ))
        if [[ ${#display_file} -gt $max_len ]]; then
            display_file="...${display_file: -$((max_len - 3))}"
        fi
        printf "  %s %s\033[K\n" "$last_status" "$display_file"
    else
        printf "\033[K\n"
    fi

    # Line 11: separator
    printf "  ${C_DIM}── Transfer Log ──────────────────────────────────────────${C_RESET}\n"

    printf "\033[K"

    tput rc 2>/dev/null || true
}

log_line() {
    printf "%s\n" "$1"
}

# Set scroll region
printf '\033[%d;%dr' "$LOG_START" "$TERM_LINES"
tput cup "$LOG_START" 0 2>/dev/null || true

draw_dashboard

# ═══════════════════════════════════════
#   FILE TRANSFER
# ═══════════════════════════════════════

while IFS=$'\t' read -r source_path target_path relative_path size_bytes status priority; do
    ((current++)) || true

    file_size_human=$(human_size "$size_bytes")

    # NTFS-incompatible check
    local_basename=$(basename "$source_path")
    if has_ntfs_bad_chars "$local_basename"; then
        ntfs_incompatible_files+=("$source_path")
        last_file="$relative_path"
        last_status="${C_YELLOW}⚠ NTFS${C_RESET}"
        log_line "  ${C_YELLOW}⚠ NTFS${C_RESET}  $relative_path ${C_DIM}($file_size_human)${C_RESET}"
        log_msg "NTFS" "Queued for tar: $relative_path ($file_size_human)" >> "$LOG_FILE"
        ((transferred_bytes += size_bytes)) || true
        if (( current % 10 == 0 )); then draw_dashboard; fi
        continue
    fi

    # Create parent directory
    target_parent=$(dirname "$target_path")
    if [[ ! -d "$target_parent" ]]; then
        mkdir -p "$target_parent" 2>/dev/null || true
    fi

    # Copy
    if [[ -f "$source_path" ]]; then
        if cp -a "$source_path" "$target_path" 2>/dev/null; then
            last_file="$relative_path"
            last_status="${C_GREEN}✓ OK${C_RESET}  "
            log_line "  ${C_GREEN}✓${C_RESET} $relative_path ${C_DIM}($file_size_human)${C_RESET}"
            log_msg "OK" "cp $relative_path ($file_size_human)" >> "$LOG_FILE"
            ((success_count++)) || true
        else
            last_file="$relative_path"
            last_status="${C_RED}✗ FAIL${C_RESET}"
            log_line "  ${C_RED}✗${C_RESET} $relative_path ${C_DIM}($file_size_human) — FAILED${C_RESET}"
            log_msg "FAIL" "cp $relative_path ($file_size_human)" >> "$LOG_FILE"
            ((error_count++)) || true
        fi
    elif [[ -d "$source_path" ]]; then
        mkdir -p "$target_path" 2>/dev/null || true
        last_file="$relative_path"
        last_status="${C_CYAN}📁 DIR${C_RESET} "
        log_line "  ${C_CYAN}📁${C_RESET} $relative_path ${C_DIM}(empty dir)${C_RESET}"
        log_msg "OK" "mkdir $relative_path" >> "$LOG_FILE"
        ((success_count++)) || true
    else
        log_msg "SKIP" "$relative_path — not a regular file" >> "$LOG_FILE"
    fi

    ((transferred_bytes += size_bytes)) || true

    # Update dashboard every 10 files
    if (( current % 10 == 0 )); then
        draw_dashboard
    fi

done < <(jq -r '.[] | select(.status == "NEEDS_BACKUP" or .status == "PARTIAL") | [.source_path, .target_path, .relative_path, (.size_bytes | tostring), .status, (.priority | tostring)] | @tsv' "$MANIFEST_FILE")

# Final dashboard update
draw_dashboard

# ═══════════════════════════════════════
#   POST-TRANSFER (in scroll region)
# ═══════════════════════════════════════

# NTFS-incompatible bundle
if [[ ${#ntfs_incompatible_files[@]} -gt 0 ]]; then
    log_line ""
    log_line "  ${C_YELLOW}${C_BOLD}── NTFS Bundle ──${C_RESET} ${#ntfs_incompatible_files[@]} files"

    tar_list_file=$(mktemp)
    for f in "${ntfs_incompatible_files[@]}"; do
        echo "$f" >> "$tar_list_file"
        log_line "    ${C_DIM}+ ${f#${SOURCE}/}${C_RESET}"
    done

    if tar -czf "$NTFS_TAR" -T "$tar_list_file" 2>/dev/null; then
        tar_size=$(stat -c '%s' "$NTFS_TAR" 2>/dev/null || echo 0)
        log_line "  ${C_GREEN}✓${C_RESET} ntfs-incompatible.tar.gz ($(human_size "$tar_size"))"
        log_msg "TAR" "ntfs-incompatible.tar.gz (${#ntfs_incompatible_files[@]} files)" >> "$LOG_FILE"
    else
        log_line "  ${C_RED}✗${C_RESET} Failed to create ntfs-incompatible.tar.gz"
        ((error_count++)) || true
    fi
    rm -f "$tar_list_file"
fi

# Permission-critical tar archives
log_line ""
log_line "  ${C_CYAN}${C_BOLD}── Permission Archives ──${C_RESET}"

for perm_dir in "${PERMISSION_CRITICAL_DIRS[@]}"; do
    source_dir="${SOURCE}/home/${DEFAULT_USER}/${perm_dir}"
    if [[ -d "$source_dir" ]]; then
        tar_name=""
        [[ "$perm_dir" == ".gnupg" ]] && tar_name="gnupg-keys.tar.gz"
        [[ "$perm_dir" == ".ssh" ]] && tar_name="ssh-keys.tar.gz"
        [[ -z "${tar_name:-}" ]] && tar_name="${perm_dir#.}-keys.tar.gz"

        fc=$(find "$source_dir" -type f 2>/dev/null | wc -l)
        log_line "  ${C_CYAN}▸${C_RESET} $tar_name ($fc files)"

        if tar -czf "${TARGET}/${tar_name}" -C "${SOURCE}/home/${DEFAULT_USER}" "$perm_dir" 2>/dev/null; then
            ts=$(stat -c '%s' "${TARGET}/${tar_name}" 2>/dev/null || echo 0)
            log_line "    ${C_GREEN}✓${C_RESET} Created ($(human_size "$ts") compressed)"
            log_msg "TAR" "$tar_name ($fc files, $(human_size "$ts"))" >> "$LOG_FILE"
        else
            log_line "    ${C_RED}✗${C_RESET} Failed"
            ((error_count++)) || true
        fi
    else
        log_line "  ${C_DIM}⊘ $perm_dir not found — skipped${C_RESET}"
    fi
done

# Final log
{
    echo ""
    echo "# Completed: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# Files: $success_count success, $error_count errors, ${#ntfs_incompatible_files[@]} NTFS-bundled"
    echo "# Bytes: $(human_size "$transferred_bytes") transferred"
} >> "$LOG_FILE"

# ═══════════════════════════════════════
#   FINAL SUMMARY
# ═══════════════════════════════════════
total_elapsed=$(elapsed_since "$TRANSFER_START")
total_secs=$(( $(date +%s) - TRANSFER_START ))
avg_speed="--"
[[ $total_secs -gt 0 ]] && [[ $transferred_bytes -gt 0 ]] && avg_speed="$(human_size $(( transferred_bytes / total_secs )))/s"

log_line ""
log_line "  ${C_BOLD}${C_GREEN}══════════════════════════════════════════════════════════════${C_RESET}"
log_line "  ${C_BOLD}${C_GREEN}  TRANSFER COMPLETE${C_RESET}  $total_elapsed  $avg_speed avg"
log_line "  ${C_BOLD}${C_GREEN}══════════════════════════════════════════════════════════════${C_RESET}"
log_line ""
log_line "  ${C_GREEN}█${C_RESET} Copied:       $success_count files ($(human_size "$transferred_bytes"))"
[[ ${#ntfs_incompatible_files[@]} -gt 0 ]] && log_line "  ${C_YELLOW}█${C_RESET} NTFS-bundled: ${#ntfs_incompatible_files[@]} files"
if [[ $error_count -gt 0 ]]; then
    log_line "  ${C_RED}█${C_RESET} Errors:       $error_count files"
else
    log_line "  ${C_GREEN}█${C_RESET} Errors:       0"
fi
log_line ""
log_line "  ${C_CYAN}📋${C_RESET} Log: $LOG_FILE"
[[ -f "${TARGET}/ssh-keys.tar.gz" ]] && log_line "  ${C_CYAN}🔑${C_RESET} SSH: ${TARGET}/ssh-keys.tar.gz"
[[ -f "${TARGET}/gnupg-keys.tar.gz" ]] && log_line "  ${C_CYAN}🔐${C_RESET} GPG: ${TARGET}/gnupg-keys.tar.gz"
log_line ""

if [[ $error_count -gt 0 ]]; then
    log_line "  ${C_BG_YELLOW}${C_WHITE} ⚠ $error_count ERRORS — review $LOG_FILE ${C_RESET}"
else
    log_line "  ${C_BG_GREEN}${C_WHITE} ✓ ALL FILES TRANSFERRED SUCCESSFULLY ${C_RESET}"
fi
log_line "  ${C_DIM}Re-run checker.sh to validate.${C_RESET}"
log_line ""
