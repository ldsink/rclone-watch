#!/bin/bash

# Adapted from https://github.com/dx8ug/rclone-watch (MIT).
set -o pipefail

# Logging functions
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1"
}

validate_boolean() {
    local name="$1"
    case "${!name}" in
    true | false) return 0 ;;
    *)
        log_error "$name must be true or false"
        return 1
        ;;
    esac
}

# Default settings (set early to use in checks)
S3_PREFIX="${S3_PREFIX:-}"
UPLOAD_DELAY="${UPLOAD_DELAY:-5}" # Delay before upload in seconds
DRY_RUN="${DRY_RUN:-false}"       # Test mode without real upload
DELETE_AFTER_UPLOAD="${DELETE_AFTER_UPLOAD:-false}"
UPLOAD_EXISTING_FILES="${UPLOAD_EXISTING_FILES:-false}"
MAX_PARALLEL="${MAX_PARALLEL:-5}" # Maximum parallel uploads
mapfile -t include_patterns <<<"${WATCH_INCLUDE:-}"
mapfile -t exclude_patterns <<<"${WATCH_EXCLUDE:-}"

validate_boolean DRY_RUN || exit 1
validate_boolean DELETE_AFTER_UPLOAD || exit 1
validate_boolean UPLOAD_EXISTING_FILES || exit 1

# Check required environment variables
if [ -z "$WATCH_DIR" ]; then
    log_error "WATCH_DIR variable is not set"
    exit 1
fi

# In dry-run mode, remote configuration is not required
if [ "$DRY_RUN" != "true" ]; then
    if [ -z "$RCLONE_REMOTE" ]; then
        log_error "RCLONE_REMOTE variable is not set"
        exit 1
    fi
fi

# Check if watch directory exists
if [ ! -d "$WATCH_DIR" ]; then
    log_error "Watch directory does not exist: $WATCH_DIR"
    exit 1
fi

if ! [[ "$UPLOAD_DELAY" =~ ^(0|[1-9][0-9]*)$ && "$MAX_PARALLEL" =~ ^[1-9][0-9]*$ ]]; then
    log_error "UPLOAD_DELAY must be a nonnegative integer and MAX_PARALLEL a positive integer"
    exit 1
fi

# rclone is configured via RCLONE_CONFIG_* environment variables
# No configuration files required!

# Queue file for failed uploads (stored in /tmp - no persistent logging)
QUEUE_FILE="/tmp/upload_queue.txt"
QUEUE_LOCK="${QUEUE_FILE}.lock"
touch "$QUEUE_FILE"

if [ "$DRY_RUN" = "true" ]; then
    log_warn "DRY-RUN MODE ENABLED - files will NOT be uploaded to cloud"
fi

# Graceful shutdown handler
cleanup() {
    log "Shutting down gracefully, waiting for background jobs..."
    wait
    log "Shutdown complete"
    exit 0
}

trap cleanup SIGTERM SIGINT

# Parallel job control
wait_for_job_slot() {
    # Wait until number of background jobs is less than MAX_PARALLEL
    while [ "$(jobs -r | wc -l)" -ge "$MAX_PARALLEL" ]; do
        sleep 0.5
    done
}

# Function to build remote path with prefix support
build_remote_path() {
    local filepath="$1"
    local relative_path="${filepath#"${WATCH_DIR%/}"/}"
    local destination="${RCLONE_REMOTE:-cloud}"

    # Remove leading slash if exists
    relative_path="${relative_path#/}"

    if [[ "$destination" != *: ]]; then
        destination="${destination%/}/"
    fi
    printf '%s%s%s\n' "$destination" "${S3_PREFIX:+${S3_PREFIX%/}/}" "$relative_path"
}

matches_watch_filters() {
    local relative_path="${1#"${WATCH_DIR%/}"/}"
    relative_path="${relative_path#/}"
    local pattern
    local has_include=false

    for pattern in "${exclude_patterns[@]}"; do
        [[ -n "$pattern" && "$relative_path" == $pattern ]] && return 1
    done

    for pattern in "${include_patterns[@]}"; do
        [[ -n "$pattern" ]] || continue
        has_include=true
        [[ "$relative_path" == $pattern ]] && return 0
    done

    [[ "$has_include" == false ]]
}

# Function to add file to queue (thread-safe with flock)
add_to_queue() {
    local filepath="$1"
    (
        flock -x 200
        if ! grep -qxF "$filepath" "$QUEUE_FILE" 2>/dev/null; then
            echo "$filepath" >>"$QUEUE_FILE"
            log "File added to queue: $(basename "$filepath")"
        fi
    ) 200>"$QUEUE_LOCK"
}

