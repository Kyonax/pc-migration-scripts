#!/usr/bin/env bash
# checker.sh — Backup Analysis & Comparison
# Scans relevant directories on a broken system, compares against what already
# exists on the Storage disk, and produces a report + JSON manifest.
#
# Usage:
#   ./checker.sh --source /mnt --target /mnt/recovery/backup-arch-2026-03-20 \
#                --user kyonax --output /tmp/recovery-scripts

set -euo pipefail

# Error trap — show where the script failed
trap 'echo ""; echo "ERROR: checker.sh failed at line $LINENO (exit code $?)"; echo "Last command: $BASH_COMMAND"; exit 1' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "${SCRIPT_DIR}/config.sh" ]]; then
    echo "ERROR: config.sh not found at ${SCRIPT_DIR}/config.sh"
    exit 1
fi
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
SCAN_START=$(date +%s)

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
dir_index=0
dir_total=${#SCAN_DIRS[@]}

# --- JSON Manifest Array ---
manifest_entries=()

# --- Report Tables ---
table_will_move=()
table_already_saved=()
table_excluded=()

# ═══════════════════════════════════════
#   BANNER
# ═══════════════════════════════════════
print_header "BACKUP CHECKER — pc-migration-scripts"

printf "  ${C_BOLD}Source:${C_RESET}   %s\n" "$SOURCE"
printf "  ${C_BOLD}Target:${C_RESET}   %s\n" "$TARGET"
printf "  ${C_BOLD}User:${C_RESET}     %s\n" "$USER_NAME"
printf "  ${C_BOLD}Output:${C_RESET}   %s\n" "$OUTPUT_DIR"
printf "  ${C_BOLD}Started:${C_RESET}  %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# --- Validation ---
if [[ ! -d "$SOURCE" ]]; then
    printf "  ${C_RED}✗${C_RESET} Source directory does not exist: %s\n" "$SOURCE"
    printf "    Is the broken system's root partition mounted?\n"
    exit 1
fi
print_status "✓" "$C_GREEN" "Source exists" "$SOURCE"

if [[ -d "$TARGET" ]]; then
    print_status "✓" "$C_GREEN" "Target exists" "$TARGET (incremental scan)"
else
    print_status "○" "$C_YELLOW" "Target absent" "$TARGET (fresh backup — all files will be NEEDS_BACKUP)"
fi

# Show scan tiers
echo ""
print_subheader "Scan Configuration"
echo ""
local_crit=0 local_imp=0 local_sys=0
for entry in "${SCAN_DIRS[@]}"; do
    IFS='|' read -r p _ _ <<< "$entry"
    case "$p" in 1) ((local_crit++)) || true;; 2) ((local_imp++)) || true;; 3) ((local_sys++)) || true;; esac
done
printf "  ${C_BOLD}Directories:${C_RESET}  %d total (%d CRITICAL, %d IMPORTANT, %d SYSTEM)\n" "$dir_total" "$local_crit" "$local_imp" "$local_sys"
printf "  ${C_BOLD}Excludes:${C_RESET}     %d patterns\n" "${#EXCLUDE_PATTERNS[@]}"
printf "  ${C_BOLD}Large file:${C_RESET}   >%s flagged\n" "$(human_size $LARGE_FILE_THRESHOLD)"
echo ""

# Show all directories to be scanned
for entry in "${SCAN_DIRS[@]}"; do
    IFS='|' read -r priority config_path description <<< "$entry"
    local_source=$(resolve_path "$config_path" "$SOURCE" "$USER_NAME")
    exists_mark=""
    if [[ -d "$local_source" ]]; then
        exists_mark="${C_GREEN}✓${C_RESET}"
    else
        exists_mark="${C_RED}✗${C_RESET}"
    fi
    printf "    ${C_DIM}P%s${C_RESET} %b %-45s %s\n" "$priority" "$exists_mark" "$config_path" "${C_DIM}${description}${C_RESET}"
done
echo ""

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

