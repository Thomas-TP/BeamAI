-- Route planning over the semantic road graph (docs/ARCHITECTURE.md section 8,
-- phase 2). roadGraph.lua handles fine geometry along a single segment;
-- nothing before this module computed *which* segments to follow, in what
-- order, to reach a destination -- findLookaheadPoint just followed
-- "continuation" junctions and aimed at any real junction it hit, with no
-- notion of a destination or a chosen branch. This is that missing piece.
--
-- Segments are the graph's nodes for routing purposes; two segments are
-- connected if they share a junction. The graph JSON only records which
-- segments meet at a junction (junction.approaches), not which END of each
-- segment does -- buildIndex recovers that once, by proximity of each
-- segment's first/last node to the junction position, instead of
-- re-deriving it on every route request.
--
-- Respects oneWay (+ flipDirection, BeamNG's own DecalRoad field -- see
-- tools/extract_road_graph.py): a one-way segment can only be entered from
-- its allowed-start end, never travelled against. On west_coast_usa, 665 of
-- 1303 segments (about half) are oneWay=true -- many of these are simply one
-- carriageway of a divided two-way road (BeamNG often models each direction
-- as a separate road_invisible spline) rather than a literal one-way street,
-- so getting this right matters for a large fraction of the network, not
-- just an edge case.
--
-- Pure Lua, no BeamNG dependency (besides requiring roadGraph.lua for
-- segmentLength/pointAtDistance, themselves pure) -- unit tested standalone.

local roadGraph = require("beamai/roadGraph")

local M = {}