# Function to remove file from queue (thread-safe with flock)
remove_from_queue() {
    local filepath="$1"
    (
        flock -x 200
        local temp_file="${QUEUE_FILE}.tmp"
        grep -vxF "$filepath" "$QUEUE_FILE" >"$temp_file" 2>/dev/null || true
        mv "$temp_file" "$QUEUE_FILE"
    ) 200>"$QUEUE_LOCK"
}

# Function to process queue
process_queue() {
    [ -s "$QUEUE_FILE" ] || return 0

    (
        flock -x 200
        # Read queue line by line
        while IFS= read -r filepath; do
            # Check if file still exists
            if [ -f "$filepath" ]; then
                matches_watch_filters "$filepath" || continue
                upload_file "$filepath"
                local status=$?
                if [[ "$status" == 0 ]]; then
                    # Remove from queue only if upload succeeded
                    local temp_file="${QUEUE_FILE}.tmp"
                    grep -vxF "$filepath" "$QUEUE_FILE" >"$temp_file" 2>/dev/null || true
                    mv "$temp_file" "$QUEUE_FILE"
                    log "File from queue uploaded successfully: $(basename "$filepath")"
                elif [[ "$status" != 9 ]]; then
                    # Stop processing queue if upload failed
                    break
                fi
            else
                # File does not exist, remove from queue silently
                local temp_file="${QUEUE_FILE}.tmp"
                grep -vxF "$filepath" "$QUEUE_FILE" >"$temp_file" 2>/dev/null || true
                mv "$temp_file" "$QUEUE_FILE"
            fi
        done <"$QUEUE_FILE"
    ) 200>"$QUEUE_LOCK"
}

delete_uploaded_file() {
    local filepath="$1" remote_path="$2" source_state="$3"
    local filename="${filepath##*/}"
    local local_hash remote_hash

    [[ -e "$filepath" || -L "$filepath" ]] || return 0
    if [[ -z "$source_state" || "$source_state" != "$(stat -c '%d:%i:%s:%y:%z' -- "$filepath")" ]]; then
        log_warn "Keeping local file because the source changed or could not be checked: $filepath"
    # Require an exact object match even when rclone settings can skip transfers.
    elif ! local_hash=$(sha256sum <"$filepath") ||
        ! remote_hash=$(printf '%s\n' "$filename" | rclone hashsum SHA-256 --download --no-traverse --files-from-raw - "${remote_path%"$filename"}") ||
        [[ "$remote_hash" != "${local_hash%% *}  $filename" ]]; then
        log_warn "Keeping local file because remote contents could not be verified: $filepath"
    elif [[ "$source_state" != "$(stat -c '%d:%i:%s:%y:%z' -- "$filepath")" ]]; then
        log_warn "Keeping local file because the source changed during verification: $filepath"
    elif rm -f -- "$filepath"; then
        log "Deleted local file: $filepath"
    else
        log_warn "Upload succeeded but local deletion failed: $filepath"
    fi
}

# Core upload function (performs actual upload)
upload_file() {
    local filepath="$1"
    local filename=$(basename "$filepath")
    local remote_path=$(build_remote_path "$filepath")

    # DRY-RUN mode - only show what would happen
    if [ "$DRY_RUN" = "true" ]; then
        log_warn "[DRY-RUN] Will be uploaded: $filename -> $remote_path"
        local filesize=$(du -h "$filepath" | cut -f1)
        log_warn "[DRY-RUN] File size: $filesize"
        log_warn "[DRY-RUN] Simulation completed for: $filename"
        return 9
    fi

    local source_state
    local -a copy_flags=()
    if [[ "$DELETE_AFTER_UPLOAD" == true ]]; then
        copy_flags+=(--error-on-no-transfer)
        if [[ -f "$filepath" && ! -L "$filepath" ]]; then
            source_state=$(stat -c '%d:%i:%s:%y:%z' -- "$filepath")
        fi
    fi

    rclone copyto "${copy_flags[@]}" "$filepath" "$remote_path"
    local status=$?
    case "${RCLONE_DRY_RUN:-false}" in
    0 | f | F | false | False | FALSE) ;;
    1 | t | T | true | True | TRUE)
        log_warn "Keeping local file because RCLONE_DRY_RUN is set: $filepath"
        return 9
        ;;
    *)
        log_error "Invalid RCLONE_DRY_RUN value: $RCLONE_DRY_RUN"
        return 1
        ;;
    esac
    [[ "$status" == 0 || "$status" == 9 ]] || return 1
    if [[ "$status" == 9 ]]; then
        log_warn "Keeping local file because rclone transferred nothing: $filepath"
        return 9
    fi

    log "Uploaded successfully: $filename"
    if [[ "$DELETE_AFTER_UPLOAD" == true ]]; then
        delete_uploaded_file "$filepath" "$remote_path" "$source_state"
    fi
    return 0
}

