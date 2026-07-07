-- Standalone unit tests for mod/lua/ge/extensions/beamai/idm.lua.
-- Run with: lua tests/lua/test_idm.lua   (from the repo root)

package.path = package.path .. ";" .. (arg[0]:match("(.*)tests[/\\]lua[/\\]") or "./") .. "mod/lua/ge/extensions/beamai/?.lua"
local idm = require("idm")

local failures = 0
local function check(name, cond)
  if cond then
    print("  ok   " .. name)
  else
    print("  FAIL " .. name)
    failures = failures + 1
  end
end

print("Test 1: free road, starting from rest")
do
  local speed = 0
  local a0 = idm.acceleration(speed, nil, math.huge)
  check("accelerates from rest (a > 0)", a0 > 0)
  check("a0 close to maxAcceleration", math.abs(a0 - idm.defaultParams.maxAcceleration) < 1e-6)
end

print("Test 2: at desired speed, free road -> ~zero acceleration")
do
  local v0 = idm.defaultParams.desiredSpeed
  local a = idm.acceleration(v0, nil, math.huge)
  check("acceleration ~ 0 at v0 (got " .. string.format("%.4f", a) .. ")", math.abs(a) < 1e-6)
end

print("Test 3: free road acceleration decreases as speed rises toward v0")
do
  local v0 = idm.defaultParams.desiredSpeed
  local aLow = idm.acceleration(0.2 * v0, nil, math.huge)
  local aMid = idm.acceleration(0.6 * v0, nil, math.huge)
  local aHigh = idm.acceleration(0.9 * v0, nil, math.huge)
  check("aLow > aMid > aHigh > 0", aLow > aMid and aMid > aHigh and aHigh > 0)
end

print("Test 4: closing fast on a slower leader -> braking (negative acceleration)")
do
  local a = idm.acceleration(20, 5, 15) -- fast approach, modest gap
  check("brakes hard (a < -1)", a < -1)
end

print("Test 5: no collision over a full stop-approach simulation")
do
  local speed = 15 -- m/s (~54 km/h)
  local leaderSpeed = 0 -- stationary obstacle
  local gap = 100 -- metres to the obstacle's rear bumper
  local dt = 0.1
  local minGapSeen = gap
  local steps = 0
  for _ = 1, 3000 do
    local newSpeed, _accel = idm.nextSpeed(speed, leaderSpeed, gap, dt)
    local distClosed = ((speed + newSpeed) / 2) * dt
    gap = gap - distClosed
    speed = newSpeed
    minGapSeen = math.min(minGapSeen, gap)
    steps = steps + 1
    if speed < 0.01 and gap < idm.defaultParams.minGap + 1 then
      break
    end
  end
  check("never collided (min gap " .. string.format("%.2f", minGapSeen) .. "m > 0)", minGapSeen > 0)
  check("settles near the minimum gap (s0=" .. idm.defaultParams.minGap .. "m, ended at "
    .. string.format("%.2f", gap) .. "m)", gap > 0 and gap < idm.defaultParams.minGap + 2)
  check("vehicle has essentially stopped (speed=" .. string.format("%.3f", speed) .. " m/s)", speed < 0.1)
  print("  (" .. steps .. " simulated steps of dt=" .. dt .. "s)")
end

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
  os.exit(0)
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