# --- Scan a single file (verbose) ---
scan_file() {
    local file_path="$1"
    local source_root="$2"
    local target_root="$3"
    local priority="$4"
    local scan_dir_path="$5"

    ((total_files++)) || true

    local rel_from_source="${file_path#${SOURCE}/}"
    local target_file="${TARGET}/${rel_from_source}"
    local basename_file
    basename_file=$(basename "$file_path")

    # Symlink
    if [[ -L "$file_path" ]]; then
        local link_target
        link_target=$(readlink "$file_path" 2>/dev/null || echo "unreadable")
        add_entry "$file_path" "$target_file" "$rel_from_source" 0 "SYMLINK" "$priority" "symlink" "$link_target"
        printf "    ${C_MAGENTA}⤳${C_RESET} ${C_DIM}SYMLINK${C_RESET}  %s → %s\n" "$rel_from_source" "$link_target"
        return
    fi

    # Special file
    if [[ ! -f "$file_path" ]]; then
        printf "    ${C_DIM}⊘ SKIP     %s (special file)${C_RESET}\n" "$rel_from_source"
        return
    fi

    local size_bytes
    size_bytes=$(stat -c '%s' "$file_path" 2>/dev/null || echo 0)
    local size_human
    size_human=$(human_size "$size_bytes")

    # Excluded
    if is_excluded "$rel_from_source"; then
        add_entry "$file_path" "$target_file" "$rel_from_source" "$size_bytes" "EXCLUDED" "$priority" "file" "null" "matches exclude pattern"
        printf "    ${C_YELLOW}⊘${C_RESET} ${C_DIM}EXCLUDED${C_RESET} %s ${C_DIM}(%s)${C_RESET}\n" "$rel_from_source" "$size_human"
        return
    fi

    # NTFS-incompatible check (flag only, still classify normally)
    local ntfs_flag=""
    if has_ntfs_bad_chars "$basename_file"; then
        ntfs_flag=" ${C_RED}[NTFS!]${C_RESET}"
    fi

    # Large file check (flag only)
    local large_flag=""
    if [[ $size_bytes -ge $LARGE_FILE_THRESHOLD ]]; then
        large_flag=" ${C_YELLOW}[>1G]${C_RESET}"
    fi

    # Compare with target
    if [[ -f "$target_file" ]]; then
        local target_size
        target_size=$(stat -c '%s' "$target_file" 2>/dev/null || echo 0)

        if [[ "$size_bytes" -eq "$target_size" ]]; then
            add_entry "$file_path" "$target_file" "$rel_from_source" "$size_bytes" "ALREADY_SAVED" "$priority" "file"
            printf "    ${C_GREEN}✓${C_RESET} ${C_DIM}SAVED${C_RESET}    %s ${C_DIM}(%s)${C_RESET}\n" "$rel_from_source" "$size_human"
        else
            add_entry "$file_path" "$target_file" "$rel_from_source" "$size_bytes" "PARTIAL" "$priority" "file" "null" "size mismatch: source=${size_bytes} target=${target_size}"
            printf "    ${C_YELLOW}△${C_RESET} PARTIAL  %s ${C_DIM}(%s vs %s on target)${C_RESET}%b%b\n" "$rel_from_source" "$size_human" "$(human_size "$target_size")" "$ntfs_flag" "$large_flag"
        fi
    else
        add_entry "$file_path" "$target_file" "$rel_from_source" "$size_bytes" "NEEDS_BACKUP" "$priority" "file"
        printf "    ${C_RED}+${C_RESET} ${C_BOLD}BACKUP${C_RESET}   %s ${C_DIM}(%s)${C_RESET}%b%b\n" "$rel_from_source" "$size_human" "$ntfs_flag" "$large_flag"
    fi
}

