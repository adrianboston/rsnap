#!/bin/zsh
# Time Machine–style backup script for macOS using rsync + hard links

# path to rsync binary (3.4.1 version recommended)
RSYNC=/opt/local/bin/rsync
TAIL=/usr/bin/tail
AWK=/usr/bin/awk
DF=/bin/df

# macOS system and metadata files to exclude from backups
EXCLUDES=(
".DS_Store"
".AppleDouble"
".AppleDB"
".AppleDesktop"
".Spotlight-V100"
".Trash"
".Trashes"
".TemporaryItems"
".fseventsd"
".com.apple.timemachine.donotpresent"
".DocumentRevisions-V100"
".PKInstallSandboxManager"
".PKInstallSandboxManager-SystemSoftware"
".VolumeIcon.icns"
".quarantine"
"*.swp"
"*.lock"
"*.sock"
"*/SingletonSocket"  # socket files
)

OS=$(uname)
#echo "Running on OS: $OS"


get_device_id() {
    local path="$1"

    if [[ ! -d "$path" && ! -f "$path" ]]; then
        echo "unknown"
        return
    fi

    # Use df -P (POSIX format) to reliably get the filesystem info
    # Extract the device/volume name
    local dev
    dev=$($DF -P "$path" 2>/dev/null | $TAIL -1 | $AWK '{print $1}')
    if [[ -n "$dev" ]]; then
        echo "$dev"
    else
        echo "unknown"
    fi    
}

# Function to get the most recent backup directory in DEST_ROOT
get_last_backup() {
    local dest_root="$1"
    local last_backup=""

    if [[ ! -d "$dest_root" ]]; then
        echo ""
        return
    fi

    local last_backup=""
    if [[ $OS == "Darwin" ]]; then
        # macOS
        last_backup=$(find "$dest_root" -mindepth 1 -maxdepth 1 -type d \
                      -exec stat -f '%m %N' {} + 2>/dev/null \
                      | sort -nr | head -n 1 | awk '{print $2}')
    else
        # Linux (GNU find supports -printf)
        last_backup=$(find "$dest_root" -mindepth 1 -maxdepth 1 -type d \
                      -printf '%T@ %p\n' 2>/dev/null \
                      | sort -nr | head -n 1 | awk '{print $2}')
    fi    

    echo "$last_backup"
}

# Helper for logging
log() {
    if [[ $QUIET -eq 0 ]]; then
        echo "$@"
    fi
}

err() {
    echo "$@" >&2
}



# Build the --exclude parameters for rsync
EXCLUDE_ARGS=()
for e in "${EXCLUDES[@]}"; do
    EXCLUDE_ARGS+=(--exclude="$e")
done

# Raise file descriptor limit for this script run
# ulimit -n 65536

SOURCE=""  # source folder to back up
DESTINATION=""  # root folder where snapshots are stored

FORCE_FULL=0
DRY_RUN=0  # Set to true for testing without actual file changes
EXTRA_EXCLUDE=""  # user-supplied extra exclude folder/file

VAULT_NAME=$(hostname)  # default prefix or vault name for snapshot folders
DEST_FS_TYPE=""  # filesystem type of destination (apfs, hfs, unix, fat, ntfs)
SAFECOPY=0  # safe mode, do not follow symlinks
ALLOW_SAME_VOLUME=0  # allow source and destination on same volume (largely for testing)
NICE_LEVEL_STRING="normal"  # idle | normal | fast
NICE_LEVEL=10  # set a nice level for rsync process (lower = higher priority)
BWLIMIT=0     # 0 means unlimited bandwidth for rsync (in KB/s)
IONICE_CLASS="2"  # normal I/O priority (Linux only, ignored on macOS)
SNAP_COUNT=0
QUIET=0  # quiet mode, minimal output

# ====== Parse flags ======
while getopts s:d:v:e:f:SFAtq flag; do
    case "${flag}" in
        s) SOURCE=${OPTARG};; # source folder to back up
        d) DESTINATION=${OPTARG};;  # root folder where snapshots are stored
        v) VAULT_NAME=${OPTARG};;  # prefix for snapshot folders       
        e) EXTRA_EXCLUDE=${OPTARG};; # user-supplied folder/file to exclude
        f) DEST_FS_TYPE=${OPTARG};;   # filesystem type
        S) SAFECOPY=1;;  # safe mode, do not follow symlinks
        F) FORCE_FULL=1;;  # force full backup, ignore link-dest
        A) ALLOW_SAME_VOLUME=1;;  # allow source and destination on same volume (largely for testing)
        n) NICE_LEVEL_STRING=${OPTARG};;  # set nice level for rsync process
        t) DRY_RUN=1;;  # test mode, do not execute rsync
        q) QUIET=1;;  # quiet mode, minimal output
        *) 
           echo "Usage: $0 -s <source_path> -d <destination_root> -m <vault_name> [-e <excludes>] [-F <apfs|hfs|unix|fat|ntfs>] [-F] [-S] [-t]"
           exit 1
           ;;
    esac
done

if [[ -z "$SOURCE" || -z "$DESTINATION" ]]; then
    err "Error: both -s (source) and -d (destination) must be provided."
    err "Usage: $0 -s <source_path> -d <destination_root>"
    exit 1
fi

if [[ ! -d "$SOURCE" ]]; then
  err "Error: source directory '$SOURCE' does not exist."
  exit 1
