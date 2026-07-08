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
--      last one. Now uses router.findUpcomingTrafficLight (moved there from
--      roadGraph.lua later on, see below), which looks ahead through
--      "continuation" segments (see tools/extract_road_graph.py).
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
-- vehicle wrong is a lot less forgiving than a wrong speed.
--
-- ON BY DEFAULT for every vehicle on a bundled map (M.autoFullControlOnStart,
-- applied from onClientStartMission below) -- explicit product decision: this
-- mod's whole point is to replace BeamNG's traffic AI, so loading a supported
-- map is meant to be enough on its own, no console commands required. This
-- has NOT been validated in-game yet at the time this default was flipped on
-- (only unit-tested). If traffic drives off-road, steers the wrong way, or
-- behaves erratically after loading the map, the single fastest way back to
-- normal is `extensions.beamai_core.setEnabled(false)` in the console (stops
-- this mod from touching any vehicle further; already-disabled vehicles stay
-- under our control but harmlessly idle -- reload the level to fully reset
-- everyone back to native AI). To go back to the older, lower-risk
-- ai.setSpeed-only path instead: `extensions.beamai_core.setAutoFullControlOnStart(false)`
-- before loading/reloading the map. For a controlled single-vehicle test
-- instead of every vehicle at once, see README.md Test 5.
--
-- IMPORTANT lesson from the first attempt to test this manually: extensions.reload()
-- resets this module's state (M.enabled=false, M.graph=nil, no tracked
-- vehicles) but does NOT re-fire onClientStartMission -- that hook only fires
-- on an actual level load, not an extension reload. So calling
-- setFullControlEnabled(true) right after a reload, with nothing else set up,
-- does *nothing at all*: onUpdate's very first line returns immediately
-- because M.enabled/M.graph are still unset, and no vehicle ever had
-- ai.setMode('disabled') sent to it. Whatever driving was observed in that
-- state was still 100% native BeamNG AI.
--
-- This turned out to be a real, general gap, not just a manual-testing
-- footgun: confirmed in-game that after some play sessions M.enabled and
-- M.fullControlEnabled both read false with ZERO "beamai_core" log lines at
-- all (filtering the console log for "beamai" showed nothing) -- meaning
-- onClientStartMission genuinely never fired that session (e.g. the level
-- was already loaded before this extension's own load/reload happened).
-- Fixed with M.onExtensionLoaded() below (a real, confirmed hook -- see
-- lua/ge/extensions/core/busRouteManager.lua for the exact same pattern
-- shipped in the game itself): it calls the CONFIRMED real global
-- getMissionFilename() (also used the same way in environment.lua,
-- gamestate.lua, vehicles.lua, trafficSignals.lua) to check whether a level
-- is already loaded at the moment this extension loads, and self-activates
-- immediately if so, instead of only reacting to a future level-load event
-- that may never come.
--
-- Obstacle avoidance while in full control: implemented (updateFullControlAvoidance
-- below) by offsetting our own pure-pursuit lookahead target sideways
-- (roadGraph.offsetPointLateral) instead of nudging native side-avoidance,
-- which doesn't run anymore once ai.setMode('disabled') has been sent. The
-- side is chosen by checking which offset direction is actually clear of
-- other tracked vehicles right now (roadGraph.isOffsetPathClear). Confirmed
-- working in-game ("il esquive"). One bug found and fixed after that: the
-- clearance check included the obstacle itself, which is reliably closer
-- than minClearance to the offset target point, so both sides came back
-- "not clear" and no maneuver ever started in most cases -- the vehicle just
-- braked to a stop instead of going around. findLeaderOnSegment now returns
-- the leader's own id so it can be explicitly excluded from that check.
--
-- Turning at real intersections (router.lua, roadmap phase 2): until now,
-- findLookaheadPoint aimed at the junction itself rather than choosing a
-- branch -- no vehicle had a destination or a planned route at all. Now,
-- full-control vehicles get a random destination (router.planRandomRoute)
-- and actually follow the chosen branch through real junctions
-- (router.findLookaheadPointOnRoute), re-planning a new random destination
-- once they run off the end of their route. Respects one-way streets
-- (oneWay + flipDirection -- the latter wasn't even extracted from the game
-- before this). Route planning (an A* search) is capped at
-- MAX_ROUTE_PLANS_PER_TICK per tick so a burst of vehicles all needing a
-- route at once (e.g. right after registerAll()) can't stall a frame; a
-- vehicle without a route yet this tick just falls back to
-- roadGraph.findLookaheadPoint's older, never-turns heuristic until its turn
-- comes up. Not yet tested in-game. Rollback without touching anything else:
-- extensions.beamai_core.setRoutingEnabled(false).
--
-- Priority at real (non-signalized) junctions (roadmap phase 2): until now, a
-- "junction"-type node had zero priority logic -- vehicles just drove
-- straight through regardless of cross traffic, since only trafficLight
-- junctions were ever treated as a stop-line constraint. tools/extract_road_graph.py
-- now assigns each real junction a priorityRule -- "roadClassHierarchy" when
-- one approach is a strictly higher road class than the others (that
-- approach has priority, the rest yield), else "allWayStop" (everyone
-- yields -- the common USA unsignalized-intersection default, also just a
-- safe default in general: requiring a stop is never unsafe, only
-- cautious). findJunctionPriorityConstraint enforces a real, mandatory full
-- stop the first time a yielding vehicle reaches the line (not just a
-- yield/roll-through) -- tracked per vehicle per junction
-- (vehState.junctionStopState) -- then only re-imposes the constraint once
-- stopped if another moving vehicle is actually near the junction
-- (roadGraph.isCrossTrafficNearJunction, a straight-line-distance heuristic,
-- not real trajectory prediction -- see roadmap phase 3bis). No FIFO
-- ordering between multiple simultaneously-waiting vehicles yet (a vehicle
-- could in principle wait a long time if traffic keeps arriving on another
-- approach) -- a known, documented limitation, not an oversight. Not yet
-- tested in-game.

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
local router = require("beamai/router")

local M = {}

M.enabled = false
-- ON by default: obstacle avoidance for native-driven vehicles
-- OFF by default as of this revision -- reverted alongside
-- M.junctionPriorityEnabled below after a severe, confirmed in-game
-- regression (FPS 100 -> 20, every vehicle crawling at ~15 km/h everywhere)
-- on the first session where this mod's activation itself actually worked.
-- The underlying technique (updateNativeAvoidance boosting native's own
-- side_avoidance via ai.setParameters({awarenessForceCoef=...})) was
-- separately confirmed working in an earlier, isolated in-game test ("oui il
-- esquive"), so it's a less likely root cause than the newer, never-live-
-- tested junction priority system -- but reverted to off here too, to give
-- a clean, minimal, working baseline while the real cause is isolated one
-- toggle at a time rather than leaving two newly-reactivated systems on
-- simultaneously. Turn back on with setAvoidanceEnabled(true) once
-- junction priority has been cleared or fixed.
M.avoidanceEnabled = false
M.fullControlEnabled = false
M.autoScanEnabled = true
-- Whether onClientStartMission switches straight to full custom control for
-- every vehicle on a bundled map, with zero console commands needed.
--
-- OFF by default as of this revision -- reversed from an earlier ON default
-- after a direct, controlled in-game comparison: 6 native-driven traffic
-- vehicles held 120 FPS, 6 vehicles under full custom control (steering +
-- throttle/brake computed and dispatched by us every tick, replacing
-- ai.lua's own driving entirely) dropped to 30 FPS -- a real, measured, per-
-- vehicle cost that doesn't scale with vehicle count, so it isn't something
-- that only shows up "at scale". A hard budget was set explicitly: no more
-- than ~5 FPS lost versus stock native traffic. Full custom control cannot
-- meet that budget yet, so it is no longer the default -- the code stays
-- (real, tested, and a genuine longer-term ambition), but native ai.lua now
-- drives again by default, with this mod only overriding what native
-- driving actually gets wrong (see dispatchSpeed/findJunctionPriorityConstraint
-- for the stop-sign safety fix, and updatePlayerMergeSafety for the merge
-- safety mitigation, both below) -- an approach with near-zero added
-- per-tick cost, since ai.lua's own steering/path-following logic runs
-- regardless of what drives it, native or us.
M.autoFullControlOnStart = false
M.graph = nil
-- router.buildIndex(M.graph) result, rebuilt whenever M.graph changes (see
-- setGraphPath) -- expensive to build (scans every junction/segment once) so
-- built once per graph load, never per tick or per route request.
M.routingIndex = nil
-- Whether full-control vehicles actually turn at real junctions by following
-- a planned route (router.lua), vs. the older geometric-only fallback
-- (roadGraph.findLookaheadPoint, which just aims at any real junction it
-- meets). ON by default per explicit request -- see M.setRoutingEnabled.
M.routingEnabled = true
-- OFF by default as of this revision -- reverted after a severe, confirmed
-- in-game regression on the FIRST session where activation itself actually
-- worked (every earlier test of this feature had activation silently broken,
-- so it had never really been exercised live before): FPS 100 -> 20, and
-- every vehicle crawling at ~15 km/h regardless of road type, including deep
-- in a highway tunnel far from any real intersection. Root cause not yet
-- isolated -- prime suspects: west_coast_usa has 337 real junctions (194 of
-- them all-way-stop) packed into only 1303 segments, so MAX_LIGHT_LOOKAHEAD
-- (150m) may mean a vehicle is almost never actually clear of an upcoming
-- stop-priority junction, which combined with IDM could produce a
-- persistent low-speed equilibrium that then propagates backward through
-- following traffic via ordinary car-following -- or a real bug in
-- findUpcomingPriorityJunction/walkToNextRealJunction (router.lua) returning
-- a wrong/too-small distance. Kept available as an explicit opt-in
-- (M.setJunctionPriorityEnabled(true)) for isolating the cause without
-- forcing it on everyone by default while unresolved.
M.junctionPriorityEnabled = false
-- OFF by default too, TEMPORARILY, as the next diagnostic step: disabling
-- both avoidance and junction priority produced ZERO change to the reported
-- regression (still ~15 km/h everywhere, still ~20 FPS), which rules them
-- out and points at whatever still runs completely unconditionally --
-- findStopLineConstraint (traffic light lookahead) was the only such path
-- left. It correlates with a real, observed log line: "could not read live
-- traffic light state" -- trafficLights.isStopState fails safe by treating
-- an unreadable light as red, never green (docs/ARCHITECTURE.md section
-- 4.5), so if that live-state read is failing systematically (not just
-- once), EVERY one of west_coast_usa's ~130 traffic lights would look
-- permanently red to every vehicle, forcing a perpetual approach-and-crawl
-- cycle from light to light instead of ever reaching cruising speed. This
-- exact lookahead was rewritten this session (router.findUpcomingTrafficLight,
-- for performance) and has not been re-validated in-game since -- the
-- original, pre-rewrite version WAS validated successfully in the very
-- first playtest of this whole project. Disabling this now isolates whether
-- the regression is in this lookahead specifically (rewritten, unverified)
-- or somewhere even more fundamental (car-following/speed-limit dispatch,
-- unchanged since the first validated playtest). Turn back on with
-- setTrafficLightEnabled(true) once isolated.
M.trafficLightEnabled = false
-- vehId -> { profile, junctionDecision = {junctionId, obeys}, avoidanceState = <avoidance state> }
local trackedVehicles = {}
local JUNCTION_SEARCH_RADIUS = 8.0 -- metres; matches the extractor's clustering radius (~6m) plus margin
local MAX_LIGHT_LOOKAHEAD = 150.0 -- metres; far enough to brake comfortably from highway speed
local warnedNoLiveTrafficLightState = false
local REGISTER_SCAN_INTERVAL = 3.0 -- seconds between automatic re-scans for newly spawned vehicles
local MAX_ROUTE_PLANS_PER_TICK = 2 -- caps how many A* searches (router.findRoute) run in a single onUpdate tick
local timeSinceLastScan = math.huge -- forces an immediate scan on the first onUpdate
local AVOIDANCE_PARAMS = avoidance.defaultParams
local CREEP_SPEED_MS = 3.0 -- ~11 km/h; cautious speed while easing past a close obstacle
local DEFAULT_AWARENESS_COEF = 0.25 -- lua/vehicle/ai.lua's own default for parameters.awarenessForceCoef
local BOOSTED_AWARENESS_COEF = 1.0 -- more decisive native side-avoidance while easing past, at low speed
local STOP_SPEED_THRESHOLD_MS = 1.0 -- ~3.6 km/h; below this counts as "has come to a stop" at a priority junction
local STOP_ARRIVAL_RADIUS_M = 3.0 -- metres from the stop line within which a full stop actually counts
local CROSS_TRAFFIC_RADIUS_M = 18.0 -- metres from a junction within which another moving vehicle blocks a yield
local CROSS_TRAFFIC_MIN_SPEED_MS = 0.5 -- ignore other near-stationary (parked/already-waiting) vehicles near the junction

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
  -- Built once per graph load (scans every junction once) -- see router.lua
  -- header comment. Never rebuilt per tick or per vehicle.
  M.routingIndex = router.buildIndex(graph, JUNCTION_SEARCH_RADIUS)
  log("I", "beamai_core", string.format(
    "loaded road graph '%s': %d segments, %d junctions",
    tostring(graph.map), #graph.segments, #graph.junctions
  ))
  return true
end

function M.setEnabled(value)
  M.enabled = value and true or false
end

-- Switch for the lateral avoidance maneuver -- see the header comment above.
-- ON by default. Native-driven vehicles (the default path) boost native's
-- own side_avoidance responsiveness (updateNativeAvoidance). Under full
-- control (see M.setFullControlEnabled), this instead drives a lateral
-- offset of our own pure-pursuit lookahead target (updateFullControlAvoidance).
function M.setAvoidanceEnabled(value)
  M.avoidanceEnabled = value and true or false
end

-- Opt-in switch for the periodic auto re-scan (every REGISTER_SCAN_INTERVAL
-- seconds, see onUpdate) that picks up newly spawned vehicles by calling
-- registerAll(). ON by default for normal play. Turn OFF before an isolated
-- single-vehicle test (README.md Test 5): otherwise the very next onUpdate
-- tick after M.setEnabled(true) sweeps in every other vehicle on the map too
-- -- including, if M.fullControlEnabled is already on, disabling their native
-- AI as well. registerVehicle/registerAll still work manually while this is
-- off; only the automatic timer is affected.
function M.setAutoScanEnabled(value)
  M.autoScanEnabled = value and true or false
end

-- See M.autoFullControlOnStart above. Console override, e.g. to fall back to
-- the legacy ai.setSpeed-only path without restarting the game:
--   extensions.beamai_core.setAutoFullControlOnStart(false)
--   extensions.beamai_core.setFullControlEnabled(false) -- if already on this session
function M.setAutoFullControlOnStart(value)
  M.autoFullControlOnStart = value and true or false
end

-- Opt-in-by-default switch for route-following (router.lua): whether
-- full-control vehicles actually pick a destination and turn at real
-- junctions, vs. falling back to roadGraph.findLookaheadPoint's geometric
-- heuristic (aims at any real junction, never turns). Console rollback if
-- something looks wrong with turning specifically, without touching the rest
-- of the pilotage: extensions.beamai_core.setRoutingEnabled(false).
function M.setRoutingEnabled(value)
  M.routingEnabled = value and true or false
end

-- Opt-in-by-default switch for stop/yield priority at real (non-signalized)
-- junctions (findJunctionPriorityConstraint). Independent from
-- M.setRoutingEnabled -- this can be turned off on its own (vehicles keep
-- turning, but stop enforcing/yielding at unsignalized junctions) if it
-- turns out to be the culprit for a specific issue, without losing routing.
function M.setJunctionPriorityEnabled(value)
  M.junctionPriorityEnabled = value and true or false
end

-- Diagnostic toggle, see M.trafficLightEnabled above for why this exists and
-- what it's isolating. Turn back on once the regression is understood.
function M.setTrafficLightEnabled(value)
  M.trafficLightEnabled = value and true or false
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
      junctionStopState = { junctionId = nil, hasStopped = false }, -- stop-sign/yield state at a priority junction, see findJunctionPriorityConstraint
      avoidanceState = avoidance.newState(),
      speedControllerState = speedController.newState(),
      lastSegment = nil, -- sticky hint for roadGraph.findNearestSegmentNear, set every tick in onUpdate
      aiDisabled = false,
      route = nil,       -- router.lua route (list of {segId, entryEnd}), full-control + routing only
      routeIndex = nil,  -- which step of `route` the vehicle is currently on
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

-- Debug/introspection: is this specific vehicle actually being driven by
-- BeamAI right now (native ai.lua genuinely disabled on it), rather than
-- just "tracked" in general? Console check:
--   extensions.beamai_core.isVehicleUnderFullControl(12345)
-- Returns false for an untracked id, or a tracked vehicle still on the
-- legacy ai.setSpeed-only path (fullControlEnabled was off when it was
-- registered).
function M.isVehicleUnderFullControl(vehId)
  local vehState = trackedVehicles[vehId]
  return vehState ~= nil and vehState.aiDisabled == true
end

-- Debug/introspection: every vehicle id this mod is currently tracking, so
-- you don't have to guess one to pass to isVehicleUnderFullControl. Console
-- check: dump(extensions.beamai_core.getTrackedVehicleIds())
function M.getTrackedVehicleIds()
  local ids = {}
  for vehId in pairs(trackedVehicles) do
    table.insert(ids, vehId)
  end
  return ids
end

-- Switch for full custom control (own steering + own throttle/brake, ai.lua's
-- own driving disabled entirely) -- see the header comment above. Applied
-- automatically on map load by default (M.autoFullControlOnStart); this
-- function is the manual override, e.g. to force it off mid-session
-- (`setFullControlEnabled(false)`) or on for a specific vehicle registered by
-- hand. HIGHEST RISK setting in this mod.
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

-- Plain list of {x,y,z} for every tracked vehicle except `ownVehId` and
-- `leaderVehId` -- the shape roadGraph.isOffsetPathClear expects. Excluding
-- the leader is not optional: it's the very obstacle we're checking whether
-- we can drive around, sitting almost exactly at the offset target point
-- (roughly `gap` ahead, near-zero lateral offset from the lane centre) --
-- left in, it is reliably closer than minClearance to BOTH candidate offset
-- points, so isOffsetPathClear reports neither side clear and no maneuver
-- ever starts (the same bug this project already hit and fixed once before,
-- in the older ai.laneChange-based avoidance -- see docs/ARCHITECTURE.md
-- section 10, point 10). Only built when actually about to check a maneuver
-- (not every tick), since it's an O(n) allocation.
local function buildOtherPositionsList(positionsById, ownVehId, leaderVehId)
  local list = {}
  for otherVehId, data in pairs(positionsById) do
    if otherVehId ~= ownVehId and otherVehId ~= leaderVehId then
      table.insert(list, data.pos)
    end
  end
  return list
end

-- CORRECTION, caught before shipping: an earlier version of this function
-- used ai.driveUsingPath({routeOffset=X, avoidCars=...}), a technique copied
-- from reading a real, shipped community mod
-- (github.com/twiks228/Advancedtrafficaibeamg). That mod targets BeamNG
-- 0.38.3; checking OUR installed game's own lua/vehicle/ai.lua directly
-- (the driveUsingPath(arg) function, ~line 6702) shows its argument
-- validation requires arg.path, arg.wpTargetList, or arg.script to be a
-- table, or the function returns immediately doing nothing -- and there is
-- no `routeOffset` key anywhere in ai.lua at all in this version. Calling it
-- the way that mod does would have silently no-op'd every time, exactly
-- like the earlier ai.laneChange dead end. Reverted to the technique
-- already empirically confirmed working by direct in-game testing earlier
-- in this project ("oui il esquive"): temporarily boosting native's own
-- continuous side-avoidance responsiveness via
-- ai.setParameters({awarenessForceCoef=...}) -- confirmed real and exported
-- -- and letting native ai.lua's own side_avoidance (active whenever
-- avoidCars=='on', the default) work out the actual lateral maneuver and
-- clearance itself, rather than us computing our own offset/clearance for a
-- native-driven vehicle.
local function dispatchAwareness(vehObj, coef)
  vehObj:queueLuaCommand(string.format("ai.setParameters({awarenessForceCoef = %f})", coef))
end

-- Runs the creep-past state machine for one vehicle (avoidance.lua's state
-- machine, reused for its timing/hysteresis only -- native's own
-- side_avoidance computes the actual lateral offset and clearance, we only
-- decide when to boost its responsiveness and for how long).
local function updateNativeAvoidance(vehState, ownVehId, vehObj, vehGap, vehLeaderSpeed, ownSpeed, dtSim)
  local state = vehState.avoidanceState
  local wantsToAvoid = state.phase == avoidance.IDLE and mobil.shouldAttemptObstacleAvoidance(vehGap, vehLeaderSpeed)

  local distanceMoved = ownSpeed * dtSim
  local action = avoidance.update(state, dtSim, distanceMoved, wantsToAvoid, 1, AVOIDANCE_PARAMS)

  if action == "beginOffset" then
    log("I", "beamai_core", "vehicle " .. tostring(ownVehId) .. ": easing past a close, slow obstacle")
    dispatchAwareness(vehObj, BOOSTED_AWARENESS_COEF)
  elseif action == "returnToCentre" then
    dispatchAwareness(vehObj, DEFAULT_AWARENESS_COEF)
  end

  if state.phase ~= avoidance.IDLE then
    return nil, nil, true -- suppress the hard-stop constraint; caller applies a creep-speed cap instead
  end
  return vehGap, vehLeaderSpeed, false
end

-- Same idea as buildOtherPositionsList, but keeps each vehicle's speed too --
-- needed by roadGraph.isCrossTrafficNearJunction (a near-stationary vehicle
-- already waiting/parked near a junction shouldn't block a yield). Only
-- built when actually checking a junction yield, not every tick.
local function buildOtherPositionsWithSpeed(positionsById, ownVehId, leaderVehId)
  local list = {}
  for otherVehId, data in pairs(positionsById) do
    if otherVehId ~= ownVehId and otherVehId ~= leaderVehId then
      table.insert(list, { pos = data.pos, speed = data.speed })
    end
  end
  return list
end

-- Full-control equivalent of updateNativeAvoidance (above): there is no
-- native side_avoidance left to boost once ai.setMode('disabled') has been
-- sent, so this instead drives a continuous signed lateral offset (metres)
-- of our own pure-pursuit lookahead point (roadGraph.offsetPointLateral,
-- applied by the caller) -- the car steers toward a laterally-shifted target rather than
-- the raw path centreline. The side (left/right) is chosen only once, at the
-- moment the maneuver starts, by checking which offset direction is actually
-- clear of the other tracked vehicles right now (roadGraph.isOffsetPathClear,
-- unit tested standalone); if neither side is clear yet, no maneuver starts
-- this tick and the vehicle just keeps a safe IDM gap behind the obstacle
-- until an opening appears. Same idle/offsetting/returning timing/hysteresis
-- as the legacy path (avoidance.lua), reused unchanged.
local function updateFullControlAvoidance(vehState, ownVehId, leaderVehId, segment, ownProj, vehGap, vehLeaderSpeed, ownSpeed, dtSim, positionsById)
  local state = vehState.avoidanceState
  local wantsToAvoid = false
  local offsetSign = state.sign

  if state.phase == avoidance.IDLE and mobil.shouldAttemptObstacleAvoidance(vehGap, vehLeaderSpeed) then
    local others = buildOtherPositionsList(positionsById, ownVehId, leaderVehId)
    local offsetM = AVOIDANCE_PARAMS.offsetMetres
    local maneuverM = AVOIDANCE_PARAMS.maneuverDistance
    if roadGraph.isOffsetPathClear(segment, ownProj, offsetM, maneuverM, others) then
      wantsToAvoid, offsetSign = true, 1
    elseif roadGraph.isOffsetPathClear(segment, ownProj, -offsetM, maneuverM, others) then
      wantsToAvoid, offsetSign = true, -1
    end
    -- else: neither side clear right now -- stay idle, IDM keeps a safe gap and we retry next tick
  end

  local distanceMoved = ownSpeed * dtSim
  avoidance.update(state, dtSim, distanceMoved, wantsToAvoid, offsetSign, AVOIDANCE_PARAMS)
  local lateralOffsetMetres = avoidance.currentOffsetMetres(state, AVOIDANCE_PARAMS)

  if state.phase ~= avoidance.IDLE then
    return nil, nil, true, lateralOffsetMetres -- suppress the hard-stop constraint; caller applies a creep-speed cap instead
  end
  return vehGap, vehLeaderSpeed, false, lateralOffsetMetres
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
local function findStopLineConstraint(routingIndex, segment, entryEnd, ownProj, vehState)
  local junction, distance = router.findUpcomingTrafficLight(
    routingIndex, segment, entryEnd, ownProj, MAX_LIGHT_LOOKAHEAD)
  if not junction then
    return nil
  end

  -- tangentAtProjection always points in the segment's own nodes[1]->nodes[n]
  -- order; flip it when actually travelling the other way (entryEnd=="end")
  -- so pickBestInstance/queryLiveState picks the light facing our real
  -- direction of travel, not the opposite one. A latent bug fixed as a
  -- byproduct of adding entryEnd-awareness here (this whole lookahead used
  -- to silently assume forward travel only).
  local travelDir = roadGraph.tangentAtProjection(segment.nodes, ownProj)
  if entryEnd == "end" then
    travelDir = { -travelDir[1], -travelDir[2], -travelDir[3] }
  end
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

-- Real (non-signalized) junction priority: stop signs / priority-to-the-major-road
-- (roadmap phase 2, docs/ARCHITECTURE.md section 8). Two-stage, tracked per
-- vehicle per junction (vehState.junctionStopState, reset whenever the
-- upcoming junction id changes -- same pattern as junctionDecision above):
--   1. Not yet stopped -- treat the stop line as a hard constraint (virtual
--      stationary leader, exactly like a red light) regardless of whether
--      the junction is empty, until speed drops below STOP_SPEED_THRESHOLD_MS
--      within STOP_ARRIVAL_RADIUS_M of the line. This is what makes it a
--      real stop-sign-like "arrêt complet obligatoire, y compris sans trafic
--      visible" instead of a mere yield/roll-through.
--   2. Once stopped once at this junction: only re-impose the constraint
--      when another moving vehicle is actually near the junction
--      (roadGraph.isCrossTrafficNearJunction) -- otherwise clear to proceed.
-- Builds the cross-traffic position list (buildOtherPositionsWithSpeed) only
-- on the rare ticks it's actually needed -- i.e. once this vehicle has
-- already come to its mandatory stop -- rather than every tick for every
-- tracked vehicle, matching the same lazy pattern updateFullControlAvoidance
-- uses for its own clearance check.
local function findJunctionPriorityConstraint(routingIndex, segment, entryEnd, ownProj, vehState, ownVehId, leaderVehId, ownSpeed, positionsById)
  local junction, distance, mustYield = router.findUpcomingPriorityJunction(
    routingIndex, segment, entryEnd, ownProj, MAX_LIGHT_LOOKAHEAD)
  if not junction or not mustYield then
    return nil
  end

  if vehState.junctionStopState.junctionId ~= junction.id then
    vehState.junctionStopState.junctionId = junction.id
    vehState.junctionStopState.hasStopped = false
  end

  if distance <= 0 then
    return nil -- already at or past the stop line
  end

  if not vehState.junctionStopState.hasStopped then
    if ownSpeed < STOP_SPEED_THRESHOLD_MS and distance < STOP_ARRIVAL_RADIUS_M then
      vehState.junctionStopState.hasStopped = true
    else
      return distance -- keep decelerating toward a full stop at the line
    end
  end

  local otherPositions = buildOtherPositionsWithSpeed(positionsById, ownVehId, leaderVehId)
  if roadGraph.isCrossTrafficNearJunction(junction.position, otherPositions, CROSS_TRAFFIC_RADIUS_M, CROSS_TRAFFIC_MIN_SPEED_MS) then
    return distance -- stopped once already, but still yielding to real traffic
  end
  return nil -- stopped once, junction is clear: go
end

-- Merge/lane-change safety toward the player -- a MITIGATION, not a
-- root-cause fix (see the header comment on M.autoFullControlOnStart for
-- why we're not replacing native steering entirely anymore). Confirmed by
-- reading lua/vehicle/ai.lua directly: its own lane-change safety check
-- (ego.ghostL/ego.ghostR, which blocks a lane change into an occupied lane)
-- only looks at whether another vehicle is within roughly 1.2x combined
-- vehicle lengths RIGHT NOW (ai.lua ~line 2238: `ego2v < square((1.2 *
-- ego.length + 1.2*v.length))`) -- it never considers a vehicle further
-- back that's closing in fast, and that threshold is baked into ai.lua, not
-- exposed as a parameter we can override. route.laneChanges/ego.ghostL/R
-- are module-local to ai.lua too, so we can't inspect or cancel a specific
-- lane-change decision from outside. What we CAN do cheaply: notice when a
-- tracked (native-driven) vehicle is actively drifting sideways on its own
-- lane (a lane change plausibly in progress) while the player is following
-- fairly close behind it in roughly the same lateral band, and temporarily
-- cap that vehicle's own dispatched speed to open the gap it leaves --
-- makes a cut-in in front of the player less abrupt/close, without editing
-- ai.lua or costing more than a few vector operations per vehicle per tick.
local PLAYER_MERGE_WATCH_RADIUS_M = 25.0 -- metres behind the vehicle within which the player triggers this mitigation
local PLAYER_MERGE_LATERAL_BAND_M = 6.0 -- how far to the side of the vehicle's own lane the player still counts as "in the way"
local PLAYER_MERGE_LATERAL_SPEED_THRESHOLD_MS = 0.3 -- m/s of lateral drift counted as "actively changing lanes"
local PLAYER_MERGE_SPEED_CAP_FACTOR = 0.6 -- fraction of the vehicle's own current speed to cap it to when triggered

local function playerMergeSpeedCap(segment, ownProj, data, playerPos, playerVehId, ownVehId)
  if not playerPos or playerVehId == ownVehId then
    return nil
  end

  local lateralDir = roadGraph.lateralDirectionAtProjection(segment.nodes, ownProj)
  local lateralSpeed = roadGraph.dot(data.vel, lateralDir)
  if roadGraph.isRiskyMergeTarget(
      data.pos, data.heading, lateralDir, lateralSpeed, playerPos,
      PLAYER_MERGE_WATCH_RADIUS_M, PLAYER_MERGE_LATERAL_BAND_M, PLAYER_MERGE_LATERAL_SPEED_THRESHOLD_MS) then
    return data.speed * PLAYER_MERGE_SPEED_CAP_FACTOR
  end
  return nil
end

-- Which end of `segment` the vehicle is currently heading toward, inferred
-- from its real heading vector vs. the segment's tangent at its own
-- projection -- needed to seed router.findRoute/planRandomRoute with the
-- correct starting direction (a two-way segment can legally be driven either
-- way, so this can't be assumed).
local function guessEntryEnd(segment, ownProj, heading)
  local tangent = roadGraph.tangentAtProjection(segment.nodes, ownProj)
  if roadGraph.dot(tangent, roadGraph.normalize(heading)) >= 0 then
    return "start" -- heading roughly the same way as start->end
  end
  return "end" -- heading roughly the same way as end->start
end

-- Finds where in `route` the vehicle's current segment id appears, searching
-- forward from `hintIndex` first (sticky, same pattern as
-- roadGraph.findNearestSegmentNear) before falling back to a full scan.
-- Returns nil if `route` is nil or the segment isn't in it at all -- either
-- there is no active route yet, or the vehicle has driven past the end of
-- its planned route (or drifted off it), and the caller should plan a new one.
local function syncRouteIndex(route, hintIndex, currentSegId)
  if not route then
    return nil
  end
  for i = hintIndex or 1, #route do
    if route[i].segId == currentSegId then
      return i
    end
  end
  for i = 1, (hintIndex or 1) - 1 do
    if route[i].segId == currentSegId then
      return i
    end
  end
  return nil
end

-- Plans a fresh random-destination route for `vehState`, starting from its
-- current segment/direction, respecting a small per-tick budget
-- (routePlanBudget) so a burst of vehicles all needing a route on the same
-- tick (e.g. right after registerAll()) can't stall a single frame with
-- several A* searches at once -- see docs/ARCHITECTURE.md section 8 phase 9
-- (per-frame compute budget) for the same idea applied elsewhere later.
-- Returns the new routeIndex (always 1) on success, nil if the budget was
-- already spent this tick or no reachable destination was found.
local function planNewRouteIfBudgetAllows(vehState, routePlanBudget, currentSegId, currentEntryEnd)
  if routePlanBudget.remaining <= 0 then
    return nil
  end
  routePlanBudget.remaining = routePlanBudget.remaining - 1
  local route = router.planRandomRoute(M.routingIndex, currentSegId, currentEntryEnd)
  if route then
    vehState.route = route
    vehState.routeIndex = 1
    return 1
  end
  vehState.route = nil
  vehState.routeIndex = nil
  return nil
end

-- Auto-run hook: confirmed real signature (lua/ge/extensions/career/career.lua
-- and others), fired once a level finishes loading, with the level path. If we
-- have a bundled graph for this level, load it and switch on automatically --
-- no console commands needed for the zip-and-drop test (README.md).
-- Shared by both onClientStartMission (fires on a fresh level load) and
-- onExtensionLoaded (fires when this extension itself loads/reloads -- see
-- below for why that second path is necessary too).
local function activateForLevel(levelPath)
  local levelName = path.levelFromPath(levelPath)
  local graphPath = BUNDLED_GRAPHS[levelName]
  if not graphPath then
    log("I", "beamai_core", "no bundled road graph for level '" .. tostring(levelName) .. "', staying idle")
    return
  end
  timeSinceLastScan = math.huge
  if M.setGraphPath(graphPath) then
    if M.autoFullControlOnStart then
      M.setFullControlEnabled(true) -- flag only; applied per vehicle as registerAll picks each one up below
    end
    M.setEnabled(true) -- triggers onUpdate, which auto-registers every vehicle within REGISTER_SCAN_INTERVAL seconds
  end
end

function M.onClientStartMission(levelPath)
  activateForLevel(levelPath)
end

-- CONFIRMED real hook (lua/ge/extensions/core/busRouteManager.lua, which
-- uses exactly this pattern): fires once when this extension itself is
-- loaded or reloaded (extensions.reload("beamai_core")), taking no
-- arguments -- unlike onClientStartMission, which only fires on an actual
-- fresh level load. Without this, a real gap existed: if the level was
-- already loaded before this extension loaded/reloaded (e.g. the mod was
-- installed/updated mid-session, or something else caused the extension to
-- (re)load after the mission had already started), onClientStartMission
-- would simply never fire again and the mod would silently stay disabled
-- forever -- confirmed in practice (M.enabled/M.fullControlEnabled both
-- read false in-game with no "beamai_core" log lines at all, i.e.
-- onClientStartMission never ran). getMissionFilename() (CONFIRMED real,
-- engine-exposed global, used the same way in busRouteManager.lua,
-- environment.lua, gamestate.lua, vehicles.lua, trafficSignals.lua) returns
-- the current level's path, or "" if no level is loaded (e.g. main menu) --
-- treat that exactly as if onClientStartMission had just fired with it.
function M.onExtensionLoaded()
  local levelPath = getMissionFilename()
  if levelPath and levelPath ~= "" then
    activateForLevel(levelPath)
  end
end

function M.onClientEndMission()
  M.setEnabled(false)
  M.graph = nil
  M.routingIndex = nil
  trackedVehicles = {}
end

function M.onUpdate(dtReal, dtSim, dtRaw)
  if not M.enabled or not M.graph then
    return
  end

  -- Automatically pick up newly spawned/despawned vehicles every few seconds,
  -- so nobody has to call registerAll() by hand after spawning traffic.
  if M.autoScanEnabled then
    timeSinceLastScan = timeSinceLastScan + dtSim
    if timeSinceLastScan >= REGISTER_SCAN_INTERVAL then
      timeSinceLastScan = 0
      M.registerAll()
    end
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

  local routePlanBudget = { remaining = MAX_ROUTE_PLANS_PER_TICK }

  -- For playerMergeSpeedCap below -- computed once per tick, not per vehicle.
  local playerPos, playerVehId = nil, nil
  do
    local playerVeh = be:getPlayerVehicle(0)
    if playerVeh then
      playerVehId = playerVeh:getID()
      local p = playerVeh:getPosition()
      playerPos = { p.x, p.y, p.z }
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
      -- Computed once per vehicle per tick and reused by routing, the
      -- traffic-light lookahead, and the priority-junction lookahead below --
      -- a two-way segment can legally be driven in either direction, so this
      -- can't be assumed from the segment's own node order alone.
      local entryEnd = guessEntryEnd(segment, ownProj, data.heading)
      local vehGap, vehLeaderSpeed, vehLeaderId = findLeaderOnSegment(segment, vehId, ownProj, positionsById)

      -- Under full control there's no native path-following left to nudge (it
      -- stopped running once ai.setMode('disabled') was sent), so avoidance
      -- there instead offsets our own steering target laterally
      -- (updateFullControlAvoidance). Native-driven vehicles instead boost
      -- native's own side_avoidance responsiveness (updateNativeAvoidance,
      -- ai.setParameters({awarenessForceCoef=...})) -- confirmed working by
      -- direct in-game testing, unlike ai.laneChange or routeOffset (see
      -- updateNativeAvoidance's header comment for why routeOffset doesn't
      -- work in this game version despite appearing to in a reference mod).
      local isCreepingPastObstacle = false
      local lateralOffsetMetres = 0
      if M.avoidanceEnabled then
        if M.fullControlEnabled then
          vehGap, vehLeaderSpeed, isCreepingPastObstacle, lateralOffsetMetres = updateFullControlAvoidance(
            vehState, vehId, vehLeaderId, segment, ownProj, vehGap, vehLeaderSpeed, data.speed, dtSim, positionsById)
        else
          vehGap, vehLeaderSpeed, isCreepingPastObstacle = updateNativeAvoidance(
            vehState, vehId, data.obj, vehGap, vehLeaderSpeed, data.speed, dtSim)
        end
      end

      local lightGap = nil
      if M.trafficLightEnabled then
        lightGap = findStopLineConstraint(M.routingIndex, segment, entryEnd, ownProj, vehState)
      end
      local junctionGap = nil
      if M.junctionPriorityEnabled then
        junctionGap = findJunctionPriorityConstraint(
          M.routingIndex, segment, entryEnd, ownProj, vehState, vehId, vehLeaderId, data.speed, positionsById)
      end

      -- Whichever obstacle is nearer along the path is the binding constraint
      -- for IDM (same simplification used by most simple traffic-AI stacks:
      -- a stop line -- traffic light or priority junction -- is just a
      -- stationary leader at speed 0).
      local gap, leaderSpeed = vehGap, vehLeaderSpeed
      if lightGap ~= nil and (gap == nil or lightGap < gap) then
        gap, leaderSpeed = lightGap, 0
      end
      if junctionGap ~= nil and (gap == nil or junctionGap < gap) then
        gap, leaderSpeed = junctionGap, 0
      end

      local profile = vehState.profile
      local idmParams = driverProfile.applyIdmOverrides(idm.defaultParams, profile)
      idmParams.desiredSpeed = ((segment.speedLimit or 50) / 3.6) * profile.speedFactor
      if isCreepingPastObstacle then
        idmParams.desiredSpeed = math.min(idmParams.desiredSpeed, CREEP_SPEED_MS)
      end

      local targetSpeed = idm.nextSpeed(data.speed, leaderSpeed or 0, gap, dtSim, idmParams)

      local mergeSpeedCap = playerMergeSpeedCap(segment, ownProj, data, playerPos, playerVehId, vehId)
      if mergeSpeedCap then
        targetSpeed = math.min(targetSpeed, mergeSpeedCap)
      end

      if M.fullControlEnabled then
        local lookahead = steeringController.lookaheadDistance(data.speed)
        local target = nil

        -- Route-following: actually turn at real junctions (router.lua)
        -- instead of just aiming at them. Falls back to the geometric-only
        -- heuristic (roadGraph.findLookaheadPoint, never turns) whenever
        -- there's no usable route yet -- routing disabled, graph has no
        -- routing index, this vehicle's route ran out/was never planned and
        -- the per-tick A* budget is already spent, or no reachable
        -- destination was found -- so a vehicle is never left without any
        -- lookahead target at all.
        if M.routingEnabled and M.routingIndex then
          local syncedIndex = syncRouteIndex(vehState.route, vehState.routeIndex, segment.id)
          if not syncedIndex then
            syncedIndex = planNewRouteIfBudgetAllows(vehState, routePlanBudget, segment.id, entryEnd)
          end
          if syncedIndex then
            vehState.routeIndex = syncedIndex
            target = router.findLookaheadPointOnRoute(M.routingIndex, vehState.route, syncedIndex, ownProj, lookahead)
          end
        end

        if not target then
          target = roadGraph.findLookaheadPoint(M.graph, segment, ownProj, lookahead, JUNCTION_SEARCH_RADIUS)
        end

        if lateralOffsetMetres ~= 0 then
          local lateralDir = roadGraph.lateralDirectionAtProjection(segment.nodes, ownProj)
          target = roadGraph.offsetPointLateral(target, lateralDir, lateralOffsetMetres)
        end
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
