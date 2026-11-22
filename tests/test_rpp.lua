-- Run from the repo root:  lua tests/test_rpp.lua
package.path = "./lib/?.lua;./tests/?.lua;" .. package.path
local rpp = require("rpp")
local T = require("testlib")

local function track(guid, name, body)
  return ([[
  <TRACK %s
    NAME "%s"
    MUTESOLO 0 0 0
    ISBUS 0 0
    TRACKID %s
%s  >
]]):format(guid, name, guid, body or "")
end

local function item(guid, name, pos)
  return ([[
    <ITEM
      POSITION %s
      LENGTH 4
      IGUID %s
      NAME "%s"
      <SOURCE WAVE
        FILE "Media/%s.wav"
      >
    >
]]):format(pos, guid, name, name)
end

local G = {
  t1 = "{11111111-1111-1111-1111-111111111111}",
  t2 = "{22222222-2222-2222-2222-222222222222}",
  t3 = "{33333333-3333-3333-3333-333333333333}",
  i1 = "{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}",
  i2 = "{BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB}",
  i3 = "{CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC}",
}

local function project(tempo, tracks)
  return ('<REAPER_PROJECT 0.1 "7.22/linux-x86_64" 1732000000\n  TEMPO %s 4 4\n%s>\n')
    :format(tempo, table.concat(tracks))
end

