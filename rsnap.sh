#!/bin/bash
# Time Machine–style backup script for macOS using rsync + hard links

# path to rsync binary (3.4.1 version recommended)
RSYNC=/opt/local/bin/rsync
TAIL=/usr/bin/tail
AWK=/usr/bin/awk
DF=/bin/df
MKDIR=/bin/mkdir
TOUCH=/usr/bin/touch

# -----------------------------------
# Function: get device/volume ID for a given path
# -----------------------------------
get_device_id() {
    local path="$1"

    if [[ ! -d "$path" && ! -f "$path" ]]; then
        log "unknown"
        return
    fi

    # Use df -P (POSIX format) to reliably get the filesystem info
    # Extract the device/volume name
    local dev
    dev=$($DF -P "$path" 2>/dev/null | $TAIL -1 | $AWK '{print $1}')
    if [[ -n "$dev" ]]; then
        log "$dev"
    else
        log "unknown"
    fi    
}

# -------------------------
# Function: prune old nested rsnap backups
# -------------------------
prune_snapshots() {
    local dest_root="$1"
    local keep_count="$2"
    local dry_run="${3:-0}"

    # Check destination exists
    if [[ ! -d "$dest_root" ]]; then
        log "Backup directory does not exist: $dest_root"
        return
    fi

     # --- Step 1: Collect all backup set directories ---
    local backups=()
    for dir in "$dest_root"/*/; do
        [[ -d "$dir" ]] || continue
        backups+=("$dir")
    done

    local total=${#backups[@]}

    if (( total <= keep_count )); then
        return
    fi

    local to_delete=$(( total - keep_count ))

    # Nothing to prune
    if (( to_delete <= 0 )); then
        return
    fi

    # Sort lexicographically (oldest first)
    IFS=$'\n' backups=($(printf "%s\n" "${backups[@]}" | sort))
    unset IFS    

    # --- Step 2: Check newest set for at least one complete backup ---
    #local newest_set="${sets[-1]}"  # Bash-compatible: last element
    # Bash doesn't support negative index, so use:
    local newest_set="${backups[$(( ${#backups[@]} - 1 ))]}"

    local valid_found=0
    for backup in "$newest_set"/*/; do
        [[ -d "$backup" ]] || continue
        [[ "$backup" == *"_partial/" ]] && continue
        valid_found=1
        break
    done

    if (( valid_found == 0 )); then
        log "Newest backup set '$newest_set' contains no complete backups. Skipping pruning."
        return
    fi

    # --- Step 3: Determine how many old sets to prune ---
    for (( i=0; i<to_delete; i++ )); do
        [[ -n "${backups[i]}" ]] || continue  # safety check

        if (( dry_run )); then
            log "[DRY RUN] Would delete: ${backups[i]}"
        else
            rm -rf "${backups[i]}"
            log "Deleted: ${backups[i]}"
        fi
    done
}


