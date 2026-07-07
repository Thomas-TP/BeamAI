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
-- Phase 3, first increment -- easing past a close, slow/stopped obstacle
-- (roadmap phase 3/4). OFF BY DEFAULT (see M.setAvoidanceEnabled).
--
-- Second in-game playtest (West Coast USA, ~24 tracked vehicles) surfaced two
-- performance/correctness bugs (both fixed) and, more importantly, a design
-- change after reading more of lua/vehicle/ai.lua:
--   4. Performance -- onUpdate rescanned every one of the graph's ~1300
--      segments for every tracked vehicle on every single tick
--      (roadGraph.findNearestSegment). Now uses findNearestSegmentNear, which
--      checks the vehicle's segment from last tick first and only falls back
--      to the full scan when that no longer fits.
--   5. The player's own vehicle is now excluded from registerAll -- this mod
--      should never send ai.setSpeed/ai.setParameters into a human-driven car.
--   6. REDESIGNED the maneuver itself. The original approach manually called
--      ai.laneChange to shift the vehicle sideways. Two things killed that
--      idea: (a) tested directly in isolation (bypassing all of this mod's
--      logic) it had no visible effect at all -- ai.laneChange operates on
--      currentRoute.plan, and ai.lua explicitly clears currentRoute to nil
--      "if stopped near player" (search that comment in ai.lua), which is
--      exactly the test scenario (an AI vehicle stopped close to the player);
--      (b) more fundamentally, lua/vehicle/ai.lua already has its own
--      continuous, native side-avoidance (search "side_avoidance" and
--      "trafficTable" in ai.lua): every tick, for every nearby vehicle with
--      avoidCars == 'on' (the default whenever this mod doesn't touch
--      ai.setMode, which it never does), it computes a lateral displacement
--      to nudge around them and applies it to the live plan, clamped to the
--      road's own width. Manually calling ai.laneChange on top of that is
--      redundant at best and fights the native recompute at worst.
--      So instead of computing our own lateral offset: when a close,
--      slow/stopped obstacle is detected (mobil.shouldAttemptObstacleAvoidance),
--      this mod (i) stops treating it as a hard IDM stop constraint so the
--      vehicle can actually keep approaching instead of queuing up behind it
--      forever, (ii) caps the speed to a cautious creep (CREEP_SPEED_MS) so it
--      eases in rather than barrelling into a maneuver, and (iii) temporarily
--      raises ai.lua's own awarenessForceCoef parameter (confirmed real,
--      default 0.25, see lua/vehicle/ai.lua) so the native side-avoidance
--      reacts more decisively at that lower speed, then restores the default
--      once past. avoidance.lua's state machine (idle/offsetting/returning) is
--      reused unchanged for the timing/hysteresis of this creep-and-boost
--      window; only what core.lua *does* on each transition changed. Still
--      unverified in-game: whether this actually produces a visibly smooth
--      "goes around" rather than just "doesn't stop" -- see README.md.
--
-- Project direction change: build BeamAI's own complete driving stack rather
-- than sit on top of BeamNG's native ai.lua (speed via ai.setSpeed, steering/
-- path-following left entirely to the native system, obstacle avoidance
-- leaning on native side_avoidance). ai.lua is now studied only to learn
-- which real, confirmed low-level primitives exist (see below), not reused
-- as the actual decision-maker.
--
-- Confirmed (lua/vehicle/ai.lua, lua/vehicle/input.lua, lua/common/inputFilters.lua):
-- ai.lua's own final control step is
--   input.event("steering", steering, "FILTER_AI", nil, nil, nil, "ai")
--   input.event("throttle", throttle, "FILTER_AI", nil, nil, nil, "ai")
--   input.event("brake", brake, "FILTER_AI", nil, nil, nil, "ai")
-- (its `driveCar` function) -- a documented, stable, low-level input channel
-- (FILTER_AI is a real constant, lua/common/inputFilters.lua) that we can
-- drive directly with our own numbers, exactly as ai.lua itself does, instead
-- of asking ai.lua to compute them for us.
--
-- M.setFullControlEnabled(true) switches tracked vehicles to this: on first
-- tick under full control, ai.setMode('disabled') is sent once (ai.lua then
-- stops calling driveCar() itself, per its own source -- "if M.mode ==
-- 'disabled' then driveCar(0,0,0,0); M.updateGFX = nop", so it steps out of
-- the way instead of fighting our injected inputs every tick). From then on,
-- every tick this mod computes:
--   - a lookahead point on our own road graph (roadGraph.findLookaheadPoint)
--   - a steering command from it (steeringController.lua, pure-pursuit)
--   - a target speed (idm.lua, unchanged) and throttle/brake to track it
--     (speedController.lua, PID)
-- and injects all three directly. This is the highest-risk change so far --
-- unlike every previous increment, there is no native fallback/safety net
-- once ai.setMode('disabled') has been sent, and steering an actual physics
-- vehicle wrong is a lot less forgiving than a wrong speed. OFF BY DEFAULT.
-- Test it in the most boring possible setting first (one vehicle, empty
-- straight road, low speed) before anything else -- see README.md. Known
-- gaps, not yet attempted: obstacle avoidance while in full control (the
-- creep-and-boost trick above relied on native ai.lua, which is now disabled
-- for these vehicles -- IDM still prevents a collision by slowing/stopping,
-- but nothing yet steers around an obstacle in this mode), and turning
-- decisions at real intersections (still phase 2, findLookaheadPoint aims at
-- the junction itself rather than guessing a branch).

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
local steeringController = require("beamai/steeringController")
local speedController = require("beamai/speedController")

