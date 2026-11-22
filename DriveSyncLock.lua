-- @description Drive Sync Lock - check-out/check-in locking for REAPER projects in a synced folder
-- @version 0.2.0
-- @author Colin Lee Campbell
-- @about
--   Run once to start (toggle action). While running, it:
--     * writes "<project>.rpp.lock" next to every saved project you open, so other
--       machines sharing the folder (Google Drive, rclone, Dropbox, ...) know you're editing it
--     * keeps the lock alive with a heartbeat, and releases it when you close the project
--     * warns when you open a project another machine has locked, and lets you
--       view it, take over the lock, or close it
--     * notices when the .rpp changes on disk from another machine and offers to reload
--     * offers you the lock when the other machine releases it
--     * finds sync conflict copies next to the project and merges them track by track
--     * keeps a local history of every version it sees (backups + merge ancestors)
--   Run again to stop (all of your locks are released).

------------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------------
local POLL_INTERVAL          = 2   -- seconds between checks of the project files
local HEARTBEAT_INTERVAL     = 60  -- seconds between lock refreshes
local CONFLICT_SCAN_INTERVAL = 30  -- seconds between scans for sync conflict copies
-- (stale-lock timeout and history size are in lib/drivesync.lua)

------------------------------------------------------------------------------
local script_path = select(2, reaper.get_action_context())
local script_dir = script_path:match("^(.*)[/\\]") or "."
package.path = script_dir .. "/lib/?.lua;" .. package.path
local ds = require("drivesync")

ds.SCRIPT_NAME = "Drive Sync Lock"
local log, msgbox, basename = ds.log, ds.msgbox, ds.basename
local MACHINE_ID = ds.machine_id()

------------------------------------------------------------------------------
-- Per-project state
------------------------------------------------------------------------------
-- projects[path] = {
--   path, lock, proj, owner (bool), acquired, content (last known .rpp text),
--   dirty (last tick), last_heartbeat, offered (already offered a free lock),
--   last_conflict_scan, handled_conflicts = {}
-- }
local projects = {}

local function acquire(st)
  st.owner = true
  st.acquired = os.time()
  st.last_heartbeat = os.time()
  st.offered = false
  st.handled_conflicts = {} -- re-offer merges now that we can write the project
  ds.write_lock(st.lock, st.acquired)
  log("Locked %s", basename(st.path))
end

local function release(st)
  if not st.owner then return end
  if ds.lock_is_mine(ds.read_lock(st.lock)) then
    os.remove(st.lock)
    log("Released lock on %s", basename(st.path))
  end
  st.owner = false
end

local function close_project(proj)
  local cur = reaper.EnumProjects(-1)
  reaper.SelectProjectInstance(proj)
  reaper.Main_OnCommand(40860, 0) -- Close current project tab
  if cur ~= proj then reaper.SelectProjectInstance(cur) end
end

local function reload(st)
  st.proj = ds.reload(st.proj, st.path)
  st.content = ds.read_file(st.path)
  st.dirty = false
end

