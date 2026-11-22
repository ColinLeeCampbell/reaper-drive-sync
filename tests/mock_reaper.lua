-- A fake REAPER, enough to run the Drive Sync scripts outside REAPER.
-- Each "machine" gets its own environment (own reaper API, own clock, own
-- ExtState and resource folder) but they share the real filesystem, which
-- plays the role of the synced folder.

local Mock = {}

local function sh_quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

function Mock.read(path)
  local f = io.open(path, "rb"); if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end

function Mock.write(path, s)
  local f = assert(io.open(path, "wb")); f:write(s); f:close()
end

function Mock.exists(path)
  local f = io.open(path, "rb"); if f then f:close() return true end
  return false
end

function Mock.ls(dir)
  local out = {}
  local p = io.popen("ls -1 " .. sh_quote(dir) .. " 2>/dev/null")
  for line in p:lines() do out[#out + 1] = line end
  p:close()
  return out
end

-- shared clock for all machines (wall clock in seconds)
Mock.clock = 1800000000

function Mock.machine(name, opts)
  opts = opts or {}
  local m = {
    name = name,
    tabs = {},            -- { {path=, memory=, dirty=}, ... }
    active = nil,
    dialogs = {},         -- every message box shown: { text=, kind= }
    answers = {},         -- queue of answers for message boxes
    console = {},
    ext = { DriveSyncLock = { machine_id = "machine-" .. name } },
    resource = opts.resource,
    deferred = nil,
    atexit = nil,
  }
  os.execute("mkdir -p " .. sh_quote(m.resource))

  local listing = {}
  local R = {}
  m.reaper = R

  function R.get_action_context() return false, opts.script_path, 0, 4242 end
  function R.set_action_options() end
  function R.SetToggleCommandState() end
  function R.RefreshToolbar2() end
  function R.ShowConsoleMsg(s) m.console[#m.console + 1] = s end
  function R.time_precise() return Mock.clock end
  function R.defer(fn) m.deferred = fn end
  function R.atexit(fn) m.atexit = fn end
  function R.GetResourcePath() return m.resource end
  function R.RecursiveCreateDirectory(dir) os.execute("mkdir -p " .. sh_quote(dir)) return 1 end
  function R.GetExtState(sec, key) return (m.ext[sec] or {})[key] or "" end
  function R.SetExtState(sec, key, v) m.ext[sec] = m.ext[sec] or {}; m.ext[sec][key] = v end

  function R.EnumerateFiles(dir, i)
    if i < 0 then listing[dir] = Mock.ls(dir) return nil end
    listing[dir] = listing[dir] or Mock.ls(dir)
    return listing[dir][i + 1]
  end

  function R.EnumProjects(i)
    if i == -1 then
      if not m.active then return nil end
      return m.active, m.active.path
    end
    local t = m.tabs[i + 1]
    if not t then return nil end
    return t, t.path
  end

  function R.IsProjectDirty(p) return p.dirty and 1 or 0 end
  function R.SelectProjectInstance(p) m.active = p end

  function R.Main_OnCommand(cmd)
    if cmd == 40860 then -- close current tab
      for i, t in ipairs(m.tabs) do
        if t == m.active then table.remove(m.tabs, i) break end
      end
      m.active = m.tabs[1]
    end
  end

  function R.Main_openProject(spec)
    local path = spec:gsub("^noprompt:", "")
    m.active.path = path
    m.active.memory = Mock.read(path)
    m.active.dirty = false
  end

  function R.Main_SaveProject(p)
    p = p or m.active
    Mock.write(p.path, p.memory)
    p.dirty = false
  end

  function R.ShowMessageBox(text, title, kind)
    m.dialogs[#m.dialogs + 1] = { text = text, kind = kind }
    if kind == 0 then return 1 end
    local a = table.remove(m.answers, 1)
    if not a then error("unexpected dialog on machine " .. name .. ":\n" .. text, 2) end
    return a
  end

  -- environment in which scripts run
  local env = setmetatable({}, { __index = _G })
  env.reaper = R
  env.os = setmetatable({ time = function() return Mock.clock end }, { __index = os })
  env.package = { path = "", config = package.config }
  local loaded = {}
  env.require = function(mod)
    if loaded[mod] == nil then
      local f = assert(loadfile(opts.lib_dir .. "/" .. mod .. ".lua", "t", env))
      loaded[mod] = f() or true
    end
    return loaded[mod]
  end
  m.env = env

  ----------------------------------------------------------------------------
  -- helpers for tests
  function m.run(script) assert(loadfile(script, "t", env))() end
  function m.tick()
    Mock.clock = Mock.clock + 2
    local fn = m.deferred
    m.deferred = nil
    if fn then fn() end
  end
  function m.open(path)
    local t = { path = path, memory = Mock.read(path), dirty = false }
    m.tabs[#m.tabs + 1] = t
    m.active = t
    return t
  end
  function m.close(tab)
    m.active = tab
    R.Main_OnCommand(40860)
  end
  function m.edit(tab, newtext) tab.memory = newtext; tab.dirty = true end
  function m.save(tab) R.Main_SaveProject(tab) end
  function m.answer(...) for _, a in ipairs({ ... }) do m.answers[#m.answers + 1] = a end end
  function m.last_dialog() local d = m.dialogs[#m.dialogs]; return d and d.text or "" end
  function m.stop() if m.atexit then m.atexit() end m.deferred = nil end

  return m
end

return Mock
