-- Standalone unit tests for the pure parts of
-- mod/lua/ge/extensions/beamai/trafficLights.lua (isStopState, normalizeStateName).
-- queryLiveState needs BeamNG's live extensions.core_trafficSignals and is not
-- covered here -- see the file's header comment and README.md "Test 2".
-- Run with: lua tests/lua/test_trafficLights.lua   (from the repo root)

package.path = package.path .. ";" .. (arg[0]:match("(.*)tests[/\\]lua[/\\]") or "./") .. "mod/lua/ge/extensions/beamai/?.lua"
local tl = require("trafficLights")

local failures = 0
local function check(name, cond)
  if cond then
    print("  ok   " .. name)
  else
    print("  FAIL " .. name)
    failures = failures + 1
  end
end

print("Test 1: isStopState fails safe on unknown")
do
  check("nil -> stop", tl.isStopState(nil) == true)
  check("green -> go", tl.isStopState("green") == false)
  check("red -> stop", tl.isStopState("red") == true)
  check("yellow -> stop", tl.isStopState("yellow") == true)
  check("garbage string -> stop", tl.isStopState("banana") == true)
end

print("Test 2: normalizeStateName recognizes BeamNG's real state names")
do
  check("greenTrafficLight -> green", tl.normalizeStateName("greenTrafficLight") == "green")
  check("yellowTrafficLight -> yellow", tl.normalizeStateName("yellowTrafficLight") == "yellow")
  check("redTrafficLight -> red", tl.normalizeStateName("redTrafficLight") == "red")
  check("case-insensitive (GREENTRAFFICLIGHT)", tl.normalizeStateName("GREENTRAFFICLIGHT") == "green")
  check("amber treated as yellow", tl.normalizeStateName("amberTrafficLight") == "yellow")
  check("nil -> nil", tl.normalizeStateName(nil) == nil)
  check("unrecognized string -> nil", tl.normalizeStateName("flashingBlue") == nil)
end

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
  os.exit(0)
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