local function on_project_opened(proj, path)
  local st = {
    path = path,
    lock = ds.lock_path(path),
    proj = proj,
    owner = false,
    content = ds.read_file(path),
    dirty = reaper.IsProjectDirty(proj) == 1,
    last_heartbeat = 0,
    offered = false,
    last_conflict_scan = 0,
    handled_conflicts = {},
  }
  ds.snapshot(path, st.content, "opened")

  local lock = ds.read_lock(st.lock)
  local name = basename(path)

  if not lock or ds.lock_is_mine(lock) then
    -- Free, or ours (e.g. left behind after a crash).
    acquire(st)
  elseif ds.lock_is_stale(lock) then
    local r = msgbox(("%s has a lock from %s, but it hasn't been refreshed for %s.\n\n" ..
      "It was probably left behind by a crash or a machine that went offline.\n\n" ..
      "Take over the lock?\n\nYes = take it and edit\nNo = view only (don't save)")
      :format(name, ds.lock_owner_desc(lock), ds.fmt_age(os.time() - lock.heartbeat)), 4)
    if r == 6 then acquire(st) else log("Viewing %s (view only)", name) end
  else
    local r = msgbox(("%s is being edited by %s (last active %s ago).\n\n" ..
      "Yes = open view-only (do NOT save, or you'll overwrite their work)\n" ..
      "No = take over the lock anyway (their unsaved work may collide with yours)\n" ..
      "Cancel = close the project")
      :format(name, ds.lock_owner_desc(lock), ds.fmt_age(os.time() - lock.heartbeat)), 3)
    if r == 7 then
      acquire(st)
    elseif r == 2 then
      st.closed = true
      close_project(proj)
    else
      log("Viewing %s (view only, locked by %s)", name, ds.lock_owner_desc(lock))
    end
  end
  return st
end

