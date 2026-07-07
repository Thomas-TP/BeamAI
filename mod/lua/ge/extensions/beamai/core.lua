-- BeamAI -- Game Engine extension entry point.
--
-- Scope of this version (roadmap phase 1, docs/ARCHITECTURE.md section 8):
-- IDM-based speed control for a small, explicitly-registered set of vehicles,
-- stopping for red lights found by looking ahead through the road graph, with
-- per-driver personality variation (docs/ARCHITECTURE.md section 7.I). Real
-- intersection priority/turning negotiation is still out of scope (phase 2) --
-- see the in-game feedback notes below for what that means in practice.
--
-- Every engine API call has been checked against the actual installed game's
-- own Lua source (read directly off disk: lua/ge/ge_utils.lua, lua/ge/extensions
-- /core/vehicles.lua, lua/vehicle/ai.lua, lua/ge/extensions/core/trafficSignals.lua)
-- rather than guessed, and the whole loop has been confirmed working in-game
-- (respects lights, drives at the right speed -- first playtest on West Coast,
-- USA). This revision fixes three issues from that playtest:
--   1. Late braking at lights -- findStopLineConstraint only checked the
--      *current* segment's end; on a road chopped into several short DecalRoad
--      pieces, a red light several segments ahead wasn't seen until the very
--      last one. Now uses roadGraph.findUpcomingTrafficLight, which looks
--      ahead through "continuation" segments (see tools/extract_road_graph.py).
--   2. Hesitating mid-turn at intersections -- findLeaderOnSegment treated any
--      nearby tracked vehicle as "ahead of us", including cross-traffic that
--      merely projects close to our polyline right where segments converge at
--      a junction. Now filtered by roadGraph.isPlausibleLeader (heading
--      alignment), so only vehicles actually moving our way count.
--   3. Driver personality -- some vehicles now drive faster/slower than the
--      limit, follow closer or further, and a small fraction occasionally run
--      a stop line (see driverProfile.lua). This does NOT affect collision
--      avoidance: a "reckless" driver still never intentionally rear-ends
--      someone, it just may not stop for a light with nothing physically in
--      the way.
-- Phase 3, first increment -- lateral obstacle avoidance (roadmap phase 3/4):
-- EXPERIMENTAL, OFF BY DEFAULT (see M.setAvoidanceEnabled). Unlike everything
-- above, this one physically displaces the vehicle sideways via ai.laneChange
-- -- confirmed to exist and be clamped to the road's own drivable width by the
-- game's source (lua/vehicle/ai.lua), so it cannot drive the vehicle off the
-- pavement, but two things are genuinely unverified in-game:
--   - which way is "left" vs "right" for the signed offset it's given (the
--     maneuver is internally consistent either way -- always the same side
--     relative to travel direction -- but which physical side that is has not
--     been observed yet; watch the first test and flip the hardcoded sign
--     argument (currently 1) passed to avoidance.update in updateAvoidance
--     below if it swerves the wrong way).
--   - whether the interaction with the ongoing IDM speed control (suppressed
--     for the original obstacle while a maneuver is in progress, see onUpdate)
--     actually reads as smooth driving rather than a lurch.
-- Decision logic (mobil.lua, avoidance.lua state machine) is pure and fully
-- unit tested; only the ai.laneChange dispatch itself is unverified. Test it
-- in isolation first (one vehicle, one stationary obstacle, empty road) --
-- see README.md -- before trusting it in full city traffic.

