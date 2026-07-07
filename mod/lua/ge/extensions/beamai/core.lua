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
local trafficLights = require("trafficLights")

local M = {}

M.enabled = false
M.graph = nil
local trackedVehicleIds = {}
local JUNCTION_SEARCH_RADIUS = 8.0 -- metres; matches the extractor's clustering radius (~6m) plus margin
local warnedNoLiveTrafficLightState = false

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

-- Convenience for manual testing: registers every vehicle currently spawned in
-- the level, so there is no need to hunt down individual vehicle IDs in the
-- console. Call again after spawning more vehicles.
function M.registerAll()
  local n = be:getObjectCount()
  local count = 0
  for i = 0, n - 1 do
    local obj = be:getObject(i)
    if obj then
      trackedVehicleIds[obj:getID()] = true
      count = count + 1
    end
  end
  log("I", "beamai_core", string.format("registerAll: now tracking %d vehicle(s)", count))
  return count
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

-- If `segment` ends at a traffic-light junction and that light is not green,
-- returns the gap (metres) from `ownProj` to the stop line, treating it as a
-- stationary virtual leader. Returns nil if the light is green, unclassified,
-- too far, or already passed -- i.e. "no constraint from a light here".
--
-- Fails safe by design (docs/ARCHITECTURE.md section 4.5): if the live state
-- can't be read at all, isStopState(nil) is true, so an unreadable light is
-- treated as red, never as green.
local function findStopLineConstraint(graph, segment, ownProj)
  local endNode = segment.nodes[#segment.nodes]
  local junction = roadGraph.findJunctionNear(graph, { endNode[1], endNode[2], endNode[3] }, JUNCTION_SEARCH_RADIUS)
  if not junction or junction.type ~= "trafficLight" then
    return nil
  end

  local state = trafficLights.queryLiveState(junction.trafficLightGroupId, junction.trafficLightControllerIds)
  if state == nil and not warnedNoLiveTrafficLightState then
    warnedNoLiveTrafficLightState = true
    log("W", "beamai_core",
      "could not read live traffic light state (extensions.core_trafficSignals accessor not confirmed yet -- "
      .. "see trafficLights.lua). Failing safe: treating unreadable lights as red until fixed.")
  end
  if not trafficLights.isStopState(state) then
    return nil -- confirmed green: no constraint from this light
  end

  local gap = roadGraph.segmentLength(segment.nodes) - ownProj.distanceAlong
  if gap <= 0 then
    return nil -- already at or past the stop line
  end
  return gap
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
      local vehGap, vehLeaderSpeed = findLeaderOnSegment(segment, vehId, ownProj, positionsById)
      local lightGap = findStopLineConstraint(M.graph, segment, ownProj)

      -- Whichever obstacle is nearer along the path is the binding constraint
      -- for IDM (same simplification used by most simple traffic-AI stacks:
      -- the stop line is just a stationary leader at speed 0).
      local gap, leaderSpeed
      if lightGap ~= nil and (vehGap == nil or lightGap < vehGap) then
        gap, leaderSpeed = lightGap, 0
      else
        gap, leaderSpeed = vehGap, vehLeaderSpeed
      end

      local targetSpeed = idm.nextSpeed(data.speed, leaderSpeed or 0, gap, dtSim)
      dispatchSpeed(data.obj, targetSpeed)
    end
  end
end

return M
