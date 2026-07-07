-- Loads and queries the semantic road graph produced by
-- tools/extract_road_graph.py (see docs/ARCHITECTURE.md section 4.2).
--
-- The geometry helpers (closestPointOnPolyline, distanceAlongSegment) are pure
-- Lua with no BeamNG dependency and are unit-tested standalone. loadGraph() is
-- the only part that touches BeamNG's engine globals (readFile / jsonDecode)
-- and needs in-game confirmation -- it is a thin wrapper on purpose.

local M = {}

local function vsub(a, b)
  return { a[1] - b[1], a[2] - b[2], a[3] - b[3] }
end

local function vlen(v)
  return math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
end

local function vdot(a, b)
  return a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
end

-- Projects `point` ({x,y,z}) onto the polyline `nodes` (list of {x,y,z,width,...}).
-- Returns a table:
--   segmentIndex    -- index i such that the projection falls on nodes[i]-nodes[i+1]
--   t               -- 0..1 fraction along that sub-segment
--   point           -- {x,y,z} of the projected point
--   lateralOffset   -- perpendicular distance from `point` to the polyline (metres)
--   distanceAlong   -- cumulative arc length from nodes[1] to the projected point
-- Returns nil if `nodes` has fewer than 2 points.
function M.closestPointOnPolyline(nodes, point)
  if #nodes < 2 then
    return nil
  end

  local best = nil
  local cumulative = 0.0

  for i = 1, #nodes - 1 do
    local a, b = nodes[i], nodes[i + 1]
    local ab = vsub(b, a)
    local abLen = vlen(ab)
    local t = 0.0
    if abLen > 1e-9 then
      local ap = vsub(point, a)
      t = vdot(ap, ab) / (abLen * abLen)
      if t < 0 then
        t = 0
      elseif t > 1 then
        t = 1
      end
    end
    local proj = { a[1] + ab[1] * t, a[2] + ab[2] * t, a[3] + ab[3] * t }
    local lateral = vlen(vsub(point, proj))

    if best == nil or lateral < best.lateralOffset then
      best = {
        segmentIndex = i,
        t = t,
        point = proj,
        lateralOffset = lateral,
        distanceAlong = cumulative + t * abLen,
      }
    end
    cumulative = cumulative + abLen
  end

  return best
end

-- Arc length of `nodes` between two points already expressed as {segmentIndex, t}
-- (as returned by closestPointOnPolyline). Assumes fromPos comes before toPos
-- along the polyline; negative results mean toPos is actually behind fromPos.
function M.distanceAlong(nodes, fromPos, toPos)
  local function cumulativeAt(pos)
    local cumulative = 0.0
    for i = 1, pos.segmentIndex - 1 do
      cumulative = cumulative + vlen(vsub(nodes[i + 1], nodes[i]))
    end
    local a, b = nodes[pos.segmentIndex], nodes[pos.segmentIndex + 1]
    cumulative = cumulative + pos.t * vlen(vsub(b, a))
    return cumulative
  end
  return cumulativeAt(toPos) - cumulativeAt(fromPos)
end

function M.normalize(v)
  local len = vlen(v)
  if len < 1e-9 then
    return { 0, 0, 0 }
  end
  return { v[1] / len, v[2] / len, v[3] / len }
end

M.dot = vdot

-- Normalized travel direction at a projection (as returned by
-- closestPointOnPolyline): the direction of the polyline's sub-segment the
-- projection falls on, in node order.
function M.tangentAtProjection(nodes, proj)
  local a, b = nodes[proj.segmentIndex], nodes[proj.segmentIndex + 1]
  local d = vsub(b, a)
  local len = vlen(d)
  if len < 1e-9 then
    return { 0, 0, 0 }
  end
  return { d[1] / len, d[2] / len, d[3] / len }
end

-- Total arc length of a polyline (list of {x,y,z,...} nodes).
function M.segmentLength(nodes)
  local total = 0.0
  for i = 1, #nodes - 1 do
    total = total + vlen(vsub(nodes[i + 1], nodes[i]))
  end
  return total