-- Full path relative to lua/ge/extensions/ (confirmed convention: real shipped
-- extensions always require siblings this way, e.g.
-- lua/ge/extensions/util/trackBuilder/segmentToProceduralMesh.lua does
-- require('util/trackBuilder/basicCenters') for a file in its own folder --
-- never a bare require("basicCenters"). A bare require("idm") here caused a
-- real in-game error ("loop or previous error loading module") the first
-- time this was tested live.
local idm = require("beamai/idm")
local roadGraph = require("beamai/roadGraph")
local trafficLights = require("beamai/trafficLights")
local driverProfile = require("beamai/driverProfile")
local mobil = require("beamai/mobil")
local avoidance = require("beamai/avoidance")

local M = {}

M.enabled = false
M.avoidanceEnabled = false
M.graph = nil
-- vehId -> { profile, junctionDecision = {junctionId, obeys}, avoidanceState = <avoidance state> }
local trackedVehicles = {}
local JUNCTION_SEARCH_RADIUS = 8.0 -- metres; matches the extractor's clustering radius (~6m) plus margin
local MAX_LIGHT_LOOKAHEAD = 150.0 -- metres; far enough to brake comfortably from highway speed
local warnedNoLiveTrafficLightState = false
local REGISTER_SCAN_INTERVAL = 3.0 -- seconds between automatic re-scans for newly spawned vehicles
local timeSinceLastScan = math.huge -- forces an immediate scan on the first onUpdate
local AVOIDANCE_PARAMS = avoidance.defaultParams

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

-- Opt-in switch for the experimental lateral avoidance maneuver -- see the
-- header comment above. Off by default even when M.enabled is on.
function M.setAvoidanceEnabled(value)
  M.avoidanceEnabled = value and true or false
end

-- CONFIRMED against the actual installed game's source (lua/vehicle/ai.lua):
-- ai.setSpeed(speed) takes ONLY the number -- the 'limit' vs 'set' vs 'legal'
-- behaviour is a *separate* call, ai.setSpeedMode(mode), gating whether/how
-- routeSpeed is applied. So each newly tracked vehicle gets setSpeedMode
-- ('limit') once; dispatchSpeed only ever touches setSpeed after that.
--
-- Assumption this still depends on: the vehicle is already in an active AI
-- driving mode (e.g. spawned as traffic) before being registered here. This
-- mod deliberately never calls ai.setMode itself, to not fight whatever mode
-- (and its side effects -- lane following, collision model, etc.) already
-- governs the vehicle.
local function initSpeedControl(vehId)
  local obj = be:getObjectByID(vehId)
  if obj then
    obj:queueLuaCommand("ai.setSpeedMode('limit')")
  end
end

local function trackVehicle(vehId)
  if not trackedVehicles[vehId] then
    trackedVehicles[vehId] = {
      profile = driverProfile.generate(),
      junctionDecision = { junctionId = nil, obeys = true },
      avoidanceState = avoidance.newState(),
    }
  end
  initSpeedControl(vehId)
end

function M.registerVehicle(vehId)
  trackVehicle(vehId)
end

function M.unregisterVehicle(vehId)
  trackedVehicles[vehId] = nil
end

-- Convenience for manual testing: registers every vehicle currently spawned in
-- the level, so there is no need to hunt down individual vehicle IDs in the
-- console. Call again after spawning more vehicles (or let onUpdate re-scan
-- automatically every REGISTER_SCAN_INTERVAL seconds).
function M.registerAll()
  local n = be:getObjectCount()
  local count = 0
  for i = 0, n - 1 do
    local obj = be:getObject(i)
    if obj then
      trackVehicle(obj:getID())
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

-- ai.laneChange(plan, dist, signedDisp) -- confirmed exported (lua/vehicle/ai.lua,
-- M.laneChange = laneChange), defaults `plan` to the vehicle's own currentRoute.plan
-- when passed nil, so it can be dispatched exactly like this from the outside.
-- EXPERIMENTAL -- see header comment.
local function dispatchLaneChange(vehObj, signedOffset)
  vehObj:queueLuaCommand(string.format("ai.laneChange(nil, %f, %f)", AVOIDANCE_PARAMS.maneuverDistance, signedOffset))
end

-- Runs the experimental avoidance state machine for one vehicle and performs
-- the ai.laneChange side effect the pure state machine (avoidance.lua) asks
-- for. distanceMovedThisTick is approximated as speed * dt (no extra position
-- history needed). Returns the (possibly nil'd out) vehGap/vehLeaderSpeed to
-- use for IDM: while a maneuver is in progress, the original obstacle is
-- suppressed as a constraint (we're going around it, not stopping for it) --
-- the traffic-light constraint is untouched and always still applies.
local function updateAvoidance(vehState, segment, ownProj, positionsById, ownVehId, ownSpeed, vehGap, vehLeaderSpeed, dtSim)
  local state = vehState.avoidanceState
  local wantsToAvoid = false

  if state.phase == avoidance.IDLE and mobil.shouldAttemptObstacleAvoidance(vehGap, vehLeaderSpeed) then
    local otherPositions = {}
    for otherId, otherData in pairs(positionsById) do
      if otherId ~= ownVehId then
        table.insert(otherPositions, otherData.pos)
      end
    end
    wantsToAvoid = roadGraph.isOffsetPathClear(
      segment, ownProj, AVOIDANCE_PARAMS.offsetMetres, AVOIDANCE_PARAMS.maneuverDistance, otherPositions)
  end

  local distanceMoved = ownSpeed * dtSim
  local action = avoidance.update(state, dtSim, distanceMoved, wantsToAvoid, 1, AVOIDANCE_PARAMS)

  if action == "beginOffset" then
    log("I", "beamai_core", "vehicle " .. tostring(ownVehId) .. ": beginning avoidance maneuver")
    dispatchLaneChange(positionsById[ownVehId].obj, AVOIDANCE_PARAMS.offsetMetres * state.sign)
  elseif action == "returnToCentre" then
    log("I", "beamai_core", "vehicle " .. tostring(ownVehId) .. ": returning to lane centre")
    dispatchLaneChange(positionsById[ownVehId].obj, -AVOIDANCE_PARAMS.offsetMetres * state.sign)
  end

  if state.phase ~= avoidance.IDLE then
    return nil, nil -- mid-maneuver: stop treating the original obstacle as a speed constraint
  end
  return vehGap, vehLeaderSpeed
end

-- Finds the closest other tracked vehicle plausibly ahead of `ownProj` on the
-- same segment (roadGraph.isPlausibleLeader filters out cross-traffic that
-- merely passes close to our polyline near an intersection -- see header).
local function findLeaderOnSegment(segment, ownVehId, ownProj, positionsById)
  local bestGap, bestSpeed = nil, nil
  for vehId in pairs(trackedVehicles) do
    if vehId ~= ownVehId then
      local otherPos = positionsById[vehId]
      if otherPos then
        local otherProj = roadGraph.closestPointOnPolyline(segment.nodes, otherPos.pos)
        if otherProj then
          local gap = roadGraph.distanceAlong(segment.nodes, ownProj, otherProj)
          if gap > 0 and (bestGap == nil or gap < bestGap)
              and roadGraph.isPlausibleLeader(segment, otherProj, otherPos.vel, otherPos.speed) then
            bestGap, bestSpeed = gap, otherPos.speed
          end
        end
      end
    end
  end
  return bestGap, bestSpeed
end

-- Looks ahead (through continuation segments) for the nearest upcoming
-- trafficLight junction. If it is not green, returns the gap (metres) from
-- `ownProj` to the stop line, treating it as a stationary virtual leader --
-- unless this specific driver decides to ignore it (driverProfile), which is
-- rolled once per junction (not every frame, so the decision doesn't flicker)
-- and never applies to a real vehicle already in front (collision avoidance
-- is separate, see findLeaderOnSegment).
--
-- Fails safe by design (docs/ARCHITECTURE.md section 4.5): if the live state
-- can't be read at all, isStopState(nil) is true, so an unreadable light is
-- treated as red, never as green.
local function findStopLineConstraint(graph, segment, ownProj, vehState)
  local junction, distance = roadGraph.findUpcomingTrafficLight(
    graph, segment, ownProj, MAX_LIGHT_LOOKAHEAD, JUNCTION_SEARCH_RADIUS)
  if not junction then
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

  if vehState.junctionDecision.junctionId ~= junction.id then
    vehState.junctionDecision.junctionId = junction.id
    vehState.junctionDecision.obeys = driverProfile.decidesToObeyStopLine(vehState.profile)
  end
  if not vehState.junctionDecision.obeys then
    return nil -- this driver is running the light (driverProfile.lua)
  end

  if distance <= 0 then
    return nil -- already at or past the stop line
  end
  return distance
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
  trackedVehicles = {}
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

  -- Snapshot every tracked vehicle's position/velocity once per tick (avoids
  -- re-querying the engine per-pair below).
  local positionsById = {}
  for vehId in pairs(trackedVehicles) do
    local obj = be:getObjectByID(vehId)
    if obj then
      local pos = obj:getPosition()
      local vel = obj:getVelocity()
      positionsById[vehId] = {
        pos = { pos.x, pos.y, pos.z },
        vel = { vel.x, vel.y, vel.z },
        speed = math.sqrt(vel.x * vel.x + vel.y * vel.y + vel.z * vel.z),
        obj = obj,
      }
    end
  end

  for vehId, data in pairs(positionsById) do
    local segment, ownProj = roadGraph.findNearestSegment(M.graph, data.pos)
    if segment and ownProj then
      local vehState = trackedVehicles[vehId]
      local vehGap, vehLeaderSpeed = findLeaderOnSegment(segment, vehId, ownProj, positionsById)

      if M.avoidanceEnabled then
        vehGap, vehLeaderSpeed = updateAvoidance(
          vehState, segment, ownProj, positionsById, vehId, data.speed, vehGap, vehLeaderSpeed, dtSim)
      end

      local lightGap = findStopLineConstraint(M.graph, segment, ownProj, vehState)

      -- Whichever obstacle is nearer along the path is the binding constraint
      -- for IDM (same simplification used by most simple traffic-AI stacks:
      -- the stop line is just a stationary leader at speed 0).
      local gap, leaderSpeed
      if lightGap ~= nil and (vehGap == nil or lightGap < vehGap) then
        gap, leaderSpeed = lightGap, 0
      else
        gap, leaderSpeed = vehGap, vehLeaderSpeed
      end

      local profile = vehState.profile
      local idmParams = driverProfile.applyIdmOverrides(idm.defaultParams, profile)
      idmParams.desiredSpeed = ((segment.speedLimit or 50) / 3.6) * profile.speedFactor

      local targetSpeed = idm.nextSpeed(data.speed, leaderSpeed or 0, gap, dtSim, idmParams)
      dispatchSpeed(data.obj, targetSpeed)
    end
  end
end

return M
