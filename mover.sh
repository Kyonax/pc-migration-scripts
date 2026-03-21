#!/usr/bin/env bash
# mover.sh — Backup Transfer with Progress
# Reads the JSON manifest produced by checker.sh and transfers all NEEDS_BACKUP
# and PARTIAL entries to the Storage disk with verbose progress.
#
# Usage:
#   ./mover.sh --manifest /tmp/recovery-scripts/backup_manifest.json \
#              --source /mnt --target /mnt/recovery/backup-arch-2026-03-20

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

if [[ ! -f "$MANIFEST_FILE" ]]; then
    echo "ERROR: Manifest file not found: $MANIFEST_FILE"
    exit 1
fi

LOG_FILE="${SCRIPT_DIR}/mover_log.txt"
NTFS_TAR="${TARGET}/ntfs-incompatible.tar.gz"

# --- Validation ---
if [[ ! -d "$SOURCE" ]]; then
    echo "ERROR: Source directory does not exist: $SOURCE"
    exit 1
fi

# Check jq is available
if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required but not installed"
    echo "Run: pacman -S --noconfirm jq"
    exit 1
fi

# --- Parse Manifest ---
echo "========================================="
echo "  Backup Mover — pc-migration-scripts"
echo "========================================="
echo ""
echo "Manifest: $MANIFEST_FILE"
echo "Source:   $SOURCE"
echo "Target:   $TARGET"
echo "Log:      $LOG_FILE"
echo ""

# Count transferable entries
transfer_count=$(jq '[.[] | select(.status == "NEEDS_BACKUP" or .status == "PARTIAL")] | length' "$MANIFEST_FILE")
transfer_bytes=$(jq '[.[] | select(.status == "NEEDS_BACKUP" or .status == "PARTIAL") | .size_bytes] | add // 0' "$MANIFEST_FILE")
transfer_human=$(human_size "$transfer_bytes")

if [[ "$transfer_count" -eq 0 ]]; then
    echo "Nothing to transfer — all files already saved."
    exit 0
fi

echo "[BACKUP] Starting transfer: $transfer_count files, $transfer_human total"
echo ""

# Check available space
target_dir="$TARGET"
[[ ! -d "$target_dir" ]] && target_dir="$(dirname "$TARGET")"
avail_bytes=$(df -B1 "$target_dir" 2>/dev/null | tail -1 | awk '{print $4}')
avail_human=$(human_size "$avail_bytes")

if [[ "$transfer_bytes" -gt "$avail_bytes" ]]; then
    echo "ERROR: Not enough space on target!"
    echo "  Transfer size:   $transfer_human"
    echo "  Available space: $avail_human"
    echo ""
    echo "Free up space or reduce the manifest, then re-run."
    exit 1
fi

echo "  Available space: $avail_human — sufficient"
echo ""

# --- Create target directory ---
mkdir -p "$TARGET"

# --- Initialize log ---
echo "# Backup Mover Log" > "$LOG_FILE"
echo "# Started: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
echo "# Source: $SOURCE" >> "$LOG_FILE"
echo "# Target: $TARGET" >> "$LOG_FILE"
echo "# Files: $transfer_count, Size: $transfer_human" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

# --- Transfer Loop ---
current=0
transferred_bytes=0
error_count=0
ntfs_incompatible_files=()

