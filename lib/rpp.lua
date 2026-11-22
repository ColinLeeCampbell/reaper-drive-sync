-- rpp.lua - parse, serialize and 3-way merge REAPER project (.rpp) files.
--
-- Pure Lua (5.3 / 5.4), no REAPER API, so it can be used both inside REAPER and
-- from the command line (tools/rppmerge.lua) and tests.
--
-- An .rpp file is a tree of chunks:
--
--   <REAPER_PROJECT 0.1 "7.22/linux-x86_64" 1732000000
--     TEMPO 120 4 4
--     <TRACK {GUID}
--       NAME "Bass"
--       TRACKID {GUID}
--       <ITEM
--         POSITION 0
--         IGUID {GUID}
--         ...
--       >
--     >
--   >
--
-- A node is { header = "<TRACK {GUID}" (without the "<"), children = { line | node, ... } }.
-- Lines are stored with leading indentation and trailing "\r" removed.
-- Serializing re-indents with 2 spaces per level, which is what REAPER writes.

local M = {}

------------------------------------------------------------------------------
-- Parse / serialize
------------------------------------------------------------------------------

function M.parse(text)
  local root = { header = nil, children = {} }
  local stack = { root }
  for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
    local line = raw:gsub("\r$", ""):gsub("^%s+", "")
    if line ~= "" then
      local top = stack[#stack]
      if line:sub(1, 1) == "<" then
        local node = { header = line:sub(2), children = {} }
        top.children[#top.children + 1] = node
        stack[#stack + 1] = node
      elseif line == ">" and #stack > 1 then
        stack[#stack] = nil
      else
        top.children[#top.children + 1] = line
      end
    end
  end
  if #stack ~= 1 then
    return nil, ("unbalanced chunks: %d not closed"):format(#stack - 1)
  end
  -- The project itself is normally the single top-level chunk.
  if #root.children == 1 and type(root.children[1]) == "table" then
    return root.children[1]
  end
  return nil, "not a REAPER project (expected a single <REAPER_PROJECT chunk)"
end

local function serialize_into(node, depth, out)
  local indent = ("  "):rep(depth)
  out[#out + 1] = indent .. "<" .. node.header
  for _, c in ipairs(node.children) do
    if type(c) == "table" then
      serialize_into(c, depth + 1, out)
    else
      out[#out + 1] = indent .. "  " .. c
    end
  end
  out[#out + 1] = indent .. ">"
end

-- Serialize a node (or a single line) to text. `newline` defaults to "\n".
function M.serialize(node, newline)
  if type(node) == "string" then return node end
  local out = {}
  serialize_into(node, 0, out)
  return table.concat(out, newline or "\n") .. (newline or "\n")
end

-- Canonical text used for equality checks (independent of indentation / CRLF).
local function canon(elem)
  if elem == nil then return nil end
  if type(elem) == "string" then return elem end
  if not elem._canon then elem._canon = M.serialize(elem, "\n") end
  return elem._canon
end
M.canon = canon

------------------------------------------------------------------------------
-- Helpers for identifying elements
------------------------------------------------------------------------------

local function first_token(s)
  return s:match("^(%S+)") or ""
end

local function chunk_name(node)
  return first_token(node.header)
end

-- Find the first child line starting with `token ` and return the rest.
local function child_value(node, token)
  local pat = "^" .. token:gsub("%p", "%%%0") .. "%s+(.*)$"
  for _, c in ipairs(node.children) do
    if type(c) == "string" then
      local v = c:match(pat)
      if v then return v end
    end
  end
  return nil
end
M.child_value = child_value

function M.track_guid(node)
  local g = child_value(node, "TRACKID") or node.header:match("^TRACK%s+({[^}]+})")
  return g
end

function M.item_guid(node)
  return child_value(node, "IGUID") or child_value(node, "GUID")
end

function M.track_name(node)
  local n = child_value(node, "NAME")
  if not n then return "(unnamed)" end
  return (n:gsub('^"(.*)"$', "%1"))
end

-- The first take's name is the NAME line directly inside the ITEM chunk.
function M.item_name(node)
  local n = child_value(node, "NAME")
  return n and (n:gsub('^"(.*)"$', "%1")) or "(unnamed item)"
end

-- Build keys for a list of children. GUID-identified chunks get stable keys;
-- everything else is keyed by its first token plus an occurrence counter, so
-- e.g. the 2nd "MARKER 3" line is "L:MARKER 3#2".
local function make_keys(children, guid_chunks)
  local keys, counts = {}, {}
  for i, c in ipairs(children) do
    local base
    if type(c) == "table" then
      local name = chunk_name(c)
      local getter = guid_chunks[name]
      local guid = getter and getter(c)
      if guid then
        base = "G:" .. name .. guid
      else
        base = "C:" .. name
      end
    else
      local tok = first_token(c)
      if tok == "MARKER" then
        tok = tok .. " " .. (c:match("^MARKER%s+(%S+)") or "")
      end
      base = "L:" .. tok
    end
    counts[base] = (counts[base] or 0) + 1
    keys[i] = (base:sub(1, 2) == "G:") and base or (base .. "#" .. counts[base])
  end
  return keys
end

------------------------------------------------------------------------------
-- GUID regeneration (used when duplicating a track as a "conflict copy")
------------------------------------------------------------------------------

local random_seeded = false
local function new_guid()
  if not random_seeded then
    math.randomseed(os.time() + math.floor((os.clock() * 1e6) % 1e6))
    random_seeded = true
  end
  local function hex(n)
    local t = {}
    for i = 1, n do t[i] = ("%X"):format(math.random(0, 15)) end
    return table.concat(t)
  end
  return ("{%s-%s-%s-%s-%s}"):format(hex(8), hex(4), hex(4), hex(4), hex(12))
end
M.new_guid = new_guid

local GUID_PAT = "{%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x}"

local function deep_copy_new_guids(node, map)
  map = map or {}
  local function fix(s)
    return (s:gsub(GUID_PAT, function(g)
      local u = g:upper()
      if not map[u] then map[u] = new_guid() end
      return map[u]
    end))
  end
  local copy = { header = fix(node.header), children = {} }
  for i, c in ipairs(node.children) do
    if type(c) == "table" then
      copy.children[i] = deep_copy_new_guids(c, map)
    else
      copy.children[i] = fix(c)
    end
  end
  return copy
end

-- Turn a track into a muted, top-level, clearly-labelled copy with fresh GUIDs.
local function make_conflict_copy(track, label)
  local copy = deep_copy_new_guids(track)
  for i, c in ipairs(copy.children) do
    if type(c) == "string" then
      local tok = first_token(c)
      if tok == "NAME" then
        local name = c:match('^NAME%s+"(.*)"$') or c:match("^NAME%s+(.*)$") or ""
        copy.children[i] = ('NAME "%s (%s)"'):format(name:gsub('"', "'"), label)
      elseif tok == "ISBUS" then
        copy.children[i] = "ISBUS 0 0" -- never open or close a folder
      elseif tok == "MUTESOLO" then
        copy.children[i] = c:gsub("^MUTESOLO%s+%S+", "MUTESOLO 1") -- muted
      end
    end
  end
  return copy
end

------------------------------------------------------------------------------
-- 3-way merge of a list of children
------------------------------------------------------------------------------
--
-- For every key present in base (b), ours (o) or theirs (t):
--   o == t           -> take it (same change on both sides, or nobody changed it)
--   o == b           -> only theirs changed: take theirs (including deletion)
--   t == b           -> only ours changed: take ours (including deletion)
--   otherwise        -> conflict, handled by `on_conflict(key, b, o, t)` which
--                       returns the element to keep (or nil) plus optional extras
--
-- Order: ours' order, with elements that exist only in theirs inserted right
-- after their nearest preceding neighbour in theirs.

local function merge_children(b_list, o_list, t_list, guid_chunks, on_conflict)
  local bk = make_keys(b_list, guid_chunks)
  local ok = make_keys(o_list, guid_chunks)
  local tk = make_keys(t_list, guid_chunks)

  local B, O, T = {}, {}, {}
  for i, k in ipairs(bk) do B[k] = b_list[i] end
  for i, k in ipairs(ok) do O[k] = o_list[i] end
  for i, k in ipairs(tk) do T[k] = t_list[i] end

  local result = {}   -- key -> chosen element (absent = deleted)
  local extras = {}   -- elements appended at the end (conflict copies)

  local function decide(k)
    if result[k] ~= nil then return end
    local b, o, t = B[k], O[k], T[k]
    local cb, co, ct = canon(b), canon(o), canon(t)
    if co == ct then
      result[k] = o or false
    elseif co == cb then
      result[k] = t or false
    elseif ct == cb then
      result[k] = o or false
    else
      local keep, extra = on_conflict(k, b, o, t)
      result[k] = keep or false
      if extra then extras[#extras + 1] = extra end
    end
  end

  for _, k in ipairs(ok) do decide(k) end
  for _, k in ipairs(tk) do decide(k) end
  for _, k in ipairs(bk) do decide(k) end

  -- Ordering
  local order = {}
  local placed = {}
  for _, k in ipairs(ok) do
    if result[k] then order[#order + 1] = k; placed[k] = true end
  end
  for i, k in ipairs(tk) do
    if result[k] and not placed[k] then
      -- find nearest preceding key from theirs that is already placed
      local pos = 0
      for j = i - 1, 1, -1 do
        local pk = tk[j]
        if placed[pk] then
          for idx, ek in ipairs(order) do
            if ek == pk then pos = idx break end
          end
          break
        end
      end
      table.insert(order, pos + 1, k)
      placed[k] = true
    end
  end

  local merged = {}
  for _, k in ipairs(order) do merged[#merged + 1] = result[k] end
  return merged, extras
end

------------------------------------------------------------------------------
-- Public merge
------------------------------------------------------------------------------

local TRACK_CHUNKS = { ITEM = M.item_guid }
local PROJECT_CHUNKS = { TRACK = M.track_guid }

local function describe_key(k)
  return (k:gsub("^[LCG]:", ""):gsub("#1$", ""))
end

-- Merge one track that was changed on both sides. Returns merged track and the
-- number of unresolved conflicts inside it.
local function merge_track(b, o, t, report, tname)
  local unresolved = 0
  local function on_conflict(k, cb, co, ct)
    if co and ct then
      unresolved = unresolved + 1
      return co
    end
    -- deleted on one side, changed on the other: keep the changed one
    local kept = co or ct
    if type(kept) == "table" and chunk_name(kept) == "ITEM" then
      report.notes[#report.notes + 1] = ('Track "%s": item "%s" was deleted on one side and edited on the other; kept the edited item')
        :format(tname, M.item_name(kept))
    else
      report.notes[#report.notes + 1] = ('Track "%s": "%s" was deleted on one side and edited on the other; kept the edited version')
        :format(tname, describe_key(k))
    end
    return kept
  end
  local children = merge_children(b and b.children or {}, o.children, t.children, TRACK_CHUNKS, on_conflict)
  local header = (canon(o.header) == (b and b.header)) and t.header or o.header
  return { header = header, children = children }, unresolved
end

-- 3-way merge. All three arguments are .rpp text (base may be nil: then the merge
-- treats every difference as a conflict). Returns merged_text, report where
--   report.taken_theirs  = list of track names taken from theirs
--   report.merged_tracks = list of track names merged item-by-item
--   report.conflict_tracks = list of track names with conflicts (theirs added as muted copy)
--   report.project_conflicts = list of project settings where ours was kept
--   report.notes = list of human-readable notes
function M.merge(base_text, ours_text, theirs_text, opts)
  opts = opts or {}
  local label = opts.theirs_label or "theirs"
  local o, err = M.parse(ours_text)
  if not o then return nil, "ours: " .. err end
  local t, err2 = M.parse(theirs_text)
  if not t then return nil, "theirs: " .. err2 end
  local b = { header = o.header, children = {} }
  if base_text then
    local pb, err3 = M.parse(base_text)
    if not pb then return nil, "base: " .. err3 end
    b = pb
  end

  local report = {
    taken_theirs = {}, merged_tracks = {}, conflict_tracks = {},
    added_theirs = {}, deleted_by_theirs = {},
    project_conflicts = {}, notes = {},
  }

  local function on_conflict(k, cb, co, ct)
    if co and ct and type(co) == "table" and chunk_name(co) == "TRACK" then
      local name = M.track_name(co)
      local merged, unresolved = merge_track(cb, co, ct, report, name)
      if unresolved == 0 then
        report.merged_tracks[#report.merged_tracks + 1] = name
        return merged
      end
      report.conflict_tracks[#report.conflict_tracks + 1] = name
      return merged, make_conflict_copy(ct, label)
    end
    if co and ct then
      report.project_conflicts[#report.project_conflicts + 1] = describe_key(k)
      return co
    end
    local kept = co or ct
    if type(kept) == "table" and chunk_name(kept) == "TRACK" then
      report.notes[#report.notes + 1] = ('Track "%s" was deleted on one side and edited on the other; kept it')
        :format(M.track_name(kept))
    else
      report.notes[#report.notes + 1] = ('Project setting "%s" was deleted on one side and edited on the other; kept the edited version')
        :format(describe_key(k))
    end
    return kept
  end

  local children, extras = merge_children(b.children, o.children, t.children, PROJECT_CHUNKS, on_conflict)

  -- Conflict copies go at the end of the track list (after the last TRACK).
  if #extras > 0 then
    local last_track = 0
    for i, c in ipairs(children) do
      if type(c) == "table" and chunk_name(c) == "TRACK" then last_track = i end
    end
    for j, e in ipairs(extras) do
      table.insert(children, last_track + j, e)
    end
  end

  -- Fill in report for tracks that came over cleanly from theirs.
  local function track_map(node)
    local m = {}
    for _, c in ipairs(node.children) do
      if type(c) == "table" and chunk_name(c) == "TRACK" then
        local g = M.track_guid(c)
        if g then m[g] = c end
      end
    end
    return m
  end
  local bm, om, tm = track_map(b), track_map(o), track_map(t)
  local mm = track_map({ children = children })
  for g, tr in pairs(tm) do
    if mm[g] and canon(mm[g]) == canon(tr) and canon(om[g]) ~= canon(tr) then
      if om[g] then
        report.taken_theirs[#report.taken_theirs + 1] = M.track_name(tr)
      else
        report.added_theirs[#report.added_theirs + 1] = M.track_name(tr)
      end
    end
  end
  for g, tr in pairs(om) do
    if not mm[g] and bm[g] then
      report.deleted_by_theirs[#report.deleted_by_theirs + 1] = M.track_name(tr)
    end
  end
  for _, list in pairs(report) do table.sort(list) end

  local merged = { header = o.header, children = children }
  local newline = ours_text:find("\r\n", 1, true) and "\r\n" or "\n"
  return M.serialize(merged, newline), report
end

-- Human-readable summary of a merge report.
function M.format_report(report)
  local lines = {}
  local function section(title, list)
    if #list > 0 then
      lines[#lines + 1] = title
      for _, v in ipairs(list) do lines[#lines + 1] = "  - " .. v end
    end
  end
  section("Tracks updated from the other version:", report.taken_theirs)
  section("Tracks added from the other version:", report.added_theirs)
  section("Tracks deleted in the other version:", report.deleted_by_theirs)
  section("Tracks merged item by item:", report.merged_tracks)
  section("Tracks edited on both sides (the other version was added as a muted copy at the end):", report.conflict_tracks)
  section("Project settings changed on both sides (kept yours):", report.project_conflicts)
  section("Notes:", report.notes)
  if #lines == 0 then lines[1] = "No differences to merge." end
  return table.concat(lines, "\n")
end

-- Has the merge left anything the user should look at?
function M.needs_review(report)
  return #report.conflict_tracks > 0 or #report.project_conflicts > 0 or #report.notes > 0
end

-- Score how similar two projects are (number of identical top-level children).
-- Used to guess the common ancestor of a conflict copy from local history.
function M.similarity(a_text, b_text)
  local a, b = M.parse(a_text), M.parse(b_text)
  if not a or not b then return -1 end
  local ka = make_keys(a.children, PROJECT_CHUNKS)
  local kb = make_keys(b.children, PROJECT_CHUNKS)
  local A = {}
  for i, k in ipairs(ka) do A[k] = canon(a.children[i]) end
  local score = 0
  for i, k in ipairs(kb) do
    if A[k] and A[k] == canon(b.children[i]) then score = score + 1 end
  end
  return score
end

-- Pick the best common ancestor for merging `ours` and `theirs` from a list of
-- candidate texts (e.g. local history snapshots): the one that shares the most
-- unchanged elements with both versions.
function M.pick_base(candidates, ours_text, theirs_text)
  local best, best_score = nil, -1
  for _, c in ipairs(candidates) do
    local s = math.min(M.similarity(c, ours_text), M.similarity(c, theirs_text))
    if s > best_score then best, best_score = c, s end
  end
  return best
end

return M
