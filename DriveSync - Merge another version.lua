-- @description Drive Sync - Merge another version into the current project
-- @version 0.2.0
-- @author Colin Lee Campbell
-- @about
--   Pick another copy of the current project (a "Save as" copy you made while someone
--   else had the lock, a conflict copy, a version from another machine...) and merge it
--   into the current project track by track.
--
--   * Tracks changed in only one version are taken from that version.
--   * Tracks changed in both, but in different items, are merged item by item.
--   * Tracks with the same thing changed in both keep your version; the other version is
--     added as a muted track at the end, named "<track> (<file name>)".
--   * Project settings (tempo etc.) changed in both keep your version.
--   Your unsaved changes are saved first, and both versions are backed up to the local
--   history folder (REAPER resource path / DriveSync / history).

local script_path = select(2, reaper.get_action_context())
local script_dir = script_path:match("^(.*)[/\\]") or "."
package.path = script_dir .. "/lib/?.lua;" .. package.path
local ds = require("drivesync")
ds.SCRIPT_NAME = "Drive Sync - Merge"

local proj, path = reaper.EnumProjects(-1)
if path == "" then
  ds.msgbox("Save this project first. Merging works on saved projects.")
  return
end

local dir = ds.split_path(path)
local ok, other = reaper.GetUserFileNameForRead(dir .. "/", "Pick the version to merge into " .. ds.basename(path), ".rpp")
if not ok or other == "" then return end
if other == path then
  ds.msgbox("That's the current project. Pick a different version to merge in.")
  return
end

local label = ds.basename(other):gsub("%.[Rr][Pp][Pp]$", "")
local r = ds.msgbox(("Merge\n\n    %s\n\ninto the current project\n\n    %s ?\n\n" ..
  "Your unsaved changes will be saved first. Backups of both versions are kept.")
  :format(ds.basename(other), ds.basename(path)), 4)
if r ~= 6 then return end

local report, err = ds.merge_into_project(proj, path, other, { label = label })
if not report then
  ds.msgbox("Merge failed: " .. tostring(err))
  return
end
ds.msgbox("Merge finished.\n\n" .. ds.format_merge_report(report) ..
  "\n\nThe file you merged in was left where it was. Delete it once you're happy with the result.")