# --- Scan a directory recursively ---
scan_directory() {
    local dir_path="$1"
    local priority="$2"
    local config_path="$3"
    local description="$4"

    if [[ ! -d "$dir_path" ]]; then
        printf "  ${C_RED}✗${C_RESET} Directory does not exist: %s\n" "$dir_path"
        return
    fi

    # Count files first for percentage
    local expected_count
    expected_count=$(find "$dir_path" -mindepth 1 \( -type f -o -type l \) 2>/dev/null | wc -l)

    # Get directory size
    local dir_size_bytes
    dir_size_bytes=$(du -sb "$dir_path" 2>/dev/null | awk '{print $1}' || echo 0)
    local dir_size_human
    dir_size_human=$(human_size "$dir_size_bytes")

    printf "  ${C_BOLD}%s${C_RESET} ${C_DIM}(%s files, %s)${C_RESET}\n" "$dir_path" "$expected_count" "$dir_size_human"
    echo ""

    local file_count=0
    local dir_start
    dir_start=$(date +%s)

    while IFS= read -r -d '' file; do
        scan_file "$file" "$SOURCE" "$TARGET" "$priority" "$config_path"
        ((file_count++)) || true

        # Inline progress every 100 files
        if (( file_count % 100 == 0 )); then
            local dir_pct=0
            [[ "$expected_count" -gt 0 ]] && dir_pct=$(( (file_count * 100) / expected_count ))
            local dir_elapsed
            dir_elapsed=$(elapsed_since "$dir_start")
            printf "\n    ${C_DIM}── %d/%d files (%d%%) — elapsed %s ──${C_RESET}\n\n" \
                "$file_count" "$expected_count" "$dir_pct" "$dir_elapsed"
        fi
    done < <(find "$dir_path" -mindepth 1 \( -type f -o -type l \) -print0 2>/dev/null)

    # Empty directories
    while IFS= read -r -d '' dir; do
        local dir_rel="${dir#${SOURCE}/}"
        local target_dir="${TARGET}/${dir_rel}"
        if [[ -z "$(ls -A "$dir" 2>/dev/null)" ]]; then
            add_entry "$dir" "$target_dir" "$dir_rel" 0 "NEEDS_BACKUP" "$priority" "directory" "null" "empty directory"
            printf "    ${C_CYAN}▪${C_RESET} ${C_DIM}EMPTYDIR${C_RESET} %s\n" "$dir_rel"
        fi
    done < <(find "$dir_path" -mindepth 1 -type d -empty -print0 2>/dev/null)

    local dir_elapsed
    dir_elapsed=$(elapsed_since "$dir_start")
    local rate=0
    local dir_secs=$(( $(date +%s) - dir_start ))
    [[ $dir_secs -gt 0 ]] && rate=$(( file_count / dir_secs ))

    echo ""
    printf "    ${C_GREEN}Done:${C_RESET} %d files in %s" "$file_count" "$dir_elapsed"
    [[ $rate -gt 0 ]] && printf " (%d files/sec)" "$rate"
    echo ""
}

# ═══════════════════════════════════════
#   MAIN SCAN
# ═══════════════════════════════════════
print_subheader "Scanning Directories"
echo ""

scanned_paths=()