# -----------------------------------
# Function: decide FULL vs INC backup
# -----------------------------------
last_full_snapshot() {
    local dest_root="$1"
    local full_every="${2:-7}"

    # Get newest folder
    local full_dirs=($(find "$dest_root" -mindepth 1 -maxdepth 1 -type d \
                       ! -name '*_partial' | sort))

    if (( ${#full_dirs[@]} == 0 )); then
        log "NONE"
        return
    fi

    # log "${full_dirs[-1]}"  # newest folder
    # Get last element (newest folder)
    log "${full_dirs[$((${#full_dirs[@]} - 1))]}"    
}

# -----------------------------------
# Function: Logging and usage
# -----------------------------------
log() {
    if [[ $QUIET -eq 0 ]]; then
        echo "$@"
    fi
}

# -----------------------------------
# Function: error output
# -----------------------------------
err() {
    echo "$@" >&2
}

# -----------------------------------
# Function: usage/help message
# -----------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") -s <source_path> -d <destination_root> -v <vault_name> [options]

Options:
-s <path>       Source folder to back up
-d <path>       Destination root where snapshots are stored
-v <name>       Vault name (prefix for snapshot folders)
-e <file>       Exclude file list (passed to rsync --exclude-from)
-f <fstype>     Destination filesystem type (apfs|hfs|unix|fat|ntfs)
-n <level>      Nice level (idle|normal|fast)
-S              Safe mode: do not follow symlinks
-F              Force full backup (ignore link-dest)
-A              Allow source and destination on the same volume
-P              Prune only: remove old backups, do not create new ones
-p              Prune old backups after creating new snapshot
-q              Quiet mode: minimal output
-t              Test mode (dry run, no rsync execution)
-h              Show this help message and exit
EOF
}

# Raise file descriptor limit for this script run
# ulimit -n 65536
KEEP_COUNT=3
FULL_EVERY=7      # make a true full every X runs

SOURCE=""           # source folder to back up
DESTINATION=""      # root folder where snapshots are stored

FORCE_FULL=0
DRY_RUN=0           # Set to true for testing without actual file changes
EXCLUDES=""         # user-supplied extra exclude folder/file

VAULT_NAME=$(hostname)  # default prefix or vault name for snapshot folders
DEST_FS_TYPE=""     # filesystem type of destination (apfs, hfs, unix, fat, ntfs)
SAFECOPY=0          # safe mode, do not follow symlinks
ALLOW_SAME_VOLUME=0  # allow source and destination on same volume (largely for testing)
NICE_LEVEL_STRING="normal"  # idle | normal | fast
NICE_LEVEL=10       # set a nice level for rsync process (lower = higher priority)
BWLIMIT=0           # 0 means unlimited bandwidth for rsync (in KB/s)
IONICE_CLASS="2"    # normal I/O priority (Linux only, ignored on macOS)
SNAP_COUNT=0
PRUNE_ONLY=0
PRUNE_AFTER=0
QUIET=0             # quiet mode, minimal output

# ====== Parse flags ======
while getopts s:d:v:e:f:n:SFAPptqh flag; do
    case "${flag}" in
        s) SOURCE=${OPTARG};; # source folder to back up
        d) DESTINATION=${OPTARG};;  # root folder where snapshots are stored
        v) VAULT_NAME=${OPTARG};;  # prefix for snapshot folders       
        e) EXCLUDES=${OPTARG};; # user-supplied folder/file to exclude
        f) DEST_FS_TYPE=${OPTARG};;   # filesystem type
        n) NICE_LEVEL_STRING=${OPTARG};;  # set nice level for rsync process
        S) SAFECOPY=1;;  # safe mode, do not follow symlinks
        F) FORCE_FULL=1;;  # force full backup, ignore link-dest
        A) ALLOW_SAME_VOLUME=1;;  # allow source and destination on same volume (largely for testing)
        P) PRUNE_ONLY=1;;  # only prune old backups, do not create new one
        p) PRUNE_AFTER=1;; #prune after the snapshot 
        q) QUIET=1;;  # quiet mode, minimal output
        t) DRY_RUN=1;;  # test mode, do not execute rsync
        h) usage; exit 0;;
        *) usage; exit 1;;  # unknown flag
    esac
done

# ====== End of flag parsing ======


if [[ ! -d "$DESTINATION" ]]; then
  err "Error: destination directory '$DESTINATION' does not exist."
  exit 1
fi
if [[ -z "$VAULT_NAME" ]]; then
  err "Error: vault name '$VAULT_NAME' is not set."
  exit 1
fi

# WARNING: The following sanitization removes all characters except alphanumeric, underscore, and dash.
# This is to avoid issues with filesystem naming and ensure backup folder consistency; 
# note that this may alter the hostname and affect backup folder naming if your hostname contains other characters.
VAULT_NAME=$(echo "$VAULT_NAME" | tr -cd '[:alnum:]_-')  # sanitize prefix

DEST_ROOT="$DESTINATION/Backups.rsnap/$VAULT_NAME"

