-- End-to-end tests of DriveSyncLock.lua with two simulated machines sharing a folder.
-- Run from the repo root:  lua tests/test_lock.lua
package.path = "./lib/?.lua;./tests/?.lua;" .. package.path
local T = require("testlib")
local Mock = require("mock_reaper")

local ROOT = os.getenv("TMPDIR_TEST") or ("/tmp/drivesync-test-" .. os.time())
local SCRIPT = "./DriveSyncLock.lua"
local MERGE_SCRIPT = "./DriveSync - Merge another version.lua"

local function project(tempo, body)
  return ('<REAPER_PROJECT 0.1 "7.22/linux-x86_64" 1732000000\n  TEMPO %s 4 4\n%s>\n'):format(tempo, body or "")
end
local function track(n, name, extra)
  local g = ("{%08d-0000-0000-0000-000000000000}"):format(n)
  return ('  <TRACK %s\n    NAME "%s"\n    MUTESOLO 0 0 0\n    ISBUS 0 0\n    TRACKID %s\n%s  >\n'):format(g, name, g, extra or "")
end

local case = 0
local function setup()
  case = case + 1
  local dir = ("%s/case%d"):format(ROOT, case)
  os.execute("mkdir -p '" .. dir .. "/shared'")
  local song = dir .. "/shared/song.rpp"
  Mock.write(song, project(120, track(1, "Drums") .. track(2, "Bass")))
  local function mk(name)
    return Mock.machine(name, { resource = dir .. "/res-" .. name, script_path = "./DriveSyncLock.lua", lib_dir = "./lib" })
  end
  return mk("A"), mk("B"), song, dir
end

local function lock_owner(song)
  local s = Mock.read(song .. ".lock")
  return s and s:match("machine=([^\n]+)")
end

T.test("opening a free project takes the lock; closing releases it", function()
  local A, _, song = setup()
  A.run(SCRIPT)
  local tab = A.open(song)
  A.tick()
  T.eq(lock_owner(song), "machine-A")
  A.close(tab)
  A.tick()
  T.eq(lock_owner(song), nil)
end)

T.test("second machine is warned, can view, gets reload prompt, then the lock", function()
  local A, B, song = setup()
  A.run(SCRIPT); B.run(SCRIPT)
  local ta = A.open(song); A.tick()

  B.answer(6) -- view only
  local tb = B.open(song); B.tick()
  T.truthy(B.last_dialog():find("is being edited by", 1, true))
  T.eq(lock_owner(song), "machine-A")

  -- A edits and saves
  A.edit(ta, project(128, track(1, "Drums") .. track(2, "Bass")))
  A.save(ta); A.tick()

  B.answer(6) -- reload
  B.tick()
  T.truthy(B.last_dialog():find("was updated by", 1, true))
  T.truthy(tb.memory:find("TEMPO 128", 1, true), "B reloaded A's version")

  -- A closes; B is offered the lock
  A.close(ta); A.tick()
  B.answer(6)
  B.tick()
  T.truthy(B.last_dialog():find("no longer locked", 1, true))
  T.eq(lock_owner(song), "machine-B")
end)

