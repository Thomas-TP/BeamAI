-- Lateral-maneuver decision logic (MOBIL-inspired: Kesting, Treiber, Helbing
-- 2007 -- see docs/ARCHITECTURE.md section 2.3/4.4). Pure math, no BeamNG
-- dependency, unit tested standalone. Two decisions live here:
--   1. shouldChangeLane -- the general gain/safety/politeness criterion, kept
--      for a future overtake-of-a-slower-vehicle decision (not wired up yet).
--   2. shouldAttemptObstacleAvoidance -- the simpler, more specific trigger
--      actually used today: a stopped/near-stopped obstacle close enough that
--      IDM would otherwise just brake to a halt behind it indefinitely.

local M = {}

M.defaultParams = {
  politeness = 0.3,
  changeThreshold = 0.3,      -- m/s^2; minimum net benefit to bother changing lane
  maxSafeDeceleration = 4.0,  -- m/s^2; a follower in the target lane must not be forced to brake harder than this
}

-- ownAccelCurrent: our acceleration if we stay put (may be very negative if blocked).
-- ownAccelIfChanged: our acceleration in the target lane/position.
-- newFollowerAccelBefore/After: acceleration of whoever would end up behind us
--   over there, before/after we'd move in (nil if nobody -- always safe).
-- Returns true if the lane change is both worthwhile and safe.
function M.shouldChangeLane(ownAccelCurrent, ownAccelIfChanged, newFollowerAccelBefore, newFollowerAccelAfter, params)
  params = params or M.defaultParams

  if newFollowerAccelAfter ~= nil and newFollowerAccelAfter < -params.maxSafeDeceleration then
    return false -- safety criterion: would force an unsafe brake on the follower
  end

  local followerAccelDelta = 0
  if newFollowerAccelBefore ~= nil and newFollowerAccelAfter ~= nil then
    followerAccelDelta = newFollowerAccelAfter - newFollowerAccelBefore
  end

  local incentive = (ownAccelIfChanged - ownAccelCurrent) + params.politeness * followerAccelDelta
  return incentive > params.changeThreshold
end

-- obstacleGap (metres) / obstacleSpeed (m/s): the leader currently constraining
-- us (from core.lua's findLeaderOnSegment). Returns true if it's close and
-- slow enough that going around it is worth considering, instead of just
-- queueing up behind it forever (e.g. a stalled car, not merely slow traffic).
function M.shouldAttemptObstacleAvoidance(obstacleGap, obstacleSpeed, maxAvoidGap, maxObstacleSpeed)
  maxAvoidGap = maxAvoidGap or 25.0
  maxObstacleSpeed = maxObstacleSpeed or 1.0
  return obstacleGap ~= nil and obstacleGap <= maxAvoidGap
    and obstacleSpeed ~= nil and obstacleSpeed <= maxObstacleSpeed
end

return M