# Main upload handler with queue logic
upload_with_queue() {
    local filepath="$1"

    # Try to upload file
    upload_file "$filepath"
    local status=$?
    if [[ "$status" == 0 ]]; then
        if [ -s "$QUEUE_FILE" ]; then
            remove_from_queue "$filepath"
        fi
        process_queue
    elif [[ "$status" != 9 ]]; then
        # If upload failed, add to queue
        log_error "Upload failed: $(basename "$filepath")"
        add_to_queue "$filepath"
    fi
}

# Check rclone availability (skip in dry-run mode)
if [ "$DRY_RUN" = "true" ]; then
    log_warn "[DRY-RUN] Skipping cloud connection check"
fi

declare -A startup_file_states startup_upload_pids scan_event_states

schedule_upload() {
    local filepath="$1" source="${2:-event}" state
    [[ -f "$filepath" ]] && matches_watch_filters "$filepath" || return 0

    if [[ "$source" == event && -n "${startup_file_states[$filepath]:-}" ]]; then
        state=$(stat -Lc '%d:%i:%s:%y:%z' -- "$filepath" 2>/dev/null)
        [[ "$state" == "${startup_file_states[$filepath]}" ]] && return 0
        # Keep a newer upload from racing the startup upload of the same path.
        wait "${startup_upload_pids[$filepath]}"
        unset 'startup_file_states[$filepath]' 'startup_upload_pids[$filepath]'
    fi

    if [[ "$source" == event && "$UPLOAD_DELAY" -gt 0 ]]; then
        sleep "$UPLOAD_DELAY"
    fi
    wait_for_job_slot
    [[ -f "$filepath" ]] || return 0
    if [[ "$source" == startup ]]; then
        state=$(stat -Lc '%d:%i:%s:%y:%z' -- "$filepath" 2>/dev/null)
        [[ -n "$state" && "$state" == "${scan_event_states[$filepath]:-}" ]] && return 0
        startup_file_states[$filepath]="$state"
    elif [[ -n "${scan_fd:-}" ]]; then
        scan_event_states[$filepath]=$(stat -Lc '%d:%i:%s:%y:%z' -- "$filepath" 2>/dev/null)
    fi
    upload_with_queue "$filepath" &
    if [[ "$source" == startup ]]; then
        startup_upload_pids[$filepath]=$!
    fi
}

scan_existing_files() {
    local filepath
    find "${WATCH_DIR%/}/" -type f -print0 |
        while IFS= read -r -d '' filepath; do
            [[ "$filepath" != *$'\n'* ]] && matches_watch_filters "$filepath" || continue
            if [[ "$UPLOAD_DELAY" -gt 0 ]]; then
                sleep "$UPLOAD_DELAY"
            fi
            printf '%s\0' "$filepath"
        done
}

# Read watch events while the scan enumerates and delays existing files independently.
LC_ALL=C inotifywait -m -r -e close_write,moved_to --exclude $'\n' --format 'file:%w%f' "$WATCH_DIR" 2>&1 |
    while :; do
        if [[ -z "${scan_fd:-}" ]] || IFS= read -r -t 0; then
            IFS= read -r line || break
            case "$line" in
            'Watches established.')
                printf '%s\n' "$line" >&2
                if [[ "$UPLOAD_EXISTING_FILES" == true ]]; then
                    exec {scan_fd}< <(scan_existing_files)
                    scan_pid=$!
                fi
                ;;
            file:*) schedule_upload "${line#file:}" ;;
            *) printf '%s\n' "$line" >&2 ;;
            esac
        fi

        if [[ -n "${scan_fd:-}" ]]; then
            if IFS= read -r -t 0 -u "$scan_fd" && [[ "$(jobs -r | wc -l)" -lt "$MAX_PARALLEL" ]]; then
                if IFS= read -r -d '' -u "$scan_fd" filepath; then
                    schedule_upload "$filepath" startup
                else
                    exec {scan_fd}<&-
                    unset scan_fd
                    scan_event_states=()
                    wait "$scan_pid" || log_error "Startup scan failed for $WATCH_DIR"
                fi
            elif ! IFS= read -r -t 0; then
                sleep 0.05
            fi
        fi
    done
