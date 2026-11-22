-- drivesync.lua - shared helpers for the Drive Sync scripts (needs the REAPER API).
--
--   * identity of this machine
--   * file helpers
--   * lock files ("<project>.rpp.lock")
--   * local version history (snapshots of each project, kept outside the synced folder,
--     used as backups and to find the common ancestor when merging)
--   * merging another version of a project into an open project

local rpp = require("rpp")

local M = {}

M.SCRIPT_NAME = "Drive Sync"
M.EXT = "DriveSyncLock"
M.STALE_AFTER = 15 * 60 -- a lock not refreshed for this long is treated as abandoned
M.MAX_HISTORY = 30      -- snapshots kept per project
M.VERBOSE = false   -- true = log lock activity to the ReaScript console (it pops up)

local SEP = package.config:sub(1, 1) -- "\\" on Windows, "/" elsewhere

function M.log(fmt, ...)
  if M.VERBOSE then
    reaper.ShowConsoleMsg(("[%s] " .. fmt .. "\n"):format(M.SCRIPT_NAME, ...))
  end
end

-- kind: 0 = OK, 3 = Yes/No/Cancel, 4 = Yes/No. Returns 1 = OK, 2 = Cancel, 6 = Yes, 7 = No.
function M.msgbox(text, kind)
  return reaper.ShowMessageBox(text, M.SCRIPT_NAME, kind or 0)
end

------------------------------------------------------------------------------
-- Files
------------------------------------------------------------------------------

function M.read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

function M.write_file(path, content)
  local f, err = io.open(path, "wb")
  if not f then return false, err end
  f:write(content)
  f:close()
  return true
end

function M.split_path(path)
  local dir, name = path:match("^(.*)[/\\]([^/\\]+)$")
  return dir or ".", name or path
end

function M.basename(path)
  local _, name = M.split_path(path)
  return name
end

function M.join(...)
  return table.concat({ ... }, SEP)
end

function M.fmt_age(seconds)
  if seconds < 90 then return ("%d s"):format(seconds) end
  if seconds < 90 * 60 then return ("%d min"):format(math.floor(seconds / 60 + 0.5)) end
  if seconds < 48 * 3600 then return ("%.1f h"):format(seconds / 3600) end
  return ("%.1f days"):format(seconds / 86400)
end