for entry in "${SCAN_DIRS[@]}"; do
    IFS='|' read -r priority config_path description <<< "$entry"
    ((dir_index++)) || true

    local_source=$(resolve_path "$config_path" "$SOURCE" "$USER_NAME")

    # Overall progress
    overall_pct=$(( (dir_index * 100) / dir_total ))
    bar=$(progress_bar "$overall_pct")
    elapsed=$(elapsed_since "$SCAN_START")

    printf "${C_BOLD}[%d/%d] [%s] %3d%% ${C_RESET}${C_DIM}elapsed %s${C_RESET}\n" \
        "$dir_index" "$dir_total" "$bar" "$overall_pct" "$elapsed"

    # Priority label
    prio_label="" ; prio_color=""
    case "$priority" in
        1) prio_label="CRITICAL" prio_color="$C_RED" ;;
        2) prio_label="IMPORTANT" prio_color="$C_YELLOW" ;;
        3) prio_label="SYSTEM" prio_color="$C_CYAN" ;;
    esac
    printf "${prio_color}  [P%s %s]${C_RESET} %s\n" "$priority" "$prio_label" "$description"

    # Dedup check
    skip=false
    for scanned in "${scanned_paths[@]:-}"; do
        if [[ -n "$scanned" ]] && [[ "$local_source" == "$scanned"/* ]]; then
            printf "  ${C_YELLOW}↷${C_RESET} ${C_DIM}Skipped (already covered by parent scan: %s)${C_RESET}\n\n" "$scanned"
            skip=true
            break
        fi
    done
    [[ "$skip" == "true" ]] && continue

    scan_directory "$local_source" "$priority" "$config_path" "$description"
    scanned_paths+=("$local_source")
    echo ""
done

# ═══════════════════════════════════════
#   GENERATE OUTPUTS
# ═══════════════════════════════════════
print_subheader "Generating Outputs"
echo ""

# JSON Manifest
printf "  ${C_CYAN}▸${C_RESET} Writing manifest: %s ..." "$MANIFEST_FILE"
{
    echo "["
    first=true
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
manifest_size=$(stat -c '%s' "$MANIFEST_FILE" 2>/dev/null || echo 0)
printf " ${C_GREEN}OK${C_RESET} (%s, %d entries)\n" "$(human_size "$manifest_size")" "${#manifest_entries[@]}"

# Report
printf "  ${C_CYAN}▸${C_RESET} Writing report:   %s ..." "$REPORT_FILE"

transfer_total=$((needs_backup_bytes + partial_bytes))
transfer_human=$(human_size $transfer_total)
saved_human=$(human_size $already_saved_bytes)
excluded_human=$(human_size $excluded_bytes)

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
    echo "## Table 1: WILL BE MOVED"
    echo ""
    if [[ ${#table_will_move[@]} -gt 0 ]]; then
        echo "| Priority | Source Path | Size | Status | Notes |"
        echo "|---|---|---|---|---|"
        for row in "${table_will_move[@]}"; do echo "$row"; done
    else
        echo "*Nothing to transfer — all files already saved.*"
    fi
    echo ""
    echo "## Table 2: ALREADY SAVED"
    echo ""
    if [[ ${#table_already_saved[@]} -gt 0 ]]; then
        echo "| Source Path | Target Path | Size | Verified |"
        echo "|---|---|---|---|"
        count=0
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
    echo "## Table 3: EXCLUDED / NOT SAVED"
    echo ""
    if [[ ${#table_excluded[@]} -gt 0 ]]; then
        echo "| Source Path | Size | Reason |"
        echo "|---|---|---|"
        count=0
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

report_size=$(stat -c '%s' "$REPORT_FILE" 2>/dev/null || echo 0)
printf " ${C_GREEN}OK${C_RESET} (%s)\n" "$(human_size "$report_size")"

# ═══════════════════════════════════════
#   FINAL SUMMARY
# ═══════════════════════════════════════
total_elapsed=$(elapsed_since "$SCAN_START")
total_secs=$(( $(date +%s) - SCAN_START ))
total_rate=0
[[ $total_secs -gt 0 ]] && total_rate=$(( total_files / total_secs ))

print_header "SCAN COMPLETE"

printf "  ${C_BOLD}Total scanned:${C_RESET}       %'d files in %s" "$total_files" "$total_elapsed"
[[ $total_rate -gt 0 ]] && printf " (%d files/sec)" "$total_rate"
echo ""
echo ""

# Status breakdown with visual bars
total_actionable=$((needs_backup_count + partial_count))
printf "  ${C_RED}█${C_RESET} ${C_BOLD}To transfer:${C_RESET}       %'6d files  %10s\n" "$total_actionable" "$transfer_human"
printf "    ${C_DIM}├─ Needs backup:    %'6d files  %10s${C_RESET}\n" "$needs_backup_count" "$(human_size $needs_backup_bytes)"
printf "    ${C_DIM}└─ Partial/changed: %'6d files  %10s${C_RESET}\n" "$partial_count" "$(human_size $partial_bytes)"
printf "  ${C_GREEN}█${C_RESET} ${C_BOLD}Already saved:${C_RESET}     %'6d files  %10s\n" "$already_saved_count" "$saved_human"
printf "  ${C_YELLOW}█${C_RESET} ${C_BOLD}Excluded:${C_RESET}          %'6d files  %10s\n" "$excluded_count" "$excluded_human"
printf "  ${C_MAGENTA}█${C_RESET} ${C_BOLD}Symlinks:${C_RESET}          %'6d\n" "$symlink_count"
echo ""

# Warnings
if [[ $large_file_count -gt 0 ]]; then
    printf "  ${C_YELLOW}⚠${C_RESET}  Large files (>1G): %d — review in report\n" "$large_file_count"
fi
if [[ $ntfs_incompatible_count -gt 0 ]]; then
    printf "  ${C_YELLOW}⚠${C_RESET}  NTFS-incompatible:  %d — will be tar-bundled by mover\n" "$ntfs_incompatible_count"
fi
echo ""

# Space check
printf "  ${C_BOLD}Transfer size:${C_RESET}       %s\n" "$transfer_human"
printf "  ${C_BOLD}Available on target:${C_RESET}  %s\n" "$target_avail"

if [[ -n "$target_mount" ]] && [[ "$transfer_total" -gt "$target_mount" ]]; then
    printf "\n  ${C_BG_RED}${C_WHITE} ✗ NOT ENOUGH SPACE — transfer will fail! ${C_RESET}\n"
elif [[ -n "$target_mount" ]]; then
    usage_pct=$(( (transfer_total * 100) / target_mount ))
    printf "  ${C_DIM}Transfer will use %d%% of available space${C_RESET}\n" "$usage_pct"
fi
echo ""

# Output files
print_subheader "Output Files"
echo ""
printf "  ${C_CYAN}📋${C_RESET} Report:   %s\n" "$REPORT_FILE"
printf "  ${C_CYAN}📦${C_RESET} Manifest: %s\n" "$MANIFEST_FILE"
echo ""
printf "  ${C_BOLD}${C_GREEN}Review the report before running mover.sh${C_RESET}\n"
echo ""
