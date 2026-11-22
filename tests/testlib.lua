-- Minimal test helper.
local T = { passed = 0, failed = 0 }

function T.test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    T.passed = T.passed + 1
    print("  ok   " .. name)
  else
    T.failed = T.failed + 1
    print("  FAIL " .. name .. "\n       " .. tostring(err))
  end
end

local function show(v)
  if type(v) == "string" then return ("%q"):format(v) end
  return tostring(v)
end

function T.eq(a, b, msg)
  if a ~= b then
    error((msg and (msg .. ": ") or "") .. "expected " .. show(b) .. ", got " .. show(a), 2)
  end
end

function T.truthy(v, msg) if not v then error(msg or "expected truthy", 2) end end
function T.falsy(v, msg) if v then error(msg or ("expected falsy, got " .. show(v)), 2) end end

function T.done()
  print(("%d passed, %d failed"):format(T.passed, T.failed))
  os.exit(T.failed == 0 and 0 or 1)
end

return T
