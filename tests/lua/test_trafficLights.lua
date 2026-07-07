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

print("Test 3: pickBestInstance picks the light whose direction best matches ours")
do
  -- Mimics a real intersection: two instances govern the N/S road (dir ~ +/-Y),
  -- two govern the E/W road (dir ~ +/-X). Travelling along +X should pick one
  -- of the E/W instances, regardless of the (unconfirmed) sign convention.
  local instances = {
    { id = 1, dir = { 0, 1, 0 }, controllerId = 10 },   -- N/S
    { id = 2, dir = { 0, -1, 0 }, controllerId = 10 },  -- N/S
    { id = 3, dir = { 1, 0, 0 }, controllerId = 20 },   -- E/W
    { id = 4, dir = { -1, 0, 0 }, controllerId = 20 },  -- E/W
  }
  local best = tl.pickBestInstance(instances, { 1, 0, 0 })
  check("picked an E/W instance (id 3 or 4)", best.id == 3 or best.id == 4)
  check("picked the E/W controller (20)", best.controllerId == 20)

  local bestNS = tl.pickBestInstance(instances, { 0, 1, 0 })
  check("travelling +Y picks an N/S instance", bestNS.id == 1 or bestNS.id == 2)
end

print("Test 4: pickBestInstance handles no instances")
do
  check("empty list -> nil", tl.pickBestInstance({}, { 1, 0, 0 }) == nil)
  check("nil list -> nil", tl.pickBestInstance(nil, { 1, 0, 0 }) == nil)
end

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
  os.exit(0)
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
