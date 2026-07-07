-- Traffic-light state for a junction, read from BeamNG's own live signal
-- simulation (extensions.core_trafficSignals) rather than re-simulated locally.
--
-- Why not re-simulate: signals.json's "sequences" choreograph which controller
-- in a group is currently allowed to cycle (green/yellow/red) while others sit
-- at a default state -- see tools/extract_road_graph.py. BeamNG is already
-- animating the real light poles the player sees; a second, independently
-- clocked simulation could drift out of sync with what's visually on screen.
-- So this module queries the game's live state instead.
--
-- CONFIRMED against the actual installed game's source
-- (lua/ge/extensions/core/trafficSignals.lua, read directly from disk):
--   M.getElementById(id)   -> the SignalInstance/Controller/Sequence with that id
--   SignalInstance:getState() -> stateName, stateData
--     stateName is one of: 'greenTrafficLight', 'yellowTrafficLight',
--     'redTrafficLight', 'redYellowTrafficLight', 'greenFlashingTrafficLight', ...
--     (see settings/trafficSignals.json for the full list; normalizeStateName
--     below only needs to tell "green" apart from everything else).
--   signals.json's per-instance `id` is preserved as-is into elementsById, so
--   the extractor's trafficLightInstances[].id (tools/extract_road_graph.py)
--   is exactly the id to pass to getElementById.
--
-- STILL NOT VALIDATED IN-GAME: an intersection's "group" bundles light
-- instances facing every approach (e.g. both NS and EW), each with its own
-- current state -- only one governs *our* lane. pickBestInstance guesses which
-- one by matching each instance's stored facing direction against our travel
-- direction (largest |dot product|, sign-convention-agnostic on purpose, since
-- the source wasn't conclusive on which way `dir` points). Confirm in-game
-- that this actually selects the light facing the player's approach -- see
-- README.md "Test 2".

local M = {}

-- state: "green" | "yellow" | "red" | nil (unknown).
-- Fail-safe: unknown is treated the same as red, never the same as green.
function M.isStopState(state)
  return state ~= "green"
end

function M.normalizeStateName(raw)
  if raw == nil then
    return nil
  end
  local s = tostring(raw):lower()
  if s:find("green") then
    return "green"
  elseif s:find("yellow") or s:find("amber") then
    return "yellow"
  elseif s:find("red") then
    return "red"
  end
  return nil
end

local function dot3(a, b)
  return a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
end

-- Pure function (unit tested standalone): given the junction's
-- trafficLightInstances ({id, dir, controllerId}, from the extracted graph)
-- and our own travel direction ({x,y,z}, normalized), returns the instance
-- whose facing direction is most aligned (in either sign) with ours -- i.e.
-- the light instance most likely governing our approach/lane.
function M.pickBestInstance(instances, travelDir)
  local best, bestScore = nil, nil
  for _, inst in ipairs(instances or {}) do
    local score = math.abs(dot3(inst.dir, travelDir))
    if bestScore == nil or score > bestScore then
      best, bestScore = inst, score
    end
  end
  return best
end

-- Queries the live state of whichever light instance best matches our travel
-- direction. Returns "green" / "yellow" / "red" / nil (unknown -- caller must
-- fail safe, see isStopState).
function M.queryLiveState(instances, travelDir)
  local ext = extensions.core_trafficSignals
  if not ext or not ext.getElementById then
    return nil
  end

  local best = M.pickBestInstance(instances, travelDir)
  if not best then
    return nil
  end

  local ok, signalObj = pcall(ext.getElementById, best.id)
  if not ok or not signalObj or not signalObj.getState then
    return nil
  end

  local ok2, stateName = pcall(signalObj.getState, signalObj)
  if not ok2 then
    return nil
  end
  return M.normalizeStateName(stateName)
end

return M
