-- Standalone unit tests for mod/lua/ge/extensions/beamai/roadGraph.lua.
-- Run with: lua tests/lua/test_roadGraph.lua   (from the repo root)
-- Only exercises the pure-geometry functions -- loadGraph() needs BeamNG's
-- engine globals (readFile/jsonDecode) and is not covered here.

package.path = package.path .. ";" .. (arg[0]:match("(.*)tests[/\\]lua[/\\]") or "./") .. "mod/lua/ge/extensions/beamai/?.lua"
local rg = require("roadGraph")

local failures = 0
local function check(name, cond)
  if cond then
    print("  ok   " .. name)
  else
    print("  FAIL " .. name)
    failures = failures + 1
  end
end
local function near(a, b, eps)
  return math.abs(a - b) < (eps or 1e-6)
end

-- A straight 100m road along X, split into two polyline sub-segments at x=50.
local straightNodes = {
  { 0, 0, 0, 3.5 },
  { 50, 0, 0, 3.5 },
  { 100, 0, 0, 3.5 },
}

print("Test 1: point exactly on the line, mid-segment")
do
  local p = rg.closestPointOnPolyline(straightNodes, { 25, 0, 0 })
  check("lateralOffset ~ 0", near(p.lateralOffset, 0, 1e-6))
  check("distanceAlong ~ 25", near(p.distanceAlong, 25, 1e-6))
end

print("Test 2: point offset to the side")
do
  local p = rg.closestPointOnPolyline(straightNodes, { 25, 3, 0 })
  check("lateralOffset ~ 3", near(p.lateralOffset, 3, 1e-6))
  check("distanceAlong ~ 25", near(p.distanceAlong, 25, 1e-6))
end

print("Test 3: point beyond the end of the polyline clamps to the last node")
do
  local p = rg.closestPointOnPolyline(straightNodes, { 150, 0, 0 })
  check("distanceAlong clamps to full length (100)", near(p.distanceAlong, 100, 1e-6))
  check("lateralOffset ~ 50 (distance past the end)", near(p.lateralOffset, 50, 1e-6))
end

print("Test 4: distanceAlong between two projected points")
do
  local posA = rg.closestPointOnPolyline(straightNodes, { 10, 0, 0 })
  local posB = rg.closestPointOnPolyline(straightNodes, { 80, 0, 0 })
  local d = rg.distanceAlong(straightNodes, posA, posB)
  check("distance A->B ~ 70", near(d, 70, 1e-6))
  local dRev = rg.distanceAlong(straightNodes, posB, posA)
  check("distance B->A ~ -70 (behind)", near(dRev, -70, 1e-6))
end

print("Test 5: findNearestSegment picks the right segment among several")
do
  local perpNodes = {
    { 25, 0, 0, 3.5 },
    { 25, 50, 0, 3.5 },
  }
  local graph = {
    segments = {
      { id = "seg_straight", nodes = straightNodes },
      { id = "seg_perp", nodes = perpNodes },
    },
  }
  local seg, proj = rg.findNearestSegment(graph, { 60, 0.5, 0 })
  check("nearest segment is seg_straight", seg.id == "seg_straight")
  check("small lateral offset", proj.lateralOffset < 1)

  local seg2 = rg.findNearestSegment(graph, { 25, 20, 0 })
  check("nearest segment is seg_perp", seg2.id == "seg_perp")
end

print("Test 5b: tangentAtProjection")
do
  local proj = rg.closestPointOnPolyline(straightNodes, { 60, 0, 0 })
  local tangent = rg.tangentAtProjection(straightNodes, proj)
  check("points along +X", near(tangent[1], 1, 1e-6) and near(tangent[2], 0, 1e-6))
end

print("Test 6b: segmentLength")
do
  check("100m straight road", near(rg.segmentLength(straightNodes), 100, 1e-6))
end

print("Test 6c: findJunctionNear")
do
  local graph = {
    junctions = {
      { id = "j_far", position = { 1000, 1000, 0 }, type = "trafficLight" },
      { id = "j_near", position = { 100, 2, 0 }, type = "trafficLight" },
    },
  }
  local found = rg.findJunctionNear(graph, { 100, 0, 0 }, 6.0)
  check("finds the nearby junction", found ~= nil and found.id == "j_near")
  local notFound = rg.findJunctionNear(graph, { 100, 0, 0 }, 1.0)
  check("returns nil when out of radius", notFound == nil)
end

print("Test 9: normalize and dot")
do
  local n = rg.normalize({ 3, 4, 0 })
  check("normalize({3,4,0}) has length 1", near(n[1], 0.6, 1e-6) and near(n[2], 0.8, 1e-6))
  check("dot of perpendicular vectors is 0", near(rg.dot({ 1, 0, 0 }, { 0, 1, 0 }), 0, 1e-6))
  check("dot of identical unit vectors is 1", near(rg.dot({ 1, 0, 0 }, { 1, 0, 0 }), 1, 1e-6))
end

