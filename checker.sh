#!/usr/bin/env bash
# checker.sh — Backup Analysis & Comparison
# Scans relevant directories on a broken system, compares against what already
# exists on the Storage disk, and produces a report + JSON manifest.
#
# Usage:
#   ./checker.sh --source /mnt --target /mnt/recovery/backup-arch-2026-03-20 \
#                --user kyonax --output /tmp/recovery-scripts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

# --- Argument Parsing ---
SOURCE="$DEFAULT_SOURCE"
TARGET="$DEFAULT_TARGET"
USER_NAME="$DEFAULT_USER"
OUTPUT_DIR="$DEFAULT_OUTPUT"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source)  SOURCE="$2"; shift 2 ;;
        --target)  TARGET="$2"; shift 2 ;;
        --user)    USER_NAME="$2"; shift 2 ;;
        --output)  OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--source DIR] [--target DIR] [--user NAME] [--output DIR]"
            echo ""
            echo "  --source   Root of the broken system (default: $DEFAULT_SOURCE)"
            echo "  --target   Backup destination directory (default: $DEFAULT_TARGET)"
            echo "  --user     Username on the broken system (default: $DEFAULT_USER)"
            echo "  --output   Directory for report and manifest (default: $DEFAULT_OUTPUT)"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

REPORT_FILE="${OUTPUT_DIR}/backup_report.md"
MANIFEST_FILE="${OUTPUT_DIR}/backup_manifest.json"

# --- Validation ---
if [[ ! -d "$SOURCE" ]]; then
    echo "ERROR: Source directory does not exist: $SOURCE"
    echo "       Is the broken system's root partition mounted?"
    exit 1
fi

if [[ ! -d "$TARGET" ]]; then
    echo "INFO: Target directory does not exist, will be created by mover: $TARGET"
fi

# --- Counters ---
total_files=0
needs_backup_count=0
needs_backup_bytes=0
partial_count=0
partial_bytes=0
already_saved_count=0
already_saved_bytes=0
excluded_count=0
excluded_bytes=0
symlink_count=0
large_file_count=0
ntfs_incompatible_count=0

# --- JSON Manifest Array ---
manifest_entries=()

# --- Report Tables ---
table_will_move=()
table_already_saved=()
table_excluded=()

# --- Add a manifest entry ---
add_entry() {
    local source_path="$1"
    local target_path="$2"
    local relative_path="$3"
    local size_bytes="$4"
    local status="$5"
    local priority="$6"
    local entry_type="$7"
    local link_target="${8:-null}"
    local notes="${9:-}"

    local size_human
    size_human=$(human_size "$size_bytes")

    local link_json="null"
    [[ "$link_target" != "null" ]] && link_json="\"$link_target\""

    manifest_entries+=("{\"source_path\":\"$source_path\",\"target_path\":\"$target_path\",\"relative_path\":\"$relative_path\",\"size_bytes\":$size_bytes,\"size_human\":\"$size_human\",\"status\":\"$status\",\"priority\":$priority,\"type\":\"$entry_type\",\"link_target\":$link_json}")

    case "$status" in
        NEEDS_BACKUP)
            ((needs_backup_count++)) || true
            ((needs_backup_bytes += size_bytes)) || true
            local flag=""
            [[ $size_bytes -ge $LARGE_FILE_THRESHOLD ]] && flag=" **LARGE**" && ((large_file_count++)) || true
            has_ntfs_bad_chars "$(basename "$source_path")" && flag="${flag} **NTFS**" && ((ntfs_incompatible_count++)) || true
            table_will_move+=("| $priority | \`$relative_path\` | $size_human | NEEDS_BACKUP | ${notes}${flag} |")
            ;;
        PARTIAL)
            ((partial_count++)) || true
            ((partial_bytes += size_bytes)) || true
            table_will_move+=("| $priority | \`$relative_path\` | $size_human | PARTIAL | ${notes} |")
            ;;
        ALREADY_SAVED)
            ((already_saved_count++)) || true
            ((already_saved_bytes += size_bytes)) || true
            table_already_saved+=("| \`$relative_path\` | \`${target_path}\` | $size_human | YES |")
            ;;
        EXCLUDED)
            ((excluded_count++)) || true
            ((excluded_bytes += size_bytes)) || true
            table_excluded+=("| \`$relative_path\` | $size_human | Excluded (${notes}) |")
            ;;
        SYMLINK)
            ((symlink_count++)) || true
            table_excluded+=("| \`$relative_path\` | - | Symlink → ${link_target} |")
            ;;
    esac
}