if [[ $PRUNE_ONLY -eq 1 ]]; then
    if [[ -z "$DEST_ROOT" && -z "$VAULT_NAME" ]]; then
        err "Error: -d (destination) and -v (vault_name) must be provided in prune-only mode."
        exit 1
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        log "Pruning old backups in $DEST_ROOT, keeping last $KEEP_COUNT full backups..."
        log "Running in DRY RUN mode. No changes will be made."
        exit 0
    fi
    log "Pruning old backups in $DEST_ROOT, keeping last $KEEP_COUNT full backups..."
    prune_snapshots "$DEST_ROOT" "$KEEP_COUNT" $DRY_RUN
    log "Prune-only mode completed."
    exit 0
fi  

if [[ ! -d "$SOURCE" ]]; then
  err "Error: source directory '$SOURCE' does not exist."
  exit 1
fi

src_dev=$(get_device_id "$SOURCE")
dest_dev=$(get_device_id "$DESTINATION")

# Check if source and destination are on the same filesystem
# Allow if ALLOW_SAME_VOLUME is set (for testing)
if [ "$src_dev" = "$dest_dev" ] && [ "$ALLOW_SAME_VOLUME" -eq 0 ]; then
    err "Error: Source and destination are on the same filesystem ($src_dev)."
    exit 1
fi

# Get current date/time for snapshot naming
DATE=$(date +"%Y-%m-%d_%H-%M-%S")

# Ensure DEST_ROOT exists, but only if not in dry-run mode
if [[ $DRY_RUN -ne 1 ]]; then
  log "Ensuring destination root exists: $DEST_ROOT"
  MKDIR -p "$DEST_ROOT"
fi

LAST_FULL=$(last_full_snapshot "$DEST_ROOT" "$FULL_EVERY")

LINKDEST=""
SNAPSHOT_NAME=""
log "Last_full_snapshot: $LAST_FULL"

# THere is NO last full at all. Likely a new backup area
if [[ $FORCE_FULL -eq 1 || "$LAST_FULL" == "NONE" ]]; then
    # No full exists → must create one
    ts=$(date +"%Y-%m-%d-%H%M%S")
    new_dir="$DEST_ROOT/${ts}/${ts}_partial"
    if (( DRY_RUN )); then
        echo "[DRY RUN] Creating FULL -> $new_dir"
    else
        MKDIR -p "$new_dir"
        log "Created FULL -> $new_dir"
    fi
    LINKDEST=""
    SNAPSHOT_NAME="$new_dir"
else

    inc_count=$(find "$LAST_FULL" -mindepth 1 -maxdepth 1 -type d \
                ! -name '*_partial' | wc -l)

    log "Incrementals (not _partials) in last full: $inc_count (full every $FULL_EVERY)"

    # Either forced full, or no incrementals yet
    if [ "$inc_count" -ge "$FULL_EVERY" ] || [ "$FORCE_FULL" -eq 1 ]; then        # Too many incrementals → new full
        ts=$(date +"%Y-%m-%d-%H%M%S")
        new_dir="$DEST_ROOT/${ts}/${ts}_partial"
        if (( DRY_RUN )); then
            echo "[DRY RUN] Creating FULL in new directory -> $new_dir"
        else
            MKDIR -p "$new_dir"
            log "Created FULL -> $new_dir"
        fi
        LINKDEST=""
        SNAPSHOT_NAME="$new_dir"
    else
        # Make incremental inside last full
        ts=$(date +"%Y-%m-%d-%H%M%S")
        new_dir="$LAST_FULL/${ts}_partial"
        # Find the newest snapshot inside last full to use as link-dest
        newest=$(find "$LAST_FULL" -mindepth 1 -maxdepth 1 -type d ! -name '*_partial' | sort | $TAIL -n1)

        log "Creating INC -> $new_dir (link-dest: $newest)"

        if [[ -n "$newest" && -d "$newest" ]]; then
            if (( DRY_RUN )); then
                echo "[DRY RUN] Creating INC -> $new_dir (link-dest: $newest)"
            else
                MKDIR -p "$new_dir"
                rsync $RSYNC_OPTS --link-dest="$newest" "$SRC/" "$new_dir/"
                log "Created INC -> $new_dir"
            fi
            LINKDEST="--link-dest=$newest"
            SNAPSHOT_NAME="$new_dir"
        else
            if (( DRY_RUN )); then
                echo "[DRY RUN] Creating FULL -> $new_dir"
            else
                MKDIR -p "$new_dir"
                log "Created FULL -> $new_dir"
            fi
            LINKDEST=""
            SNAPSHOT_NAME="$new_dir"
        fi
    fi
