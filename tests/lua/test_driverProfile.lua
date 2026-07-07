-- Standalone unit tests for mod/lua/ge/extensions/beamai/driverProfile.lua.
-- Run with: lua tests/lua/test_driverProfile.lua   (from the repo root)

package.path = package.path .. ";" .. (arg[0]:match("(.*)tests[/\\]lua[/\\]") or "./") .. "mod/lua/ge/extensions/beamai/?.lua"
local dp = require("driverProfile")

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

-- Returns a fake rng that yields the given values in order (nil after exhausted).
local function scripted(values)
  local i = 0
  return function()
    i = i + 1
    return values[i]
  end
end

print("Test 1: speedFactor spans [min, max] linearly with the rng draw")
do
  local pMin = dp.generate(scripted({ 0, 0.99, 0.99 }))
  check("rng=0 -> speedFactor == min (0.85)", near(pMin.speedFactor, 0.85, 1e-6))

  local pMax = dp.generate(scripted({ 0.999999, 0.99, 0.99 }))
  check("rng~1 -> speedFactor ~ max (1.20)", near(pMax.speedFactor, 1.20, 1e-4))
end

print("Test 2: reckless profile gets looser IDM overrides")
do
  local p = dp.generate(scripted({ 0.5, 0.01 })) -- 2nd draw < recklessProbability (0.08)
  check("isReckless is true", p.isReckless == true)
  check("isCautious is false (short-circuited)", p.isCautious == false)
  check("timeHeadway overridden tighter", near(p.idmOverrides.timeHeadway, 1.0, 1e-6))
  check("maxAcceleration overridden higher", near(p.idmOverrides.maxAcceleration, 2.0, 1e-6))
end

print("Test 3: cautious profile gets gentler IDM overrides")
do
  local p = dp.generate(scripted({ 0.5, 0.5, 0.1 })) -- not reckless, 3rd draw < cautiousProbability (0.2)
  check("isReckless is false", p.isReckless == false)
  check("isCautious is true", p.isCautious == true)
  check("timeHeadway overridden looser", near(p.idmOverrides.timeHeadway, 2.2, 1e-6))
  check("maxAcceleration overridden lower", near(p.idmOverrides.maxAcceleration, 1.0, 1e-6))
end

print("Test 4: an average driver has no overrides at all")
do
  local p = dp.generate(scripted({ 0.5, 0.5, 0.5 }))
  check("not reckless", p.isReckless == false)
  check("not cautious", p.isCautious == false)
  check("idmOverrides is empty", next(p.idmOverrides) == nil)
end

print("Test 5: decidesToObeyStopLine")
do
  local reckless = dp.generate(scripted({ 0.5, 0.01 }))
  check("reckless + low roll -> ignores the stop line", dp.decidesToObeyStopLine(reckless, scripted({ 0.3 })) == false)
  check("reckless + high roll -> still obeys sometimes", dp.decidesToObeyStopLine(reckless, scripted({ 0.9 })) == true)

  local normal = dp.generate(scripted({ 0.5, 0.5, 0.5 }))
  check("non-reckless always obeys, whatever the roll", dp.decidesToObeyStopLine(normal, scripted({ 0.0 })) == true)
end

print("Test 6: applyIdmOverrides merges without mutating the base table")
do
  local base = { timeHeadway = 1.5, maxAcceleration = 1.4, minGap = 2.0 }
  local profile = { idmOverrides = { timeHeadway = 2.2 } }
  local merged = dp.applyIdmOverrides(base, profile)
  check("override applied", near(merged.timeHeadway, 2.2, 1e-6))
  check("non-overridden field kept", near(merged.maxAcceleration, 1.4, 1e-6))
  check("base table untouched", near(base.timeHeadway, 1.5, 1e-6))
end

print("Test 7: distribution roughly matches over many samples (guards against inverted logic)")
do
  math.randomseed(1234)
  local n = 4000
  local reckless, cautious = 0, 0
  for _ = 1, n do
    local p = dp.generate(math.random)
    if p.isReckless then
      reckless = reckless + 1
    elseif p.isCautious then
      cautious = cautious + 1
    end
  end
  local recklessFrac = reckless / n
  local cautiousFrac = cautious / n
  check("reckless fraction near 8% (got " .. string.format("%.1f%%", recklessFrac * 100) .. ")",
    recklessFrac > 0.04 and recklessFrac < 0.14)
  check("cautious fraction near 18% of the rest (got " .. string.format("%.1f%%", cautiousFrac * 100) .. ")",
    cautiousFrac > 0.10 and cautiousFrac < 0.28)
end

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
  os.exit(0)
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