local function dist3(a, b)
  local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function segEndpoints(seg)
  local nodes = seg.nodes
  local first, last = nodes[1], nodes[#nodes]
  return { first[1], first[2], first[3] }, { last[1], last[2], last[3] }
end

-- Precomputes, once per loaded graph, the structures route-finding needs:
-- fast id lookups, and which junction (if any) touches each segment's two
-- ends. Call once after roadGraph.loadGraph and reuse the result -- do not
-- rebuild this every tick or every route request.
function M.buildIndex(graph, junctionRadius)
  junctionRadius = junctionRadius or 8.0
  local segmentById = {}
  for _, seg in ipairs(graph.segments) do
    segmentById[seg.id] = seg
  end
  local junctionById = {}
  for _, j in ipairs(graph.junctions) do
    junctionById[j.id] = j
  end

  -- juncAtStart[segId] / juncAtEnd[segId]: junction id touching that end, or
  -- nil (dead end, or the edge of the mapped graph).
  local juncAtStart, juncAtEnd = {}, {}
  for _, j in ipairs(graph.junctions) do
    for _, segId in ipairs(j.approaches) do
      local seg = segmentById[segId]
      if seg then
        local startPos, endPos = segEndpoints(seg)
        local dStart = dist3(startPos, j.position)
        local dEnd = dist3(endPos, j.position)
        if dStart <= junctionRadius and dStart <= dEnd then
          juncAtStart[segId] = j.id
        elseif dEnd <= junctionRadius then
          juncAtEnd[segId] = j.id
        end
      end
    end
  end

  return {
    graph = graph,
    segmentById = segmentById,
    junctionById = junctionById,
    juncAtStart = juncAtStart,
    juncAtEnd = juncAtEnd,
  }
end

-- Whether `seg` may be driven start->end ("forward") / end->start
-- ("backward"). Two-way segments allow both (lanes in both directions share
-- one polyline in this schema, same assumption the rest of the codebase
-- already makes). One-way segments allow only one, per flipDirection.
local function allowsForwardTravel(seg)
  return (not seg.oneWay) or (not seg.flipDirection)
end

local function allowsBackwardTravel(seg)
  return (not seg.oneWay) or (seg.flipDirection == true)
end

-- Segments reachable directly after fully travelling `fromSegId`, entered at
-- `entryEnd` ("start" or "end") -- i.e. the neighbours one hop away in the
-- routing graph, respecting one-way restrictions on both the segment being
-- left and the segment being entered. Returns a list of
-- { segId, viaJunctionId, entryEnd } -- entryEnd is which end of the
-- neighbour segment you'd arrive at (needed to keep exploring from there).
function M.neighbors(index, fromSegId, entryEnd)
  local seg = index.segmentById[fromSegId]
  if not seg then
    return {}
  end

  -- NOTE: deliberately not using Lua's `cond and a or b` idiom below for any
  -- of these -- when `a` can itself be `false` (as allowsForwardTravel/
  -- allowsBackwardTravel and a possibly-nil junction id both can be), that
  -- idiom silently falls through to `b` regardless of `cond`. Caught by
  -- test_router.lua Test 3/5 failing even though the logic looked right.
  local farEnd = entryEnd == "start" and "end" or "start" -- safe: both branches are non-empty strings, never false/nil

  local canTraverse
  if farEnd == "end" then
    canTraverse = allowsForwardTravel(seg)
  else
    canTraverse = allowsBackwardTravel(seg)
  end
  if not canTraverse then
    return {}
  end

  local juncId
  if farEnd == "end" then
    juncId = index.juncAtEnd[fromSegId]
  else
    juncId = index.juncAtStart[fromSegId]
  end
  if not juncId then
    return {} -- dead end / edge of the mapped graph
  end
  local junction = index.junctionById[juncId]
  if not junction then
    return {}
  end

  local results = {}
  for _, otherId in ipairs(junction.approaches) do
    if otherId ~= fromSegId then
      local otherSeg = index.segmentById[otherId]
      if otherSeg then
        local otherEnd = nil
        if index.juncAtStart[otherId] == juncId then
          otherEnd = "start"
        elseif index.juncAtEnd[otherId] == juncId then
          otherEnd = "end"
        end
        if otherEnd then
          local entryOk
          if otherEnd == "start" then
            entryOk = allowsForwardTravel(otherSeg)
          else
            entryOk = allowsBackwardTravel(otherSeg)
          end
          if entryOk then
            table.insert(results, { segId = otherId, viaJunctionId = juncId, entryEnd = otherEnd })
          end
        end
      end
    end
  end
  return results
end

-- A* over the segment graph from (startSegId, startEntryEnd) to any
-- traversal of goalSegId. Cost = travelled road distance (roadGraph.segmentLength),
-- heuristic = straight-line distance from the far end of the current segment
-- to the goal's midpoint (admissible: real road distance is never shorter
-- than a straight line). Priority queue is a plain linear scan -- fine for an
-- occasional route request on graphs of this size (~1300 segments), not
-- meant to run every tick.
--
-- Returns an ordered list of { segId, entryEnd } traversal steps from start
-- to goal (inclusive), or nil if unreachable.
function M.findRoute(index, startSegId, startEntryEnd, goalSegId)
  local goalSeg = index.segmentById[goalSegId]
  if not goalSeg or not index.segmentById[startSegId] then
    return nil
  end

  if startSegId == goalSegId then
    return { { segId = startSegId, entryEnd = startEntryEnd } }
  end

  local goalPos = roadGraph.pointAtDistance(goalSeg.nodes, roadGraph.segmentLength(goalSeg.nodes) / 2)

  local function heuristic(segId, entryEnd)
    local seg = index.segmentById[segId]
    local startPos, endPos = segEndpoints(seg)
    local farPos = entryEnd == "start" and endPos or startPos
    return dist3(farPos, goalPos)
  end

  local function key(segId, entryEnd)
    return segId .. ":" .. entryEnd
  end

  local gScore = {}       -- key -> best known cost from start
  local cameFrom = {}     -- key -> { segId, entryEnd } of the predecessor step
  local visited = {}      -- key -> true once expanded
  local queue = {}         -- open set, linear-scanned for the lowest f each iteration

  local startKey = key(startSegId, startEntryEnd)
  gScore[startKey] = 0
  table.insert(queue, { segId = startSegId, entryEnd = startEntryEnd, key = startKey, f = heuristic(startSegId, startEntryEnd) })

  while #queue > 0 do
    local bestIdx = 1
    for i = 2, #queue do
      if queue[i].f < queue[bestIdx].f then
        bestIdx = i
      end
    end
    local current = table.remove(queue, bestIdx)

    if not visited[current.key] then
      visited[current.key] = true

      if current.segId == goalSegId then
        local path = { { segId = current.segId, entryEnd = current.entryEnd } }
        local k = current.key
        while cameFrom[k] do
          local prev = cameFrom[k]
          table.insert(path, 1, { segId = prev.segId, entryEnd = prev.entryEnd })
          k = key(prev.segId, prev.entryEnd)
        end
        return path
      end

      for _, n in ipairs(M.neighbors(index, current.segId, current.entryEnd)) do
        local hopLength = roadGraph.segmentLength(index.segmentById[n.segId].nodes)
        local g = gScore[current.key] + hopLength
        local nk = key(n.segId, n.entryEnd)
        if gScore[nk] == nil or g < gScore[nk] then
          gScore[nk] = g
          cameFrom[nk] = { segId = current.segId, entryEnd = current.entryEnd }
          table.insert(queue, { segId = n.segId, entryEnd = n.entryEnd, key = nk, f = g + heuristic(n.segId, n.entryEnd) })
        end
      end
    end
  end

  return nil -- goal unreachable from here under the current one-way restrictions
end

return M
