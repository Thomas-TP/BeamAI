-- BeamAI -- Game Engine extension entry point.
--
-- Scope of this first version (roadmap phase 1, docs/ARCHITECTURE.md section 8):
-- IDM-based speed control for a small, explicitly-registered set of vehicles on
-- a single lane, no intersections. Everything beyond that (behavior tree states,
-- MOBIL lane changes, the safety layer, the population lifecycle...) is later
-- phases and deliberately not attempted here.
--
-- NOT YET VALIDATED IN-GAME. Written against documented/well-established BeamNG
-- Lua conventions (GE extension shape, `be`/vehicle object API, queueLuaCommand
-- to reach a vehicle's own AI Lua VM, jsonDecode/readFile globals), but this
-- machine cannot run BeamNG.drive interactively, so every call into the engine
-- API below is best-effort and flagged where its exact signature is uncertain.
-- Load in-game, watch the console, and fix up anything that errors before
-- trusting this beyond a single test vehicle on an empty road.

local idm = require("idm")
local roadGraph = require("roadGraph")

local M = {}

M.enabled = false
M.graph = nil
local trackedVehicleIds = {}

-- Call from the GE Lua console: extensions.beamai_core.setGraphPath("...")
function M.setGraphPath(path)
  local graph, err = roadGraph.loadGraph(path)
  if not graph then
    log("E", "beamai_core", "failed to load road graph: " .. tostring(err))
    return false
  end
  M.graph = graph
  log("I", "beamai_core", string.format(
    "loaded road graph '%s': %d segments, %d junctions",
    tostring(graph.map), #graph.segments, #graph.junctions
  ))
  return true
end

function M.setEnabled(value)
  M.enabled = value and true or false
end

function M.registerVehicle(vehId)
  trackedVehicleIds[vehId] = true
end

function M.unregisterVehicle(vehId)
  trackedVehicleIds[vehId] = nil
end

-- Sends a target speed (m/s) into vehId's own Vehicle Lua VM via its AI controller.
-- Mirrors BeamNGpy's AIApi.set_speed(speed, mode="limit") found in research
-- (section 2.1 of docs/ARCHITECTURE.md) -- confirm `ai.setSpeed` signature in-game.
local function dispatchSpeed(vehObj, speedMs)
  vehObj:queueLuaCommand(string.format("ai.setSpeed(%f, 'limit')", speedMs))
end

-- Finds the closest other tracked vehicle ahead of `ownProj` on the same segment.
-- v0 only looks among explicitly registered vehicles (not the full traffic
-- population) to keep the first in-game test small and easy to reason about.
local function findLeaderOnSegment(segment, ownVehId, ownProj, positionsById)
  local bestGap, bestSpeed = nil, nil
  for vehId in pairs(trackedVehicleIds) do
    if vehId ~= ownVehId then
      local otherPos = positionsById[vehId]
      if otherPos then
        local otherProj = roadGraph.closestPointOnPolyline(segment.nodes, otherPos.pos)
        if otherProj and otherProj.lateralOffset < segment.width / 2 + 1 then
          local gap = roadGraph.distanceAlong(segment.nodes, ownProj, otherProj)
          if gap > 0 and (bestGap == nil or gap < bestGap) then
            bestGap, bestSpeed = gap, otherPos.speed
          end
        end
      end
    end
  end
  return bestGap, bestSpeed
end

function M.onUpdate(dtReal, dtSim, dtRaw)
  if not M.enabled or not M.graph then
    return
  end

  -- Snapshot every tracked vehicle's position/speed once per tick (avoids
  -- re-querying the engine per-pair below). `be` is BeamNG's GE-side vehicle
  -- manager singleton; getObjectByID/getPosition/getVelocity are the
  -- long-standing standard accessors.
  local positionsById = {}
  for vehId in pairs(trackedVehicleIds) do
    local obj = be:getObjectByID(vehId)
    if obj then
      local pos = obj:getPosition()
      local vel = obj:getVelocity()
      positionsById[vehId] = {
        pos = { pos.x, pos.y, pos.z },
        speed = math.sqrt(vel.x * vel.x + vel.y * vel.y + vel.z * vel.z),
        obj = obj,
      }
    end
  end

  for vehId, data in pairs(positionsById) do
    local segment, ownProj = roadGraph.findNearestSegment(M.graph, data.pos)
    if segment and ownProj then
      local gap, leaderSpeed = findLeaderOnSegment(segment, vehId, ownProj, positionsById)
      -- TODO (phase 2): when gap is nil, check the segment's terminal junction
      -- for a red/yellow trafficLight via extensions.core_trafficSignals and
      -- treat the stop line as a virtual leader at speed 0. Not implemented
      -- yet -- this v0 targets a single lane with no intersection.
      local targetSpeed = idm.nextSpeed(data.speed, leaderSpeed or 0, gap, dtSim)
      dispatchSpeed(data.obj, targetSpeed)
    end
  end
end

return M
