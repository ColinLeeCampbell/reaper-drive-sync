-- @description Drive Sync Lock - check-out/check-in locking for REAPER projects in a synced folder
-- @version 0.1.0
-- @about
--   Run once to start (toggle action). While running, it:
--     * writes "<project>.rpp.lock" next to every saved project you open, so other
--       machines sharing the folder (Google Drive, rclone, Dropbox, ...) know you're editing it
--     * keeps the lock alive with a heartbeat, and releases it when you close the project
--     * warns when you open a project another machine has locked, and lets you
--       view it, take over the lock, or close it
--     * notices when the .rpp changes on disk from another machine and offers to reload
--     * offers you the lock when the other machine releases it
--     * warns about sync conflict copies next to the project
--   Run again to stop (all of your locks are released).

------------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------------
local POLL_INTERVAL      = 2       -- seconds between checks of the project files
local HEARTBEAT_INTERVAL = 60      -- seconds between lock refreshes
local STALE_AFTER        = 15 * 60 -- a lock not refreshed for this long is treated as abandoned
local CONFLICT_SCAN_INTERVAL = 30  -- seconds between scans for sync conflict copies
local VERBOSE            = true    -- print status messages to the ReaScript console

------------------------------------------------------------------------------
local SCRIPT_NAME = "Drive Sync Lock"
local EXT = "DriveSyncLock"

local function log(fmt, ...)
  if VERBOSE then
    reaper.ShowConsoleMsg(("[%s] " .. fmt .. "\n"):format(SCRIPT_NAME, ...))
  end
end

local function msgbox(text, kind)
  -- kind: 0 = OK, 3 = Yes/No/Cancel, 4 = Yes/No
  -- returns 1 = OK, 2 = Cancel, 6 = Yes, 7 = No
  return reaper.ShowMessageBox(text, SCRIPT_NAME, kind or 0)
end

------------------------------------------------------------------------------
-- Identity
------------------------------------------------------------------------------
local function get_hostname()
  local h = os.getenv("COMPUTERNAME") or os.getenv("HOSTNAME")
  if not h or h == "" then
    local p = io.popen("hostname")
    if p then h = p:read("*l"); p:close() end
  end
  if not h or h == "" then h = "unknown-host" end
  return h
end

local HOSTNAME = get_hostname()
local USERNAME = os.getenv("USER") or os.getenv("USERNAME") or "unknown-user"

-- A per-install ID, so two machines with the same hostname don't get mixed up.
local function get_machine_id()
  local id = reaper.GetExtState(EXT, "machine_id")
  if id == "" then
    math.randomseed(os.time() + math.floor(reaper.time_precise() * 1000))
    id = ("%s-%04x%04x"):format(HOSTNAME, math.random(0, 0xffff), math.random(0, 0xffff))
    reaper.SetExtState(EXT, "machine_id", id, true)
  end
  return id
end

local MACHINE_ID = get_machine_id()

------------------------------------------------------------------------------
-- File helpers
------------------------------------------------------------------------------
local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function split_path(path)
  local dir, name = path:match("^(.*)[/\\]([^/\\]+)$")
  return dir or ".", name or path
end

local function basename(path)
  local _, name = split_path(path)
  return name
end

local function fmt_age(seconds)
  if seconds < 90 then return ("%d s"):format(seconds) end
  if seconds < 90 * 60 then return ("%d min"):format(math.floor(seconds / 60 + 0.5)) end
  if seconds < 48 * 3600 then return ("%.1f h"):format(seconds / 3600) end
  return ("%.1f days"):format(seconds / 86400)
end

------------------------------------------------------------------------------
-- Lock file:  plain "key=value" lines next to the project, "<project>.rpp.lock"
------------------------------------------------------------------------------
local function lock_path(project_path)
  return project_path .. ".lock"
end