local function is_conflict_copy(stem, name, f)
  if f == name or f:sub(1, #stem) ~= stem then return false end
  local rest = f:sub(#stem + 1):lower()
  if rest:match("%.lock$") or rest:match("%.rpp%-bak$") or rest:match("%.rpp%-undo$") then return false end
  return rest:match("conflict") ~= nil
    or rest:match("^%s*%(%d+%)%.rpp$") ~= nil -- Google Drive / Windows style "name (1).rpp"
end

local function scan_for_conflicts(st)
  local dir, name = ds.split_path(st.path)
  local stem = name:gsub("%.[Rr][Pp][Pp]$", "")
  for _, f in ipairs(ds.list_dir(dir)) do
    if is_conflict_copy(stem, name, f) and not st.handled_conflicts[f] then
      st.handled_conflicts[f] = true
      local copy_path = ds.join(dir, f)
      if st.owner then
        local r = msgbox(("Found a sync conflict copy next to %s:\n\n    %s\n\n" ..
          "Two machines saved the project at the same time.\n\n" ..
          "Merge it into this project now?\n\n" ..
          "Tracks changed on only one side are combined automatically. Tracks changed on both " ..
          "sides keep your version, and the other version is added as a muted copy at the end. " ..
          "Your unsaved changes are saved first. Backups of both versions are kept.\n\n" ..
          "Yes = merge now\nNo = leave it alone")
          :format(name, f), 4)
        if r == 6 then
          local report, err = ds.merge_into_project(st.proj, st.path, copy_path,
            { label = "conflict copy", remove_other = true })
          if report then
            st.proj = ds.find_project(st.path) or st.proj
            st.content = ds.read_file(st.path)
            st.dirty = false
            msgbox("Merge finished.\n\n" .. ds.format_merge_report(report))
          else
            msgbox("Merge failed: " .. tostring(err))
          end
        end
      else
        msgbox(("Found a sync conflict copy next to %s:\n\n    %s\n\n" ..
          "Two machines saved the project at the same time. Once you hold the lock on this " ..
          "project you'll be offered an automatic merge.")
          :format(name, f))
      end
    end
  end
end

local function check_project(st)
  local now = os.time()
  local name = basename(st.path)
  local dirty = reaper.IsProjectDirty(st.proj) == 1
  local lock = ds.read_lock(st.lock)

  -- 1. Did the .rpp change on disk?
  local content = ds.read_file(st.path)
  if content and content ~= st.content then
    if st.owner then
      st.content = content -- our own save
      ds.snapshot(st.path, content, "saved")
    elseif st.dirty and not dirty then
      -- We saved without holding the lock.
      st.content = content
      ds.snapshot(st.path, content, "saved-unlocked")
      msgbox(("You saved %s without holding its lock%s.\n\n" ..
        "If someone else is editing it, one of your saves will be lost or turn into a " ..
        "conflict copy. Use File > Save project as... with a new name to keep your version " ..
        "safe. Later you can combine it with the \"Drive Sync - Merge another version\" action.")
        :format(name, lock and (" (locked by " .. ds.lock_owner_desc(lock) .. ")") or ""))
    else
      -- Someone else saved it.
      ds.snapshot(st.path, content, "remote")
      local who = lock and ds.lock_owner_desc(lock) or "another machine"
      local text = ("%s was updated by %s.\n\nReload it now?"):format(name, who)
      if dirty then
        text = text .. "\n\nWARNING: you have unsaved changes in this project. Reloading " ..
          "discards them. To keep them, answer No and use File > Save project as... with a new " ..
          "name, then merge later with the \"Drive Sync - Merge another version\" action."
      end
      if msgbox(text, 4) == 6 then
        reload(st)
        dirty = false
      else
        st.content = content -- don't ask again for this version
      end
    end
  end
  st.dirty = dirty

  -- 2. Lock housekeeping
  if st.owner then
    if lock and not ds.lock_is_mine(lock) then
      st.owner = false
      msgbox(("%s took over the lock on %s.\n\n" ..
        "Don't save this project now, or the two versions will collide. To keep your changes, " ..
        "use File > Save project as... with a new name, then merge later with the " ..
        "\"Drive Sync - Merge another version\" action.")
        :format(ds.lock_owner_desc(lock), name))
    elseif not lock or now - st.last_heartbeat >= HEARTBEAT_INTERVAL then
      ds.write_lock(st.lock, st.acquired)
      st.last_heartbeat = now
    end
  else
    local free = (not lock) or ds.lock_is_stale(lock)
    if free and not st.offered then
      st.offered = true
      local text = lock
        and ("The lock on %s from %s has gone stale.\n\nTake the lock so you can edit?")
            :format(name, ds.lock_owner_desc(lock))
        or ("%s is no longer locked by anyone.\n\nTake the lock so you can edit?"):format(name)
      if msgbox(text, 4) == 6 then acquire(st) end
    elseif not free then
      st.offered = false
    end
  end

  -- 3. Conflict copies
  if now - st.last_conflict_scan >= CONFLICT_SCAN_INTERVAL then
    st.last_conflict_scan = now
    scan_for_conflicts(st)
  end
end

------------------------------------------------------------------------------
-- Main loop
------------------------------------------------------------------------------
local last_poll = -math.huge

local function poll()
  local seen = {}
  local i = 0
  while true do
    local proj, path = reaper.EnumProjects(i)
    if not proj then break end
    if path ~= "" then -- unsaved projects have no file to lock yet
      seen[path] = true
      local st = projects[path]
      if not st then
        st = on_project_opened(proj, path)
        projects[path] = st
        if st.closed then break end -- tab list changed, pick it up next tick
      else
        st.proj = proj
        check_project(st)
      end
    end
    i = i + 1
  end
  -- Projects that were closed, or renamed with "Save as"
  for path, st in pairs(projects) do
    if not seen[path] then
      release(st)
      projects[path] = nil
    end
  end
end

local function tick()
  local t = reaper.time_precise()
  if t - last_poll >= POLL_INTERVAL then
    last_poll = t
    poll()
  end
  reaper.defer(tick)
end

------------------------------------------------------------------------------
-- Start / stop
------------------------------------------------------------------------------
local _, _, section_id, command_id = reaper.get_action_context()

if reaper.set_action_options then
  reaper.set_action_options(1) -- running the action again stops it instead of asking
end
reaper.SetToggleCommandState(section_id, command_id, 1)
reaper.RefreshToolbar2(section_id, command_id)

reaper.atexit(function()
  for _, st in pairs(projects) do release(st) end
  reaper.SetToggleCommandState(section_id, command_id, 0)
  reaper.RefreshToolbar2(section_id, command_id)
  log("Stopped.")
end)

log("Started. This machine is %s (%s@%s).", MACHINE_ID, ds.USERNAME, ds.HOSTNAME)
tick()
