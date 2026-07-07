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

print("Test 6: findSegmentById")
do
  local graph = { segments = { { id = "a" }, { id = "b" } } }
  check("finds existing id", rg.findSegmentById(graph, "b").id == "b")
  check("returns nil for missing id", rg.findSegmentById(graph, "zzz") == nil)
end

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
  os.exit(0)
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