# --- Scan a single file ---
scan_file() {
    local file_path="$1"
    local source_root="$2"
    local target_root="$3"
    local priority="$4"
    local scan_dir_path="$5"  # the original scan dir config path (for relative path calc)

    ((total_files++)) || true

    # Get path relative to source root
    local rel_from_source="${file_path#${SOURCE}/}"
    local target_file="${TARGET}/${rel_from_source}"

    # Check if it's a symlink
    if [[ -L "$file_path" ]]; then
        local link_target
        link_target=$(readlink "$file_path" 2>/dev/null || echo "unreadable")
        add_entry "$file_path" "$target_file" "$rel_from_source" 0 "SYMLINK" "$priority" "symlink" "$link_target"
        return
    fi

    # Check if it's a special file (socket, pipe, device)
    if [[ ! -f "$file_path" ]]; then
        return
    fi

    # Get file size
    local size_bytes
    size_bytes=$(stat -c '%s' "$file_path" 2>/dev/null || echo 0)

    # Check exclude patterns
    if is_excluded "$rel_from_source"; then
        add_entry "$file_path" "$target_file" "$rel_from_source" "$size_bytes" "EXCLUDED" "$priority" "file" "null" "matches exclude pattern"
        return
    fi

    # Check if target exists
    if [[ -f "$target_file" ]]; then
        local target_size
        target_size=$(stat -c '%s' "$target_file" 2>/dev/null || echo 0)

        if [[ "$size_bytes" -eq "$target_size" ]]; then
            add_entry "$file_path" "$target_file" "$rel_from_source" "$size_bytes" "ALREADY_SAVED" "$priority" "file"
        else
            add_entry "$file_path" "$target_file" "$rel_from_source" "$size_bytes" "PARTIAL" "$priority" "file" "null" "size mismatch: source=${size_bytes} target=${target_size}"
        fi
    else
        add_entry "$file_path" "$target_file" "$rel_from_source" "$size_bytes" "NEEDS_BACKUP" "$priority" "file"
    fi
}

# --- Scan a directory recursively ---
scan_directory() {
    local dir_path="$1"
    local priority="$2"
    local config_path="$3"
    local description="$4"

    if [[ ! -d "$dir_path" ]]; then
        echo "  SKIP: Directory does not exist: $dir_path"
        return
    fi

    echo "  Scanning: $dir_path ($description)"

    local file_count=0
    while IFS= read -r -d '' file; do
        scan_file "$file" "$SOURCE" "$TARGET" "$priority" "$config_path"
        ((file_count++)) || true

        # Progress indicator every 500 files
        if (( file_count % 500 == 0 )); then
            echo "    ... $file_count files scanned"
        fi
    done < <(find "$dir_path" -mindepth 1 \( -type f -o -type l \) -print0 2>/dev/null)

    # Also record empty directories
    while IFS= read -r -d '' dir; do
        local dir_rel="${dir#${SOURCE}/}"
        local target_dir="${TARGET}/${dir_rel}"
        if [[ ! -d "$target_dir" ]] && [[ -z "$(find "$dir" -maxdepth 0 -empty 2>/dev/null)" ]]; then
            continue
        fi
        if [[ -z "$(ls -A "$dir" 2>/dev/null)" ]]; then
            add_entry "$dir" "$target_dir" "$dir_rel" 0 "NEEDS_BACKUP" "$priority" "directory" "null" "empty directory"
        fi
    done < <(find "$dir_path" -mindepth 1 -type d -empty -print0 2>/dev/null)

    echo "    Done: $file_count files found"
}

# --- Main Scan ---
echo "========================================="
echo "  Backup Checker — pc-migration-scripts"
echo "========================================="
echo ""
echo "Source:  $SOURCE"
echo "Target:  $TARGET"
echo "User:    $USER_NAME"
echo "Output:  $OUTPUT_DIR"
echo ""
echo "Scanning directories..."
echo ""

# Track which source directories we've already scanned to avoid duplicates
# (e.g., ~/Documents contains ~/Documents/github-kyonax)
scanned_paths=()