end

-- Finds the closest junction to `point` within `radius` metres, or nil if none.
-- Used to check whether a segment's far end (the direction of travel) leads
-- into a signalized junction -- see core.lua.
function M.findJunctionNear(graph, point, radius)
  local best, bestDist = nil, nil
  for _, j in ipairs(graph.junctions) do
    local d = vlen(vsub(j.position, point))
    if d <= radius and (bestDist == nil or d < bestDist) then
      best, bestDist = j, d
    end
  end
  return best
end

-- Looks ahead from `ownProj` (on `segment`) for the nearest upcoming
-- trafficLight junction, transparently following "continuation" junctions
-- (the same logical road split into consecutive DecalRoad pieces -- see
-- tools/extract_road_graph.py classify_cluster) so a light several segments
-- ahead is found early enough to brake comfortably, instead of only being
-- noticed once the vehicle is on the final short segment leading into it.
-- Stops looking (returns nil) at a real, unclassified junction -- turning
-- there is a decision this v0 does not make (roadmap phase 2).
--
-- Returns junction, distanceToStopLine (metres from ownProj) or nil, nil.
function M.findUpcomingTrafficLight(graph, segment, ownProj, maxLookahead, junctionRadius)
  local distanceSoFar = M.segmentLength(segment.nodes) - ownProj.distanceAlong
  local currentSeg = segment
  local visited = { [segment.id] = true }

  while distanceSoFar <= maxLookahead do
    local endNode = currentSeg.nodes[#currentSeg.nodes]
    local junction = M.findJunctionNear(graph, { endNode[1], endNode[2], endNode[3] }, junctionRadius)
    if not junction then
      return nil, nil
    end
    if junction.type == "trafficLight" then
      return junction, distanceSoFar
    end
    if junction.type ~= "continuation" then
      return nil, nil -- a real junction (or unclassified): phase-2 territory, stop here
    end

    local nextId = nil
    for _, sid in ipairs(junction.approaches) do
      if sid ~= currentSeg.id then
        nextId = sid
      end
    end
    if not nextId or visited[nextId] then
      return nil, nil
    end
    visited[nextId] = true

    local nextSeg = M.findSegmentById(graph, nextId)
    if not nextSeg then
      return nil, nil
    end
    distanceSoFar = distanceSoFar + M.segmentLength(nextSeg.nodes)
    currentSeg = nextSeg
  end

  return nil, nil
end

function M.findSegmentById(graph, id)
  for _, seg in ipairs(graph.segments) do
    if seg.id == id then
      return seg
    end
  end
  return nil
end

-- Finds the graph segment whose polyline passes closest to `point`.
-- Returns segment, projection (as from closestPointOnPolyline), or nil, nil.
function M.findNearestSegment(graph, point)
  local bestSeg, bestProj = nil, nil
  for _, seg in ipairs(graph.segments) do
    local proj = M.closestPointOnPolyline(seg.nodes, point)
    if proj and (bestProj == nil or proj.lateralOffset < bestProj.lateralOffset) then
      bestSeg, bestProj = seg, proj
    end
  end
  return bestSeg, bestProj
end

-- Same result as findNearestSegment, but checks `hintSegment` (typically the
-- vehicle's segment from the previous tick) first and returns immediately if
-- the point still projects onto it closely enough -- avoids rescanning every
-- segment in the graph (hundreds to thousands of them) for every vehicle on
-- every single tick, which is the dominant cost of core.lua's onUpdate and
-- was the direct cause of an observed in-game performance drop with ~24
-- tracked vehicles. Falls back to the full scan when there is no hint or the
-- vehicle has left it (e.g. crossed into the next segment, or first tick).
function M.findNearestSegmentNear(graph, point, hintSegment)
  if hintSegment then
    local proj = M.closestPointOnPolyline(hintSegment.nodes, point)
    if proj and proj.lateralOffset <= (hintSegment.width / 2 + 2.0) then
      return hintSegment, proj
    end
  end
  return M.findNearestSegment(graph, point)
end

-- Perpendicular (horizontal-plane) direction at a projection, assuming a
-- Z-up world (BeamNG convention): rotate the tangent 90 degrees around Z.
-- The sign (which side is "left" vs "right") is not confirmed in-game yet --
-- see avoidance usage in core.lua.
function M.lateralDirectionAtProjection(nodes, proj)
  local t = M.tangentAtProjection(nodes, proj)
  return M.normalize({ -t[2], t[1], 0 })
end

-- Checks whether shifting `lateralOffset` metres sideways from `ownProj`, over
-- the next `maneuverDistance` metres of travel, would come within
-- `minClearance` of any position in `otherPositions` (list of {x,y,z}) --
-- i.e. whether an avoidance maneuver into that offset is currently safe.
-- Pure geometry, no BeamNG dependency -- unit tested standalone.
function M.isOffsetPathClear(segment, ownProj, lateralOffset, maneuverDistance, otherPositions, minClearance)
  minClearance = minClearance or 2.5
  local tangent = M.tangentAtProjection(segment.nodes, ownProj)
  local lateral = M.lateralDirectionAtProjection(segment.nodes, ownProj)
  local base = ownProj.point

  for _, otherPos in ipairs(otherPositions) do
    local rel = { otherPos[1] - base[1], otherPos[2] - base[2], otherPos[3] - base[3] }
    local alongDist = vdot(rel, tangent)
    if alongDist >= -minClearance and alongDist <= maneuverDistance + minClearance then
      local target = {
        base[1] + tangent[1] * alongDist + lateral[1] * lateralOffset,
        base[2] + tangent[2] * alongDist + lateral[2] * lateralOffset,
        base[3] + tangent[3] * alongDist + lateral[3] * lateralOffset,
      }
      if vlen(vsub(otherPos, target)) < minClearance then
        return false
      end
    end
  end
  return true
end

local DEFAULT_MIN_SPEED_FOR_HEADING_CHECK = 1.0 -- m/s; below this, treat as a stationary obstacle regardless of heading
local DEFAULT_MIN_HEADING_ALIGNMENT = 0.5 -- cos(60 deg): must be moving roughly the same way to count as "in our lane"

-- Whether another vehicle projected at `otherProj` on `segment` is plausibly
-- "ahead of us in our lane" rather than crossing traffic that merely happens
-- to pass close to our polyline -- which is common right at intersections,
-- where multiple segments' geometry converges within a few metres of each
-- other. A vehicle nearly stopped (below minSpeedForHeadingCheck) is always
-- considered a real obstacle regardless of heading, since a stopped/parked
-- car blocking the lane must still be respected.
function M.isPlausibleLeader(segment, otherProj, otherVel, otherSpeed, minSpeedForHeadingCheck, minHeadingAlignment)
  minSpeedForHeadingCheck = minSpeedForHeadingCheck or DEFAULT_MIN_SPEED_FOR_HEADING_CHECK
  minHeadingAlignment = minHeadingAlignment or DEFAULT_MIN_HEADING_ALIGNMENT

  if otherProj.lateralOffset >= segment.width / 2 + 1 then
    return false
  end
  if otherSpeed >= minSpeedForHeadingCheck then
    local tangent = M.tangentAtProjection(segment.nodes, otherProj)
    local otherHeading = M.normalize(otherVel)
    if M.dot(tangent, otherHeading) < minHeadingAlignment then
      return false -- likely crossing traffic near an intersection, not really ahead of us
    end
  end
  return true
end

-- Loads a graph JSON file produced by tools/extract_road_graph.py.
-- Uses BeamNG's engine-provided `jsonReadFile` global (confirmed against the
-- actual installed game's source, e.g. lua/ge/extensions/core/trafficSignals.lua
-- and core/vehicles.lua, both of which load their own JSON data this same way)
-- -- not usable outside the game.
function M.loadGraph(path)
  local graph = jsonReadFile(path)
  if not graph then
    return nil, "could not read/parse " .. tostring(path)
  end
  return graph
end

return M