print("Test 10: isPlausibleLeader filters out crossing traffic near intersections")
do
  local segment = { width = 3.5, nodes = { { 0, 0, 0, 3.5 }, { 100, 0, 0, 3.5 } } }
  local otherProj = rg.closestPointOnPolyline(segment.nodes, { 60, 0.2, 0 }) -- almost dead-ahead, small lateral offset

  check("same-direction moving vehicle ahead counts as a leader",
    rg.isPlausibleLeader(segment, otherProj, { 10, 0, 0 }, 10) == true)

  check("perpendicular-moving vehicle (crossing traffic) is filtered out",
    rg.isPlausibleLeader(segment, otherProj, { 0, 10, 0 }, 10) == false)

  check("a nearly stationary vehicle still counts regardless of heading",
    rg.isPlausibleLeader(segment, otherProj, { 0, 0.5, 0 }, 0.3) == true)

  check("a vehicle too far to the side is filtered out even if aligned",
    rg.isPlausibleLeader(segment, rg.closestPointOnPolyline(segment.nodes, { 60, 5, 0 }), { 10, 0, 0 }, 10) == false)
end

print("Test 11: lateralDirectionAtProjection is perpendicular to travel")
do
  local proj = rg.closestPointOnPolyline(straightNodes, { 60, 0, 0 })
  local lateral = rg.lateralDirectionAtProjection(straightNodes, proj)
  check("perpendicular to +X tangent (dot ~ 0)", near(rg.dot(lateral, { 1, 0, 0 }), 0, 1e-6))
  check("unit length", near(lateral[1] * lateral[1] + lateral[2] * lateral[2], 1, 1e-6))
end

print("Test 12: isOffsetPathClear detects a vehicle in the way, ignores irrelevant ones")
do
  local segment = { width = 3.5, nodes = straightNodes }
  local ownProj = rg.closestPointOnPolyline(straightNodes, { 20, 0, 0 })
  local lateral = rg.lateralDirectionAtProjection(straightNodes, ownProj)
  local offset = 2.2

  local blockingPos = {
    ownProj.point[1] + 10 * 1 + lateral[1] * offset, -- 10m ahead, right at the offset lane
    ownProj.point[2] + lateral[2] * offset,
    ownProj.point[3],
  }
  check("a vehicle sitting in the offset path blocks it",
    rg.isOffsetPathClear(segment, ownProj, offset, 20.0, { blockingPos }, 2.5) == false)

  local farAwayPos = { ownProj.point[1] + 10, ownProj.point[2] + 20, ownProj.point[3] }
  check("a vehicle far to the side does not block it",
    rg.isOffsetPathClear(segment, ownProj, offset, 20.0, { farAwayPos }, 2.5) == true)

  local behindPos = { ownProj.point[1] - 30, ownProj.point[2], ownProj.point[3] }
  check("a vehicle well behind us does not block it",
    rg.isOffsetPathClear(segment, ownProj, offset, 20.0, { behindPos }, 2.5) == true)

  check("no other vehicles at all -> clear", rg.isOffsetPathClear(segment, ownProj, offset, 20.0, {}, 2.5) == true)
end

print("Test 13: findNearestSegmentNear reuses the hint without a full scan when it still fits")
do
  local perpNodes = {
    { 25, 0, 0, 3.5 },
    { 25, 50, 0, 3.5 },
  }
  local graph = {
    segments = {
      { id = "seg_straight", width = 3.5, nodes = straightNodes },
      { id = "seg_perp", width = 3.5, nodes = perpNodes },
    },
  }
  local seg, proj = rg.findNearestSegmentNear(graph, { 60, 0.5, 0 }, graph.segments[1])
  check("stays on the hinted segment", seg.id == "seg_straight")
  check("projection is still accurate", near(proj.distanceAlong, 60, 1e-6))

  -- Point has moved somewhere the hint no longer covers -> falls back to a full scan.
  local seg2 = rg.findNearestSegmentNear(graph, { 25, 20, 0 }, graph.segments[1])
  check("falls back to the correct segment when the hint no longer fits", seg2.id == "seg_perp")

  -- No hint at all -> behaves exactly like findNearestSegment.
  local seg3 = rg.findNearestSegmentNear(graph, { 60, 0.5, 0 }, nil)
  check("works with no hint", seg3.id == "seg_straight")
end

print("Test 14: pointAtDistance")
do
  local p0 = rg.pointAtDistance(straightNodes, 0)
  check("distance 0 -> first node", near(p0[1], 0, 1e-6) and near(p0[2], 0, 1e-6))
  local p30 = rg.pointAtDistance(straightNodes, 30)
  check("distance 30 -> (30,0,0)", near(p30[1], 30, 1e-6) and near(p30[2], 0, 1e-6))
  local pEnd = rg.pointAtDistance(straightNodes, 500) -- overshoots the 100m polyline
  check("overshooting distance clamps to the last node", near(pEnd[1], 100, 1e-6))
end