local function names_in_order(text)
  local p = assert(rpp.parse(text))
  local out = {}
  for _, c in ipairs(p.children) do
    if type(c) == "table" and c.header:match("^TRACK") then out[#out + 1] = rpp.track_name(c) end
  end
  return table.concat(out, ",")
end

local function find_track(text, name)
  local p = assert(rpp.parse(text))
  for _, c in ipairs(p.children) do
    if type(c) == "table" and c.header:match("^TRACK") and rpp.track_name(c) == name then return c end
  end
end

local base = project(120, {
  track(G.t1, "Drums", item(G.i1, "kick", 0)),
  track(G.t2, "Bass", item(G.i2, "bassline", 0)),
})

T.test("parse/serialize round trip", function()
  local p = assert(rpp.parse(base))
  T.eq(rpp.serialize(p), base)
end)

T.test("CRLF files round trip and merge keeps CRLF", function()
  local crlf = base:gsub("\n", "\r\n")
  local p = assert(rpp.parse(crlf))
  T.eq(rpp.serialize(p, "\r\n"), crlf)
  local merged = assert(rpp.merge(crlf, crlf, crlf))
  T.eq(merged, crlf)
end)

T.test("rejects non-projects", function()
  T.eq(rpp.parse("hello"), nil)
  T.eq(rpp.parse("<REAPER_PROJECT\n<TRACK\n>"), nil)
end)

T.test("different tracks edited on each side merge cleanly", function()
  local ours = project(120, {
    track(G.t1, "Drums", item(G.i1, "kick", 0) .. item(G.i3, "snare", 8)),
    track(G.t2, "Bass", item(G.i2, "bassline", 0)),
  })
  local theirs = project(120, {
    track(G.t1, "Drums", item(G.i1, "kick", 0)),
    track(G.t2, "Bass Guitar", item(G.i2, "bassline", 0)),
  })
  local merged, report = assert(rpp.merge(base, ours, theirs))
  T.eq(names_in_order(merged), "Drums,Bass Guitar")
  T.truthy(merged:find("snare", 1, true), "ours' new item kept")
  T.eq(report.taken_theirs[1], "Bass Guitar")
  T.falsy(rpp.needs_review(report))
end)

T.test("same track, different items edited -> item-level merge", function()
  local ours = project(120, {
    track(G.t1, "Drums", item(G.i1, "kick", 2)),
    track(G.t2, "Bass", item(G.i2, "bassline", 0)),
  })
  local theirs = project(120, {
    track(G.t1, "Drums", item(G.i1, "kick", 0) .. item(G.i3, "hat", 16)),
    track(G.t2, "Bass", item(G.i2, "bassline", 0)),
  })
  local merged, report = assert(rpp.merge(base, ours, theirs))
  local drums = find_track(merged, "Drums")
  local text = rpp.serialize(drums)
  T.truthy(text:find("POSITION 2", 1, true), "ours moved kick")
  T.truthy(text:find('"hat"', 1, true), "theirs added hat")
  T.eq(report.merged_tracks[1], "Drums")
  T.falsy(rpp.needs_review(report))
end)

T.test("same item edited on both sides -> conflict copy of theirs, muted, fresh GUIDs", function()
  local ours = project(120, {
    track(G.t1, "Drums", item(G.i1, "kick", 2)),
    track(G.t2, "Bass", item(G.i2, "bassline", 0)),
  })
  local theirs = project(120, {
    track(G.t1, "Drums", item(G.i1, "kick", 5)),
    track(G.t2, "Bass", item(G.i2, "bassline", 0)),
  })
  local merged, report = assert(rpp.merge(base, ours, theirs, { theirs_label = "from laptop" }))
  T.eq(names_in_order(merged), "Drums,Bass,Drums (from laptop)")
  T.eq(report.conflict_tracks[1], "Drums")
  T.truthy(rpp.needs_review(report))
  local copy = find_track(merged, "Drums (from laptop)")
  T.eq(rpp.child_value(copy, "MUTESOLO"), "1 0 0")
  T.truthy(rpp.track_guid(copy) ~= G.t1, "copy has a new track GUID")
  T.falsy(rpp.serialize(copy):find(G.i1, 1, true), "copy has new item GUIDs")
  T.truthy(rpp.serialize(copy):find("POSITION 5", 1, true), "copy holds theirs' edit")
  T.truthy(rpp.serialize(find_track(merged, "Drums")):find("POSITION 2", 1, true), "original holds ours")
end)

T.test("track added on theirs is inserted after its neighbour", function()
  local theirs = project(120, {
    track(G.t1, "Drums", item(G.i1, "kick", 0)),
    track(G.t3, "Keys"),
    track(G.t2, "Bass", item(G.i2, "bassline", 0)),
  })
  local merged, report = assert(rpp.merge(base, base, theirs))
  T.eq(names_in_order(merged), "Drums,Keys,Bass")
  T.eq(report.added_theirs[1], "Keys")
end)

T.test("tracks added on both sides are both kept", function()
  local ours = project(120, {
    track(G.t1, "Drums", item(G.i1, "kick", 0)),
    track(G.t2, "Bass", item(G.i2, "bassline", 0)),
    track("{44444444-4444-4444-4444-444444444444}", "Vox"),
  })
  local theirs = project(120, {
    track(G.t1, "Drums", item(G.i1, "kick", 0)),
    track(G.t2, "Bass", item(G.i2, "bassline", 0)),
    track(G.t3, "Keys"),
  })
  local merged = assert(rpp.merge(base, ours, theirs))
  T.eq(names_in_order(merged), "Drums,Bass,Keys,Vox")
end)

T.test("track deleted on theirs is deleted", function()
  local theirs = project(120, { track(G.t1, "Drums", item(G.i1, "kick", 0)) })
  local merged, report = assert(rpp.merge(base, base, theirs))
  T.eq(names_in_order(merged), "Drums")
  T.eq(report.deleted_by_theirs[1], "Bass")
end)

T.test("deleted on one side, edited on the other -> keep edited", function()
  local ours = project(120, {
    track(G.t1, "Drums", item(G.i1, "kick", 0)),
    track(G.t2, "Bass", item(G.i2, "bassline", 3)),
  })
  local theirs = project(120, { track(G.t1, "Drums", item(G.i1, "kick", 0)) })
  local merged, report = assert(rpp.merge(base, ours, theirs))
  T.eq(names_in_order(merged), "Drums,Bass")
  T.truthy(rpp.needs_review(report))
end)

T.test("project setting changed on both sides keeps ours and reports it", function()
  local merged, report = assert(rpp.merge(base, (base:gsub("TEMPO 120", "TEMPO 128")), (base:gsub("TEMPO 120", "TEMPO 90"))))
  T.truthy(merged:find("TEMPO 128", 1, true))
  T.eq(report.project_conflicts[1], "TEMPO")
end)

T.test("project setting changed on one side only is taken", function()
  local merged = assert(rpp.merge(base, base, (base:gsub("TEMPO 120", "TEMPO 90"))))
  T.truthy(merged:find("TEMPO 90", 1, true))
end)

T.test("pick_base chooses the real ancestor from history", function()
  local v2 = project(120, {
    track(G.t1, "Drums", item(G.i1, "kick", 0) .. item(G.i3, "snare", 8)),
    track(G.t2, "Bass", item(G.i2, "bassline", 0)),
  })
  local ours = project(120, {
    track(G.t1, "Drums", item(G.i1, "kick", 0) .. item(G.i3, "snare", 8)),
    track(G.t2, "Bass", item(G.i2, "bassline", 4)),
  })
  local theirs = project(140, {
    track(G.t1, "Drums", item(G.i1, "kick", 0) .. item(G.i3, "snare", 8)),
    track(G.t2, "Bass", item(G.i2, "bassline", 0)),
  })
  T.eq(rpp.pick_base({ ours, v2, base }, ours, theirs), v2)
end)

T.test("format_report lists sections", function()
  local _, report = assert(rpp.merge(base, (base:gsub("TEMPO 120", "TEMPO 128")), (base:gsub("TEMPO 120", "TEMPO 90"))))
  T.truthy(rpp.format_report(report):find("Project settings changed on both sides", 1, true))
end)

T.done()
