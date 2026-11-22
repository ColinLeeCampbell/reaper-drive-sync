# Drive Sync Lock for REAPER

A ReaScript that adds check-out/check-in locking to REAPER projects that live in a
synced folder (Google Drive, rclone, Dropbox, Syncthing...). Only one machine edits a
project at a time. Everyone else gets warnings and reload prompts instead of silently
overwriting each other.

## What it does

While the script is running, for every **saved** project open in any tab:

| Situation | What happens |
|---|---|
| You open a project nobody has locked | A `MySong.rpp.lock` file is written next to it, naming your machine |
| You open a project another machine has locked | You choose: **view-only**, **take over the lock**, or **close** |
| The lock is old (no heartbeat for 15 min) | It's treated as abandoned (crash or machine offline), and you're offered the lock |
| You're editing | The lock is refreshed every 60 s |
| You close the project / stop the script / quit REAPER | Your lock is deleted |
| The `.rpp` changes on disk from the other machine | You're asked whether to reload (with a warning if you have unsaved changes) |
| The other machine releases the lock while you're viewing | You're offered the lock |
| Someone takes over your lock | You're warned not to save, and told to use *Save as* if you want to keep your changes |
| You save while not holding the lock | You're warned that a collision is likely |
| A sync conflict copy appears (`MySong (1).rpp`, `...conflict...`) | You're warned so you can merge it by hand |

## Install

1. Copy `DriveSyncLock.lua` into REAPER's `Scripts` folder (*Options > Show REAPER resource path*).
2. *Actions > Show action list > New action... > Load ReaScript...* and pick the file.
3. (Optional) Add it to a toolbar. The button lights up while the script is running.
4. (Optional) Start it automatically: install SWS, then *Extensions > Startup actions*,
   or add the action to `__startup.lua`.

Run the action again to stop the script. Stopping releases all of your locks.

Settings (poll rate, heartbeat, stale timeout) are at the top of the script.

## Recommended REAPER settings (on every machine)

- **Peaks stored locally:** *Preferences > Media > Peaks/waveforms*. Store peak caches in
  an alternate path outside the synced folder.
- **Backups out of the shared folder:** *Preferences > Project > Backup*. Point timestamped
  backups at a local folder, or rely on the filter list below.
- **Media inside the project folder:** *Preferences > Audio > Recording*. Record into a
  `Media/` subfolder relative to the project. Never reference files by absolute paths
  outside the shared folder.
- Use the same plugins and plugin versions on every machine.

## Syncing the folder

### Windows / macOS: Google Drive for Desktop
Put your projects in a Drive folder set to **"Mirror files"** (or mark the folder
"Available offline" in streaming mode). REAPER needs real local files, not on-demand
placeholders.

### Linux: rclone bisync
There's no official Drive client for Linux. Use `rclone`:

```bash
rclone config                        # create a remote called "gdrive"
# first run only:
rclone bisync ~/ReaperProjects gdrive:ReaperProjects \
  --filters-file ~/Dev/reaper-drive-sync/rclone-filters.txt --resync
# after that, run on a short loop (every 30-60 s) while you work:
while true; do
  rclone bisync ~/ReaperProjects gdrive:ReaperProjects \
    --filters-file ~/Dev/reaper-drive-sync/rclone-filters.txt
  sleep 30
done
```

You could also run that loop as a systemd user timer. Keep the sync interval well
below the 15-minute stale timeout.

## Workflow

1. Wait for the sync client to finish (green check / rclone idle) **before** opening a project.
2. Open the project. If it's free, you hold the lock.
3. Work and save normally.
4. Close the project when you're done, so the lock is released and synced.
5. On the other machine, wait for the sync, then open the project.

## Limitations (read these)

- **Sync delay is the weak spot.** The lock is just a file. If two machines open the
  same project within the sync interval, both can think they hold the lock. When you take
  a lock, the script doesn't wait for confirmation from the other machine. Opening the
  project only after sync has settled avoids this.
- **View-only isn't enforced.** REAPER has no read-only mode the script can switch on.
  It warns you if you save without the lock, but it can't stop the save.
- **Clocks should be roughly in sync** (normal NTP is fine). Stale detection compares
  timestamps written by different machines.
- **Own-save detection is simple.** While you hold the lock, any change to the `.rpp` is
  assumed to be your own save.
- The whole `.rpp` is re-read every 2 s for each open project. That's fine for typical
  projects (a few MB). Raise `POLL_INTERVAL` for huge ones.
- There's no merging. If the same project is edited on two machines anyway, you merge
  the conflict copy by hand. Track-level merging (tracks have GUIDs in the `.rpp`) is the
  logical next feature.