# Read entries from manifest using jq
while IFS=$'\t' read -r source_path target_path relative_path size_bytes status; do
    ((current++)) || true

    # Calculate percentage
    if [[ "$transfer_bytes" -gt 0 ]]; then
        pct=$(( (transferred_bytes * 100) / transfer_bytes ))
    else
        pct=100
    fi

    transferred_human=$(human_size "$transferred_bytes")
    file_size_human=$(human_size "$size_bytes")

    # Progress line
    printf "\r[%*d/%d] [%3d%%] [%s / %s] Copying %s (%s)" \
        "${#transfer_count}" "$current" "$transfer_count" \
        "$pct" "$transferred_human" "$transfer_human" \
        "$relative_path" "$file_size_human"

    # Check for NTFS-incompatible filename
    local_basename=$(basename "$source_path")
    if has_ntfs_bad_chars "$local_basename"; then
        # Bundle into tar instead of direct copy
        ntfs_incompatible_files+=("$source_path")
        log_msg "NTFS" "Queued for tar bundle: $relative_path" >> "$LOG_FILE"
        ((transferred_bytes += size_bytes)) || true
        echo ""
        continue
    fi

    # Create parent directory
    target_parent=$(dirname "$target_path")
    if [[ ! -d "$target_parent" ]]; then
        mkdir -p "$target_parent" 2>/dev/null || true
    fi

    # Copy the file
    if [[ -f "$source_path" ]]; then
        if cp -a "$source_path" "$target_path" 2>/dev/null; then
            log_msg "OK" "cp $relative_path (${file_size_human})" >> "$LOG_FILE"
        else
            log_msg "FAIL" "cp $relative_path — cp failed" >> "$LOG_FILE"
            ((error_count++)) || true
            echo ""
            echo "  WARNING: Failed to copy $relative_path"
        fi
    elif [[ -d "$source_path" ]]; then
        # Empty directory
        mkdir -p "$target_path" 2>/dev/null || true
        log_msg "OK" "mkdir $relative_path" >> "$LOG_FILE"
    else
        log_msg "SKIP" "$relative_path — not a regular file" >> "$LOG_FILE"
    fi

    ((transferred_bytes += size_bytes)) || true

done < <(jq -r '.[] | select(.status == "NEEDS_BACKUP" or .status == "PARTIAL") | [.source_path, .target_path, .relative_path, (.size_bytes | tostring), .status] | @tsv' "$MANIFEST_FILE")

echo ""
echo ""

