-- Smoke test for mod/lua/ge/extensions/beamai/core.lua: does the module load
-- cleanly (correct syntax, requires resolve, no top-level runtime error) and
-- expose the expected functions? Does NOT call onUpdate/setGraphPath, since
-- those need BeamNG's `be`/`log`/jsonDecode globals which don't exist outside
-- the game -- see README.md "Test 1" and "Test 2" for the in-game checks.
-- Run with: lua tests/lua/test_core_smoke.lua   (from the repo root)
--
-- package.path mirrors BeamNG's real convention on purpose (root at
-- lua/ge/extensions/, siblings required as "beamai/idm" etc, never a bare
-- "idm") so this test would have caught the "loop or previous error loading
-- module" bug hit on the first real in-game load.

package.path = package.path .. ";" .. (arg[0]:match("(.*)tests[/\\]lua[/\\]") or "./") .. "mod/lua/ge/extensions/?.lua"

local failures = 0
local function check(name, cond)
  if cond then
    print("  ok   " .. name)
  else
    print("  FAIL " .. name)
    failures = failures + 1
  end
end

print("Test: core.lua loads without a top-level error and exposes its API")
local ok, core = pcall(require, "beamai/core")
check("require('core') succeeded (" .. tostring(core) .. ")", ok)
if ok then
  check("setGraphPath is a function", type(core.setGraphPath) == "function")
  check("setEnabled is a function", type(core.setEnabled) == "function")
  check("registerVehicle is a function", type(core.registerVehicle) == "function")
  check("unregisterVehicle is a function", type(core.unregisterVehicle) == "function")
  check("onUpdate is a function", type(core.onUpdate) == "function")
  check("starts disabled", core.enabled == false)
else
  print("  error: " .. tostring(core))
end

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
  os.exit(0)
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
