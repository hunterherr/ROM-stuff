#!/bin/bash

# Configuration & Constants
ROOT_DIR="$(pwd)"
LOG="$ROOT_DIR/conversion_log.txt"
PROCESSED_DIR="$ROOT_DIR/processed_zips"
TEMP_DIR="$ROOT_DIR/temp_extract"
BYTES_PER_GB=1073741824

mkdir -p "$PROCESSED_DIR"
echo "--- Sega CD Multi-Rev Conversion Started: $(date) ---" > "$LOG"

# Global tracking variables
total_pre_bytes=0
total_post_bytes=0
total_saved_bytes=0

# ==========================================
# UTILITY FUNCTIONS (Single Responsibility)
# ==========================================

log_msg() {
    echo "$1" | tee -a "$LOG"
}

prepare_temp_dir() {
    rm -rf "$1" && mkdir -p "$1"
}

cleanup() {
    rm -rf "$TEMP_DIR"
}

is_already_processed() {
    [[ -f "$1" ]]
}

extract_zip() {
    unzip -q "$1" -d "$2"
}

# Uses a subshell (...) to search without changing the main script's directory state
find_cue() {
    (cd "$1" && ls *.cue 2>/dev/null | head -n 1)
}

calculate_pre_bytes() {
    (cd "$1" && du -cb *.cue *.bin 2>/dev/null | awk 'END {print $1}')
}

build_chd() {
    chdman createcd -i "$1" -o "$2"
}

verify_chd() {
    chdman verify -i "$1"
}

archive_source() {
    mv "$1" "$PROCESSED_DIR/"
}

update_running_totals() {
    local pre_bytes="$1"
    local out_path="$2"
    
    local post_bytes=$(stat -c%s "$out_path" 2>/dev/null)
    local saved_bytes=$((pre_bytes - post_bytes))

    total_pre_bytes=$((total_pre_bytes + pre_bytes))
    total_post_bytes=$((total_post_bytes + post_bytes))
    total_saved_bytes=$((total_saved_bytes + saved_bytes))
}

# ==========================================
# THE CONTROLLER
# ==========================================

process_zip() {
    local zip_file="$1"
    local base_name="${zip_file%.*}"
    local out_name="${base_name}.chd"
    local out_path="$ROOT_DIR/$out_name"

    if is_already_processed "$out_path"; then
        log_msg "[SKIP] $out_name exists. Archiving source."
        archive_source "$zip_file"
        return 0
    fi

    prepare_temp_dir "$TEMP_DIR"

    if ! extract_zip "$zip_file" "$TEMP_DIR"; then
        log_msg "[ERROR] Failed to extract $base_name"
        cleanup; return 1
    fi

    local cue_file=$(find_cue "$TEMP_DIR")
    if [[ -z "$cue_file" ]]; then
        log_msg "[SKIP] No .cue in $zip_file"
        cleanup; return 1
    fi

    local pre_bytes=$(calculate_pre_bytes "$TEMP_DIR")

    if ! build_chd "$TEMP_DIR/$cue_file" "$out_path"; then
        log_msg "[CREATE FAILED] $base_name"
        cleanup; return 1
    fi

    if ! verify_chd "$out_path"; then
        log_msg "[VERIFY FAILED] $base_name"
        cleanup; return 1
    fi

    # Post-Processing
    update_running_totals "$pre_bytes" "$out_path"
    log_msg "[SUCCESS] $base_name | Verified & Compressed"
    
    archive_source "$zip_file"
    cleanup
    return 0
}

# Catch termination signals (Ctrl+C, kill)
trap 'log_msg "\n[ABORT] Interrupt signal received. Cleaning up..."; cleanup; exit 1' SIGINT SIGTERM

# ==========================================
# MAIN EXECUTION LOOP
# ==========================================

total_zips=$(ls *.zip 2>/dev/null | wc -l)
current_count=0

echo "Found $total_zips files (including revisions). Starting process..."

for zip_file in *.zip; do
    [[ -e "$zip_file" ]] || break
    ((current_count++))
    
    echo "-------------------------------------------------------"
    echo "[$current_count / $total_zips] Processing: $zip_file"
    
    process_zip "$zip_file"
done

# Final Math output
total_pre_gb=$(awk "BEGIN {printf \"%.2f\", $total_pre_bytes/$BYTES_PER_GB}")
total_post_gb=$(awk "BEGIN {printf \"%.2f\", $total_post_bytes/$BYTES_PER_GB}")
total_saved_gb=$(awk "BEGIN {printf \"%.2f\", $total_saved_bytes/$BYTES_PER_GB}")
percent_saved=$(awk "BEGIN {printf \"%.1f\", ($total_saved_bytes/($total_pre_bytes+1))*100}")

log_msg "-------------------------------------------------------"
log_msg "FINAL ARCHIVE TALLY:"
log_msg "Original Uncompressed : ${total_pre_gb} GB"
log_msg "CHD Collection Size   : ${total_post_gb} GB"
log_msg "Space Reclaimed       : ${total_saved_gb} GB (${percent_saved}%)"
log_msg "--- Finished: $(date) ---"
