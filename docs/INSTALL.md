# Installing Drive Sync for REAPER

This guide walks through the whole setup, step by step, for **Windows** and **macOS**
(with a shorter section for **Linux**). Do every step on **each computer** that will work
on the shared projects.

There are four parts:

1. [Set up a shared Google Drive folder](#part-1--set-up-a-shared-google-drive-folder) (once, from any computer)
2. [Install Google Drive for Desktop](#part-2--install-google-drive-for-desktop) (on each computer)
3. [Install the Drive Sync scripts in REAPER](#part-3--install-the-drive-sync-scripts-in-reaper) (on each computer)
4. [Configure REAPER for shared projects](#part-4--configure-reaper-for-shared-projects) (on each computer)

Then [test it](#part-5--test-it-with-two-computers) with two computers and read
[the everyday workflow](#part-6--everyday-workflow).

> **Menu names.** REAPER and Google Drive sometimes rename menu items between versions.
> If something here doesn't match exactly, look for the closest equivalent nearby.

---

## What you need

- **REAPER 6.0 or newer** on every computer. **REAPER 7** is recommended, because
  re-running the script then stops it cleanly instead of asking.
- **A Google account** for each person. One shared account also works.
- **Google Drive for Desktop** (Windows/macOS) or **rclone** (Linux).
- **The Drive Sync files** from
  <https://github.com/ColinLeeCampbell/reaper-drive-sync>.
- **Enough Google Drive storage** for your projects. Audio adds up fast: an hour of 24-bit
  48 kHz stereo is about 1 GB.

---

## Part 1 – Set up a shared Google Drive folder

Do this **once**, on any computer, in a web browser.

1. Go to <https://drive.google.com> and sign in.
2. Click **+ New → New folder** and name it, e.g. `REAPER Projects`.
3. **If everyone uses the same Google account**, skip to Part 2.
4. **If each person has their own Google account:**
   1. Right-click the folder → **Share → Share**.
   2. Type the other person's Google email address.
   3. Set their role to **Editor** (not Viewer or Commenter).
   4. Click **Send**.
5. **The other person** must now add the folder to their own Drive, or Drive for Desktop won't
   sync it:
   1. On <https://drive.google.com>, open **Shared with me** in the left sidebar.
   2. Right-click `REAPER Projects` → **Organize → Add shortcut**. (In older versions:
      **Add shortcut to Drive**.)
   3. Choose **My Drive** and click **Add**.

   The folder now appears in their **My Drive** and syncs like their own folder.

> Every project goes in **its own subfolder** inside `REAPER Projects`, e.g.
> `REAPER Projects/Song Title/Song Title.rpp`, with its audio in
> `REAPER Projects/Song Title/Media/`.

---

## Part 2 – Install Google Drive for Desktop

### Windows

1. Go to <https://www.google.com/drive/download/> and click **Download Drive for desktop**.
2. Run `GoogleDriveSetup.exe`. Allow it to make changes if Windows asks.
   Leave the desktop shortcuts ticked if you like, then click **Install**.
3. When it finishes, click **Sign in with browser**. Choose your Google account and click
   **Sign in** in the browser.
4. Google Drive now has an icon in the **system tray** (bottom-right, next to the clock;
   click the **^** arrow if you can't see it).
5. **Switch to "Mirror files"** (strongly recommended):
   1. Click the tray icon → the **gear ⚙** → **Preferences**.
   2. Select **Google Drive** in the left column.
   3. Choose **Mirror files**.
   4. Note the folder location it shows, usually `C:\Users\<you>\My Drive`. Change it if you
      like.
   5. Click **Save** and wait for the first sync to finish. The tray icon stops animating.

   **Why mirror?** In "Stream files" mode, files are only downloaded when something
   opens them. REAPER may then see a half-downloaded project or a placeholder instead of
   the audio.

   **If you must use Stream mode** (e.g. small disk): open the `G:` drive in File Explorer,
   right-click your `REAPER Projects` folder → **Offline access → Available offline**.
6. Open File Explorer and go to `My Drive\REAPER Projects` (mirror) or
   `G:\My Drive\REAPER Projects` (stream). Make sure you can see the folder.
7. Optional but useful: in File Explorer, click **View → Show → File name extensions**,
   so you can see `.rpp` and `.lock` files.

### macOS

1. Go to <https://www.google.com/drive/download/> and click **Download Drive for desktop**.
2. Open `GoogleDrive.dmg` and double-click `GoogleDrive.pkg`. Follow the installer and enter
   your Mac password when asked.
3. On first launch, click **Sign in with browser** and sign in to your Google account.
4. **Allow the system extension**, if macOS asks for it. Recent macOS versions use Apple's
   "File Provider", so this usually isn't needed. If you see *"System Extension Blocked"*:
   1. Open  **→ System Settings → Privacy & Security**.
   2. Scroll down and click **Allow** next to the message about Google software.
   3. Restart the Mac if asked.
5. Google Drive now has an icon in the **menu bar** (top-right).
6. **Switch to "Mirror files"** (strongly recommended):
   1. Click the menu-bar icon → the **gear ⚙** → **Preferences** (or **Settings**).
   2. Select **Google Drive**.
   3. Choose **Mirror files**.
   4. Note the folder location shown. Depending on the Drive version, it's either a folder
      like `~/My Drive` or
      `~/Library/CloudStorage/GoogleDrive-<your email>/My Drive`.
   5. Click **Save** and wait for the first sync to finish.

   **If you must use Stream mode:** in Finder, go to **Google Drive** in the sidebar
   (under *Locations*). Right-click `REAPER Projects` → **Make available offline**
   (or **Available offline**).
7. In Finder, check that you can open `My Drive/REAPER Projects`. It's also listed in the
   Finder sidebar under **Locations → Google Drive**.
8. **Let REAPER access the folder.** The first time REAPER opens a file from Google Drive,
   macOS may ask *"REAPER would like to access files…"*. Click **Allow**. If you clicked
   *Don't Allow* by mistake:
   1. Open  **→ System Settings → Privacy & Security → Files and Folders**.
   2. Find **REAPER** and turn on the relevant switches.
   3. If REAPER still can't open files under `~/Library/CloudStorage`, go to **Privacy &
      Security → Full Disk Access**, click **+**, and add `/Applications/REAPER.app`.
   4. Quit and restart REAPER.

### Linux

There's no official Google Drive app for Linux. Use **rclone**, which is free and open
source:

1. Install rclone: `sudo apt install rclone` (Debian/Ubuntu), `sudo dnf install rclone`
   (Fedora), or `curl https://rclone.org/install.sh | sudo bash` for the newest version.
   You need **rclone 1.64 or newer** for `bisync`. Check with `rclone version`.
2. Run `rclone config`, then:
   1. `n` (new remote), name it `gdrive`.
   2. Storage type: `drive` (Google Drive).
   3. Leave `client_id` and `client_secret` empty. Choose scope `1` (full access).
   4. Accept the defaults, and say **yes** to auto config. A browser opens; sign in.
   5. If the folder is shared with you from another account, answer **yes** to
      *"Configure this as a Shared Drive"* only if it's a real Shared Drive. For a
      normal shared folder, use the **Add shortcut** step in Part 1 instead.
3. Make a local folder and do the first sync:
   ```bash
   mkdir -p ~/ReaperProjects
   rclone bisync ~/ReaperProjects "gdrive:REAPER Projects" \
     --filters-file ~/reaper-drive-sync/sync/rclone-filters.txt --resync
   ```
4. Keep it syncing while you work. Run this in a terminal and leave it open:
   ```bash
   while true; do
     rclone bisync ~/ReaperProjects "gdrive:REAPER Projects" \
       --filters-file ~/reaper-drive-sync/sync/rclone-filters.txt
     sleep 30
   done
   ```
   You could also run it as a systemd user timer. Keep the sync interval **well under
   15 minutes**, because a lock that isn't refreshed for 15 minutes counts as abandoned.

---

## Part 3 – Install the Drive Sync scripts in REAPER

### 3.1 Download the scripts

**Option A – ZIP (easiest):**

1. Go to <https://github.com/ColinLeeCampbell/reaper-drive-sync>.
2. Click the green **Code** button → **Download ZIP**.
3. Unzip it:
   - **Windows:** right-click the ZIP in *Downloads* → **Extract All…** → **Extract**.
   - **macOS:** double-click the ZIP in *Downloads*.

   You get a folder called `reaper-drive-sync-main`. **Rename it to `reaper-drive-sync`.**

**Option B – git:**

```bash
git clone https://github.com/ColinLeeCampbell/reaper-drive-sync.git
```

You can update later with `git pull`.

### 3.2 Find REAPER's resource folder

1. Open REAPER.
2. Click **Options → Show REAPER resource path in explorer/finder…**
3. A File Explorer (Windows) or Finder (macOS) window opens. Usually it's:

   | System | Resource folder |
   |---|---|
   | Windows | `C:\Users\<you>\AppData\Roaming\REAPER` |
   | Windows (portable install) | the folder you installed REAPER into |
   | macOS | `/Users/<you>/Library/Application Support/REAPER` |
   | Linux | `~/.config/REAPER` |

   On macOS the `Library` folder is hidden. Using REAPER's menu item avoids that problem.
   You can also use Finder **Go → Go to Folder…** (⇧⌘G) and paste
   `~/Library/Application Support/REAPER`.

4. Open the **`Scripts`** folder inside it. Create it if it doesn't exist.

### 3.3 Copy the scripts in

Copy (or move) the whole **`reaper-drive-sync`** folder into `Scripts`. The result must
look exactly like this:

```
REAPER resource folder/
└── Scripts/
    └── reaper-drive-sync/
        ├── DriveSyncLock.lua
        ├── DriveSync - Merge another version.lua
        ├── lib/
        │   ├── drivesync.lua
        │   └── rpp.lua
        ├── docs/ ...
        └── ...
```

> **Important:** the `lib` folder must stay next to the two `.lua` scripts. If you copy only
> the scripts, you'll get the error `module 'drivesync' not found`.

> **Don't** put the scripts inside your Google Drive folder. They belong in REAPER's
> resource folder on each computer.

### 3.4 Add the scripts to REAPER's action list

1. In REAPER, open **Actions → Show action list…** (shortcut: **?**).
2. Click **New action…** (bottom right) → **Load ReaScript…**.
   (In older versions: **ReaScript: Load…**.)
3. Go to `Scripts/reaper-drive-sync/`. Select **both**:
   - `DriveSyncLock.lua`
   - `DriveSync - Merge another version.lua`

   **Windows:** hold **Ctrl** while clicking. **macOS:** hold **⌘** while clicking.
4. Click **Open**. Both now appear in the action list as
   `Script: DriveSyncLock.lua` and `Script: DriveSync - Merge another version.lua`.
   Type `DriveSync` in the **Filter** box to find them.

### 3.5 (Recommended) Add a toolbar button

The button lights up while the lock script is running, so you can always see whether
you're protected.

1. Right-click an empty part of REAPER's main toolbar → **Customize toolbar…**
2. Click **Add…**, type `DriveSyncLock` in the filter, select it, and click **Select/close**.
3. With the new button selected, click **Text icon…** and type e.g. `Sync` (or choose an icon).
4. Click **Save**.

### 3.6 (Recommended) Start it automatically with REAPER

1. In the action list, right-click `Script: DriveSyncLock.lua` →
   **Copy selected action command ID**. This copies something like `_RS1a2b3c4d...`.
2. In the `Scripts` folder (from step 3.2), open the file **`__startup.lua`** in a text
   editor, or create it. Note the **two** underscores.
   - **Windows:** Notepad works. When saving, choose *Save as type: All files* so it isn't
     saved as `__startup.lua.txt`.
   - **macOS:** use TextEdit with **Format → Make Plain Text**, or any code editor.
3. Add this line, pasting your own command ID in place of the example:
   ```lua
   reaper.Main_OnCommand(reaper.NamedCommandLookup("_RS1a2b3c4d5e6f7a8b9c0d"), 0)
   ```
4. Save, then restart REAPER. The toolbar button should light up straight away.

Alternative: if you use the **SWS extension**, open **Extensions → Startup actions → Set
global startup action…** and pick `Script: DriveSyncLock.lua`.

### 3.7 Start it now

Run `Script: DriveSyncLock.lua` from the action list (select it → **Run**), or click the
toolbar button. You won't see a window. The script runs quietly in the background until
something needs your attention.

To **stop** it, run it again or click the toolbar button again. Stopping releases all of
your locks. On REAPER 6, REAPER asks whether to terminate the running instance:
tick **Remember my answer** and choose **Terminate instances**.

---

## Part 4 – Configure REAPER for shared projects

Do these on **every** computer. They prevent most sync problems.

### 4.1 Keep peak (waveform) files out of Google Drive

REAPER writes a `.reapeaks` file next to every audio file. Each computer can rebuild
these, so syncing them is wasted traffic.

1. **Options → Preferences…** (Windows: **Ctrl+P**, macOS: **⌘,**).
2. Go to **Media** in the left column. On some versions the peak options are on
   **Media → Peaks/Waveforms**.
3. Find the peak cache settings and tick
   **"Store all peak caches (.reapeaks) in alternate path"**.
4. Set the path to a local folder outside Google Drive, e.g.
   - Windows: `C:\Users\<you>\Documents\REAPER Peaks`
   - macOS: `/Users/<you>/Documents/REAPER Peaks`
5. Click **OK**.

### 4.2 Keep backups and autosaves out of Google Drive

1. **Options → Preferences → Project** (the **Backup** settings are on this page or the
   *Backup* sub-page).
2. If **"Save project file backup (.rpp-bak)"** or timestamped backups are on, set them to
   save to a **separate backup directory** outside Google Drive, e.g.
   `Documents\REAPER Backups`.
3. Do the same for **auto-save**, if you use it.
4. Click **OK**.

Drive Sync also keeps its own history of every project version it sees, in
`<resource folder>/DriveSync/history`, so you're covered either way.

### 4.3 Keep each project's media inside its project folder

1. When creating a project, use **File → Save project as…** and tick:
   - **Create subdirectory for project**
   - **Copy all media into project directory**
2. Then **File → Project settings… → Media** tab. Set **"Path to save media files"** to
   `Media` and click **OK**.
3. To make that the default for all new projects: in **Project settings**, click
   **Save as default project settings**.

This way every audio file is stored relative to the project, e.g. `Media/Guitar-01.wav`,
and the project opens on any computer regardless of where Google Drive lives on that
machine.

### 4.4 Match plugins

Install the **same plugins and plugin versions** on every computer. A plugin missing on
one machine shows as offline there. It isn't deleted from the project, but don't remove
the offline FX, or the other machine loses it too.

---

## Part 5 – Test it with two computers

Use a throwaway project for this.

1. **Computer 1:** create a new project, add a track called `Test`, and save it into
   `REAPER Projects/Sync Test/Sync Test.rpp`. A file `Sync Test.rpp.lock` appears next to it.
2. Wait until Google Drive shows the files as synced on **Computer 2** (open the folder and
   check that both files are there).
3. **Computer 2:** open `Sync Test.rpp`. You should see:
   *"Sync Test.rpp is being edited by <user>@<computer 1>…"*. Click **Yes** (view only).
4. **Computer 1:** rename the track to `Test 2` and save.
5. **Computer 2:** within a minute or so (depending on sync speed) you'll be asked
   *"Sync Test.rpp was updated by…  Reload it now?"*. Click **Yes**. The track is now
   called `Test 2`.
6. **Computer 1:** close the project (**File → Close project**, or close the tab).
7. **Computer 2:** after the next sync you'll be asked
   *"…is no longer locked by anyone. Take the lock so you can edit?"*. Click **Yes**.

If all of that happened, everything is working. If not, see Troubleshooting below.

---

## Part 6 – Everyday workflow

1. **Before opening a project,** check that Google Drive has finished syncing. The tray or
   menu-bar icon should show it's up to date.
2. **Open the project.** If nobody else has it, you get the lock silently.
3. **Work and save as usual.**
4. **When you're done, close the project** (or quit REAPER). The lock is released and syncs
   to the others.
5. If you're asked to reload, reload, unless you have unsaved work you want to keep (see
   below).

**If someone else has the lock and you make changes anyway:**

1. Don't save over the project. Use **File → Save project as…** with a new name, e.g.
   `Song - Colin's ideas.rpp`.
2. When the other person is done, open the real project (you'll get the lock).
3. Run **`Script: DriveSync - Merge another version.lua`** and pick your copy.
4. Read the report. Tracks changed on both sides keep the version in the main project, and
   the other version is added as a **muted** track at the end, so you can compare them and
   keep what you want.

**If you see a "conflict copy"** (e.g. `Song (1).rpp`, created when two computers saved
at the same time), Drive Sync offers to merge it automatically and keeps backups of both
versions.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `module 'drivesync' not found` | The `lib` folder isn't next to the scripts. Re-check step 3.3. |
| Nothing seems to happen | Make sure the script is running (toolbar button lit). The lock only applies to **saved** projects, so save the project once. |
| "is being edited by…" but nobody is | The other computer crashed or went offline with the project open. After 15 minutes, you're offered the lock. If you're sure, you can also delete the `.rpp.lock` file next to the project. |
| Both computers think they have the lock | They opened the project within a few seconds of each other, before the lock synced. Close it on one computer. Always wait for sync before opening. |
| REAPER says media is offline on the other computer | The media isn't inside the project folder (see 4.3), it hasn't finished syncing yet, or (macOS) REAPER doesn't have permission to read the Drive folder (see Part 2, macOS step 8). |
| Files keep re-syncing all the time | Peak files or backups are inside Google Drive. See 4.1 and 4.2. |
| REAPER 6 asks "script is already running" | Choose **Terminate instances** and tick **Remember**. Re-running the action is how you stop it. |
| I want to see what it's doing | In `lib/drivesync.lua`, set `M.VERBOSE = true`. Messages then appear in the ReaScript console. |
| I need an old version of a project | Look in `<resource folder>/DriveSync/history/<project name>-<id>/`. Each file is a complete `.rpp`, named `<unix time>-<n>-<reason>.rpp`. Copy one next to the project and open it. |

---

## Updating

- **ZIP install:** download the new ZIP and replace the `reaper-drive-sync` folder inside
  `Scripts`. Keep the same folder name, so the actions and the `__startup.lua` command ID
  keep working.
- **git install:** run `git pull` inside the folder.

Restart the script (click the toolbar button twice) or restart REAPER.

## Uninstalling

1. Stop the script, so your locks are released.
2. In the action list, select the two `Script: DriveSync…` actions → **Delete**.
3. Remove the line you added to `__startup.lua`, if any.
4. Delete `Scripts/reaper-drive-sync`.
5. Optionally delete `<resource folder>/DriveSync` (the local history/backups).