fi
if [[ ! -d "$DESTINATION" ]]; then
  err "Error: destination directory '$DESTINATION' does not exist."
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
# WARNING: The following sanitization removes all characters except alphanumeric, underscore, and dash.
# This may alter the hostname and affect backup folder naming if your hostname contains other characters.
VAULT_NAME=$(echo "$VAULT_NAME" | tr -cd '[:alnum:]_-')  # sanitize prefix
DEST_ROOT="$DESTINATION/Backups.rsnap/$VAULT_NAME"

# Get current date/time for snapshot naming
DATE=$(date +"%Y-%m-%d_%H-%M-%S")


# Ensure DEST_ROOT exists, but only if not in dry-run mode
if [[ $DRY_RUN -ne 1 ]]; then
    mkdir -p "$DEST_ROOT"
fi


# Count how many snapshot directories exist already
SNAP_COUNT=$(find "$DEST_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)

log "SNAP_COUNT: $SNAP_COUNT"

# Determine if this should be a full or incremental backup
# if [[ "$FORCE_FULL" -eq 1 || $((SNAP_COUNT + 1)) % 7 -eq 0 ]]; then
if (( FORCE_FULL == 1 || SNAP_COUNT == 0  || (SNAP_COUNT + 1) % 7 == 0 )); then
    SNAPSHOT_NAME="${DATE}_full"
    LINKDEST=""
    log "Forcing full copy (snapshot #$((SNAP_COUNT+1)))"
else
    # Find the most recent backup directory
    LAST_BACKUP=$(get_last_backup "$DEST_ROOT")

    #echo LAST_BACKUP: "$LAST_BACKUP"

    if [[ -n "$LAST_BACKUP" && -d "$LAST_BACKUP" ]]; then
        SNAPSHOT_NAME="${DATE}_inc"
        LINKDEST="--link-dest=$DEST_ROOT/$LAST_BACKUP"
        log "Using previous snapshot as link-dest: $DEST_ROOT/$LAST_BACKUP"
    else
        SNAPSHOT_NAME="${DATE}_full"
        LINKDEST=""
        log "No previous snapshot found, doing full copy"
    fi
fi

DEST="$DEST_ROOT/$SNAPSHOT_NAME"

# rsync options
OPTIONS=(
    -ahv           # archive  (preserves perms, symlinks, timestamps, etc.)+ human-readable + verbose
    --progress     # show progress
    --delete       # remove files in DEST that no longer exist in SOURCE
    --stats        # give some file transfer stats
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
    log "Unknown FS type '$FS_TYPE', defaulting to unix-safe mode"
    OPTIONS+=(--no-xattrs)
    ;;
esac

if [[ $SAFECOPY -eq 1 ]]; then
    OPTIONS+=(--no-links)
    log "Safe mode enabled: skipping symlink targets."
fi




# Input: NICE_LEVEL_STRING = idle | normal | fast
# Output: NICE_LEVEL (int)

case "$NICE_LEVEL_STRING" in
  idle)
    NICE_LEVEL=19   # very low priority
    BWLIMIT=1000  # limit to 1 MB/s (max 2000 KB/s for rsync)
#    OPTIONS+=(--bwlimit=$BWLIMIT)
    IONICE_CLASS="3"  # idle I/O priority (Linux only, ignored on macOS)
    ;;
  normal)
    NICE_LEVEL=0    # default
    BWLIMIT=0      # unlimited bandwidth
    IONICE_CLASS="2"  # normal I/O priority (Linux only, ignored on macOS)
    ;;
  fast)
    NICE_LEVEL=-5   # higher priority, but not too aggressive
    BWLIMIT=0      # unlimited bandwidth
    IONICE_CLASS="1"  # best-effort I/O priority (Linux only, ignored on macOS) 
    ;;
  *)
    echo "Unknown NICE_LEVEL_STRING: $NICE_LEVEL_STRING" >&2
    NICE_LEVEL=0
    BWLIMIT=0
    IONICE_CLASS="2"  # normal I/O priority (Linux only, ignored on macOS)
    ;;
esac


# Optionally append a single extra exclude
if [[ -n "$EXTRA_EXCLUDE" ]]; then
  EXCLUDE_ARGS+=( --exclude="$EXTRA_EXCLUDE" )
fi


log "=== Backup started at $(date) ==="


# Run rsync with optional link-dest
# Then call rsync with the array (safe for spaces, special characters)
RSYNC_CMD=(nice -n "$NICE_LEVEL" "$RSYNC" "${OPTIONS[@]}" "${EXCLUDE_ARGS[@]}" ${LINKDEST:+$LINKDEST} "$SOURCE/" "$DEST/" )

log "Running command: ${RSYNC_CMD[@]}"

# If DRY_RUN is set, just print the command instead of executing it
if [ $DRY_RUN -eq 1 ]; then
  echo "DRY RUN. Backup would have been created at $DEST"
  exit 0
fi


# Execute the command in the background
"${RSYNC_CMD[@]}" &
RSYNC_PID=$!


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

if [ $RSYNC_EXIT -eq 0 ]; then
  log "Backup completed successfully at $(date) into $DEST"

  # === PRUNE OLD SNAPSHOTS ===
  cd "$DEST_ROOT"
  ls -1t | tail -n +8 | while read -r dir; do
    [ -d "$dir" ] && rm -rf "$dir"
  done
  log "Pruned old backups, kept latest 7"
else
  err "Backup failed with exit code $RSYNC_EXIT at $(date)"
fi