for entry in "${SCAN_DIRS[@]}"; do
    IFS='|' read -r priority config_path description <<< "$entry"

    local_source=$(resolve_path "$config_path" "$SOURCE" "$USER_NAME")

    # Check if this path is a subdirectory of an already-scanned path
    skip=false
    for scanned in "${scanned_paths[@]:-}"; do
        if [[ -n "$scanned" ]] && [[ "$local_source" == "$scanned"/* ]]; then
            echo "  SKIP: $config_path (already covered by parent scan)"
            skip=true
            break
        fi
    done
    [[ "$skip" == "true" ]] && continue

    echo "[Priority $priority] $description"
    scan_directory "$local_source" "$priority" "$config_path" "$description"
    scanned_paths+=("$local_source")
    echo ""
done

# --- Generate JSON Manifest ---
echo "Generating manifest..."
{
    echo "["
    local first=true
    for entry in "${manifest_entries[@]}"; do
        if [[ "$first" == "true" ]]; then
            echo "  $entry"
            first=false
        else
            echo "  ,$entry"
        fi
    done
    echo "]"
} > "$MANIFEST_FILE"

# --- Generate Report ---
echo "Generating report..."

transfer_total=$((needs_backup_bytes + partial_bytes))
transfer_human=$(human_size $transfer_total)
saved_human=$(human_size $already_saved_bytes)
excluded_human=$(human_size $excluded_bytes)

# Get available space on target
target_avail="unknown"
if [[ -d "$TARGET" ]] || [[ -d "$(dirname "$TARGET")" ]]; then
    target_mount=$(df -B1 "$(dirname "$TARGET")" 2>/dev/null | tail -1 | awk '{print $4}')
    if [[ -n "$target_mount" ]]; then
        target_avail=$(human_size "$target_mount")
    fi
fi

{
    echo "# Backup Analysis Report"
    echo ""
    echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Source: \`$SOURCE\` | Target: \`$TARGET\` | User: \`$USER_NAME\`"
    echo ""
    echo "## Summary"
    echo ""
    echo "| Metric | Count | Size |"
    echo "|---|---|---|"
    echo "| Files to transfer | $((needs_backup_count + partial_count)) | $transfer_human |"
    echo "| Already saved | $already_saved_count | $saved_human |"
    echo "| Excluded | $excluded_count | $excluded_human |"
    echo "| Symlinks | $symlink_count | - |"
    echo "| Large files (>1G) | $large_file_count | - |"
    echo "| NTFS-incompatible names | $ntfs_incompatible_count | - |"
    echo "| **Total scanned** | **$total_files** | - |"
    echo ""
    echo "**Transfer size: $transfer_human** | Available on target: $target_avail"
    echo ""

    # Table 1: Will Be Moved
    echo "## Table 1: WILL BE MOVED"
    echo ""
    if [[ ${#table_will_move[@]} -gt 0 ]]; then
        echo "| Priority | Source Path | Size | Status | Notes |"
        echo "|---|---|---|---|---|"
        for row in "${table_will_move[@]}"; do
            echo "$row"
        done
    else
        echo "*Nothing to transfer — all files already saved.*"
    fi
    echo ""

    # Table 2: Already Saved
    echo "## Table 2: ALREADY SAVED"
    echo ""
    if [[ ${#table_already_saved[@]} -gt 0 ]]; then
        echo "| Source Path | Target Path | Size | Verified |"
        echo "|---|---|---|---|"
        # Limit to first 100 entries to keep report readable
        local count=0
        for row in "${table_already_saved[@]}"; do
            echo "$row"
            ((count++)) || true
            if [[ $count -ge 100 ]] && [[ ${#table_already_saved[@]} -gt 100 ]]; then
                echo "| ... | ... | ... | ... |"
                echo "| *$(( ${#table_already_saved[@]} - 100 )) more entries omitted* | | | |"
                break
            fi
        done
    else
        echo "*No files found on target — this is a fresh backup.*"
    fi
    echo ""

    # Table 3: Excluded / Not Saved
    echo "## Table 3: EXCLUDED / NOT SAVED"
    echo ""
    if [[ ${#table_excluded[@]} -gt 0 ]]; then
        echo "| Source Path | Size | Reason |"
        echo "|---|---|---|"
        local count=0
        for row in "${table_excluded[@]}"; do
            echo "$row"
            ((count++)) || true
            if [[ $count -ge 100 ]] && [[ ${#table_excluded[@]} -gt 100 ]]; then
                echo "| ... | ... | ... |"
                echo "| *$(( ${#table_excluded[@]} - 100 )) more entries omitted* | | |"
                break
            fi
        done
    else
        echo "*No files excluded.*"
    fi
    echo ""

    echo "---"
    echo ""
    echo "**Transfer size: $transfer_human** | **Already saved: $saved_human** | **Excluded: $excluded_human** | **Available: $target_avail**"
} > "$REPORT_FILE"

# --- Summary ---
echo ""
echo "========================================="
echo "  Scan Complete"
echo "========================================="
echo ""
echo "  Total files scanned:    $total_files"
echo "  To transfer:            $((needs_backup_count + partial_count)) files ($transfer_human)"
echo "    - Needs backup:       $needs_backup_count"
echo "    - Partial (changed):  $partial_count"
echo "  Already saved:          $already_saved_count ($saved_human)"
echo "  Excluded:               $excluded_count ($excluded_human)"
echo "  Symlinks:               $symlink_count"
echo "  Large files (>1G):      $large_file_count"
echo "  NTFS-incompatible:      $ntfs_incompatible_count"
echo ""
echo "  Available on target:    $target_avail"
echo ""
echo "  Report:   $REPORT_FILE"
echo "  Manifest: $MANIFEST_FILE"
echo ""
echo "Review the report before running mover.sh"
