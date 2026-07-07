-- Intelligent Driver Model (Treiber, Hennecke, Helbing, 2000).
-- Pure math, no BeamNG API dependency -- see docs/ARCHITECTURE.md section 4.4.
-- Computes longitudinal acceleration from own speed, leader speed and gap.

local M = {}

M.defaultParams = {
  desiredSpeed = 13.9,       -- v0, m/s (~50 km/h)
  timeHeadway = 1.5,         -- T, seconds
  maxAcceleration = 1.4,     -- a, m/s^2
  comfortableBraking = 2.0,  -- b, m/s^2
  minGap = 2.0,              -- s0, metres
  accelerationExponent = 4,  -- delta
}

-- gap: bumper-to-bumper distance to the leader in metres, or nil/math.huge if none.
-- speed, leaderSpeed: m/s. Returns acceleration in m/s^2 (can be negative).
function M.acceleration(speed, leaderSpeed, gap, params)
  params = params or M.defaultParams
  local v0 = params.desiredSpeed
  local T = params.timeHeadway
  local a = params.maxAcceleration
  local b = params.comfortableBraking
  local s0 = params.minGap
  local delta = params.accelerationExponent

  local freeRoadTerm = 1 - (speed / v0) ^ delta

  local interactionTerm = 0
  if gap ~= nil and gap ~= math.huge then
    local deltaV = speed - leaderSpeed
    local desiredGap = s0 + math.max(0, speed * T + (speed * deltaV) / (2 * math.sqrt(a * b)))
    local s = math.max(gap, 0.1) -- avoid divide-by-zero on (near) bumper-to-bumper contact
    interactionTerm = (desiredGap / s) ^ 2
  end

  return a * (freeRoadTerm - interactionTerm)
end

-- Integrates acceleration over dt seconds; returns the new speed (clamped >= 0) and
-- the acceleration actually applied, for callers that want to log/inspect it.
function M.nextSpeed(speed, leaderSpeed, gap, dt, params)
  local accel = M.acceleration(speed, leaderSpeed, gap, params)
  local newSpeed = speed + accel * dt
  if newSpeed < 0 then
    newSpeed = 0
  end
  return newSpeed, accel
end

return M
