#!/usr/bin/env bash
# mover.sh — Backup Transfer with Progress
# Reads the JSON manifest produced by checker.sh and transfers all NEEDS_BACKUP
# and PARTIAL entries to the Storage disk with verbose progress.
#
# Usage:
#   ./mover.sh --manifest /tmp/recovery-scripts/backup_manifest.json \
#              --source /mnt --target /mnt/recovery/backup-arch-2026-03-20

set -euo pipefail

# Error trap — show where the script failed
trap 'echo ""; echo "ERROR: mover.sh failed at line $LINENO (exit code $?)"; echo "Last command: $BASH_COMMAND"; exit 1' ERR

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

# ═══════════════════════════════════════
#   BANNER
# ═══════════════════════════════════════
print_header "BACKUP MOVER — pc-migration-scripts"

printf "  ${C_BOLD}Manifest:${C_RESET}  %s\n" "$MANIFEST_FILE"
printf "  ${C_BOLD}Source:${C_RESET}    %s\n" "$SOURCE"
printf "  ${C_BOLD}Target:${C_RESET}    %s\n" "$TARGET"
printf "  ${C_BOLD}Log:${C_RESET}       %s\n" "$LOG_FILE"
printf "  ${C_BOLD}Started:${C_RESET}   %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# --- Validation ---
if [[ ! -f "$MANIFEST_FILE" ]]; then
    printf "  ${C_RED}✗${C_RESET} Manifest file not found: %s\n" "$MANIFEST_FILE"
    exit 1
fi
print_status "✓" "$C_GREEN" "Manifest found" "$MANIFEST_FILE"

if [[ ! -d "$SOURCE" ]]; then
    printf "  ${C_RED}✗${C_RESET} Source directory does not exist: %s\n" "$SOURCE"
    exit 1
fi
print_status "✓" "$C_GREEN" "Source exists" "$SOURCE"

if ! command -v jq &>/dev/null; then
    printf "  ${C_RED}✗${C_RESET} jq is required but not installed\n"
    echo "    Run: pacman -S --noconfirm jq"
    exit 1
fi
print_status "✓" "$C_GREEN" "jq available" "$(jq --version 2>/dev/null || echo 'yes')"

echo ""

# ═══════════════════════════════════════
#   PRE-FLIGHT ANALYSIS
# ═══════════════════════════════════════
print_subheader "Pre-Flight Analysis"
echo ""

printf "  ${C_CYAN}▸${C_RESET} Parsing manifest..."

# Full manifest stats
total_entries=$(jq 'length' "$MANIFEST_FILE")
transfer_count=$(jq '[.[] | select(.status == "NEEDS_BACKUP" or .status == "PARTIAL")] | length' "$MANIFEST_FILE")
transfer_bytes=$(jq '[.[] | select(.status == "NEEDS_BACKUP" or .status == "PARTIAL") | .size_bytes] | add // 0' "$MANIFEST_FILE")
transfer_human=$(human_size "$transfer_bytes")

needs_count=$(jq '[.[] | select(.status == "NEEDS_BACKUP")] | length' "$MANIFEST_FILE")
needs_bytes=$(jq '[.[] | select(.status == "NEEDS_BACKUP") | .size_bytes] | add // 0' "$MANIFEST_FILE")
partial_count=$(jq '[.[] | select(.status == "PARTIAL")] | length' "$MANIFEST_FILE")
partial_bytes=$(jq '[.[] | select(.status == "PARTIAL") | .size_bytes] | add // 0' "$MANIFEST_FILE")
saved_count=$(jq '[.[] | select(.status == "ALREADY_SAVED")] | length' "$MANIFEST_FILE")
excluded_count=$(jq '[.[] | select(.status == "EXCLUDED")] | length' "$MANIFEST_FILE")
symlink_count=$(jq '[.[] | select(.status == "SYMLINK")] | length' "$MANIFEST_FILE")

