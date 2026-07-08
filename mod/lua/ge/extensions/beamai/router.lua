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

-- Minimal binary min-heap keyed by item.f, backing findRoute's open set
-- below. Tolerates stale/duplicate entries for the same node (the caller
-- discards them after popping, by checking `visited` -- the same "lazy
-- deletion" approach a plain linear-scan queue would use, just with O(log n)
-- push/pop instead of an O(n) rescan for the minimum on every single
-- iteration. That rescan was a real, confirmed in-game performance bug: on
-- west_coast_usa's ~1300-segment graph, a route to a genuinely distant
-- random destination could expand a queue of hundreds of entries, rescanned
-- in full on every pop -- observed to drop the game from 120 to 25 FPS the
-- moment several vehicles needed a route at once (right after registerAll()
-- during the very first tick of an automatic activation).
local function heapPush(heap, item)
  local n = #heap + 1
  heap[n] = item
  while n > 1 do
    -- math.floor(n/2), not the // operator: BeamNG's embedded Lua version
    -- isn't confirmed to support Lua 5.3+ integer division syntax, and
    -- math.floor works identically on every Lua version.
    local parent = math.floor(n / 2)
    if heap[parent].f <= heap[n].f then
      break
    end
    heap[parent], heap[n] = heap[n], heap[parent]
    n = parent
  end
end

local function heapPop(heap)
  local n = #heap
  if n == 0 then
    return nil
  end
  local top = heap[1]
  heap[1] = heap[n]
  heap[n] = nil
  n = n - 1
  local i = 1
  while true do
    local left, right, smallest = i * 2, i * 2 + 1, i
    if left <= n and heap[left].f < heap[smallest].f then
      smallest = left
    end
    if right <= n and heap[right].f < heap[smallest].f then
      smallest = right
    end
    if smallest == i then
      break
    end
    heap[i], heap[smallest] = heap[smallest], heap[i]
    i = smallest
  end
  return top
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
-- than a straight line). Priority queue is a binary min-heap (heapPush/heapPop
-- above) -- see their header comment for why a plain linear scan here was a
-- real, confirmed in-game performance bug, not just a theoretical concern.
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
  local queue = {}        -- open set: binary min-heap on .f, may hold stale duplicate entries (see heapPop)

  local startKey = key(startSegId, startEntryEnd)
  gScore[startKey] = 0
  heapPush(queue, { segId = startSegId, entryEnd = startEntryEnd, key = startKey, f = heuristic(startSegId, startEntryEnd) })

  while #queue > 0 do
    local current = heapPop(queue)

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
          heapPush(queue, { segId = n.segId, entryEnd = n.entryEnd, key = nk, f = g + heuristic(n.segId, n.entryEnd) })
        end
      end
    end
  end

  return nil -- goal unreachable from here under the current one-way restrictions
end

-- Picks a uniformly random destination segment id, different from
-- `excludeSegId` when possible (falls back to whatever was last drawn if 5
-- tries keep landing on it -- only matters for tiny graphs). `rng` is
-- injectable for tests, same convention as driverProfile.lua: defaults to
-- math.random, called with no arguments, must return a float in [0, 1).
function M.pickRandomDestination(graph, excludeSegId, rng)
  rng = rng or math.random
  local n = #graph.segments
  if n == 0 then
    return nil
  end
  local candidate
  for _ = 1, 5 do
    local idx = math.min(math.floor(rng() * n) + 1, n)
    candidate = graph.segments[idx].id
    if candidate ~= excludeSegId then
      return candidate
    end
  end
  return candidate
end

-- Picks a random destination and finds a route to it in one call, retrying a
-- few times if the first pick(s) turn out unreachable (e.g. an isolated
-- one-way pocket, or a dead-end segment with no onward junction). Returns nil
-- if no reachable destination was found within maxAttempts -- callers should
-- just retry on a later tick/call rather than treating this as an error.
function M.planRandomRoute(index, currentSegId, currentEntryEnd, rng, maxAttempts)
  maxAttempts = maxAttempts or 5
  for _ = 1, maxAttempts do
    local destSegId = M.pickRandomDestination(index.graph, currentSegId, rng)
    if destSegId then
      local route = M.findRoute(index, currentSegId, currentEntryEnd, destSegId)
      if route and #route > 1 then
        return route
      end
    end
  end
  return nil
end

