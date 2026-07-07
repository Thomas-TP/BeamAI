-- Per-vehicle lateral-avoidance state machine: idle -> offsetting -> returning
-- -> idle. Pure logic, no BeamNG dependency, unit tested standalone -- the
-- actual ai.laneChange dispatch (the risky, unverified-in-game part) is a
-- side effect the caller (core.lua) performs based on the action this module
-- returns, never here. Keeping the two separate means the state-transition
-- logic itself -- when to start, how long to hold, the hard safety timeout --
-- is fully testable even though the physical maneuver isn't.

local M = {}

M.IDLE = "idle"
M.OFFSETTING = "offsetting"
M.RETURNING = "returning"

M.defaultParams = {
  offsetMetres = 2.2,      -- lateral shift requested from ai.laneChange / the full-control steering target
  maneuverDistance = 20.0, -- metres the ai.laneChange ramp is applied over
  holdDistance = 15.0,     -- metres travelled while offset before starting to return
  maxDuration = 15.0,      -- seconds; hard safety timeout back to centre no matter what
  rampDistance = 5.0,      -- metres over which currentOffsetMetres eases in/out, avoiding a steering step
}

function M.newState()
  return { phase = M.IDLE, sign = 1, distanceTravelled = 0, elapsed = 0 }
end

-- Call once per tick. Mutates `state` in place. Returns an action string the
-- caller must act on:
--   nil               -- nothing to do this tick
--   "beginOffset"      -- dispatch ai.laneChange(.., +params.offsetMetres * offsetSign)
--   "returnToCentre"   -- dispatch ai.laneChange(.., -(previous offset)) to recentre
function M.update(state, dt, distanceMovedThisTick, wantsToAvoid, offsetSign, params)
  params = params or M.defaultParams

  if state.phase == M.IDLE then
    if wantsToAvoid then
      state.phase = M.OFFSETTING
      state.sign = offsetSign or 1
      state.distanceTravelled = 0
      state.elapsed = 0
      return "beginOffset"
    end
    return nil
  end

  state.distanceTravelled = state.distanceTravelled + (distanceMovedThisTick or 0)
  state.elapsed = state.elapsed + (dt or 0)

  if state.elapsed >= params.maxDuration then
    -- Safety net: something took too long (stuck, blocked, logic bug) -- bail out.
    state.phase = M.IDLE
    return "returnToCentre"
  end

  if state.phase == M.OFFSETTING and state.distanceTravelled >= params.holdDistance then
    state.phase = M.RETURNING
    return "returnToCentre"
  end

  if state.phase == M.RETURNING and state.distanceTravelled >= params.holdDistance + params.maneuverDistance then
    state.phase = M.IDLE
  end

  return nil
end

-- Continuous signed lateral offset (metres) for the *current* state, eased in
-- and out over params.rampDistance instead of stepping straight to
-- offsetMetres -- used by the full-control path (core.lua) to bend the
-- pure-pursuit lookahead target sideways smoothly, tick by tick. Call after
-- M.update() so state reflects this tick's phase/distanceTravelled already.
-- Pure function of state, no side effects.
function M.currentOffsetMetres(state, params)
  params = params or M.defaultParams
  local ramp = params.rampDistance or 5.0

  if state.phase == M.OFFSETTING then
    local t = ramp > 1e-9 and math.min(state.distanceTravelled / ramp, 1.0) or 1.0
    return state.sign * params.offsetMetres * t
  end

  if state.phase == M.RETURNING then
    local distanceIntoReturn = state.distanceTravelled - params.holdDistance
    local t = ramp > 1e-9 and math.max(1.0 - distanceIntoReturn / ramp, 0.0) or 0.0
    return state.sign * params.offsetMetres * t
  end

  return 0
end

return M
