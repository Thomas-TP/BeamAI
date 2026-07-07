-- Standalone unit tests for mod/lua/ge/extensions/beamai/speedController.lua.
-- Run with: lua tests/lua/test_speedController.lua   (from the repo root)

package.path = package.path .. ";" .. (arg[0]:match("(.*)tests[/\\]lua[/\\]") or "./") .. "mod/lua/ge/extensions/beamai/?.lua"
local speedCtrl = require("speedController")

local failures = 0
local function check(name, cond)
  if cond then
    print("  ok   " .. name)
  else
    print("  FAIL " .. name)
    failures = failures + 1
  end
end

print("Test 1: below target speed -> throttle, no brake")
do
  local s = speedCtrl.newState()
  local throttle, brake = speedCtrl.compute(s, 5, 15, 0.1)
  check("throttle > 0", throttle > 0)
  check("brake == 0", brake == 0)
end

print("Test 2: above target speed -> brake, no throttle")
do
  local s = speedCtrl.newState()
  local throttle, brake = speedCtrl.compute(s, 20, 10, 0.1)
  check("brake > 0", brake > 0)
  check("throttle == 0", throttle == 0)
end

print("Test 3: at target speed with a fresh state -> negligible output")
do
  local s = speedCtrl.newState()
  local throttle, brake = speedCtrl.compute(s, 10, 10, 0.1)
  check("throttle ~ 0", throttle < 1e-6)
  check("brake ~ 0", brake < 1e-6)
end

print("Test 4: outputs always stay within [0, 1] even for a huge error")
do
  local s = speedCtrl.newState()
  local throttle, brake = speedCtrl.compute(s, 0, 1000, 0.1)
  check("throttle clamped to 1", throttle <= 1)
  local s2 = speedCtrl.newState()
  local throttle2, brake2 = speedCtrl.compute(s2, 1000, 0, 0.1)
  check("brake clamped to 1", brake2 <= 1)
end

print("Test 5: anti-windup caps the integral term over many ticks of sustained error")
do
  local s = speedCtrl.newState()
  for _ = 1, 500 do
    speedCtrl.compute(s, 0, 30, 0.1) -- sustained large positive error
  end
  check("integral does not exceed integralMax", s.integral <= speedCtrl.defaultParams.integralMax + 1e-6)
end

print("Test 6: converges -- tracking a constant target speed settles the error near zero")
do
  local s = speedCtrl.newState()
  local speed = 0
  local target = 15
  for _ = 1, 300 do
    local throttle, brake = speedCtrl.compute(s, speed, target, 0.1)
    -- crude open-loop plant: throttle accelerates, brake decelerates, drag slows down
    speed = speed + (throttle * 3 - brake * 6 - speed * 0.05) * 0.1
    if speed < 0 then speed = 0 end
  end
  check("settles close to the target speed (got " .. string.format("%.2f", speed) .. ")",
    math.abs(speed - target) < 1.0)
end

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
  os.exit(0)
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