T.test("cancel closes the project on the second machine", function()
  local A, B, song = setup()
  A.run(SCRIPT); B.run(SCRIPT)
  A.open(song); A.tick()
  B.answer(2)
  B.open(song); B.tick()
  T.eq(#B.tabs, 0)
  B.tick() -- no further dialogs, no errors
  T.eq(lock_owner(song), "machine-A")
end)

T.test("stale locks can be taken over", function()
  local A, B, song = setup()
  A.run(SCRIPT)
  A.open(song); A.tick()
  A.deferred = nil -- A "crashes": no more heartbeats, lock left behind
  Mock.clock = Mock.clock + 20 * 60
  B.run(SCRIPT)
  B.answer(6)
  B.open(song); B.tick()
  T.truthy(B.last_dialog():find("hasn't been refreshed", 1, true))
  T.eq(lock_owner(song), "machine-B")
end)

T.test("heartbeat keeps the lock fresh", function()
  local A, B, song = setup()
  A.run(SCRIPT)
  A.open(song); A.tick()
  for _ = 1, 600 do A.tick() end -- 20 minutes of ticks
  B.run(SCRIPT)
  B.answer(6) -- view only
  B.open(song); B.tick()
  T.truthy(B.last_dialog():find("is being edited by", 1, true), "lock is not stale")
end)

T.test("taking over the lock warns the previous owner", function()
  local A, B, song = setup()
  A.run(SCRIPT); B.run(SCRIPT)
  A.open(song); A.tick()
  B.answer(7) -- take over
  B.open(song); B.tick()
  T.eq(lock_owner(song), "machine-B")
  A.tick()
  T.truthy(A.last_dialog():find("took over the lock", 1, true))
  -- A must not re-write its lock afterwards
  for _ = 1, 40 do A.tick() end
  T.eq(lock_owner(song), "machine-B")
end)

T.test("saving without the lock warns", function()
  local A, B, song = setup()
  A.run(SCRIPT); B.run(SCRIPT)
  A.open(song); A.tick()
  B.answer(6)
  local tb = B.open(song); B.tick()
  B.edit(tb, project(99, track(1, "Drums"))); B.tick()
  B.save(tb); B.tick()
  T.truthy(B.last_dialog():find("without holding its lock", 1, true))
end)

T.test("conflict copy is merged track by track and removed", function()
  local A, _, song, dir = setup()
  A.run(SCRIPT)
  local ta = A.open(song); A.tick()
  -- A renames Drums and saves
  A.edit(ta, project(120, track(1, "Drums") .. track(2, "Bass Guitar")))
  A.save(ta); A.tick()
  -- a conflict copy appears where the other machine renamed Drums from the original
  Mock.write(dir .. "/shared/song (1).rpp", project(120, track(1, "Kit") .. track(2, "Bass")))
  A.answer(6) -- merge
  for _ = 1, 16 do A.tick() end -- wait for the conflict scan
  T.truthy(A.last_dialog():find("Merge finished", 1, true), A.last_dialog())
  local merged = Mock.read(song)
  T.truthy(merged:find('NAME "Kit"', 1, true), "theirs' rename")
  T.truthy(merged:find('NAME "Bass Guitar"', 1, true), "ours' rename")
  T.falsy(Mock.exists(dir .. "/shared/song (1).rpp"), "conflict copy removed")
  T.eq(ta.memory, merged, "project reloaded with the merge")
  -- history holds backups
  local hist = Mock.ls(A.resource .. "/DriveSync/history")
  T.eq(#hist, 1)
  local snaps = table.concat(Mock.ls(A.resource .. "/DriveSync/history/" .. hist[1]), ",")
  T.truthy(snaps:find("merged-in", 1, true), snaps)
  -- the merge counts as our own save: no "updated by" prompt afterwards
  local n = #A.dialogs
  for _ = 1, 20 do A.tick() end
  T.eq(#A.dialogs, n)
end)

T.test("viewer is told about conflict copies but not offered a merge", function()
  local A, B, song, dir = setup()
  A.run(SCRIPT); B.run(SCRIPT)
  A.open(song); A.tick()
  B.answer(6)
  B.open(song); B.tick()
  Mock.write(dir .. "/shared/song (1).rpp", project(120, track(1, "Kit")))
  A.answer(7) -- A declines the merge
  for _ = 1, 16 do A.tick(); B.tick() end
  T.truthy(B.last_dialog():find("Once you hold the lock", 1, true), B.last_dialog())
end)

T.test("merge action merges a save-as copy into the current project", function()
  local A, _, song, dir = setup()
  A.run(SCRIPT)
  local ta = A.open(song); A.tick()
  local mine = dir .. "/shared/song-mine.rpp"
  Mock.write(mine, project(120, track(1, "Drums") .. track(2, "Bass") .. track(3, "Vox")))
  A.reaper.GetUserFileNameForRead = function() return true, mine end
  A.answer(6)
  A.run(MERGE_SCRIPT)
  T.truthy(A.last_dialog():find("Merge finished", 1, true), A.last_dialog())
  T.truthy(ta.memory:find('NAME "Vox"', 1, true))
  T.truthy(Mock.exists(mine), "merged-in file is left in place")
end)

T.test("merge action refuses when someone else holds the lock", function()
  local A, B, song, dir = setup()
  A.run(SCRIPT); B.run(SCRIPT)
  A.open(song); A.tick()
  B.answer(6)
  B.open(song); B.tick()
  local other = dir .. "/shared/other.rpp"
  Mock.write(other, project(120, track(1, "Drums")))
  B.reaper.GetUserFileNameForRead = function() return true, other end
  B.answer(6)
  B.run(MERGE_SCRIPT)
  T.truthy(B.last_dialog():find("is locked by", 1, true), B.last_dialog())
end)

T.test("stopping the script releases all locks", function()
  local A, _, song, dir = setup()
  local song2 = dir .. "/shared/song2.rpp"
  Mock.write(song2, project(100))
  A.run(SCRIPT)
  A.open(song); A.open(song2); A.tick()
  T.eq(lock_owner(song), "machine-A"); T.eq(lock_owner(song2), "machine-A")
  A.stop()
  T.eq(lock_owner(song), nil); T.eq(lock_owner(song2), nil)
end)

T.test("save-as moves the lock to the new file", function()
  local A, _, song, dir = setup()
  A.run(SCRIPT)
  local ta = A.open(song); A.tick()
  ta.path = dir .. "/shared/song-v2.rpp"
  Mock.write(ta.path, ta.memory)
  A.tick()
  T.eq(lock_owner(song), nil)
  T.eq(lock_owner(ta.path), "machine-A")
end)

T.test("history is pruned to MAX_HISTORY snapshots", function()
  local A, _, song = setup()
  A.run(SCRIPT)
  local ta = A.open(song); A.tick()
  for i = 1, 40 do
    A.edit(ta, project(100 + i, track(1, "Drums")))
    A.save(ta); A.tick()
  end
  local hist = Mock.ls(A.resource .. "/DriveSync/history")
  T.eq(#Mock.ls(A.resource .. "/DriveSync/history/" .. hist[1]), 30)
end)

os.execute("rm -rf '" .. ROOT .. "'")
T.done()
