# rsnap (rsync-based Time Machine–style backups)

`rsnap` is a lightweight macOS backup utility that uses `rsync` and hard links to create efficient, incremental, snapshot-based backups — similar in spirit to Time Machine, but simpler and fully transparent. Hardlinks allow you to restore previous versions with minimal disk usage. A full backup will be done every 7 backups.

A key distinction is that `rsnap` is file-level hard-link snapshots opposed to block-level offered by Time Machine as outlined in the following comparison:

Block-level snapshots (Time Machine on APFS)

- APFS-only: Block-level snapshots rely on APFS features like copy-on-write and metadata tracking.
- Cannot use on `HFS+`, `exFAT`, or network shares that don’t support `APFS` snapshots.
- Speed & efficiency: Very fast for large files because unchanged blocks are never copied.
- Limitation: You’re tied to APFS for both source and destination volumes to get the snapshot magic.

File-level hard-link snapshots (rsnap)

- Filesystem-agnostic: Works on `APFS`, `HFS+`, `ext4`, `XFS`, `exFAT`, etc.
- Mechanism: Hard links to unchanged files; new files or changed files are copied.
- Trade-offs: Slower for huge files that change slightly (entire file is copied if modified).
- Flexibility: Can back up to external drives, network mounts, or any filesystem that supports hard links.


Overall, `rsnap` is much more suitable for NAS devices like QNAP or Synology for a few reasons:

#### Filesystem compatibility

Most NAS devices use `ext4`, `Btrfs`, `XFS`, or network filesystems (`SMB/NFS`). APFS snapshots won’t work here, so Time Machine’s block-level magic cannot be utilized. `rsnap` just relies on file-level hard links, which work fine over these filesystems (or at least over NFS/SMB with some caveats).

#### Flexibility

Back up to any mounted volume or network share is possible. You control what to include/exclude with --exclude-from. You can run it from macOS, Linux, or even directly on the NAS (if it has rsync).

#### Incremental backups

`rsnap` still uses the hard-link + timestamped snapshot pattern, giving the same incremental benefits as Time Machine. On networked NAS, this is critical — you don’t want to copy everything every time.

#### Logging and scripting

Logging, dry-run tests, or scheduling with launchd or cron is easily added.  You can tweak ulimit, exclude lists, or snapshot frequency for your NAS environment.

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

`rsnap` uses `rsync` to copy files from your source directory to a backup location. For each backup, unchanged files are hard-linked to previous snapshots, saving space and speeding up the process. Only new or changed files are copied.

---

## 📋 Requirements

- macOS (tested on recent versions) or Linux  
- `rsync` installed (default on macOS)  
- Sufficient permissions to read source and write to backup location  

---

## 🚀 Usage

    ./rsnap.sh -s <source_path> -d <destination_root> -m <VAULT_NAME> [options]

    Options:

    -s <path>       Source folder to back up
    -d <path>       Destination root where snapshots are stored
    -v <name>       Vault name (prefix for snapshot folders)
    -x <file>       Exclude file list (passed to rsync --exclude-from)
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



### Run manually

Example:

    ./rsnap.sh -s $HOME/Documents -d /Volumes/BackupDrive -v MyVault -f hfs -S
   
Backups are created in:

    /Volumes/BackupDrive/Backups.rsnap/MyVault/<timestamp>/

### Typical Scenario

**- Saving to HFS on external drive**

A likely scenario is saving to an external drive using `HFS+` and not `APFS` thus we need `-F` and `-S` options and `-q` helps to remove a noisy log file. Add `-n idle` to avoid hogging the CPU and I/O

```sh
./rsnap.sh -s ~/Users -d /Volumes/HFSBackup -v UsersVault -F hfs -S -n idle -q
```

This adjusts rsync flags for compatibility with `HFS+` filesystems and doesnt follow symlinks and uses quiet mode.

### More Usage Examples

**1. Backup with exclude patterns**

Exclude files and folders listed in `linux_excludes.txt`:

```sh
./rsnap.sh -s ~/Pictures -d /Volumes/BackupDrive -v PhotosVault -x linux_excludes.txt
```
This will skip any files or directories matching patterns in `exclude.txt`.

**2. Dry-run (test mode)**

Preview what would be backed up without making changes:

```sh
./rsnap.sh -s ~/Projects -d /Volumes/BackupDrive -v CodeVault -t
```
No files are copied; output shows what would happen.

**3. Quiet mode**

Suppress non-error output for silent backups:

```sh
./rsnap.sh -s ~/Music -d /Volumes/BackupDrive -v MusicVault -q
```
Only errors will be displayed.

**4. Safe mode (do not follow symlinks)**

Back up without following symbolic links:

```sh
./rsnap.sh -s ~/Documents -d /Volumes/BackupDrive -v DocsVault -S
```
Symlinks are preserved as links, not as the files they point to.

**5. Specify filesystem type for destination**

Optimize rsync options for a FAT-formatted drive:

```sh
./rsnap.sh -s ~/Downloads -d /Volumes/FATBackup -v DownloadsVault -F fat
```
This adjusts rsync flags for compatibility with FAT filesystems.

### Clone / Download  
Save the script somewhere in your path, e.g.:

```sh
git clone https://github.com/yourusername/rsnap.git
cd rsnap
chmod +x rsnap.sh
```

### Scheduling with launchd  
This section explains how to run `rsnap` automatically on macOS.

**Step 1 — Copy the plist**

```sh
mkdir -p ~/Library/LaunchAgents
cp com.user.rsnap.plist ~/Library/LaunchAgents/com.user.rsnap.plist
```

You might need to clear any attributes that can be applied, in particular `com.apple.provenance`

```sh
xattr -l ~/Library/LaunchAgents/com.user.rsnap.plist
com.apple.provenance

xattr -c ~/Library/LaunchAgents/com.user.rsnap.plist
```

**Step 2 — Load the agent**

```sh
launchctl load ~/Library/LaunchAgents/com.user.rsnap.plist
```

Verify it’s loaded:

```sh
launchctl list | grep com.user.rsnap
```

**Step 3 — Run on demand**

```sh
launchctl start com.user.rsnap
```

**Step 4 — Check logs**

```sh
tail -f ~/rsnap.stdout.log
tail -f ~/rsnap.stderr.log
```

**Step 5 — Update settings**  
If you edit the plist:

```sh
launchctl unload ~/Library/LaunchAgents/com.user.rsnap.plist
launchctl load ~/Library/LaunchAgents/com.user.rsnap.plist
```

**Step 6 — Disable or remove**

Disable without deleting:

```sh
launchctl unload ~/Library/LaunchAgents/com.user.rsnap.plist
```

Remove completely:

```sh
rm ~/Library/LaunchAgents/com.user.rsnap.plist
```


**Suggestions:**

- Ensure `com.user.rsnap.plist` is correctly configured for your backup schedule and script path.
- Log file paths (`~/rsnap.stdout.log`, `~/rsnap.stderr.log`) should match those specified in your plist.
- Use your actual username or a unique label in the plist filename to avoid conflicts.
- Consider using `launchctl bootout` instead of `unload` on newer macOS versions (Monterey and later).
- For system-wide scheduling, use `/Library/LaunchDaemons` (requires sudo).
- Add a note about editing the plist with `nano` or `vim` if users need to customize it.

Otherwise, the steps are correct and follow standard launchd usage.
