-- Standalone unit tests for mod/lua/ge/extensions/beamai/steeringController.lua.
-- Run with: lua tests/lua/test_steeringController.lua   (from the repo root)

package.path = package.path .. ";" .. (arg[0]:match("(.*)tests[/\\]lua[/\\]") or "./") .. "mod/lua/ge/extensions/beamai/?.lua"
local steering = require("steeringController")

local failures = 0
local function check(name, cond)
  if cond then
    print("  ok   " .. name)
  else
    print("  FAIL " .. name)
    failures = failures + 1
  end
end
local function near(a, b, eps)
  return math.abs(a - b) < (eps or 1e-6)
end

print("Test 1: lookaheadDistance grows with speed and is clamped")
do
  local d0 = steering.lookaheadDistance(0)
  local d10 = steering.lookaheadDistance(10)
  local dHuge = steering.lookaheadDistance(1000)
  check("at rest, lookahead is the minimum", near(d0, steering.defaultParams.minLookahead, 1e-6))
  check("lookahead grows with speed", d10 > d0)
  check("lookahead is capped at maxLookahead", near(dHuge, steering.defaultParams.maxLookahead, 1e-6))
end

print("Test 2: target directly ahead -> ~zero steering")
do
  local s = steering.computeSteering({ 0, 0, 0 }, { 1, 0, 0 }, { 20, 0, 0 })
  check("steering ~ 0 (got " .. string.format("%.4f", s) .. ")", near(s, 0, 1e-6))
end

print("Test 3: target to the left -> positive steering (with default STEERING_SIGN)")
do
  local s = steering.computeSteering({ 0, 0, 0 }, { 1, 0, 0 }, { 20, 10, 0 })
  local expectedSign = steering.STEERING_SIGN
  check("steering has the expected sign for a left target", (s > 0) == (expectedSign > 0))
  check("steering is within [-1, 1]", s >= -1 and s <= 1)
end

print("Test 4: target to the right -> opposite sign from the left case")
do
  local sLeft = steering.computeSteering({ 0, 0, 0 }, { 1, 0, 0 }, { 20, 10, 0 })
  local sRight = steering.computeSteering({ 0, 0, 0 }, { 1, 0, 0 }, { 20, -10, 0 })
  check("left and right targets give opposite-sign steering", (sLeft > 0) ~= (sRight > 0))
  check("symmetric magnitude for symmetric targets", near(math.abs(sLeft), math.abs(sRight), 1e-6))
end

print("Test 5: sharper lateral offset needs at least as much steering as a gentle one")
do
  local sGentle = steering.computeSteering({ 0, 0, 0 }, { 1, 0, 0 }, { 20, 2, 0 })
  local sSharp = steering.computeSteering({ 0, 0, 0 }, { 1, 0, 0 }, { 20, 15, 0 })
  check("sharper offset needs more steering", math.abs(sSharp) > math.abs(sGentle))
end

print("Test 6: always stays within [-1, 1], even for extreme/behind targets")
do
  local sBehind = steering.computeSteering({ 0, 0, 0 }, { 1, 0, 0 }, { -20, 5, 0 })
  check("behind-target steering stays clamped", sBehind >= -1 and sBehind <= 1)
  local sVeryClose = steering.computeSteering({ 0, 0, 0 }, { 1, 0, 0 }, { 0.01, 5, 0 })
  check("very close off-axis target steering stays clamped", sVeryClose >= -1 and sVeryClose <= 1)
end

print("Test 7: unnormalized heading vector still works")
do
  local s1 = steering.computeSteering({ 0, 0, 0 }, { 1, 0, 0 }, { 20, 10, 0 })
  local s2 = steering.computeSteering({ 0, 0, 0 }, { 5, 0, 0 }, { 20, 10, 0 }) -- same direction, different magnitude
  check("heading magnitude does not affect the result", near(s1, s2, 1e-6))
end

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
  os.exit(0)
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