printf " ${C_GREEN}OK${C_RESET} (%d total entries)\n\n" "$total_entries"

# Breakdown
printf "  ${C_BOLD}Manifest breakdown:${C_RESET}\n"
printf "    ${C_RED}█${C_RESET} NEEDS_BACKUP:  %'6d files  %10s\n" "$needs_count" "$(human_size "$needs_bytes")"
printf "    ${C_YELLOW}█${C_RESET} PARTIAL:       %'6d files  %10s\n" "$partial_count" "$(human_size "$partial_bytes")"
printf "    ${C_GREEN}█${C_RESET} ALREADY_SAVED: %'6d files  ${C_DIM}(skipped)${C_RESET}\n" "$saved_count"
printf "    ${C_DIM}█${C_RESET} EXCLUDED:      %'6d files  ${C_DIM}(skipped)${C_RESET}\n" "$excluded_count"
printf "    ${C_MAGENTA}█${C_RESET} SYMLINK:       %'6d        ${C_DIM}(skipped)${C_RESET}\n" "$symlink_count"
echo ""
printf "  ${C_BOLD}Total to transfer:${C_RESET}   %'d files, %s\n" "$transfer_count" "$transfer_human"
echo ""

if [[ "$transfer_count" -eq 0 ]]; then
    printf "  ${C_GREEN}✓ Nothing to transfer — all files already saved.${C_RESET}\n\n"
    exit 0
fi

# Priority breakdown
printf "  ${C_BOLD}By priority:${C_RESET}\n"
for p in 1 2 3; do
    local pcount psize plabel pcolor
    pcount=$(jq "[.[] | select((.status == \"NEEDS_BACKUP\" or .status == \"PARTIAL\") and .priority == $p)] | length" "$MANIFEST_FILE")
    psize=$(jq "[.[] | select((.status == \"NEEDS_BACKUP\" or .status == \"PARTIAL\") and .priority == $p) | .size_bytes] | add // 0" "$MANIFEST_FILE")
    case "$p" in
        1) plabel="CRITICAL"  pcolor="$C_RED" ;;
        2) plabel="IMPORTANT" pcolor="$C_YELLOW" ;;
        3) plabel="SYSTEM"    pcolor="$C_CYAN" ;;
    esac
    printf "    ${pcolor}P%d %-10s${C_RESET} %'6d files  %10s\n" "$p" "$plabel" "$pcount" "$(human_size "$psize")"
done
echo ""

# Space check
target_dir="$TARGET"
[[ ! -d "$target_dir" ]] && target_dir="$(dirname "$TARGET")"
avail_bytes=$(df -B1 "$target_dir" 2>/dev/null | tail -1 | awk '{print $4}')
avail_human=$(human_size "$avail_bytes")

printf "  ${C_BOLD}Disk space:${C_RESET}\n"
printf "    Transfer size:    %s\n" "$transfer_human"
printf "    Available space:  %s\n" "$avail_human"

if [[ "$transfer_bytes" -gt "$avail_bytes" ]]; then
    echo ""
    printf "  ${C_BG_RED}${C_WHITE} ✗ NOT ENOUGH SPACE! ${C_RESET}\n"
    printf "    Need %s but only %s available.\n" "$transfer_human" "$avail_human"
    printf "    Free up space or reduce the manifest, then re-run.\n"
    exit 1
fi

local usage_pct=$(( (transfer_bytes * 100) / avail_bytes ))
printf "    Usage:            %d%% of available\n" "$usage_pct"
printf "    ${C_GREEN}✓ Sufficient space${C_RESET}\n"
echo ""

# --- Create target directory ---
mkdir -p "$TARGET"
printf "  ${C_GREEN}✓${C_RESET} Target directory ready: %s\n" "$TARGET"
echo ""

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
#   FILE TRANSFER
# ═══════════════════════════════════════
print_header "TRANSFERRING FILES"

