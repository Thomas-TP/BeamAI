-- BeamAI -- Game Engine extension entry point.
--
-- Scope of this first version (roadmap phase 1, docs/ARCHITECTURE.md section 8):
-- IDM-based speed control for a small, explicitly-registered set of vehicles on
-- a single lane, no intersections. Everything beyond that (behavior tree states,
-- MOBIL lane changes, the safety layer, the population lifecycle...) is later
-- phases and deliberately not attempted here.
--
-- STILL NOT RUN IN-GAME (this machine cannot launch BeamNG.drive), but every
-- engine API call below has been checked against the actual installed game's
-- own Lua source (read directly off disk: lua/ge/ge_utils.lua, lua/ge/extensions
-- /core/vehicles.lua, lua/vehicle/ai.lua, lua/ge/extensions/core/trafficSignals.lua)
-- rather than guessed: be:getObjectCount/getObject/getObjectByID, obj:getPosition/
-- getVelocity/getID/queueLuaCommand, ai.setSpeed/setSpeedMode all match confirmed
-- real usage elsewhere in the game's own code. What's still genuinely unverified
-- is *behavioural*, not API shape: does this actually produce sane driving once
-- running, does pickBestInstance (trafficLights.lua) pick the right light, does
-- a vehicle need to already be in an active AI mode for setSpeed to have any
-- effect (assumed yes, see initSpeedControl below). Load in-game, watch the
-- console -- see README.md "Test 1" / "Test 2".

local idm = require("idm")
local roadGraph = require("roadGraph")
local trafficLights = require("trafficLights")

local M = {}

M.enabled = false
M.graph = nil
local trackedVehicleIds = {}
local JUNCTION_SEARCH_RADIUS = 8.0 -- metres; matches the extractor's clustering radius (~6m) plus margin
local warnedNoLiveTrafficLightState = false
local REGISTER_SCAN_INTERVAL = 3.0 -- seconds between automatic re-scans for newly spawned vehicles
local timeSinceLastScan = math.huge -- forces an immediate scan on the first onUpdate

-- Maps a level name (as returned by path.levelFromPath) to a bundled road
-- graph shipped inside this mod, for fully automatic setup -- no console
-- commands needed. See tools/extract_road_graph.py and README.md.
local BUNDLED_GRAPHS = {
  west_coast_usa = "lua/ge/extensions/beamai/data/west_coast_usa.roadgraph.json",
}

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

-- CONFIRMED against the actual installed game's source (lua/vehicle/ai.lua,
-- read directly from disk): ai.setSpeed(speed) takes ONLY the number -- the
-- 'limit' vs 'set' vs 'legal' behaviour is a *separate* call,
-- ai.setSpeedMode(mode), gating whether/how routeSpeed is applied. So each
-- newly tracked vehicle gets setSpeedMode('limit') once; dispatchSpeed only
-- ever touches setSpeed after that.
--
-- Assumption this v0 depends on (not yet validated in-game, see README.md
-- "Test 1"): the vehicle is *already* in an active AI driving mode (e.g.
-- spawned as traffic, or set via the in-game AI/Traffic app) before being
-- registered here. ai.lua's setMode('traffic') has real side effects (forces
-- speedMode back to 'legal', changes collision/aerodynamics model, enables
-- lane-following) that this mod does not attempt to reproduce or override --
-- calling ai.setMode ourselves was deliberately avoided to not fight whatever
-- mode already governs the vehicle.
local function initSpeedControl(vehId)
  local obj = be:getObjectByID(vehId)
  if obj then
    obj:queueLuaCommand("ai.setSpeedMode('limit')")
  end
end

function M.registerVehicle(vehId)
  trackedVehicleIds[vehId] = true
  initSpeedControl(vehId)
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
      local vehId = obj:getID()
      trackedVehicleIds[vehId] = true
      initSpeedControl(vehId)
      count = count + 1
    end
  end
  log("I", "beamai_core", string.format("registerAll: now tracking %d vehicle(s)", count))
  return count
end

-- Sends a target speed (m/s) into vehId's own Vehicle Lua VM via its AI
-- controller. Requires setSpeedMode('limit') to have been sent already
-- (see initSpeedControl above), otherwise ai.lua ignores routeSpeed.
local function dispatchSpeed(vehObj, speedMs)
  vehObj:queueLuaCommand(string.format("ai.setSpeed(%f)", speedMs))
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

  local travelDir = roadGraph.tangentAtProjection(segment.nodes, ownProj)
  local state = trafficLights.queryLiveState(junction.trafficLightInstances, travelDir)
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

-- Auto-run hook: confirmed real signature (lua/ge/extensions/career/career.lua
-- and others), fired once a level finishes loading, with the level path. If we
-- have a bundled graph for this level, load it and switch on automatically --
-- no console commands needed for the zip-and-drop test (README.md).
function M.onClientStartMission(levelPath)
  local levelName = path.levelFromPath(levelPath)
  local graphPath = BUNDLED_GRAPHS[levelName]
  if not graphPath then
    log("I", "beamai_core", "no bundled road graph for level '" .. tostring(levelName) .. "', staying idle")
    return
  end
  timeSinceLastScan = math.huge
  if M.setGraphPath(graphPath) then
    M.setEnabled(true)
  end
end

function M.onClientEndMission()
  M.setEnabled(false)
  M.graph = nil
  trackedVehicleIds = {}
end

function M.onUpdate(dtReal, dtSim, dtRaw)
  if not M.enabled or not M.graph then
    return
  end

  -- Automatically pick up newly spawned/despawned vehicles every few seconds,
  -- so nobody has to call registerAll() by hand after spawning traffic.
  timeSinceLastScan = timeSinceLastScan + dtSim
  if timeSinceLastScan >= REGISTER_SCAN_INTERVAL then
    timeSinceLastScan = 0
    M.registerAll()
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
