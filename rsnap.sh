#!/bin/zsh
# Time Machine–style backup script for macOS using rsync + hard links

# ====== Parse flags ======
while getopts s:d: flag; do
    case "${flag}" in
        s) SOURCE=${OPTARG};;
        d) DESTINATION=${OPTARG};;
        *) 
           echo "Usage: $0 -s <source_path> -d <destination_root>"
           exit 1
           ;;
    esac
done

if [[ -z "$SOURCE" || -z "$DESTINATION" ]]; then
    echo "Error: both -s (source) and -d (destination) must be provided."
    echo "Usage: $0 -s <source_path> -d <destination_root>"
    exit 1
fi

if [[ ! -d "$SOURCE" ]]; then
  echo "Error: source directory '$SOURCE' does not exist."
  exit 1
fi
if [[ ! -d "$DESTINATION" ]]; then
  echo "Error: destination directory '$DESTINATION' does not exist."
  exit 1
fi

# SOURCE="$HOME/Documents"
# DEST_ROOT="/Volumes/BackupDrive/DocumentsSnapshots"   # root of all snapshots
DEST_ROOT="$DESTINATION/Backups.rsnap"  # root of all snapshots

LOGFILE="$HOME/backups.rsnap.log"
DATE=$(date +"%Y-%m-%d_%H-%M-%S")
# The new backup directory
DEST="$DEST_ROOT/$DATE"

# Count how many snapshots exist alreadymore .
# SNAP_COUNT=$(ls -1 "$DEST_ROOT" 2>/dev/null | wc -l | tr -d ' ')
SNAP_COUNT=$(find "$DEST_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')

# Every 7th snapshot -> full copy (no link-dest)
if (( (SNAP_COUNT + 1) % 7 == 0 )); then
  LINKDEST=""
  echo "Forcing full copy (snapshot #$((SNAP_COUNT+1)))" >> "$LOGFILE"
else
  # Find the latest backup (if any) to use with --link-dest
  LAST_BACKUP=$(ls -1t "$DEST_ROOT" 2>/dev/null | head -n 1)
  if [[ -n "$LAST_BACKUP" && -d "$DEST_ROOT/$LAST_BACKUP" ]]; then
    LINKDEST="--link-dest=$DEST_ROOT/$LAST_BACKUP"
    echo "Using previous snapshot as link-dest: $DEST_ROOT/$LAST_BACKUP" >> "$LOGFILE"
  else
    LINKDEST=""
    echo "No previous snapshot found, doing full copy" >> "$LOGFILE"  
  fi
fi

# rsync options
# -a = archive (preserves perms, symlinks, timestamps, etc.)
# -h = human-readable
# -v = verbose
# --delete = remove files in DEST that no longer exist in SOURCE
# --progress = show progress
OPTIONS="-ahv --progress --delete --exclude='.DS_Store'"

echo "=== Backup started at $(date) ===" >> "$LOGFILE"


# Create new destination
mkdir -p "$DEST"

# Run rsync with optional link-dest
CMD="rsync $OPTIONS $LINKDEST \"$SOURCE/\" \"$DEST/\""

echo "Running command: $CMD" >> "$LOGFILE"

eval $CMD >> "$LOGFILE" 2>&1 &
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
  echo "Backup completed successfully at $(date) into $DEST" >> "$LOGFILE"

  # === PRUNE OLD SNAPSHOTS ===
  cd "$DEST_ROOT"
  ls -1t | tail -n +8 | xargs -I {} rm -rf "{}"
  echo "Pruned old backups, kept latest 7" >> "$LOGFILE"
else
  echo "Backup failed with exit code $RSYNC_EXIT at $(date)" >> "$LOGFILE"
fi