printf "  ${C_BOLD}Starting: %'d files, %s${C_RESET}\n\n" "$transfer_count" "$transfer_human"

current=0
transferred_bytes=0
error_count=0
success_count=0
ntfs_incompatible_files=()
current_priority=0

while IFS=$'\t' read -r source_path target_path relative_path size_bytes status priority; do
    ((current++)) || true

    # Priority change header
    if [[ "$priority" != "$current_priority" ]]; then
        current_priority="$priority"
        local plabel pcolor
        case "$priority" in
            1) plabel="CRITICAL"  pcolor="$C_RED" ;;
            2) plabel="IMPORTANT" pcolor="$C_YELLOW" ;;
            3) plabel="SYSTEM"    pcolor="$C_CYAN" ;;
            *) plabel="OTHER"     pcolor="$C_DIM" ;;
        esac
        echo ""
        printf "  ${pcolor}${C_BOLD}── Priority %s: %s ──${C_RESET}\n\n" "$priority" "$plabel"
    fi

    # Progress calculations
    local pct=0
    [[ "$transfer_bytes" -gt 0 ]] && pct=$(( (transferred_bytes * 100) / transfer_bytes ))
    local bar
    bar=$(progress_bar "$pct")
    local transferred_human
    transferred_human=$(human_size "$transferred_bytes")
    local file_size_human
    file_size_human=$(human_size "$size_bytes")
    local elapsed
    elapsed=$(elapsed_since "$TRANSFER_START")

    # ETA calculation
    local eta="--:--"
    local elapsed_secs=$(( $(date +%s) - TRANSFER_START ))
    if [[ $transferred_bytes -gt 0 ]] && [[ $elapsed_secs -gt 0 ]]; then
        local remaining_bytes=$(( transfer_bytes - transferred_bytes ))
        local bytes_per_sec=$(( transferred_bytes / elapsed_secs ))
        if [[ $bytes_per_sec -gt 0 ]]; then
            local eta_secs=$(( remaining_bytes / bytes_per_sec ))
            local eta_mins=$(( eta_secs / 60 ))
            local eta_s=$(( eta_secs % 60 ))
            eta=$(printf "%dm %02ds" "$eta_mins" "$eta_s")
        fi
    fi

    # Speed calculation
    local speed="--"
    if [[ $elapsed_secs -gt 0 ]] && [[ $transferred_bytes -gt 0 ]]; then
        local bps=$(( transferred_bytes / elapsed_secs ))
        speed="$(human_size "$bps")/s"
    fi

    # Progress header line
    printf "  ${C_BOLD}[%*d/%d]${C_RESET} [${C_CYAN}%s${C_RESET}] ${C_BOLD}%3d%%${C_RESET} %s / %s  ${C_DIM}%s  ETA %s${C_RESET}\n" \
        "${#transfer_count}" "$current" "$transfer_count" \
        "$bar" "$pct" "$transferred_human" "$transfer_human" \
        "$speed" "$eta"

    # Check for NTFS-incompatible filename
    local_basename=$(basename "$source_path")
    if has_ntfs_bad_chars "$local_basename"; then
        ntfs_incompatible_files+=("$source_path")
        printf "    ${C_YELLOW}⚠ NTFS${C_RESET}  %s ${C_DIM}(%s) → queued for tar bundle${C_RESET}\n" "$relative_path" "$file_size_human"
        log_msg "NTFS" "Queued for tar bundle: $relative_path ($file_size_human)" >> "$LOG_FILE"
        ((transferred_bytes += size_bytes)) || true
        continue
    fi

    # Create parent directory
    target_parent=$(dirname "$target_path")
    if [[ ! -d "$target_parent" ]]; then
        mkdir -p "$target_parent" 2>/dev/null || true
        printf "    ${C_CYAN}📁 MKDIR${C_RESET}  %s\n" "${target_parent#${TARGET}/}"
    fi

    # Copy the file
    if [[ -f "$source_path" ]]; then
        local cp_start
        cp_start=$(date +%s%N 2>/dev/null || date +%s)

        if cp -a "$source_path" "$target_path" 2>/dev/null; then
            local cp_end
            cp_end=$(date +%s%N 2>/dev/null || date +%s)

            # File copy speed (if nanoseconds available)
            local cp_speed=""
            if [[ ${#cp_start} -gt 10 ]] && [[ $size_bytes -gt 0 ]]; then
                local cp_ns=$(( cp_end - cp_start ))
                if [[ $cp_ns -gt 0 ]]; then
                    local cp_bps=$(( (size_bytes * 1000000000) / cp_ns ))
                    cp_speed=" @ $(human_size "$cp_bps")/s"
                fi
            fi

            printf "    ${C_GREEN}✓ OK${C_RESET}     %s ${C_DIM}(%s%s)${C_RESET}\n" "$relative_path" "$file_size_human" "$cp_speed"
            log_msg "OK" "cp $relative_path ($file_size_human)" >> "$LOG_FILE"
            ((success_count++)) || true
        else
            printf "    ${C_RED}✗ FAIL${C_RESET}   %s ${C_DIM}(%s) — copy failed${C_RESET}\n" "$relative_path" "$file_size_human"
            log_msg "FAIL" "cp $relative_path — cp failed ($file_size_human)" >> "$LOG_FILE"
            ((error_count++)) || true
        fi
    elif [[ -d "$source_path" ]]; then
        mkdir -p "$target_path" 2>/dev/null || true
        printf "    ${C_CYAN}📁 MKDIR${C_RESET}  %s ${C_DIM}(empty directory)${C_RESET}\n" "$relative_path"
        log_msg "OK" "mkdir $relative_path" >> "$LOG_FILE"
        ((success_count++)) || true
    else
        printf "    ${C_DIM}⊘ SKIP${C_RESET}   %s ${C_DIM}(not a regular file)${C_RESET}\n" "$relative_path"
        log_msg "SKIP" "$relative_path — not a regular file" >> "$LOG_FILE"
    fi

    ((transferred_bytes += size_bytes)) || true

done < <(jq -r '.[] | select(.status == "NEEDS_BACKUP" or .status == "PARTIAL") | [.source_path, .target_path, .relative_path, (.size_bytes | tostring), .status, (.priority | tostring)] | @tsv' "$MANIFEST_FILE")

echo ""

# ═══════════════════════════════════════
#   NTFS-INCOMPATIBLE BUNDLE
# ═══════════════════════════════════════
if [[ ${#ntfs_incompatible_files[@]} -gt 0 ]]; then
    print_subheader "NTFS-Incompatible Files Bundle"
    echo ""
    printf "  ${C_YELLOW}▸${C_RESET} Bundling %d files into ntfs-incompatible.tar.gz ...\n" "${#ntfs_incompatible_files[@]}"

    for f in "${ntfs_incompatible_files[@]}"; do
        printf "    ${C_DIM}+ %s${C_RESET}\n" "${f#${SOURCE}/}"
    done

    tar_list_file=$(mktemp)
    for f in "${ntfs_incompatible_files[@]}"; do
        echo "$f" >> "$tar_list_file"
    done

    if tar -czf "$NTFS_TAR" -T "$tar_list_file" 2>/dev/null; then
        tar_size=$(stat -c '%s' "$NTFS_TAR" 2>/dev/null || echo 0)
        printf "\n  ${C_GREEN}✓${C_RESET} Created ntfs-incompatible.tar.gz (%s, %d files)\n" "$(human_size "$tar_size")" "${#ntfs_incompatible_files[@]}"
        log_msg "TAR" "Created ntfs-incompatible.tar.gz (${#ntfs_incompatible_files[@]} files, $(human_size "$tar_size"))" >> "$LOG_FILE"
    else
        printf "\n  ${C_RED}✗${C_RESET} Failed to create ntfs-incompatible.tar.gz\n"
        log_msg "FAIL" "Failed to create ntfs-incompatible.tar.gz" >> "$LOG_FILE"
        ((error_count++)) || true
    fi

    rm -f "$tar_list_file"
    echo ""
fi

# ═══════════════════════════════════════
#   PERMISSION-CRITICAL TAR ARCHIVES
# ═══════════════════════════════════════
print_subheader "Permission-Critical Archives"
echo ""
printf "  ${C_DIM}These tar archives preserve Linux permissions for restoration on ext4/btrfs.${C_RESET}\n\n"

for perm_dir in "${PERMISSION_CRITICAL_DIRS[@]}"; do
    source_dir="${SOURCE}/home/${DEFAULT_USER}/${perm_dir}"
    if [[ -d "$source_dir" ]]; then
        local tar_name
        [[ "$perm_dir" == ".gnupg" ]] && tar_name="gnupg-keys.tar.gz"
        [[ "$perm_dir" == ".ssh" ]] && tar_name="ssh-keys.tar.gz"
        [[ -z "${tar_name:-}" ]] && tar_name="${perm_dir#.}-keys.tar.gz"

        local dir_size
        dir_size=$(du -sb "$source_dir" 2>/dev/null | awk '{print $1}' || echo 0)
        local file_count
        file_count=$(find "$source_dir" -type f 2>/dev/null | wc -l)

        printf "  ${C_CYAN}▸${C_RESET} Creating ${C_BOLD}%s${C_RESET} from %s (%d files, %s) ...\n" \
            "$tar_name" "$perm_dir" "$file_count" "$(human_size "$dir_size")"

        # List contents
        while IFS= read -r f; do
            printf "    ${C_DIM}+ %s${C_RESET}\n" "${f#${source_dir}/}"
        done < <(find "$source_dir" -type f 2>/dev/null)

        if tar -czf "${TARGET}/${tar_name}" -C "${SOURCE}/home/${DEFAULT_USER}" "$perm_dir" 2>/dev/null; then
            tar_size=$(stat -c '%s' "${TARGET}/${tar_name}" 2>/dev/null || echo 0)
            printf "    ${C_GREEN}✓${C_RESET} %s created (%s compressed)\n\n" "$tar_name" "$(human_size "$tar_size")"
            log_msg "TAR" "Created $tar_name ($file_count files, $(human_size "$tar_size") compressed)" >> "$LOG_FILE"
        else
            printf "    ${C_RED}✗${C_RESET} Failed to create %s\n\n" "$tar_name"
            log_msg "FAIL" "Failed to create $tar_name" >> "$LOG_FILE"
            ((error_count++)) || true
        fi
    else
        printf "  ${C_DIM}⊘ %s not found at %s — skipped${C_RESET}\n\n" "$perm_dir" "$source_dir"
    fi
done

# ═══════════════════════════════════════
#   SYSTEM DATA
# ═══════════════════════════════════════
print_subheader "System Data Collection"
echo ""

SYSTEM_DIR="${TARGET}/system"
mkdir -p "$SYSTEM_DIR"
printf "  ${C_CYAN}📁${C_RESET} System directory: %s\n\n" "$SYSTEM_DIR"

# Package lists
printf "  ${C_CYAN}▸${C_RESET} Package lists:\n"

printf "    ${C_DIM}Trying arch-chroot pacman -Qqe ...${C_RESET}"
if arch-chroot "$SOURCE" pacman -Qqe > "${SYSTEM_DIR}/package-list-explicit.txt" 2>/dev/null; then
    local pkg_count
    pkg_count=$(wc -l < "${SYSTEM_DIR}/package-list-explicit.txt")
    printf "\r    ${C_GREEN}✓${C_RESET} package-list-explicit.txt (%d packages)     \n" "$pkg_count"
    log_msg "OK" "Saved package-list-explicit.txt ($pkg_count packages) via arch-chroot" >> "$LOG_FILE"
else
    printf "\r    ${C_YELLOW}△${C_RESET} arch-chroot pacman -Qqe failed (broken system)     \n"
    log_msg "WARN" "arch-chroot pacman -Qqe failed, using fallback" >> "$LOG_FILE"
fi

printf "    ${C_DIM}Trying arch-chroot pacman -Qqm ...${C_RESET}"
if arch-chroot "$SOURCE" pacman -Qqm > "${SYSTEM_DIR}/package-list-aur.txt" 2>/dev/null; then
    local aur_count
    aur_count=$(wc -l < "${SYSTEM_DIR}/package-list-aur.txt")
    printf "\r    ${C_GREEN}✓${C_RESET} package-list-aur.txt (%d AUR packages)        \n" "$aur_count"
    log_msg "OK" "Saved package-list-aur.txt ($aur_count packages) via arch-chroot" >> "$LOG_FILE"
else
    printf "\r    ${C_YELLOW}△${C_RESET} arch-chroot pacman -Qqm failed (broken system)      \n"
    log_msg "WARN" "arch-chroot pacman -Qqm failed, using fallback" >> "$LOG_FILE"
fi

if [[ -d "${SOURCE}/var/lib/pacman/local" ]]; then
    ls "${SOURCE}/var/lib/pacman/local/" > "${SYSTEM_DIR}/package-list-raw.txt" 2>/dev/null
    local raw_count
    raw_count=$(wc -l < "${SYSTEM_DIR}/package-list-raw.txt")
    printf "    ${C_GREEN}✓${C_RESET} package-list-raw.txt (%d entries, fallback)\n" "$raw_count"
    log_msg "OK" "Saved package-list-raw.txt ($raw_count entries, fallback)" >> "$LOG_FILE"
fi
echo ""

# Crontab
printf "  ${C_CYAN}▸${C_RESET} Crontab:\n"
if [[ -f "${SOURCE}/var/spool/cron/${DEFAULT_USER}" ]]; then
    cp "${SOURCE}/var/spool/cron/${DEFAULT_USER}" "${SYSTEM_DIR}/crontab-${DEFAULT_USER}" 2>/dev/null
    local cron_lines
    cron_lines=$(wc -l < "${SYSTEM_DIR}/crontab-${DEFAULT_USER}")
    printf "    ${C_GREEN}✓${C_RESET} crontab-%s (%d lines)\n" "$DEFAULT_USER" "$cron_lines"
    log_msg "OK" "Saved crontab-${DEFAULT_USER} ($cron_lines lines)" >> "$LOG_FILE"
else
    printf "    ${C_DIM}⊘ No crontab found for %s${C_RESET}\n" "$DEFAULT_USER"
    log_msg "SKIP" "No crontab for ${DEFAULT_USER}" >> "$LOG_FILE"
fi
echo ""

# User systemd services
printf "  ${C_CYAN}▸${C_RESET} Systemd user services:\n"
if [[ -d "${SOURCE}/home/${DEFAULT_USER}/.config/systemd" ]]; then
    cp -a "${SOURCE}/home/${DEFAULT_USER}/.config/systemd" "${SYSTEM_DIR}/systemd-user/" 2>/dev/null
    local svc_count
    svc_count=$(find "${SYSTEM_DIR}/systemd-user/" -type f 2>/dev/null | wc -l)
    printf "    ${C_GREEN}✓${C_RESET} systemd-user/ (%d service files)\n" "$svc_count"
    log_msg "OK" "Saved systemd-user/ ($svc_count files)" >> "$LOG_FILE"
else
    printf "    ${C_DIM}⊘ No systemd user services found${C_RESET}\n"
    log_msg "SKIP" "No systemd user services" >> "$LOG_FILE"
fi
echo ""

# --- Final log entry ---
{
    echo ""
    echo "# Completed: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# Files: $success_count success, $error_count errors, ${#ntfs_incompatible_files[@]} NTFS-bundled"
    echo "# Bytes: $(human_size "$transferred_bytes") transferred"
} >> "$LOG_FILE"

# ═══════════════════════════════════════
#   FINAL SUMMARY
# ═══════════════════════════════════════
local total_elapsed
total_elapsed=$(elapsed_since "$TRANSFER_START")
local total_secs=$(( $(date +%s) - TRANSFER_START ))
local avg_speed="--"
[[ $total_secs -gt 0 ]] && avg_speed="$(human_size $(( transferred_bytes / total_secs )))/s"

print_header "TRANSFER COMPLETE"

printf "  ${C_BOLD}Duration:${C_RESET}            %s\n" "$total_elapsed"
printf "  ${C_BOLD}Average speed:${C_RESET}       %s\n" "$avg_speed"
echo ""

printf "  ${C_GREEN}█${C_RESET} ${C_BOLD}Copied:${C_RESET}              %'d files  %10s\n" "$success_count" "$(human_size "$transferred_bytes")"

if [[ ${#ntfs_incompatible_files[@]} -gt 0 ]]; then
    printf "  ${C_YELLOW}█${C_RESET} ${C_BOLD}NTFS-bundled:${C_RESET}        %'d files  ${C_DIM}(in ntfs-incompatible.tar.gz)${C_RESET}\n" "${#ntfs_incompatible_files[@]}"
fi

if [[ $error_count -gt 0 ]]; then
    printf "  ${C_RED}█${C_RESET} ${C_BOLD}Errors:${C_RESET}              %'d files\n" "$error_count"
else
    printf "  ${C_GREEN}█${C_RESET} ${C_BOLD}Errors:${C_RESET}              0\n"
fi
echo ""

# List output artifacts
print_subheader "Output Artifacts"
echo ""
printf "  ${C_CYAN}📋${C_RESET} Log:              %s\n" "$LOG_FILE"

if [[ -f "${TARGET}/ssh-keys.tar.gz" ]]; then
    printf "  ${C_CYAN}🔑${C_RESET} SSH keys:         %s (%s)\n" "${TARGET}/ssh-keys.tar.gz" \
        "$(human_size "$(stat -c '%s' "${TARGET}/ssh-keys.tar.gz" 2>/dev/null || echo 0)")"
fi
if [[ -f "${TARGET}/gnupg-keys.tar.gz" ]]; then
    printf "  ${C_CYAN}🔐${C_RESET} GPG keys:         %s (%s)\n" "${TARGET}/gnupg-keys.tar.gz" \
        "$(human_size "$(stat -c '%s' "${TARGET}/gnupg-keys.tar.gz" 2>/dev/null || echo 0)")"
fi
if [[ -f "$NTFS_TAR" ]]; then
    printf "  ${C_CYAN}📦${C_RESET} NTFS bundle:      %s (%s)\n" "$NTFS_TAR" \
        "$(human_size "$(stat -c '%s' "$NTFS_TAR" 2>/dev/null || echo 0)")"
fi
if [[ -d "$SYSTEM_DIR" ]]; then
    printf "  ${C_CYAN}⚙️${C_RESET}  System data:      %s\n" "$SYSTEM_DIR"
fi
echo ""

if [[ $error_count -gt 0 ]]; then
    printf "  ${C_BG_YELLOW}${C_WHITE} ⚠ %d ERRORS — review %s ${C_RESET}\n" "$error_count" "$LOG_FILE"
    printf "  ${C_DIM}Re-run checker.sh to identify any remaining files.${C_RESET}\n"
else
    printf "  ${C_BG_GREEN}${C_WHITE} ✓ ALL FILES TRANSFERRED SUCCESSFULLY ${C_RESET}\n"
    printf "  ${C_DIM}Re-run checker.sh to validate — NEEDS_BACKUP table should be empty.${C_RESET}\n"
fi
echo ""