# --- Handle NTFS-incompatible files ---
if [[ ${#ntfs_incompatible_files[@]} -gt 0 ]]; then
    echo "[TAR] Bundling ${#ntfs_incompatible_files[@]} NTFS-incompatible files..."

    # Create a tar archive with these files
    tar_list_file=$(mktemp)
    for f in "${ntfs_incompatible_files[@]}"; do
        echo "$f" >> "$tar_list_file"
    done

    if tar -czf "$NTFS_TAR" -T "$tar_list_file" 2>/dev/null; then
        tar_size=$(stat -c '%s' "$NTFS_TAR" 2>/dev/null || echo 0)
        echo "[TAR] Created ntfs-incompatible.tar.gz ... OK ($(human_size "$tar_size"))"
        log_msg "TAR" "Created ntfs-incompatible.tar.gz (${#ntfs_incompatible_files[@]} files, $(human_size "$tar_size"))" >> "$LOG_FILE"
    else
        echo "[TAR] WARNING: Failed to create ntfs-incompatible.tar.gz"
        log_msg "FAIL" "Failed to create ntfs-incompatible.tar.gz" >> "$LOG_FILE"
        ((error_count++)) || true
    fi

    rm -f "$tar_list_file"
fi

# --- Permission-Critical Tar Archives ---
for perm_dir in "${PERMISSION_CRITICAL_DIRS[@]}"; do
    source_dir="${SOURCE}/home/${DEFAULT_USER}/${perm_dir}"
    if [[ -d "$source_dir" ]]; then
        tar_name="${perm_dir#.}"  # Remove leading dot
        tar_name="${tar_name}-keys.tar.gz"
        # Special case for gnupg
        [[ "$perm_dir" == ".gnupg" ]] && tar_name="gnupg-keys.tar.gz"
        [[ "$perm_dir" == ".ssh" ]] && tar_name="ssh-keys.tar.gz"

        echo "[TAR] Creating $tar_name from $source_dir ..."

        if tar -czf "${TARGET}/${tar_name}" -C "${SOURCE}/home/${DEFAULT_USER}" "$perm_dir" 2>/dev/null; then
            tar_size=$(stat -c '%s' "${TARGET}/${tar_name}" 2>/dev/null || echo 0)
            echo "[TAR] Creating $tar_name ... OK ($(human_size "$tar_size"))"
            log_msg "TAR" "Created $tar_name ($(human_size "$tar_size"))" >> "$LOG_FILE"
        else
            echo "[TAR] WARNING: Failed to create $tar_name"
            log_msg "FAIL" "Failed to create $tar_name" >> "$LOG_FILE"
            ((error_count++)) || true
        fi
    fi
done

# --- System Data ---
echo ""
SYSTEM_DIR="${TARGET}/system"
mkdir -p "$SYSTEM_DIR"

# Package lists
echo -n "[SYSTEM] Saving package lists ... "
# Try arch-chroot first
if arch-chroot "$SOURCE" pacman -Qqe > "${SYSTEM_DIR}/package-list-explicit.txt" 2>/dev/null; then
    log_msg "OK" "Saved package-list-explicit.txt via arch-chroot" >> "$LOG_FILE"
else
    log_msg "WARN" "arch-chroot pacman -Qqe failed, using fallback" >> "$LOG_FILE"
fi

if arch-chroot "$SOURCE" pacman -Qqm > "${SYSTEM_DIR}/package-list-aur.txt" 2>/dev/null; then
    log_msg "OK" "Saved package-list-aur.txt via arch-chroot" >> "$LOG_FILE"
else
    log_msg "WARN" "arch-chroot pacman -Qqm failed, using fallback" >> "$LOG_FILE"
fi

# Fallback: raw package list from pacman db
if [[ -d "${SOURCE}/var/lib/pacman/local" ]]; then
    ls "${SOURCE}/var/lib/pacman/local/" > "${SYSTEM_DIR}/package-list-raw.txt" 2>/dev/null
    log_msg "OK" "Saved package-list-raw.txt (fallback)" >> "$LOG_FILE"
fi
echo "OK"

# Crontab
echo -n "[SYSTEM] Saving crontab ... "
if [[ -f "${SOURCE}/var/spool/cron/${DEFAULT_USER}" ]]; then
    cp "${SOURCE}/var/spool/cron/${DEFAULT_USER}" "${SYSTEM_DIR}/crontab-${DEFAULT_USER}" 2>/dev/null
    log_msg "OK" "Saved crontab-${DEFAULT_USER}" >> "$LOG_FILE"
    echo "OK"
else
    echo "No crontab found"
    log_msg "SKIP" "No crontab for ${DEFAULT_USER}" >> "$LOG_FILE"
fi

# User systemd services
echo -n "[SYSTEM] Saving systemd user services ... "
if [[ -d "${SOURCE}/home/${DEFAULT_USER}/.config/systemd" ]]; then
    cp -a "${SOURCE}/home/${DEFAULT_USER}/.config/systemd" "${SYSTEM_DIR}/systemd-user/" 2>/dev/null
    log_msg "OK" "Saved systemd-user/" >> "$LOG_FILE"
    echo "OK"
else
    echo "No user services found"
    log_msg "SKIP" "No systemd user services" >> "$LOG_FILE"
fi

# --- Final log entry ---
echo "" >> "$LOG_FILE"
echo "# Completed: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
echo "# Files: $current transferred, $error_count errors" >> "$LOG_FILE"
echo "# Bytes: $(human_size "$transferred_bytes") transferred" >> "$LOG_FILE"

# --- Final Summary ---
echo ""
echo "========================================="
echo "  Transfer Complete"
echo "========================================="
echo ""
echo "[DONE] Transfer complete: $current files, $(human_size "$transferred_bytes") transferred, $error_count errors"
echo "[DONE] Log saved to $LOG_FILE"

if [[ $error_count -gt 0 ]]; then
    echo ""
    echo "WARNING: $error_count errors occurred. Review $LOG_FILE for details."
    echo "Re-run checker.sh to identify any remaining files."
fi
