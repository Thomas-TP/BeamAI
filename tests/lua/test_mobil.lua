-- Standalone unit tests for mod/lua/ge/extensions/beamai/mobil.lua.
-- Run with: lua tests/lua/test_mobil.lua   (from the repo root)

package.path = package.path .. ";" .. (arg[0]:match("(.*)tests[/\\]lua[/\\]") or "./") .. "mod/lua/ge/extensions/beamai/?.lua"
local mobil = require("mobil")

local failures = 0
local function check(name, cond)
  if cond then
    print("  ok   " .. name)
  else
    print("  FAIL " .. name)
    failures = failures + 1
  end
end

print("Test 1: shouldChangeLane rejects an unsafe move regardless of gain")
do
  -- Huge gain for us, but would force the follower over there to brake at -6 m/s^2.
  check("unsafe follower brake blocks the change",
    mobil.shouldChangeLane(-3.0, 2.0, 0, -6.0) == false)
end

print("Test 2: shouldChangeLane accepts a clearly beneficial, safe move")
do
  check("big own gain, no one behind in the target lane -> change",
    mobil.shouldChangeLane(-2.0, 1.0, nil, nil) == true)
end

print("Test 3: shouldChangeLane rejects a marginal gain (below threshold)")
do
  check("tiny gain does not justify changing lanes",
    mobil.shouldChangeLane(0.0, 0.1, nil, nil) == false)
end

print("Test 4: shouldChangeLane's politeness term weighs the follower's loss")
do
  -- Our own gain is modest; the follower over there would be mildly inconvenienced
  -- (not unsafe) -- politeness should be able to tip a marginal case either way.
  local withoutPoliteness = mobil.shouldChangeLane(0.0, 0.5, 0, 0, { politeness = 0, changeThreshold = 0.3, maxSafeDeceleration = 4 })
  local withHarshPoliteness = mobil.shouldChangeLane(0.0, 0.5, 0, -3.0, { politeness = 1.0, changeThreshold = 0.3, maxSafeDeceleration = 4 })
  check("without politeness weighting, modest own gain is enough", withoutPoliteness == true)
  check("heavy politeness weighting against a follower's loss blocks it", withHarshPoliteness == false)
end

print("Test 5: shouldAttemptObstacleAvoidance triggers only for a close, near-stopped obstacle")
do
  check("close and stopped -> attempt avoidance", mobil.shouldAttemptObstacleAvoidance(10, 0) == true)
  check("close but still moving at normal speed -> no", mobil.shouldAttemptObstacleAvoidance(10, 8) == false)
  check("stopped but far away -> no (just follow normally for now)", mobil.shouldAttemptObstacleAvoidance(100, 0) == false)
  check("no obstacle at all (nil gap) -> no", mobil.shouldAttemptObstacleAvoidance(nil, 0) == false)
end

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
  os.exit(0)
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
