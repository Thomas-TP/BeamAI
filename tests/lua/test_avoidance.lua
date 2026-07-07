-- Standalone unit tests for mod/lua/ge/extensions/beamai/avoidance.lua.
-- Run with: lua tests/lua/test_avoidance.lua   (from the repo root)

package.path = package.path .. ";" .. (arg[0]:match("(.*)tests[/\\]lua[/\\]") or "./") .. "mod/lua/ge/extensions/beamai/?.lua"
local avoidance = require("avoidance")

local failures = 0
local function check(name, cond)
  if cond then
    print("  ok   " .. name)
  else
    print("  FAIL " .. name)
    failures = failures + 1
  end
end

print("Test 1: idle stays idle with no trigger")
do
  local s = avoidance.newState()
  local action = avoidance.update(s, 0.1, 1.0, false, 1)
  check("no action", action == nil)
  check("still idle", s.phase == avoidance.IDLE)
end

print("Test 2: a trigger starts the offset exactly once")
do
  local s = avoidance.newState()
  local action = avoidance.update(s, 0.1, 0, true, -1)
  check("returns beginOffset", action == "beginOffset")
  check("phase is offsetting", s.phase == avoidance.OFFSETTING)
  check("remembers the sign", s.sign == -1)

  -- A trigger again next tick must NOT re-fire beginOffset (already offsetting).
  local action2 = avoidance.update(s, 0.1, 1.0, true, -1)
  check("does not re-trigger while already offsetting", action2 == nil)
end

print("Test 3: full cycle -- offsetting -> returning -> idle, driven by distance")
do
  local params = { offsetMetres = 2.2, maneuverDistance = 20.0, holdDistance = 15.0, maxDuration = 15.0 }
  local s = avoidance.newState()
  avoidance.update(s, 0.1, 0, true, 1, params) -- begin

  -- Travel most of the hold distance: still offsetting, no action yet.
  local action = avoidance.update(s, 0.1, 10.0, false, 1, params)
  check("still offsetting mid-hold", s.phase == avoidance.OFFSETTING and action == nil)

  -- Cross the hold distance threshold -> should return to centre once.
  action = avoidance.update(s, 0.1, 6.0, false, 1, params) -- total travelled 16 > holdDistance 15
  check("crosses into returning", s.phase == avoidance.RETURNING)
  check("returns returnToCentre exactly at the transition", action == "returnToCentre")

  -- Keep going until the maneuver distance is done -> back to idle.
  action = avoidance.update(s, 0.1, 5.0, false, 1, params) -- 21 travelled
  action = avoidance.update(s, 0.1, 15.0, false, 1, params) -- 36 travelled > 15+20=35
  check("back to idle after the return maneuver completes", s.phase == avoidance.IDLE)
end

print("Test 4: hard safety timeout forces a return regardless of distance")
do
  local params = { offsetMetres = 2.2, maneuverDistance = 20.0, holdDistance = 15.0, maxDuration = 2.0 }
  local s = avoidance.newState()
  avoidance.update(s, 0.1, 0, true, 1, params) -- begin, elapsed=0.1

  -- Barely any distance travelled (stuck), but time keeps advancing.
  local sawReturnToCentre = false
  for _ = 1, 25 do -- 25 * 0.1s = 2.5s > maxDuration
    local action = avoidance.update(s, 0.1, 0.01, false, 1, params)
    if action == "returnToCentre" then
      sawReturnToCentre = true
    end
  end
  check("timeout forces idle", s.phase == avoidance.IDLE)
  check("timeout returns returnToCentre at some point", sawReturnToCentre == true)
end

print("Test 5: currentOffsetMetres ramps in/out smoothly instead of stepping")
do
  local params = { offsetMetres = 2.2, maneuverDistance = 20.0, holdDistance = 15.0, maxDuration = 15.0, rampDistance = 5.0 }
  local s = avoidance.newState()
  check("idle -> zero offset", avoidance.currentOffsetMetres(s, params) == 0)

  avoidance.update(s, 0.1, 0, true, 1, params) -- begin offsetting, sign=1
  local earlyOffset = avoidance.currentOffsetMetres(s, params)
  check("just started offsetting -> near zero, not a step to full magnitude", earlyOffset < 0.5)

  avoidance.update(s, 0.1, 5.0, false, 1, params) -- fully into the ramp distance (5m)
  local rampedOffset = avoidance.currentOffsetMetres(s, params)
  check("past the ramp distance -> at full magnitude", math.abs(rampedOffset - 2.2) < 1e-6)

  avoidance.update(s, 0.1, 10.0, false, 1, params) -- total 15m -> crosses into returning
  check("now returning", s.phase == avoidance.RETURNING)
  local justReturningOffset = avoidance.currentOffsetMetres(s, params)
  check("just crossed into returning -> still near full magnitude (continuous, no jump)",
    math.abs(justReturningOffset - 2.2) < 1e-6)

  avoidance.update(s, 0.1, 5.0, false, 1, params) -- 5m into the return ramp
  local midReturnOffset = avoidance.currentOffsetMetres(s, params)
  check("mid return ramp -> back down to ~zero", math.abs(midReturnOffset) < 1e-6)

  local sNeg = avoidance.newState()
  avoidance.update(sNeg, 0.1, 0, true, -1, params)
  avoidance.update(sNeg, 0.1, 5.0, false, -1, params)
  check("negative sign offsets the other way", avoidance.currentOffsetMetres(sNeg, params) < 0)
end

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
  os.exit(0)
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