local function read_lock(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local t = {}
  for line in f:lines() do
    local k, v = line:match("^(%w+)=(.*)$")
    if k then t[k] = v end
  end
  f:close()
  if not t.machine then return nil end -- empty or half-synced file
  t.heartbeat = tonumber(t.heartbeat) or 0
  t.acquired = tonumber(t.acquired) or t.heartbeat
  return t
end

local function write_lock(path, acquired)
  local f = io.open(path, "w")
  if not f then
    log("ERROR: could not write lock file %s", path)
    return false
  end
  f:write(("machine=%s\nuser=%s\nhost=%s\nacquired=%d\nheartbeat=%d\n")
    :format(MACHINE_ID, USERNAME, HOSTNAME, acquired, os.time()))
  f:close()
  return true
end

local function lock_is_stale(lock)
  return os.time() - lock.heartbeat > STALE_AFTER
end

local function lock_owner_desc(lock)
  return ("%s@%s"):format(lock.user or "?", lock.host or "?")
end

------------------------------------------------------------------------------
-- Per-project state
------------------------------------------------------------------------------
-- projects[path] = {
--   path, lock, proj, owner (bool), acquired, content (last known .rpp text),
--   dirty (last tick), last_heartbeat, offered (already offered a free lock),
--   last_conflict_scan, warned_conflicts = {}
-- }
local projects = {}

local function acquire(st)
  st.owner = true
  st.acquired = os.time()
  st.last_heartbeat = os.time()
  st.offered = false
  write_lock(st.lock, st.acquired)
  log("Locked %s", basename(st.path))
end

local function release(st)
  if not st.owner then return end
  local lock = read_lock(st.lock)
  if lock and lock.machine == MACHINE_ID then
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
  local cur = reaper.EnumProjects(-1)
  local was_active = (cur == st.proj)
  reaper.SelectProjectInstance(st.proj)
  reaper.Main_openProject("noprompt:" .. st.path)
  st.proj = reaper.EnumProjects(-1)
  st.content = read_file(st.path)
  st.dirty = false
  if not was_active then reaper.SelectProjectInstance(cur) end
  log("Reloaded %s", basename(st.path))
end

local function on_project_opened(proj, path)
  local st = {
    path = path,
    lock = lock_path(path),
    proj = proj,
    owner = false,
    content = read_file(path),
    dirty = reaper.IsProjectDirty(proj) == 1,
    last_heartbeat = 0,
    offered = false,
    last_conflict_scan = 0,
    warned_conflicts = {},
  }

  local lock = read_lock(st.lock)
  local name = basename(path)

  if not lock or lock.machine == MACHINE_ID then
    -- Free, or ours (e.g. left behind after a crash).
    acquire(st)
  elseif lock_is_stale(lock) then
    local r = msgbox(("%s has a lock from %s, but it hasn't been refreshed for %s.\n\n" ..
      "It was probably left behind by a crash or a machine that went offline.\n\n" ..
      "Take over the lock?\n\nYes = take it and edit\nNo = view only (don't save)")
      :format(name, lock_owner_desc(lock), fmt_age(os.time() - lock.heartbeat)), 4)
    if r == 6 then acquire(st) else log("Viewing %s (view only)", name) end
  else
    local r = msgbox(("%s is being edited by %s (last active %s ago).\n\n" ..
      "Yes = open view-only (do NOT save, or you'll overwrite their work)\n" ..
      "No = take over the lock anyway (their unsaved work may collide with yours)\n" ..
      "Cancel = close the project")
      :format(name, lock_owner_desc(lock), fmt_age(os.time() - lock.heartbeat)), 3)
    if r == 7 then
      acquire(st)
    elseif r == 2 then
      st.closed = true
      close_project(proj)
    else
      log("Viewing %s (view only, locked by %s)", name, lock_owner_desc(lock))
    end
  end
  return st
end

local function scan_for_conflicts(st)
  local dir, name = split_path(st.path)
  local stem = name:gsub("%.[Rr][Pp][Pp]$", "")
  reaper.EnumerateFiles(dir, -1) -- force a rescan of the directory (REAPER caches listings)
  local i = 0
  while true do
    local f = reaper.EnumerateFiles(dir, i)
    if not f then break end
    if f ~= name and f:sub(1, #stem) == stem and not f:lower():match("%.lock$") then
      local rest = f:sub(#stem + 1):lower()
      local is_conflict = rest:match("conflict")
        or rest:match("^%s*%(%d+%)%.rpp$") -- Google Drive / Windows style "name (1).rpp"
      if is_conflict and not st.warned_conflicts[f] then
        st.warned_conflicts[f] = true
        msgbox(("Found a sync conflict copy next to %s:\n\n    %s\n\n" ..
          "Two machines saved the project at the same time. Open the copy in a new tab, " ..
          "move over anything you need, then delete the copy.")
          :format(name, f))
      end
    end
    i = i + 1
  end
end

local function check_project(st)
  local now = os.time()
  local name = basename(st.path)
  local dirty = reaper.IsProjectDirty(st.proj) == 1
  local lock = read_lock(st.lock)

  -- 1. Did the .rpp change on disk?
  local content = read_file(st.path)
  if content and content ~= st.content then
    if st.owner then
      st.content = content -- our own save
    elseif st.dirty and not dirty then
      -- We saved without holding the lock.
      st.content = content
      msgbox(("You saved %s without holding its lock%s.\n\n" ..
        "If someone else is editing it, one of your saves will be lost or turn into a " ..
        "conflict copy. Use File > Save project as... with a new name to keep your version safe.")
        :format(name, lock and (" (locked by " .. lock_owner_desc(lock) .. ")") or ""))
    else
      -- Someone else saved it.
      local who = lock and lock_owner_desc(lock) or "another machine"
      local text = ("%s was updated by %s.\n\nReload it now?"):format(name, who)
      if dirty then
        text = text .. "\n\nWARNING: you have unsaved changes in this project. Reloading discards them."
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
    if lock and lock.machine ~= MACHINE_ID then
      st.owner = false
      msgbox(("%s took over the lock on %s.\n\n" ..
        "Don't save this project now, or the two versions will collide. To keep your changes, " ..
        "use File > Save project as... with a new name.")
        :format(lock_owner_desc(lock), name))
    elseif not lock or now - st.last_heartbeat >= HEARTBEAT_INTERVAL then
      write_lock(st.lock, st.acquired)
      st.last_heartbeat = now
    end
  else
    local free = (not lock) or lock_is_stale(lock)
    if free and not st.offered then
      st.offered = true
      local text = lock
        and ("The lock on %s from %s has gone stale.\n\nTake the lock so you can edit?")
            :format(name, lock_owner_desc(lock))
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

local function tick()
  local t = reaper.time_precise()
  if t - last_poll >= POLL_INTERVAL then
    last_poll = t
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
      if not seen[path] and not st.closed then
        release(st)
        projects[path] = nil
      elseif st.closed and not seen[path] then
        projects[path] = nil
      end
    end
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

log("Started. This machine is %s (%s@%s).", MACHINE_ID, USERNAME, HOSTNAME)
tick()