fi

# -----------------------------------
# Final destination path for rsync
# -----------------------------------

DEST="$SNAPSHOT_NAME"
log "Final destination directory: $DEST"

# rsync options
OPTIONS=(
    -ahv           # archive  (preserves perms, symlinks, timestamps, etc.)+ human-readable + verbose
    --progress     # show progress
    --delete       # remove files in DEST that no longer exist in SOURCE
    --stats        # give some file transfer stats
    --human-readable # human-readable numbers in stats
)

# Add quiet option if requested
if [[ $QUIET -eq 1 ]]; then
    OPTIONS+=(--quiet)
fi

case "$DEST_FS_TYPE" in
  apfs)
    OPTIONS+=(--xattrs --crtimes --protect-args)   # APFS supports full metadata
    ;;
  hfs)
    OPTIONS+=(--xattrs --crtimes)  # HFS+ supports xattrs, but not symlinks on non-UNIX volumes
    ;;
  unix)
    OPTIONS+=(--no-xattrs)  # generic unix fs, no xattrs, no compression
    ;;
  fat|ntfs)
    OPTIONS+=(--no-xattrs)  # Windows filesystems, no xattrs, no symlinks
    ;;
  *)
    log "Unknown FS type '$DEST_FS_TYPE', defaulting to unix-safe mode"
    OPTIONS+=(--no-xattrs)
    ;;
esac

if [[ $SAFECOPY -eq 1 ]]; then
    OPTIONS+=(--no-links)
    log "Safe mode enabled: skipping symlink targets."
fi


case "$NICE_LEVEL_STRING" in
  idle)
    NICE_LEVEL=19   # very low priority
    BWLIMIT=20000  # limit to 20 MB/s (max 20000 KB/s for rsync)
    IONICE_CLASS="3"  # idle I/O priority (Linux only, ignored on macOS)
    ;;
  normal)
    NICE_LEVEL=0    # default
    BWLIMIT=50000      # limit to 50 MB/s (max 50000 KB/s for rsync)
    IONICE_CLASS="2"  # normal I/O priority (Linux only, ignored on macOS)
    ;;
  fast)
    NICE_LEVEL=-5   # higher priority, but not too aggressive
    BWLIMIT=100000      # unlimited bandwidth
    IONICE_CLASS="1"  # best-effort I/O priority (Linux only, ignored on macOS) 
    ;;
  *)
    log "Unknown NICE_LEVEL_STRING: $NICE_LEVEL_STRING" >&2
    NICE_LEVEL=10
    BWLIMIT=30000  # limit to 30 MB/s (max 30000 KB/s for rsync)
    IONICE_CLASS="2"  # normal I/O priority (Linux only, ignored on macOS)
    ;;
esac

if [[ "$BWLIMIT" -gt 0 ]]; then
    OPTIONS+=(--bwlimit=$BWLIMIT)
fi

# Optionally append a single extra exclude
if [[ -n "$EXCLUDES" && -f "$EXCLUDES" ]]; then
    OPTIONS+=("--exclude-from=$EXCLUDES")
fi

log "====== Backup started at $(date) ======"

# Run rsync with optional link-dest
# Then call rsync with the array (safe for spaces, special characters)
RSYNC_CMD=(nice -n "$NICE_LEVEL" "$RSYNC" "${OPTIONS[@]}")

