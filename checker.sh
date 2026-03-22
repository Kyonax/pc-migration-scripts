#!/usr/bin/env bash
# checker.sh — Backup Analysis & Comparison
# Scans the ENTIRE source disk, skips system directories, compares against
# what already exists on Storage, and produces a report + JSON manifest.
#
# Usage:
#   ./checker.sh --source /mnt/source --target /mnt/recovery/backup-arch-2026-03-20 \
#                --user kyonax --output /tmp/recovery-scripts

set -euo pipefail

trap 'tput rmcup 2>/dev/null; printf "\033[;r"; tput cup 999 0 2>/dev/null; echo ""; echo "ERROR: checker.sh failed at line $LINENO (exit code $?)"; echo "Last command: $BASH_COMMAND"; exit 1' ERR

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
SAVE_PACKAGES=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source)  SOURCE="$2"; shift 2 ;;
        --target)  TARGET="$2"; shift 2 ;;
        --user)    USER_NAME="$2"; shift 2 ;;
        --output)  OUTPUT_DIR="$2"; shift 2 ;;
        --save-packages) SAVE_PACKAGES=true; shift ;;
        -h|--help)
            echo "checker.sh — Backup Analysis & Comparison"
            echo ""
            echo "Scans the entire source disk, skips system directories, compares"
            echo "each file against the target, and produces a report + JSON manifest."
            echo ""
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --source DIR       Root of the broken system (default: $DEFAULT_SOURCE)"
            echo "  --target DIR       Backup destination directory (default: $DEFAULT_TARGET)"
            echo "  --user NAME        Username on the broken system (default: $DEFAULT_USER)"
            echo "  --output DIR       Directory for report and manifest (default: $DEFAULT_OUTPUT)"
            echo "  --save-packages    Extract pacman/yay package lists (does not affect reports)"
            echo "  -h, --help         Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0 --output /tmp/recovery-scripts"
            echo "  $0 --output /tmp/recovery-scripts --save-packages"
            echo "  $0 --source /mnt/source --target /mnt/recovery/backup --user kyonax --output ."
            echo ""
            echo "Output files:"
            echo "  backup_report.md       Human-readable report (3 tables)"
            echo "  backup_manifest.json   Machine-readable manifest for mover.sh"
            echo "  package-lists/         Package lists (only with --save-packages)"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

REPORT_FILE="${OUTPUT_DIR}/backup_report.md"
MANIFEST_FILE="${OUTPUT_DIR}/backup_manifest.json"
SCAN_START=$(date +%s)

# --- Validation (before TUI) ---
if [[ ! -d "$SOURCE" ]]; then
    echo "ERROR: Source directory does not exist: $SOURCE"
    echo "       Is the broken system's root partition mounted?"
    exit 1
fi

# --- Clean previous reports ---
rm -f "$REPORT_FILE" "$MANIFEST_FILE" 2>/dev/null || true

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
skipped_system_count=0
large_file_count=0
ntfs_incompatible_count=0
scan_dirs_found=0
scan_dirs_skipped=0
current_dir_name=""
current_dir_files=0
current_dir_total=0
last_file=""

# --- JSON Manifest Array ---
manifest_entries=()

# --- Report Tables ---
table_will_move=()
table_already_saved=()
table_excluded=()

# ═══════════════════════════════════════
#   DISCOVER TOP-LEVEL DIRECTORIES
# ═══════════════════════════════════════
# Walk the root of the source disk, separate system vs user dirs
user_dirs=()
system_dirs_found=()

