# rsnap (rsync-based Time Machine–style backups)

`rsnap` is a lightweight macOS backup utility written in shell script.  
It uses `rsync` and hard links to create efficient, incremental, snapshot-based backups — similar in spirit to Time Machine, but simpler and fully transparent. Hardlinks allow you to restore previous versions with minimal disk usage. A full backup will be done every 7 backups.

---

## ✨ Features

- **Incremental backups** – unchanged files are hard-linked, saving space.
- **Full backup every 7th run** – ensures chain integrity and recovery safety.
- **Automatic snapshot pruning** – keeps only the last 7 snapshots.
- **Human-readable snapshot folders** – each backup lives in a timestamped directory.
- **Logging** – activity and errors are logged to `~/backups.rsync.log`.
- **Portable** – no dependencies other than `rsync` (ships with macOS).

---

## ⚙️ How It Works

rsnap uses `rsync` to copy files from your source directory to a backup location.  
For each backup, unchanged files are hard-linked to previous snapshots, saving space and speeding up the process. Only new or changed files are copied.

---

## 📋 Requirements

- macOS (tested on recent versions) or Linux  
- `rsync` installed (default on macOS)  
- Sufficient permissions to read source and write to backup location  

---

## 🚀 Usage

### Run manually

    ./rsnap.sh -s <source_path> -d <destination_root>

Example:

    ./rsnap.sh -s $HOME/Documents -d /Volumes/BackupDrive

Backups are created in:

    /Volumes/BackupDrive/Backups.rsync/<timestamp>/


### Clone / Download  
Save the script somewhere in your path, e.g.:

    git clone https://github.com/yourusername/rsnap.git
    cd rsnap
    chmod +x rsnap.sh


### Scheduling with launchd  
This section explains how to run rsnap automatically on macOS.

**Step 1 — Copy the plist**

    mkdir -p ~/Library/LaunchAgents
    cp com.user.rsnap.plist ~/Library/LaunchAgents/com.user.rsnap.plist

**Step 2 — Load the agent**

    launchctl load ~/Library/LaunchAgents/com.user.rsnap.plist

Verify it’s loaded:

    launchctl list | grep com.user.rsnap

**Step 3 — Run on demand**

    launchctl start com.user.rsnap

**Step 4 — Check logs**

    tail -f ~/rsnap.stdout.log
    tail -f ~/rsnap.stderr.log

**Step 5 — Update settings**  
If you edit the plist:

    launchctl unload ~/Library/LaunchAgents/com.user.rsnap.plist
    launchctl load  ~/Library/LaunchAgents/com.user.rsnap.plist

**Step 6 — Disable or remove**

Disable without deleting:

    launchctl unload ~/Library/LaunchAgents/com.user.rsnap.plist

Remove completely:

    rm ~/Library/LaunchAgents/com.user.rsnap.plist
