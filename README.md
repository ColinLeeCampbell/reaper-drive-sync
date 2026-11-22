# Drive Sync for REAPER

Work on the same REAPER projects from two or more computers through a shared Google Drive
folder (or Dropbox, OneDrive, Syncthing, rclone...) **without overwriting each other's
work.**

Google Drive copies files but has no idea who is working on what. If two computers
save the same `.rpp`, one of them wins and the other ends up as a stray conflict copy.
Drive Sync adds what's missing:

- **Project locking.** Opening a project "checks it out" to your computer. Everyone else is
  told who has it, and can open it view-only, take over, or close it.
- **Live updates.** When the person with the lock saves, everyone viewing the project is
  offered a reload.
- **Hand-over.** When they close the project, the next person is offered the lock.
- **Crash-safe.** Locks are refreshed every minute. A lock left behind by a crash or a
  laptop that went offline expires after 15 minutes.
- **Track-by-track merging.** Conflict copies (`Song (1).rpp`) and "Save as" copies can be
  merged back automatically:
  - Tracks changed on only one side are combined.
  - Tracks where different items were changed are merged item by item.
  - Tracks where the same thing was changed on both sides keep your version, and the other
    version is added as a muted copy at the end, so nothing is lost.
- **Local history.** Every version of a project the script sees is snapshotted outside the
  synced folder (last 30 per project), as backups and as merge ancestors.

## Install

**→ See [docs/INSTALL.md](docs/INSTALL.md)** for detailed step-by-step instructions for
Windows, macOS and Linux. They cover Google Drive setup, the REAPER scripts, auto-start,
and the REAPER settings that matter.

Short version:

1. Sync a shared folder on every computer (Google Drive for Desktop in **Mirror files** mode,
   or `rclone bisync` on Linux).
2. Copy this whole folder into REAPER's `Scripts` folder
   (*Options → Show REAPER resource path*). The `lib/` folder must stay next to the scripts.
3. *Actions → Show action list → New action → Load ReaScript*, and load both `.lua` files.
4. Run `DriveSyncLock.lua`, ideally from a toolbar button and automatically at startup.

## What's in here

| Path | What it is |
|---|---|
| `DriveSyncLock.lua` | The background script (toggle action): locks, heartbeats, reload prompts, conflict-copy merging, history |
| `DriveSync - Merge another version.lua` | Action: pick another copy of the current project and merge it in |
| `lib/rpp.lua` | `.rpp` parser/serializer and 3-way merge engine (pure Lua, no REAPER needed) |
| `lib/drivesync.lua` | Shared REAPER-side helpers: lock files, history, merge-into-project |
| `tools/rppmerge.lua` | Command-line merge: `lua tools/rppmerge.lua BASE OURS THEIRS OUT` |
| `sync/rclone-filters.txt` | Files to keep out of the sync (peaks, backups, OS junk) |
| `tests/` | Merge-engine tests and two-machine simulations against a fake REAPER API |
| `docs/INSTALL.md` | Full install guide |

## How it works

**Lock file.** Next to `Song.rpp`, the script writes `Song.rpp.lock`:

```
machine=studio-pc-3fa29c01
user=colin
host=studio-pc
acquired=1795000000
heartbeat=1795000600
```

It rewrites the file every 60 s, and deletes it when you close the project, stop the
script or quit REAPER. Other computers check this file to decide what to tell their user.

**Change detection.** Every 2 s, the script compares each open project's file on disk with
what it last saw. A change while you hold the lock is your own save. A change while you
don't hold it came from another computer, so you're offered a reload.

**Merging.** `.rpp` files are text: a tree of `<CHUNK ... >` blocks where every track
and item carries a GUID. The merge engine does a 3-way merge keyed on those GUIDs. The
common ancestor is picked automatically from local history: it's the snapshot that shares
the most unchanged tracks with both versions.

## Limitations

- **Sync delay.** The lock is just a file, so it's only as fast as your sync. If two
  computers open a project within the same sync window, both can think they hold the lock.
  Wait for the sync to settle before opening.
- **View-only isn't enforced.** REAPER has no read-only mode a script can switch on. You
  get warned if you save without the lock, but the save isn't blocked.
- **Clocks.** Stale-lock detection compares timestamps from different computers, so keep
  their clocks roughly right (automatic time sync is fine).
- **Merge scope.** Merging works at the level of tracks, items and project settings. Two
  edits to the *same* track's settings (volume, FX chain, ...) or the *same* item are not
  combined. The other version is kept as a muted copy for you to reconcile. Track order
  and folder structure come from your version. Tracks added on the other side are slotted
  in next to their original neighbours.
- Each open project's `.rpp` is re-read every 2 s. That's fine for normal projects; raise
  `POLL_INTERVAL` for huge ones.

## Development

Tests need Lua 5.3 or 5.4 (the same Lua REAPER uses):

```bash
lua tests/test_rpp.lua    # merge engine
lua tests/test_lock.lua   # two simulated machines sharing a folder (uses /tmp)
```

`tests/mock_reaper.lua` implements just enough of the REAPER API to run the scripts
unmodified, with a separate clock, ExtState and resource folder per simulated machine.

## Roadmap

- [ ] ReaPack repository, for one-click install and updates
- [ ] Status window: who has which project, when it was last synced
- [ ] Field-level merging inside a track (volume vs. FX vs. items)
- [ ] Optional read-only guard: close-and-reopen instead of allowing edits without the lock
- [ ] Warn when referenced media files haven't finished syncing yet

## License

MIT, see [LICENSE](LICENSE).