for entry in "$SOURCE"/*/; do
    [[ ! -d "$entry" ]] && continue
    dirname=$(basename "$entry")
    if is_system_dir "$dirname"; then
        system_dirs_found+=("$dirname")
        ((scan_dirs_skipped++)) || true
    else
        user_dirs+=("$entry")
        ((scan_dirs_found++)) || true
    fi
done

# Also check for files directly in the root (rare but possible)
root_has_files=false
for f in "$SOURCE"/*; do
    [[ -f "$f" ]] && root_has_files=true && break
done

dir_total=${#user_dirs[@]}
[[ "$root_has_files" == "true" ]] && ((dir_total++)) || true
dir_index=0

# ═══════════════════════════════════════
#   TUI SETUP
# ═══════════════════════════════════════
TERM_LINES=$(tput lines 2>/dev/null || echo 24)
TERM_COLS=$(tput cols 2>/dev/null || echo 80)
DASHBOARD_HEIGHT=15
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
    printf "${C_BOLD}${C_CYAN}  BACKUP CHECKER — Full Disk Scan${C_RESET}%*s\n" 28 ""
    printf "${C_BOLD}${C_CYAN}══════════════════════════════════════════════════════════════${C_RESET}\n"

    printf "  Source: ${C_BOLD}%s${C_RESET}  User: ${C_BOLD}%s${C_RESET}\033[K\n" "$SOURCE" "$USER_NAME"

    # Overall progress
    overall_pct=0
    [[ $dir_total -gt 0 ]] && overall_pct=$(( (dir_index * 100) / dir_total ))
    bar=$(progress_bar "$overall_pct")
    elapsed=$(elapsed_since "$SCAN_START")
    rate=0
    elapsed_secs=$(( $(date +%s) - SCAN_START ))
    [[ $elapsed_secs -gt 0 ]] && [[ $total_files -gt 0 ]] && rate=$(( total_files / elapsed_secs ))
    printf "  [${C_CYAN}%s${C_RESET}] ${C_BOLD}%3d%%${C_RESET}  %d/%d dirs  %s" \
        "$bar" "$overall_pct" "$dir_index" "$dir_total" "$elapsed"
    [[ $rate -gt 0 ]] && printf "  %d f/s" "$rate"
    printf "\033[K\n"

    # Current directory
    if [[ -n "$current_dir_name" ]]; then
        dir_pct=0
        [[ $current_dir_total -gt 0 ]] && dir_pct=$(( (current_dir_files * 100) / current_dir_total ))
        printf "  Scanning: ${C_BOLD}%s${C_RESET} [%d/%d %d%%]\033[K\n" \
            "$current_dir_name" "$current_dir_files" "$current_dir_total" "$dir_pct"
    else
        printf "  ${C_DIM}Discovering directories...${C_RESET}\033[K\n"
    fi

    printf "  ${C_DIM}──────────────────────────────────────────────────────────${C_RESET}\n"

    # Counters
    transfer_total_live=$((needs_backup_bytes + partial_bytes))
    printf "  ${C_RED}+${C_RESET} BACKUP:   %'6d  %8s    ${C_GREEN}✓${C_RESET} SAVED:    %'6d  %8s\033[K\n" \
        "$((needs_backup_count + partial_count))" "$(human_size $transfer_total_live)" \
        "$already_saved_count" "$(human_size $already_saved_bytes)"
    printf "  ${C_YELLOW}⊘${C_RESET} EXCLUDED: %'6d  %8s    ${C_MAGENTA}⤳${C_RESET} SYMLINKS: %'6d\033[K\n" \
        "$excluded_count" "$(human_size $excluded_bytes)" \
        "$symlink_count"

    # Totals
    printf "  ${C_BOLD}Total: %'d files${C_RESET}  ${C_DIM}Dirs: %d scanned, %d system-skipped${C_RESET}" \
        "$total_files" "$scan_dirs_found" "$scan_dirs_skipped"
    [[ $large_file_count -gt 0 ]] && printf "  ${C_YELLOW}⚠%d large${C_RESET}" "$large_file_count"
    printf "\033[K\n"

    printf "  ${C_DIM}──────────────────────────────────────────────────────────${C_RESET}\n"

    # Last file (truncated)
    if [[ -n "$last_file" ]]; then
        display_file="$last_file"
        max_len=$(( TERM_COLS - 4 ))
        if [[ ${#display_file} -gt $max_len ]]; then
            display_file="...${display_file: -$((max_len - 3))}"
        fi
        printf "  ${C_DIM}%s${C_RESET}\033[K\n" "$display_file"
    else
        printf "\033[K\n"
    fi

    printf "  ${C_DIM}── File Log ──────────────────────────────────────────────${C_RESET}\n"
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

    ((total_files++)) || true
    ((current_dir_files++)) || true

    local rel_from_source="${file_path#${SOURCE}/}"
    local target_file="${TARGET}/${rel_from_source}"
    local basename_file
    basename_file=$(basename "$file_path")

    last_file="$rel_from_source"

    # Determine priority
    local priority=2
    is_critical_path "$rel_from_source" "$USER_NAME" && priority=1

    # Symlink
    if [[ -L "$file_path" ]]; then
        local link_target
        link_target=$(readlink "$file_path" 2>/dev/null || echo "unreadable")
        add_entry "$file_path" "$target_file" "$rel_from_source" 0 "SYMLINK" "$priority" "symlink" "$link_target"
        log_line "  ${C_MAGENTA}⤳${C_RESET} ${C_DIM}$rel_from_source → $link_target${C_RESET}"
        return
    fi

    # Special file
    if [[ ! -f "$file_path" ]]; then
        return
    fi

    local size_bytes
    size_bytes=$(stat -c '%s' "$file_path" 2>/dev/null || echo 0)
    local size_human
    size_human=$(human_size "$size_bytes")

    # Excluded
    if is_excluded "$rel_from_source"; then
        add_entry "$file_path" "$target_file" "$rel_from_source" "$size_bytes" "EXCLUDED" "$priority" "file" "null" "matches exclude pattern"
        log_line "  ${C_YELLOW}⊘${C_RESET} ${C_DIM}$rel_from_source ($size_human)${C_RESET}"
        return
    fi

    # Compare with target
    if [[ -f "$target_file" ]]; then
        local target_size
        target_size=$(stat -c '%s' "$target_file" 2>/dev/null || echo 0)

        if [[ "$size_bytes" -eq "$target_size" ]]; then
            add_entry "$file_path" "$target_file" "$rel_from_source" "$size_bytes" "ALREADY_SAVED" "$priority" "file"
            log_line "  ${C_GREEN}✓${C_RESET} ${C_DIM}$rel_from_source ($size_human)${C_RESET}"
        else
            add_entry "$file_path" "$target_file" "$rel_from_source" "$size_bytes" "PARTIAL" "$priority" "file" "null" "size mismatch: source=${size_bytes} target=${target_size}"
            log_line "  ${C_YELLOW}△${C_RESET} $rel_from_source ${C_DIM}($size_human vs $(human_size "$target_size"))${C_RESET}"
        fi
    else
        add_entry "$file_path" "$target_file" "$rel_from_source" "$size_bytes" "NEEDS_BACKUP" "$priority" "file"
        local flags=""
        [[ $size_bytes -ge $LARGE_FILE_THRESHOLD ]] && flags=" ${C_YELLOW}[>1G]${C_RESET}"
        has_ntfs_bad_chars "$basename_file" && flags="${flags} ${C_RED}[NTFS]${C_RESET}"
        local pmark=""
        [[ $priority -eq 1 ]] && pmark="${C_RED}*${C_RESET}"
        log_line "  ${C_RED}+${C_RESET} ${pmark}${C_BOLD}$rel_from_source${C_RESET} ${C_DIM}($size_human)${C_RESET}${flags}"
    fi

    # Update dashboard every 50 files
    if (( total_files % 50 == 0 )); then
        draw_dashboard
    fi
}

# --- Build find prune expression ---
# Generates: \( -name "node_modules" -o -name ".cache" -o ... \) -prune
build_prune_expr() {
    local expr=""
    local first=true
    for pdir in "${PRUNE_DIRS[@]}"; do
        # Use basename only (prune matches directory names at any depth)
        local base
        base=$(basename "$pdir")
        if [[ "$first" == "true" ]]; then
            expr="-name \"$base\""
            first=false
        else
            expr="$expr -o -name \"$base\""
        fi
    done
    echo "$expr"
}

PRUNE_EXPR=$(build_prune_expr)

# --- Scan a directory recursively ---
scan_directory() {
    local dir_path="$1"
    local dir_label="$2"

    if [[ ! -d "$dir_path" ]]; then
        log_line "  ${C_RED}✗${C_RESET} Not found: $dir_path"
        return
    fi

    # Count files (with pruning for accurate count)
    current_dir_total=$(eval "find \"$dir_path\" -mindepth 1 \\( -type d \\( $PRUNE_EXPR \\) -prune \\) -o \\( -type f -o -type l \\) -print" 2>/dev/null | wc -l)
    current_dir_files=0
    current_dir_name="$dir_label"

    draw_dashboard

    log_line ""
    log_line "  ${C_CYAN}${C_BOLD}── $dir_label ──${C_RESET} ${C_DIM}($current_dir_total files, pruning ${#PRUNE_DIRS[@]} dir patterns)${C_RESET}"

    # Main scan with pruning — skips excluded directories entirely (fast)
    while IFS= read -r -d '' file; do
        scan_file "$file"
    done < <(eval "find \"$dir_path\" -mindepth 1 \\( -type d \\( $PRUNE_EXPR \\) -prune \\) -o \\( -type f -o -type l \\) -print0" 2>/dev/null)

    # Empty directories (also with pruning)
    while IFS= read -r -d '' dir; do
        local dir_rel="${dir#${SOURCE}/}"
        local target_dir="${TARGET}/${dir_rel}"
        if [[ -z "$(ls -A "$dir" 2>/dev/null)" ]]; then
            add_entry "$dir" "$target_dir" "$dir_rel" 0 "NEEDS_BACKUP" 2 "directory" "null" "empty directory"
        fi
    done < <(eval "find \"$dir_path\" -mindepth 1 \\( -type d \\( $PRUNE_EXPR \\) -prune \\) -o \\( -type d -empty -print0 \\)" 2>/dev/null)

    draw_dashboard
}

# ═══════════════════════════════════════
#   MAIN SCAN — WHOLE DISK
# ═══════════════════════════════════════

# Show what we discovered
log_line "  ${C_DIM}System dirs (skipped): ${system_dirs_found[*]}${C_RESET}"
log_line "  ${C_BOLD}User dirs to scan: ${#user_dirs[@]}${C_RESET}"
for ud in "${user_dirs[@]}"; do
    log_line "    ${C_GREEN}▸${C_RESET} $(basename "$ud")"
done

# Scan root-level files first (if any)
if [[ "$root_has_files" == "true" ]]; then
    ((dir_index++)) || true
    current_dir_name="/ (root files)"
    current_dir_files=0
    current_dir_total=0
    draw_dashboard
    log_line ""
    log_line "  ${C_CYAN}${C_BOLD}── Root-level files ──${C_RESET}"
    for f in "$SOURCE"/*; do
        [[ -f "$f" || -L "$f" ]] && scan_file "$f"
    done
fi

# Scan each user directory
for user_dir in "${user_dirs[@]}"; do
    ((dir_index++)) || true
    dirname=$(basename "$user_dir")
    scan_directory "$user_dir" "$dirname"
done

# Final dashboard
current_dir_name="SCAN COMPLETE"
current_dir_files=0
current_dir_total=0
dir_index=$dir_total
draw_dashboard

# ═══════════════════════════════════════
#   GENERATE OUTPUTS
# ═══════════════════════════════════════
log_line ""
log_line "  ${C_CYAN}${C_BOLD}── Generating Outputs ──${C_RESET}"

# JSON Manifest
log_line "  ${C_CYAN}▸${C_RESET} Writing manifest: $MANIFEST_FILE"
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
log_line "    ${C_GREEN}✓${C_RESET} OK ($(human_size "$manifest_size"), ${#manifest_entries[@]} entries)"

# Report
log_line "  ${C_CYAN}▸${C_RESET} Writing report: $REPORT_FILE"

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
    echo "| System dirs skipped | $scan_dirs_skipped | - |"
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
log_line "    ${C_GREEN}✓${C_RESET} OK ($(human_size "$report_size"))"

# ═══════════════════════════════════════
#   FINAL SUMMARY
# ═══════════════════════════════════════
total_elapsed=$(elapsed_since "$SCAN_START")
total_secs=$(( $(date +%s) - SCAN_START ))
total_rate=0
[[ $total_secs -gt 0 ]] && total_rate=$(( total_files / total_secs ))

log_line ""
log_line "  ${C_BOLD}${C_GREEN}══════════════════════════════════════════════════════════════${C_RESET}"
log_line "  ${C_BOLD}${C_GREEN}  SCAN COMPLETE${C_RESET}  $total_files files in $total_elapsed ($total_rate files/s)"
log_line "  ${C_BOLD}${C_GREEN}══════════════════════════════════════════════════════════════${C_RESET}"
log_line ""
log_line "  ${C_RED}█${C_RESET} To transfer:   $((needs_backup_count + partial_count)) files ($transfer_human)"
log_line "  ${C_GREEN}█${C_RESET} Already saved: $already_saved_count files ($saved_human)"
log_line "  ${C_YELLOW}█${C_RESET} Excluded:      $excluded_count files ($excluded_human)"
log_line "  ${C_DIM}█${C_RESET} System dirs:   $scan_dirs_skipped skipped (${system_dirs_found[*]})"
log_line ""
log_line "  Transfer: $transfer_human | Available: $target_avail"
log_line ""
log_line "  ${C_CYAN}📋${C_RESET} Report:   $REPORT_FILE"
log_line "  ${C_CYAN}📦${C_RESET} Manifest: $MANIFEST_FILE"
log_line ""
log_line "  ${C_BOLD}${C_GREEN}Review the report, then run mover.sh${C_RESET}"
log_line ""

# ═══════════════════════════════════════
#   OPTIONAL: SAVE PACKAGE NAMES
# ═══════════════════════════════════════
# Only runs with --save-packages flag. Does NOT affect reports or manifest.
# Reads folder names only — never scans inside packages.
if [[ "$SAVE_PACKAGES" == "true" ]]; then
    PKG_FILE="${OUTPUT_DIR}/packages.json"
    PKG_TXT="${OUTPUT_DIR}/packages.txt"
    HOME_DIR="${SOURCE}/home/${USER_NAME}"

    log_line ""
    log_line "  ${C_CYAN}${C_BOLD}── Collecting Package Names (--save-packages) ──${C_RESET}"
    log_line ""

    pkg_json_entries=()
    pkg_total=0

    # Helper: add packages from a newline-separated list
    add_packages() {
        local platform="$1" subtype="$2" pkg_list="$3" count=0
        while IFS= read -r pkg; do
            [[ -z "$pkg" ]] && continue
            pkg_json_entries+=("{\"name\":\"$pkg\",\"platform\":\"$platform\",\"type\":\"$subtype\"}")
            ((count++)) || true
            ((pkg_total++)) || true
        done <<< "$pkg_list"
        echo "$count"
    }

    # Helper: list folder names in a directory (just names, nothing else)
    list_dirs() {
        local dir="$1"
        [[ -d "$dir" ]] && ls -1 "$dir" 2>/dev/null | sort -u || true
    }

    # ── pacman ──
    log_line "  ${C_CYAN}▸${C_RESET} pacman..."
    pacman_list=""
    if [[ -d "${SOURCE}/var/lib/pacman/local" ]]; then
        pacman_list=$(list_dirs "${SOURCE}/var/lib/pacman/local" | sed 's/-[0-9].*//' | sort -u)
    fi
    if [[ -n "$pacman_list" ]]; then
        c=$(add_packages "pacman" "installed" "$pacman_list")
        log_line "    ${C_GREEN}✓${C_RESET} $c packages"
    else
        log_line "    ${C_DIM}⊘ Not found${C_RESET}"
    fi

    # ── npm global ──
    log_line "  ${C_CYAN}▸${C_RESET} npm global..."
    npm_list=""
    for d in "${HOME_DIR}/.nvm/versions/node"/*/lib/node_modules \
             "${HOME_DIR}/.npm-global/lib/node_modules" \
             "${SOURCE}/usr/lib/node_modules"; do
        [[ -d "$d" ]] || continue
        # Regular packages (folder names)
        npm_list+=$(list_dirs "$d" | grep -v '^npm$' | grep -v '^corepack$' | grep -v '^@')
        npm_list+=$'\n'
        # Scoped packages (@scope/name → read scope folder names)
        for scope in "$d"/@*/; do
            [[ -d "$scope" ]] || continue
            s=$(basename "$scope")
            for p in "$scope"/*/; do
                [[ -d "$p" ]] || continue
                npm_list+="${s}/$(basename "$p")"$'\n'
            done
        done
    done
    npm_list=$(echo "$npm_list" | sed '/^$/d' | sort -u)
    if [[ -n "$npm_list" ]]; then
        c=$(add_packages "npm" "global" "$npm_list")
        log_line "    ${C_GREEN}✓${C_RESET} $c packages"
    else
        log_line "    ${C_DIM}⊘ Not found${C_RESET}"
    fi

    # ── cargo ──
    log_line "  ${C_CYAN}▸${C_RESET} cargo..."
    cargo_list=""
    if [[ -d "${HOME_DIR}/.cargo/bin" ]]; then
        cargo_list=$(list_dirs "${HOME_DIR}/.cargo/bin" | grep -v '^\.')
    fi
    if [[ -n "$cargo_list" ]]; then
        c=$(add_packages "cargo" "installed" "$cargo_list")
        log_line "    ${C_GREEN}✓${C_RESET} $c crates"
    else
        log_line "    ${C_DIM}⊘ Not found${C_RESET}"
    fi

    # ── go ──
    log_line "  ${C_CYAN}▸${C_RESET} go..."
    go_list=""
    for d in "${HOME_DIR}/go/bin" "${HOME_DIR}/.local/share/go/bin"; do
        [[ -d "$d" ]] && go_list+=$(list_dirs "$d")$'\n'
    done
    go_list=$(echo "$go_list" | sed '/^$/d' | sort -u)
    if [[ -n "$go_list" ]]; then
        c=$(add_packages "go" "installed" "$go_list")
        log_line "    ${C_GREEN}✓${C_RESET} $c binaries"
    else
        log_line "    ${C_DIM}⊘ Not found${C_RESET}"
    fi

    # ── pip ──
    log_line "  ${C_CYAN}▸${C_RESET} pip..."
    pip_list=""
    for d in "${HOME_DIR}/.local/lib/python"*/site-packages; do
        [[ -d "$d" ]] || continue
        # Folder names ending in .dist-info = installed packages
        pip_list+=$(list_dirs "$d" | grep '\.dist-info$' | sed 's/\.dist-info$//;s/-[0-9].*//' | sort -u)
        pip_list+=$'\n'
    done
    pip_list=$(echo "$pip_list" | sed '/^$/d' | sort -u)
    if [[ -n "$pip_list" ]]; then
        c=$(add_packages "pip" "user" "$pip_list")
        log_line "    ${C_GREEN}✓${C_RESET} $c packages"
    else
        log_line "    ${C_DIM}⊘ Not found${C_RESET}"
    fi

    # ── gem ──
    log_line "  ${C_CYAN}▸${C_RESET} gem..."
    gem_list=""
    for d in "${HOME_DIR}/.local/share/gem/ruby"/*/gems \
             "${HOME_DIR}/.gem/ruby"/*/gems; do
        [[ -d "$d" ]] && gem_list+=$(list_dirs "$d" | sed 's/-[0-9].*//' | sort -u)$'\n'
    done
    gem_list=$(echo "$gem_list" | sed '/^$/d' | sort -u)
    if [[ -n "$gem_list" ]]; then
        c=$(add_packages "gem" "user" "$gem_list")
        log_line "    ${C_GREEN}✓${C_RESET} $c gems"
    else
        log_line "    ${C_DIM}⊘ Not found${C_RESET}"
    fi

    # ── Write JSON ──
    log_line ""
    log_line "  ${C_CYAN}▸${C_RESET} Writing packages.json ($pkg_total total)..."
    {
        echo "["
        first=true
        for entry in "${pkg_json_entries[@]}"; do
            if [[ "$first" == "true" ]]; then
                echo "  $entry"
                first=false
            else
                echo "  ,$entry"
            fi
        done
        echo "]"
    } > "$PKG_FILE"
    log_line "    ${C_GREEN}✓${C_RESET} $PKG_FILE"

    # ── Write text ──
    log_line "  ${C_CYAN}▸${C_RESET} Writing packages.txt..."
    {
        echo "# Package inventory — $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# Source: $SOURCE"
        echo "# Total: $pkg_total packages"
        cur_plat="" ; cur_type=""
        for entry in "${pkg_json_entries[@]}"; do
            p=$(echo "$entry" | grep -oP '"platform":"[^"]*"' | cut -d'"' -f4)
            t=$(echo "$entry" | grep -oP '"type":"[^"]*"' | cut -d'"' -f4)
            n=$(echo "$entry" | grep -oP '"name":"[^"]*"' | cut -d'"' -f4)
            if [[ "$p/$t" != "$cur_plat/$cur_type" ]]; then
                cur_plat="$p" ; cur_type="$t"
                echo ""
                echo "## $p ($t)"
            fi
            echo "  $n"
        done
    } > "$PKG_TXT"
    log_line "    ${C_GREEN}✓${C_RESET} $PKG_TXT"

    log_line ""
    log_line "  ${C_GREEN}${C_BOLD}✓ $pkg_total packages collected${C_RESET}"
    log_line ""
fi