-- List file names in a directory (REAPER caches listings, so force a rescan).
function M.list_dir(dir)
  local out = {}
  reaper.EnumerateFiles(dir, -1)
  local i = 0
  while true do
    local f = reaper.EnumerateFiles(dir, i)
    if not f then break end
    out[#out + 1] = f
    i = i + 1
  end
  return out
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

M.HOSTNAME = get_hostname()
M.USERNAME = os.getenv("USER") or os.getenv("USERNAME") or "unknown-user"

-- A per-install ID, so two machines with the same hostname don't get mixed up.
function M.machine_id()
  local id = reaper.GetExtState(M.EXT, "machine_id")
  if id == "" then
    math.randomseed(os.time() + math.floor(reaper.time_precise() * 1000))
    id = ("%s-%04x%04x"):format(M.HOSTNAME, math.random(0, 0xffff), math.random(0, 0xffff))
    reaper.SetExtState(M.EXT, "machine_id", id, true)
  end
  return id
end

------------------------------------------------------------------------------
-- Lock files: plain "key=value" lines next to the project
------------------------------------------------------------------------------

function M.lock_path(project_path)
  return project_path .. ".lock"
end

function M.read_lock(path)
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

function M.write_lock(path, acquired)
  local ok, err = M.write_file(path, ("machine=%s\nuser=%s\nhost=%s\nacquired=%d\nheartbeat=%d\n")
    :format(M.machine_id(), M.USERNAME, M.HOSTNAME, acquired, os.time()))
  if not ok then M.log("ERROR: could not write lock file %s (%s)", path, tostring(err)) end
  return ok
end

function M.lock_is_stale(lock)
  return os.time() - lock.heartbeat > M.STALE_AFTER
end

function M.lock_is_mine(lock)
  return lock ~= nil and lock.machine == M.machine_id()
end

function M.lock_owner_desc(lock)
  return ("%s@%s"):format(lock.user or "?", lock.host or "?")
end

------------------------------------------------------------------------------
-- Local history
------------------------------------------------------------------------------

local function hash(s)
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
  return h
end

function M.history_root()
  return M.join(reaper.GetResourcePath(), "DriveSync", "history")
end

-- One folder per project path, e.g. ".../DriveSync/history/MySong.rpp-1a2b3c4d"
function M.history_dir(project_path)
  local name = M.basename(project_path):gsub("[^%w%._%- ]", "_")
  return M.join(M.history_root(), ("%s-%08x"):format(name, hash(project_path:lower())))
end

-- Snapshot names: "<unix time>-<seq>-<tag>.rpp" (sortable, newest last).
local snapshot_seq = 0

-- Returns snapshot file names, newest first.
function M.list_snapshots(project_path)
  local dir = M.history_dir(project_path)
  local files = {}
  for _, f in ipairs(M.list_dir(dir)) do
    if f:match("^%d+%-%d+%-.*%.rpp$") then files[#files + 1] = f end
  end
  table.sort(files, function(a, b)
    local ta, sa = a:match("^(%d+)%-(%d+)")
    local tb, sb = b:match("^(%d+)%-(%d+)")
    ta, sa, tb, sb = tonumber(ta), tonumber(sa), tonumber(tb), tonumber(sb)
    if ta ~= tb then return ta > tb end
    return sa > sb
  end)
  return files, dir
end

-- Save a copy of `content` into the project's history. `tag` is a short label
-- ("opened", "saved", "remote", "merge-ours", ...). Skips exact duplicates of
-- the newest snapshot. Returns the snapshot path.
function M.snapshot(project_path, content, tag)
  if not content then return nil end
  local files, dir = M.list_snapshots(project_path)
  if files[1] and M.read_file(M.join(dir, files[1])) == content then
    return M.join(dir, files[1])
  end
  reaper.RecursiveCreateDirectory(dir, 0)
  snapshot_seq = snapshot_seq + 1
  local name = ("%d-%d-%s.rpp"):format(os.time(), snapshot_seq, (tag or "snap"):gsub("[^%w%-]", "_"))
  local path = M.join(dir, name)
  M.write_file(path, content)
  -- prune: keep the new snapshot plus the MAX_HISTORY - 1 newest older ones
  for i = M.MAX_HISTORY, #files do
    os.remove(M.join(dir, files[i]))
  end
  return path
end

-- Texts of all snapshots, newest first.
function M.snapshot_texts(project_path)
  local files, dir = M.list_snapshots(project_path)
  local out = {}
  for _, f in ipairs(files) do
    local s = M.read_file(M.join(dir, f))
    if s then out[#out + 1] = s end
  end
  return out
end

------------------------------------------------------------------------------
-- Project tabs
------------------------------------------------------------------------------

function M.find_project(path)
  local i = 0
  while true do
    local proj, fn = reaper.EnumProjects(i)
    if not proj then return nil end
    if fn == path then return proj end
    i = i + 1
  end
end

-- Reload a project from disk in its own tab without any "save changes?" prompt.
-- Returns the (possibly new) ReaProject.
function M.reload(proj, path)
  local cur = reaper.EnumProjects(-1)
  local was_active = (cur == proj)
  reaper.SelectProjectInstance(proj)
  reaper.Main_openProject("noprompt:" .. path)
  local new_proj = reaper.EnumProjects(-1)
  if not was_active then reaper.SelectProjectInstance(cur) end
  M.log("Reloaded %s", M.basename(path))
  return new_proj
end

------------------------------------------------------------------------------
-- Merge another version into an open project
------------------------------------------------------------------------------
--
-- proj/path: the open project (we must hold its lock, or it must be unlocked).
-- other_path: the other version (a conflict copy, a "Save as" copy, ...).
-- opts.label: text appended to the names of conflict-copy tracks.
-- opts.remove_other: delete other_path afterwards (a backup is kept in history).
-- Returns report or nil, error.
function M.merge_into_project(proj, path, other_path, opts)
  opts = opts or {}
  local lock = M.read_lock(M.lock_path(path))
  if lock and not M.lock_is_mine(lock) and not M.lock_is_stale(lock) then
    return nil, ("%s is locked by %s. Take the lock before merging into it.")
      :format(M.basename(path), M.lock_owner_desc(lock))
  end

  if reaper.IsProjectDirty(proj) == 1 then
    reaper.Main_SaveProject(proj, false)
  end

  local ours = M.read_file(path)
  local theirs = M.read_file(other_path)
  if not ours then return nil, "could not read " .. path end
  if not theirs then return nil, "could not read " .. other_path end

  local base = rpp.pick_base(M.snapshot_texts(path), ours, theirs)
  local merged, report = rpp.merge(base, ours, theirs, { theirs_label = opts.label or "other version" })
  if not merged then return nil, report end

  -- Back up both inputs.
  M.snapshot(path, ours, "before-merge")
  local backup_other = M.snapshot(path, theirs, "merged-in")

  local ok, err = M.write_file(path, merged)
  if not ok then return nil, "could not write " .. path .. ": " .. tostring(err) end
  M.snapshot(path, merged, "merged")

  if opts.remove_other and backup_other then
    os.remove(other_path)
  end

  M.reload(proj, path)
  report.history_dir = M.history_dir(path)
  report.had_base = base ~= nil
  return report
end

function M.format_merge_report(report)
  local s = rpp.format_report(report)
  if not report.had_base then
    s = s .. "\n\n(No earlier version was found in local history, so nothing was treated as deleted.)"
  end
  if report.history_dir then
    s = s .. "\n\nBackups of both versions are in:\n" .. report.history_dir
  end
  return s
end

return M