print("Test 15: findLookaheadPoint stays on the current segment when it fits")
do
  local segA = { id = "segA", nodes = { { 0, 0, 0, 3.5 }, { 100, 0, 0, 3.5 } } }
  local graph = { segments = { segA }, junctions = {} }
  local ownProj = rg.closestPointOnPolyline(segA.nodes, { 10, 0, 0 })
  local pt = rg.findLookaheadPoint(graph, segA, ownProj, 15.0, 6.0)
  check("lookahead point is 15m ahead on the same segment", near(pt[1], 25, 1e-6))
end

print("Test 16: findLookaheadPoint crosses into the next segment through a continuation")
do
  local segA = { id = "segA", nodes = { { 0, 0, 0, 3.5 }, { 50, 0, 0, 3.5 } } }
  local segB = { id = "segB", nodes = { { 50, 0, 0, 3.5 }, { 100, 0, 0, 3.5 } } }
  local graph = {
    segments = { segA, segB },
    junctions = { { id = "j1", type = "continuation", position = { 50, 0, 0 }, approaches = { "segA", "segB" } } },
  }
  local ownProj = rg.closestPointOnPolyline(segA.nodes, { 40, 0, 0 }) -- 10m left on segA
  local pt = rg.findLookaheadPoint(graph, segA, ownProj, 25.0, 6.0) -- needs 15m into segB
  check("lookahead point lands 15m into segB (x=65)", near(pt[1], 65, 1e-6))
end

print("Test 17: findLookaheadPoint aims at a real junction instead of guessing a branch")
do
  local segA = { id = "segA", nodes = { { 0, 0, 0, 3.5 }, { 50, 0, 0, 3.5 } } }
  local segB = { id = "segB", nodes = { { 50, 0, 0, 3.5 }, { 100, 0, 0, 3.5 } } }
  local graph = {
    segments = { segA, segB },
    junctions = { { id = "j1", type = "junction", position = { 50, 0, 0 }, approaches = { "segA", "segB" } } },
  }
  local ownProj = rg.closestPointOnPolyline(segA.nodes, { 40, 0, 0 })
  local pt = rg.findLookaheadPoint(graph, segA, ownProj, 25.0, 6.0)
  check("aims at the junction position, does not cross into segB", near(pt[1], 50, 1e-6))
end

print("Test 18: findLookaheadPoint aims at the road's end when the graph runs out")
do
  local segA = { id = "segA", nodes = { { 0, 0, 0, 3.5 }, { 50, 0, 0, 3.5 } } }
  local graph = { segments = { segA }, junctions = {} }
  local ownProj = rg.closestPointOnPolyline(segA.nodes, { 40, 0, 0 })
  local pt = rg.findLookaheadPoint(graph, segA, ownProj, 25.0, 6.0)
  check("aims at the dead end (x=50)", near(pt[1], 50, 1e-6))
end

print("Test 6: findSegmentById")
do
  local graph = { segments = { { id = "a" }, { id = "b" } } }
  check("finds existing id", rg.findSegmentById(graph, "b").id == "b")
  check("returns nil for missing id", rg.findSegmentById(graph, "zzz") == nil)
end

print("Test 23: isCrossTrafficNearJunction")
do
  local junctionPos = { 100, 0, 0 }
  local moving = { pos = { 105, 2, 0 }, speed = 5.0 }
  local stopped = { pos = { 102, 0, 0 }, speed = 0.1 }
  local farAway = { pos = { 500, 0, 0 }, speed = 10.0 }

  check("a moving vehicle close to the junction counts as cross traffic",
    rg.isCrossTrafficNearJunction(junctionPos, { moving }, 18.0, 0.5))
  check("a near-stationary vehicle (already waiting/parked) does not count",
    rg.isCrossTrafficNearJunction(junctionPos, { stopped }, 18.0, 0.5) == false)
  check("a fast vehicle far from the junction does not count",
    rg.isCrossTrafficNearJunction(junctionPos, { farAway }, 18.0, 0.5) == false)
  check("no other vehicles at all -> clear", rg.isCrossTrafficNearJunction(junctionPos, {}, 18.0, 0.5) == false)
end

print("Test 19: offsetPointLateral")
do
  local pt = rg.offsetPointLateral({ 10, 20, 0 }, { 0, 1, 0 }, 2.5)
  check("shifts along the lateral direction", near(pt[1], 10, 1e-6) and near(pt[2], 22.5, 1e-6) and near(pt[3], 0, 1e-6))
  local ptNeg = rg.offsetPointLateral({ 10, 20, 0 }, { 0, 1, 0 }, -2.5)
  check("negative metres shifts the other way", near(ptNeg[2], 17.5, 1e-6))
  local ptZero = rg.offsetPointLateral({ 10, 20, 0 }, { 1, 0, 0 }, 0)
  check("zero metres leaves the point unchanged", near(ptZero[1], 10, 1e-6) and near(ptZero[2], 20, 1e-6))
end

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
  os.exit(0)
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