local M = {}

M.enabled = false
M.avoidanceEnabled = false
M.fullControlEnabled = false
M.graph = nil
-- vehId -> { profile, junctionDecision = {junctionId, obeys}, avoidanceState = <avoidance state> }
local trackedVehicles = {}
local JUNCTION_SEARCH_RADIUS = 8.0 -- metres; matches the extractor's clustering radius (~6m) plus margin
local MAX_LIGHT_LOOKAHEAD = 150.0 -- metres; far enough to brake comfortably from highway speed
local warnedNoLiveTrafficLightState = false
local REGISTER_SCAN_INTERVAL = 3.0 -- seconds between automatic re-scans for newly spawned vehicles
local timeSinceLastScan = math.huge -- forces an immediate scan on the first onUpdate
local AVOIDANCE_PARAMS = avoidance.defaultParams
local CREEP_SPEED_MS = 3.0 -- ~11 km/h; cautious speed while easing past a close obstacle
local DEFAULT_AWARENESS_COEF = 0.25 -- lua/vehicle/ai.lua's own default for parameters.awarenessForceCoef
local BOOSTED_AWARENESS_COEF = 1.0 -- more decisive native side-avoidance while easing past, at low speed

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
-- header comment above. Off by default even when M.enabled is on. Has no
-- effect on vehicles under full control (see M.setFullControlEnabled) --
-- that mode doesn't use ai.lua's native side-avoidance at all.
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

-- CONFIRMED (lua/vehicle/ai.lua): once mode is 'disabled', ai.lua zeroes the
-- controls once and then sets its own M.updateGFX = nop -- it stops calling
-- driveCar() every tick, i.e. it steps out of the way instead of continuing
-- to fight whatever inputs we inject afterwards. This is what makes full
-- custom control (see header comment) safe to attempt at all.
local function setAiDisabled(vehId)
  local obj = be:getObjectByID(vehId)
  if obj then
    obj:queueLuaCommand("ai.setMode('disabled')")
  end
end

local function trackVehicle(vehId)
  if not trackedVehicles[vehId] then
    trackedVehicles[vehId] = {
      profile = driverProfile.generate(),
      junctionDecision = { junctionId = nil, obeys = true },
      avoidanceState = avoidance.newState(),
      speedControllerState = speedController.newState(),
      lastSegment = nil, -- sticky hint for roadGraph.findNearestSegmentNear, set every tick in onUpdate
      aiDisabled = false,
    }
  end
  if M.fullControlEnabled then
    if not trackedVehicles[vehId].aiDisabled then
      setAiDisabled(vehId)
      trackedVehicles[vehId].aiDisabled = true
    end
  else
    initSpeedControl(vehId)
  end
end

function M.registerVehicle(vehId)
  trackVehicle(vehId)
end

function M.unregisterVehicle(vehId)
  trackedVehicles[vehId] = nil
end

