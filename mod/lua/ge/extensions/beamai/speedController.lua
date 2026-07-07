-- PID speed tracker -- converts a target speed (from idm.lua) into throttle
-- and brake commands in [0, 1], for direct input.event() injection (see
-- core.lua and docs/ARCHITECTURE.md for why this replaces ai.setSpeed).
-- Pure Lua, no BeamNG dependency, unit tested standalone.

local M = {}

M.defaultParams = {
  kp = 0.4,
  ki = 0.05,
  kd = 0.0,
  integralMax = 2.0, -- anti-windup clamp on the accumulated integral term
}

function M.newState()
  return { integral = 0, lastError = 0 }
end

-- Mutates `state` in place. currentSpeed/targetSpeed in m/s, dt in seconds.
-- Returns throttle, brake (both in [0, 1], never both nonzero at once).
function M.compute(state, currentSpeed, targetSpeed, dt, params)
  params = params or M.defaultParams

  local err = targetSpeed - currentSpeed
  state.integral = state.integral + err * dt
  if state.integral > params.integralMax then
    state.integral = params.integralMax
  elseif state.integral < -params.integralMax then
    state.integral = -params.integralMax
  end
  local derivative = dt > 0 and (err - state.lastError) / dt or 0
  state.lastError = err

  local output = params.kp * err + params.ki * state.integral + params.kd * derivative

  if output > 0 then
    return math.min(output, 1), 0
  else
    return 0, math.min(-output, 1)
  end
end

return M