if [[ -n "$LINKDEST" ]]; then
  RSYNC_CMD+=("$LINKDEST")
fi
RSYNC_CMD+=("$SOURCE/" "$DEST/")

log "Running command: ${RSYNC_CMD[@]}"

# If DRY_RUN is set, just print the command instead of executing it
if [ $DRY_RUN -eq 1 ]; then
  echo "DRY RUN. Backup would have been created at $DEST"
  exit 0
fi

# TMP_LOGFILE="$SNAPSHOT_NAME/rsync-stats-$$.log"
TMP_LOGFILE="/tmp/rsync-stats-$$.log"

log "Temporary rsync log will be at $TMP_LOGFILE"

MKDIR -p "$SNAPSHOT_NAME"

# mkdir -p "$(dirname "$TMP_LOGFILE")"
# $TOUCH "$TMP_LOGFILE"

log "=== Backup started at $(date) ===" > "$TMP_LOGFILE"

# Execute the command in the background
# Then apply redirection at execution time
if [[ -n "$TMP_LOGFILE" ]]; then
#   MKDIR -p "$(dirname "$TMP_LOGFILE")"
  log "Logging rsync output to $TMP_LOGFILE"

  log "2. Test log entry at $(date)" >> "$TMP_LOGFILE"

  "${RSYNC_CMD[@]}" >> "$TMP_LOGFILE" 2>&1 &
else
  "${RSYNC_CMD[@]}" &
fi

RSYNC_PID=$!

# Wait a moment to ensure rsync has started and the log file is created
sleep 1

# Spinner (only if interactive)
if [ -t 1 ]; then
  spinner() {
    local spin='-\|/'
    local i=0
    while kill -0 $RSYNC_PID 2>/dev/null; do
      i=$(( (i+1) %4 ))
      printf "\r[%c] Running backup..." "${spin:$i:1}"
      sleep 0.2
    done
    printf "\rDone!                           \n"
  }
  spinner
fi

# Always wait for rsync to finish
wait $RSYNC_PID
RSYNC_EXIT=$?

log "=== Backup finished at $(date) ===" >> "$TMP_LOGFILE"
log "Rsync exit code: $RSYNC_EXIT" >> "$TMP_LOGFILE"

# -----------------------------------
# Clean up temporary log file and handle rsync exit status
# -----------------------------------
if [[ $RSYNC_EXIT -eq 0 ]]; then
  log "====== Backup completed succesfully at $(date) ======"

    # Rename the snapshot to remove the _partial suffix
    if [[ -d "$SNAPSHOT_NAME" ]] && [[ "$SNAPSHOT_NAME" == *_partial ]]; then
        log "Renaming snapshot..."
        FINAL_DIR="${SNAPSHOT_NAME%_partial}"
        mv "$SNAPSHOT_NAME" "$FINAL_DIR"
        log "Snapshot completed: $FINAL_DIR"
    else
        log "Snapshot completed but using _partial name: $SNAPSHOT_NAME"
    fi

    if [[ -n "$TMP_LOGFILE" && -f "$TMP_LOGFILE" ]]; then
        mv "$TMP_LOGFILE" "$FINAL_DIR/rsync-log.txt"
    fi

    # ===== Prune old backups =====
    if [[ "$PRUNE_AFTER" -eq 1 ]]; then
        log "Pruning old backups after snapshot, keeping last $KEEP_COUNT full backups..."
        prune_snapshots "$DEST_ROOT" "$KEEP_COUNT" "$DRY_RUN"  # keep last 3 snapshots
    fi

    log "====== Backup finished at $(date) ======"
    exit 0

else
  err "Backup failed with exit code $RSYNC_EXIT at $(date)"
  err "Incomplete snapshot kept at $DEST"
fi

  # Clean up temporary log file
  if [[ -n "$TMP_LOGFILE" && -f "$TMP_LOGFILE" ]]; then
    rm -f "$TMP_LOGFILE"
  fi

  exit $RSYNC_EXIT

# ----------------------------------- End of script
# -----------------------------------

