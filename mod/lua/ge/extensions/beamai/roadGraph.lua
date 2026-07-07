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

-- Loads a graph JSON file produced by tools/extract_road_graph.py.
-- Requires BeamNG's engine-provided `readFile` and `jsonDecode` globals --
-- not usable outside the game; needs in-game confirmation of exact signatures.
function M.loadGraph(path)
  local text = readFile(path)
  if not text then
    return nil, "could not read " .. tostring(path)
  end
  return jsonDecode(text)
end

return M