-- Distance remaining on `seg` from `proj`, continuing in the direction of
-- travel implied by `entryEnd` ("start" = entered at the start, travelling
-- toward the end; "end" = the reverse).
local function remainingOnSegment(seg, proj, entryEnd)
  local total = roadGraph.segmentLength(seg.nodes)
  if entryEnd == "start" then
    return total - proj.distanceAlong
  end
  return proj.distanceAlong
end

-- The point `dist` metres further along `seg`, continuing in the travel
-- direction implied by `entryEnd`, starting from arc-length position
-- `fromDistanceAlong`. roadGraph.pointAtDistance's own clamping (to the first
-- node when the target distance is <= 0) happens to be exactly the right
-- clamp for backward travel too, since the first node IS where a
-- backward-travelled segment is exited.
local function pointAlongDirected(seg, fromDistanceAlong, dist, entryEnd)
  if entryEnd == "start" then
    return roadGraph.pointAtDistance(seg.nodes, fromDistanceAlong + dist)
  end
  return roadGraph.pointAtDistance(seg.nodes, fromDistanceAlong - dist)
end

-- Route-aware equivalent of roadGraph.findLookaheadPoint: instead of a
-- geometric heuristic (follow "continuation" junctions, aim at any real
-- junction otherwise -- see roadGraph.lua), this follows a specific planned
-- route (from findRoute/planRandomRoute) through however many real junctions
-- the lookahead distance reaches, since the route already says which branch
-- to take at each one -- no guessing needed.
--
-- `routeIndex` must point at the step of `route` matching the segment
-- `ownProj` was computed against (the caller is responsible for keeping this
-- in sync with the vehicle's actual position tick to tick -- see core.lua).
-- Returns the world-space lookahead point, and the routeIndex it ended up on
-- (so the caller can advance its own tracking once the vehicle physically
-- reaches that step). If the lookahead distance runs past the end of the
-- planned route, aims at the route's final point instead of guessing further
-- -- the caller is expected to plan a new route once the vehicle actually
-- arrives there (see core.lua).
function M.findLookaheadPointOnRoute(index, route, routeIndex, ownProj, lookaheadDistance)
  local step = route[routeIndex]
  local seg = index.segmentById[step.segId]
  local remaining = remainingOnSegment(seg, ownProj, step.entryEnd)

  if lookaheadDistance <= remaining then
    return pointAlongDirected(seg, ownProj.distanceAlong, lookaheadDistance, step.entryEnd), routeIndex
  end

  local distanceIntoNext = lookaheadDistance - remaining
  local i = routeIndex + 1
  while route[i] do
    local nextStep = route[i]
    local nextSeg = index.segmentById[nextStep.segId]
    local nextLen = roadGraph.segmentLength(nextSeg.nodes)
    if distanceIntoNext <= nextLen then
      local fromDist = nextStep.entryEnd == "start" and 0 or nextLen
      return pointAlongDirected(nextSeg, fromDist, distanceIntoNext, nextStep.entryEnd), i
    end
    distanceIntoNext = distanceIntoNext - nextLen
    i = i + 1
  end

  -- Ran past the end of the planned route: aim at the last point of the
  -- final leg rather than extrapolating past mapped road.
  local lastStep = route[#route]
  local lastSeg = index.segmentById[lastStep.segId]
  local lastLen = roadGraph.segmentLength(lastSeg.nodes)
  local endDist = lastStep.entryEnd == "start" and lastLen or 0
  return roadGraph.pointAtDistance(lastSeg.nodes, endDist), #route
end

-- Shared by findUpcomingTrafficLight and findUpcomingPriorityJunction below:
-- walks forward from `ownProj` on `segment` (travelling in the direction
-- implied by `entryEnd` -- "start" means heading toward the segment's last
-- node, "end" means the reverse), following "continuation" junctions (the
-- same logical road split into consecutive DecalRoad pieces) until it
-- reaches the nearest non-continuation junction of ANY type, or runs out of
-- maxLookahead, or the mapped graph ends.
--
-- Performance note (this replaced roadGraph.lua's original
-- findUpcomingTrafficLight/findUpcomingPriorityJunction, which each did
-- their OWN separate traversal): each step used to call
-- roadGraph.findJunctionNear (a full O(junction count) linear distance scan
-- over all ~646 junction candidates on west_coast_usa) and
-- roadGraph.findSegmentById (a full O(segment count) linear scan over all
-- ~1300 segments) -- and did so TWICE per vehicle per tick, once for each
-- function, once traffic lights and stop-priority junctions both became
-- default-on features. That was a real, confirmed in-game performance bug
-- (a sustained ~120 -> 30 FPS drop, not just a one-time burst like the A*
-- open-set fix above). This version uses `index` (router.buildIndex),
-- already built once per graph load specifically to answer "which junction
-- touches this segment's end" and "which segment has this id" in O(1) --
-- and walks the traversal exactly once, shared by both callers below,
-- instead of twice.
--
-- Returns junction, distanceToStopLine (metres from ownProj),
-- arrivalSegId (the specific segment actually being driven when the
-- junction is reached -- needed by findUpcomingPriorityJunction to look up
-- that approach's own priority rule), or nil, nil, nil.
local function walkToNextRealJunction(index, segment, entryEnd, ownProj, maxLookahead)
  local distanceSoFar
  if entryEnd == "start" then
    distanceSoFar = roadGraph.segmentLength(segment.nodes) - ownProj.distanceAlong
  else
    distanceSoFar = ownProj.distanceAlong
  end

  local currentSegId = segment.id
  local currentEntryEnd = entryEnd
  local visited = { [currentSegId] = true }

  while distanceSoFar <= maxLookahead do
    local juncId
    if currentEntryEnd == "start" then
      juncId = index.juncAtEnd[currentSegId]
    else
      juncId = index.juncAtStart[currentSegId]
    end
    if not juncId then
      return nil, nil, nil -- dead end / edge of the mapped graph
    end
    local junction = index.junctionById[juncId]
    if not junction then
      return nil, nil, nil
    end
    if junction.type ~= "continuation" then
      return junction, distanceSoFar, currentSegId
    end

    local nextSegId = nil
    for _, sid in ipairs(junction.approaches) do
      if sid ~= currentSegId then
        nextSegId = sid
      end
    end
    if not nextSegId or visited[nextSegId] then
      return nil, nil, nil
    end
    visited[nextSegId] = true

    local nextSeg = index.segmentById[nextSegId]
    if not nextSeg then
      return nil, nil, nil
    end
    local nextEntryEnd
    if index.juncAtStart[nextSegId] == juncId then
      nextEntryEnd = "start"
    else
      nextEntryEnd = "end"
    end

    distanceSoFar = distanceSoFar + roadGraph.segmentLength(nextSeg.nodes)
    currentSegId = nextSegId
    currentEntryEnd = nextEntryEnd
  end

  return nil, nil, nil
end

-- Looks ahead (through continuation segments) for the nearest upcoming
-- trafficLight junction, so a light several segments ahead is found early
-- enough to brake comfortably, instead of only being noticed once the
-- vehicle is on the final short segment leading into it. Stops looking
-- (returns nil) at a real, unclassified junction encountered first -- turning
-- there is a decision this v0 does not make (roadmap phase 2).
--
-- Returns junction, distanceToStopLine (metres from ownProj) or nil, nil.
function M.findUpcomingTrafficLight(index, segment, entryEnd, ownProj, maxLookahead)
  local junction, distance = walkToNextRealJunction(index, segment, entryEnd, ownProj, maxLookahead)
  if junction and junction.type == "trafficLight" then
    return junction, distance
  end
  return nil, nil
end

-- Looks ahead (through continuation segments) for the nearest upcoming
-- non-signalized real junction (type == "junction") -- one with a stop/yield
-- priority rule assigned by tools/extract_road_graph.py's
-- assign_junction_priority (roadClass hierarchy, or an all-way-stop default
-- when no class hierarchy exists). Stops looking at a trafficLight junction
-- or an unclassified one encountered first (out of scope here -- see
-- findUpcomingTrafficLight for the traffic-light case).
--
-- Returns junction, distanceToStopLine (metres from ownProj), mustYield
-- (whether the specific approach segment actually being driven when the
-- junction is reached must yield -- fails safe to true, i.e. yield, if this
-- approach isn't listed for some reason), or nil, nil, nil if none found
-- within maxLookahead.
function M.findUpcomingPriorityJunction(index, segment, entryEnd, ownProj, maxLookahead)
  local junction, distance, arrivalSegId = walkToNextRealJunction(index, segment, entryEnd, ownProj, maxLookahead)
  if not junction or junction.type ~= "junction" then
    return nil, nil, nil
  end

  local mustYield = true -- fail safe: an unlisted approach must yield
  if junction.approachPriority then
    for _, ap in ipairs(junction.approachPriority) do
      if ap.segmentId == arrivalSegId then
        mustYield = ap.mustYield
        break
      end
    end
  end
  return junction, distance, mustYield
end

return M
