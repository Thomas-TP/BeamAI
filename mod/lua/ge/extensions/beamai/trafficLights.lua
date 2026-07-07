-- Traffic-light state for a junction, read from BeamNG's own live signal
-- simulation rather than re-simulated locally.
--
-- Why not re-simulate: signals.json's "sequences" choreograph which controller
-- in a group is currently allowed to cycle (green/yellow/red) while the others
-- sit at their default (red) state -- see docs/ARCHITECTURE.md section 4 and
-- tools/extract_road_graph.py. Reconstructing that handoff logic with confidence
-- was not possible from static research alone, and BeamNG is already animating
-- the real light poles the player sees via core/trafficSignals.lua -- a second,
-- independently-clocked simulation could drift out of sync with what's visually
-- on screen. So this module queries the game's live state instead.
--
-- NOT YET VALIDATED IN-GAME: the exact accessor on extensions.core_trafficSignals
-- is a best-effort guess (a few plausible shapes are tried, defensively, via
-- pcall). If none of them work, queryLiveState returns nil and the caller must
-- fail safe -- see isStopState below. Confirm in-game and fix queryLiveState's
-- candidate list; see README.md "Test 2".

local M = {}

-- state: "green" | "yellow" | "red" | nil (unknown).
-- Fail-safe: unknown is treated the same as red, never the same as green.
-- This is a pure function -- unit tested standalone (tests/lua/test_trafficLights.lua).
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

-- Tries a handful of plausible ways to read the live state of a traffic light
-- group/controller from extensions.core_trafficSignals. Returns "green" /
-- "yellow" / "red" / nil (unknown -- caller must fail safe, see isStopState).
function M.queryLiveState(groupId, controllerIds)
  local ext = extensions.core_trafficSignals
  if not ext then
    return nil
  end

  -- Candidate 1: a direct getter keyed by controller id.
  if ext.getControllerState and controllerIds and controllerIds[1] then
    local ok, result = pcall(ext.getControllerState, controllerIds[1])
    local normalized = M.normalizeStateName(result)
    if ok and normalized then
      return normalized
    end
  end

  -- Candidate 2: a `controllers` table indexed by id, each with a `.state` field.
  if ext.controllers and controllerIds and controllerIds[1] then
    local c = ext.controllers[controllerIds[1]]
    if c and c.state then
      local normalized = M.normalizeStateName(c.state)
      if normalized then
        return normalized
      end
    end
  end

  -- Candidate 3: a getter keyed by the light-instance group name.
  if ext.getGroupState and groupId then
    local ok, result = pcall(ext.getGroupState, groupId)
    local normalized = M.normalizeStateName(result)
    if ok and normalized then
      return normalized
    end
  end

  return nil
end

return M
