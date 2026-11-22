#!/usr/bin/env lua
-- rppmerge - 3-way merge of REAPER project files from the command line.
--
--   lua tools/rppmerge.lua BASE.rpp OURS.rpp THEIRS.rpp OUT.rpp [--label "from laptop"]
--
-- BASE may be "-" if you have no common ancestor (then nothing is deleted;
-- everything that differs is treated as a conflict or an addition).
-- Exit code: 0 = clean merge, 1 = merged but needs review, 2 = error.

local script_dir = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
package.path = script_dir .. "/../lib/?.lua;" .. package.path
local rpp = require("rpp")

local function die(msg)
  io.stderr:write("rppmerge: " .. msg .. "\n")
  os.exit(2)
end

local function read(path)
  local f, err = io.open(path, "rb")
  if not f then die(err) end
  local s = f:read("*a")
  f:close()
  return s
end

local positional, label = {}, "theirs"
local i = 1
while arg[i] do
  if arg[i] == "--label" then
    label = arg[i + 1] or die("--label needs a value")
    i = i + 2
  elseif arg[i] == "-h" or arg[i] == "--help" then
    print("usage: rppmerge BASE.rpp|- OURS.rpp THEIRS.rpp OUT.rpp [--label TEXT]")
    os.exit(0)
  else
    positional[#positional + 1] = arg[i]
    i = i + 1
  end
end
if #positional ~= 4 then die("usage: rppmerge BASE.rpp|- OURS.rpp THEIRS.rpp OUT.rpp [--label TEXT]") end

local base = positional[1] ~= "-" and read(positional[1]) or nil
local merged, report = rpp.merge(base, read(positional[2]), read(positional[3]), { theirs_label = label })
if not merged then die(report) end

local f, err = io.open(positional[4], "wb")
if not f then die(err) end
f:write(merged)
f:close()

print(rpp.format_report(report))
os.exit(rpp.needs_review(report) and 1 or 0)