-- Opt-in switch for full custom control (own steering + own throttle/brake,
-- ai.lua's own driving disabled entirely) -- see the header comment above.
-- HIGHEST RISK setting in this mod: test with a single vehicle on an empty,
-- straight road at low speed before anything else.
function M.setFullControlEnabled(value)
  M.fullControlEnabled = value and true or false
  if M.fullControlEnabled then
    for vehId, vehState in pairs(trackedVehicles) do
      if not vehState.aiDisabled then
        setAiDisabled(vehId)
        vehState.aiDisabled = true
      end
    end
  end
end

-- Convenience for manual testing: registers every vehicle currently spawned in
-- the level, so there is no need to hunt down individual vehicle IDs in the
-- console. Call again after spawning more vehicles (or let onUpdate re-scan
-- automatically every REGISTER_SCAN_INTERVAL seconds). Skips the player's own
-- vehicle (be:getPlayerVehicle(0)) -- this mod should never send ai.setSpeed/
-- ai.laneChange into a human-driven car.
function M.registerAll()
  local playerVeh = be:getPlayerVehicle(0)
  local playerVehId = playerVeh and playerVeh:getID() or nil

  local n = be:getObjectCount()
  local count = 0
  for i = 0, n - 1 do
    local obj = be:getObject(i)
    if obj and obj:getID() ~= playerVehId then
      trackVehicle(obj:getID())
      count = count + 1
    end
  end
  log("I", "beamai_core", string.format("registerAll: now tracking %d vehicle(s)", count))
  return count
end

-- Sends a target speed (m/s) into vehId's own Vehicle Lua VM via its AI
-- controller. Requires setSpeedMode('limit') to have been sent already
-- (see initSpeedControl above), otherwise ai.lua ignores routeSpeed. Only
-- used for vehicles NOT under full control (see dispatchControls below).
local function dispatchSpeed(vehObj, speedMs)
  vehObj:queueLuaCommand(string.format("ai.setSpeed(%f)", speedMs))
end

-- Full custom control: injects steering/throttle/brake directly, the same
-- low-level channel ai.lua's own driveCar() uses (input.event with
-- "FILTER_AI") -- confirmed in lua/vehicle/ai.lua and lua/vehicle/input.lua.
-- Requires ai.setMode('disabled') to have been sent first (setAiDisabled)
-- so ai.lua isn't also injecting its own values into the same channel.
local function dispatchControls(vehObj, steeringVal, throttleVal, brakeVal)
  vehObj:queueLuaCommand(string.format(
    "input.event('steering', %f, 'FILTER_AI', nil, nil, nil, 'beamai'); " ..
    "input.event('throttle', %f, 'FILTER_AI', nil, nil, nil, 'beamai'); " ..
    "input.event('brake', %f, 'FILTER_AI', nil, nil, nil, 'beamai')",
    steeringVal, throttleVal, brakeVal))
end

-- ai.setParameters(data) -- confirmed exported (lua/vehicle/ai.lua). Used here
-- only to dial the native side-avoidance's own responsiveness
-- (parameters.awarenessForceCoef) up while easing past a close obstacle and
-- back down to the default afterwards -- never to compute a trajectory
-- ourselves (see header comment for why).
local function dispatchAwareness(vehObj, coef)
  vehObj:queueLuaCommand(string.format("ai.setParameters({awarenessForceCoef = %f})", coef))
end

