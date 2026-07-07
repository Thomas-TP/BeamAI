-- Per-vehicle driving personality (docs/ARCHITECTURE.md section 7.I): not
-- every driver follows the rules or the speed limit with the same strictness.
-- Pure Lua, no BeamNG dependency -- unit tested standalone.
--
-- Deliberately simple for v0: one profile is rolled per vehicle when it is
-- first registered and kept for the rest of the session (no per-event
-- re-rolling, which would make a driver flicker between obeying and ignoring
-- the same light frame to frame). A single fixed personality per vehicle is a
-- coarser approximation than a real per-trip mood, but it is stable and
-- testable; richer per-event variation is a later refinement.

local M = {}

M.defaultDistribution = {
  speedFactorMin = 0.85,        -- slowest drivers: 85% of the speed limit
  speedFactorMax = 1.20,        -- fastest drivers: 120% of the speed limit (speeding)
  recklessProbability = 0.08,   -- ~8% of drivers sometimes run a stop/red light
  recklessIgnoreProbability = 0.5, -- even a reckless driver only blows through it about half the time
  cautiousProbability = 0.2,    -- ~20% of the (non-reckless) rest are notably more cautious
}

-- rng: injectable for tests (defaults to math.random). Returns a profile table:
--   speedFactor          -- multiplier on the road's speed limit for this driver
--   isReckless           -- occasionally ignores stop lines (see decidesToStop)
--   isCautious           -- larger headway, gentler acceleration/braking
--   idmOverrides          -- table to merge over idm.defaultParams
--   runsControlThisTime() -- call once per approach to a stop line; see below
function M.generate(rng, distribution)
  rng = rng or math.random
  distribution = distribution or M.defaultDistribution

  local speedFactor = distribution.speedFactorMin
    + rng() * (distribution.speedFactorMax - distribution.speedFactorMin)
  local isReckless = rng() < distribution.recklessProbability
  local isCautious = (not isReckless) and rng() < distribution.cautiousProbability

  local idmOverrides = {}
  if isCautious then
    idmOverrides.timeHeadway = 2.2
    idmOverrides.comfortableBraking = 1.4
    idmOverrides.maxAcceleration = 1.0
  elseif isReckless then
    idmOverrides.timeHeadway = 1.0
    idmOverrides.comfortableBraking = 2.6
    idmOverrides.maxAcceleration = 2.0
  end

  return {
    speedFactor = speedFactor,
    isReckless = isReckless,
    isCautious = isCautious,
    idmOverrides = idmOverrides,
    recklessIgnoreProbability = distribution.recklessIgnoreProbability,
  }
end

-- Whether THIS driver actually obeys a stop line encountered right now.
-- Only reckless profiles ever say no, and only some of the time -- everyone
-- else always stops. Vehicle-ahead collision avoidance is never affected by
-- this (see core.lua): a reckless driver still won't rear-end someone, they
-- just may not stop for a light/stop sign with nothing physically blocking it.
function M.decidesToObeyStopLine(profile, rng)
  rng = rng or math.random
  if profile.isReckless and rng() < (profile.recklessIgnoreProbability or 0.5) then
    return false
  end
  return true
end

-- Merges profile.idmOverrides over a base params table (e.g. idm.defaultParams),
-- without mutating either input.
function M.applyIdmOverrides(baseParams, profile)
  local merged = {}
  for k, v in pairs(baseParams) do
    merged[k] = v
  end
  for k, v in pairs(profile.idmOverrides or {}) do
    merged[k] = v
  end
  return merged
end

return M
