-- Pure-pursuit steering controller -- computes a normalized steering command
-- from the vehicle's own position/heading/speed and a lookahead point on its
-- path (see roadGraph.pointAtDistance). Pure Lua, no BeamNG dependency, unit
-- tested standalone.
--
-- This exists because the project's direction (see docs/ARCHITECTURE.md) is
-- to build BeamAI's own driving stack rather than lean on BeamNG's native
-- ai.lua path-following/steering -- this replaces that entirely for lateral
-- control. The actual physical control injection (input.event("steering", ...))
-- lives in core.lua; this module only computes the number.
--
-- Sign convention UNCONFIRMED in-game: this returns a positive value when the
-- lookahead point is to the vehicle's left (standard pure-pursuit/robotics
-- convention: steering curvature positive = turn left). Whether BeamNG's
-- input.event("steering", v) expects positive v for left or right has not
-- been observed yet -- see README.md for the isolated test to confirm this,
-- and STEERING_SIGN below to flip it in one place if reversed.

local M = {}

M.STEERING_SIGN = 1 -- flip to -1 here if in-game testing shows the car turns the wrong way

M.defaultParams = {
  wheelbase = 2.7,           -- metres; rough average passenger car, tune per vehicle later
  maxSteeringAngle = 0.6,    -- radians (~34 degrees); rough average front-wheel lock angle
  minLookahead = 4.0,        -- metres; lookahead distance at very low speed
  lookaheadPerSpeed = 1.2,   -- extra metres of lookahead per m/s of speed (look further ahead when faster)
  maxLookahead = 40.0,       -- metres; cap so we don't look absurdly far ahead at high speed
}

-- Speed (m/s) -> lookahead distance (m). Pure function, unit tested.
function M.lookaheadDistance(speed, params)
  params = params or M.defaultParams
  local d = params.minLookahead + params.lookaheadPerSpeed * math.max(speed, 0)
  return math.min(d, params.maxLookahead)
end

local function normalize2(x, y)
  local len = math.sqrt(x * x + y * y)
  if len < 1e-9 then
    return 0, 0
  end
  return x / len, y / len
end

-- vehiclePos, vehicleHeading: {x,y,z} (heading need not be normalized; z is
-- ignored -- steering is computed in the horizontal plane). lookaheadPoint:
-- {x,y,z}, typically roadGraph.pointAtDistance(path, ownDistanceAlong +
-- lookaheadDistance(speed)). Returns a steering command in [-1, 1].
function M.computeSteering(vehiclePos, vehicleHeading, lookaheadPoint, params)
  params = params or M.defaultParams

  local toTargetX = lookaheadPoint[1] - vehiclePos[1]
  local toTargetY = lookaheadPoint[2] - vehiclePos[2]
  local dist = math.sqrt(toTargetX * toTargetX + toTargetY * toTargetY)
  if dist < 1e-6 then
    return 0
  end

  local fwdX, fwdY = normalize2(vehicleHeading[1], vehicleHeading[2])
  if fwdX == 0 and fwdY == 0 then
    return 0
  end
  -- "left" is the forward vector rotated +90 degrees (standard robotics
  -- convention: positive lateral = left of travel direction).
  local leftX, leftY = -fwdY, fwdX

  local forwardComponent = toTargetX * fwdX + toTargetY * fwdY
  local lateralComponent = toTargetX * leftX + toTargetY * leftY

  local alpha = math.atan(lateralComponent, forwardComponent) -- atan2(lateral, forward)
  local curvature = 2 * math.sin(alpha) / dist
  local steeringAngle = math.atan(params.wheelbase * curvature)

  local normalized = M.STEERING_SIGN * steeringAngle / params.maxSteeringAngle
  if normalized > 1 then
    normalized = 1
  elseif normalized < -1 then
    normalized = -1
  end
  return normalized
end

return M