-- Runs the creep-past state machine for one vehicle (avoidance.lua's state
-- machine, reused for its timing/hysteresis only -- see header comment for
-- why this no longer computes its own lateral offset). Returns the (possibly
-- nil'd out) vehGap/vehLeaderSpeed for IDM, and whether the caller should cap
-- the desired speed to a cautious creep while this is active.
local function updateAvoidance(vehState, ownVehId, ownObj, vehGap, vehLeaderSpeed, ownSpeed, dtSim)
  local state = vehState.avoidanceState
  local wantsToAvoid = state.phase == avoidance.IDLE and mobil.shouldAttemptObstacleAvoidance(vehGap, vehLeaderSpeed)

  local distanceMoved = ownSpeed * dtSim
  local action = avoidance.update(state, dtSim, distanceMoved, wantsToAvoid, 1, AVOIDANCE_PARAMS)

  if action == "beginOffset" then
    log("I", "beamai_core", "vehicle " .. tostring(ownVehId) .. ": easing past a close, slow obstacle")
    dispatchAwareness(ownObj, BOOSTED_AWARENESS_COEF)
  elseif action == "returnToCentre" then
    dispatchAwareness(ownObj, DEFAULT_AWARENESS_COEF)
  end

  if state.phase ~= avoidance.IDLE then
    return nil, nil, true -- suppress the hard-stop constraint; caller applies a creep-speed cap instead
  end
  return vehGap, vehLeaderSpeed, false
end

-- Finds the closest other tracked vehicle plausibly ahead of `ownProj` on the
-- same segment (roadGraph.isPlausibleLeader filters out cross-traffic that
-- merely passes close to our polyline near an intersection -- see header).
-- Also returns that vehicle's id, so callers (updateAvoidance) can exclude
-- the very obstacle they're trying to go around from their own clearance check.
local function findLeaderOnSegment(segment, ownVehId, ownProj, positionsById)
  local bestGap, bestSpeed, bestVehId = nil, nil, nil
  for vehId in pairs(trackedVehicles) do
    if vehId ~= ownVehId then
      local otherPos = positionsById[vehId]
      if otherPos then
        local otherProj = roadGraph.closestPointOnPolyline(segment.nodes, otherPos.pos)
        if otherProj then
          local gap = roadGraph.distanceAlong(segment.nodes, ownProj, otherProj)
          if gap > 0 and (bestGap == nil or gap < bestGap)
              and roadGraph.isPlausibleLeader(segment, otherProj, otherPos.vel, otherPos.speed) then
            bestGap, bestSpeed, bestVehId = gap, otherPos.speed, vehId
          end
        end
      end
    end
  end
  return bestGap, bestSpeed, bestVehId
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

  -- Snapshot every tracked vehicle's position/velocity/heading once per tick
  -- (avoids re-querying the engine per-pair below). getDirectionVector is the
  -- vehicle's own forward heading, confirmed real (lua/ge/spawn.lua,
  -- lua/ge/map.lua both call it on a vehicle object the same way).
  local positionsById = {}
  for vehId in pairs(trackedVehicles) do
    local obj = be:getObjectByID(vehId)
    if obj then
      local pos = obj:getPosition()
      local vel = obj:getVelocity()
      local heading = obj:getDirectionVector()
      positionsById[vehId] = {
        pos = { pos.x, pos.y, pos.z },
        vel = { vel.x, vel.y, vel.z },
        heading = { heading.x, heading.y, heading.z },
        speed = math.sqrt(vel.x * vel.x + vel.y * vel.y + vel.z * vel.z),
        obj = obj,
      }
    end
  end

  for vehId, data in pairs(positionsById) do
    local vehState = trackedVehicles[vehId]
    -- Sticky segment lookup: reuses last tick's segment when it still fits,
    -- instead of rescanning all ~1300 segments per vehicle per tick (the
    -- direct cause of an observed slowdown with ~24 tracked vehicles).
    local segment, ownProj = roadGraph.findNearestSegmentNear(M.graph, data.pos, vehState.lastSegment)
    if segment and ownProj then
      vehState.lastSegment = segment
      local vehGap, vehLeaderSpeed = findLeaderOnSegment(segment, vehId, ownProj, positionsById)

      -- The native-avoidance creep-and-boost trick (updateAvoidance) relies on
      -- ai.lua's own side_avoidance, which no longer runs once a vehicle is
      -- under full control (ai.setMode('disabled')) -- skip it there. IDM
      -- below still prevents a collision either way; full control just can't
      -- steer around the obstacle yet (see header comment, known gap).
      local isCreepingPastObstacle = false
      if M.avoidanceEnabled and not M.fullControlEnabled then
        vehGap, vehLeaderSpeed, isCreepingPastObstacle = updateAvoidance(
          vehState, vehId, data.obj, vehGap, vehLeaderSpeed, data.speed, dtSim)
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
      if isCreepingPastObstacle then
        idmParams.desiredSpeed = math.min(idmParams.desiredSpeed, CREEP_SPEED_MS)
      end

      local targetSpeed = idm.nextSpeed(data.speed, leaderSpeed or 0, gap, dtSim, idmParams)

      if M.fullControlEnabled then
        local lookahead = steeringController.lookaheadDistance(data.speed)
        local target = roadGraph.findLookaheadPoint(M.graph, segment, ownProj, lookahead, JUNCTION_SEARCH_RADIUS)
        local steeringVal = steeringController.computeSteering(data.pos, data.heading, target)
        local throttleVal, brakeVal = speedController.compute(vehState.speedControllerState, data.speed, targetSpeed, dtSim)
        dispatchControls(data.obj, steeringVal, throttleVal, brakeVal)
      else
        dispatchSpeed(data.obj, targetSpeed)
      end
    end
  end
end

return M
