-- Standalone unit tests for mod/lua/ge/extensions/beamai/router.lua.
-- Run with: lua tests/lua/test_router.lua   (from the repo root)

-- router.lua requires its sibling as "beamai/roadGraph" (the real BeamNG
-- convention, see core.lua) so this needs the parent-level package.path,
-- same as test_core_smoke.lua -- not the flat beamai/?.lua path the other
-- module tests use.
package.path = package.path .. ";" .. (arg[0]:match("(.*)tests[/\\]lua[/\\]") or "./") .. "mod/lua/ge/extensions/?.lua"
local router = require("beamai/router")

local failures = 0
local function check(name, cond)
  if cond then
    print("  ok   " .. name)
  else
    print("  FAIL " .. name)
    failures = failures + 1
  end
end

local function seg(id, nodes, oneWay, flipDirection)
  return { id = id, nodes = nodes, oneWay = oneWay or false, flipDirection = flipDirection or false }
end

local function junc(id, position, approaches)
  return { id = id, position = position, approaches = approaches }
end

print("Test 1: buildIndex finds the junction at each segment's touching end, nil at dead ends")
do
  local segA = seg("A", { { 0, 0, 0 }, { 100, 0, 0 } })
  local segB = seg("B", { { 100, 0, 0 }, { 200, 0, 0 } })
  local j1 = junc("j1", { 100, 0, 0 }, { "A", "B" })
  local index = router.buildIndex({ segments = { segA, segB }, junctions = { j1 } })

  check("A's end touches j1", index.juncAtEnd["A"] == "j1")
  check("B's start touches j1", index.juncAtStart["B"] == "j1")
  check("A's start is a dead end (nil)", index.juncAtStart["A"] == nil)
  check("B's end is a dead end (nil)", index.juncAtEnd["B"] == nil)
end

print("Test 2: neighbors() finds the other segment across a simple two-way junction")
do
  local segA = seg("A", { { 0, 0, 0 }, { 100, 0, 0 } })
  local segB = seg("B", { { 100, 0, 0 }, { 200, 0, 0 } })
  local j1 = junc("j1", { 100, 0, 0 }, { "A", "B" })
  local index = router.buildIndex({ segments = { segA, segB }, junctions = { j1 } })

  local neigh = router.neighbors(index, "A", "start") -- enter A at its start, travel forward to its end
  check("exactly one neighbor", #neigh == 1)
  check("neighbor is B, entered at its start", neigh[1].segId == "B" and neigh[1].entryEnd == "start")

  -- Symmetric: coming from B backward should find A.
  local neighBack = router.neighbors(index, "B", "end") -- enter B at its end, travel backward to its start (two-way, allowed)
  check("backward traversal also finds the junction", #neighBack == 1 and neighBack[1].segId == "A")
end

print("Test 3: one-way restriction excludes an illegal onward segment at a Y junction")
do
  local segA = seg("A", { { 0, 0, 0 }, { 100, 0, 0 } }) -- two-way
  local segB = seg("B", { { 100, 0, 0 }, { 200, 0, 0 } }, true, false) -- oneWay, allowed start->end (outbound from the junction)
  local segC = seg("C", { { 100, 0, 0 }, { 100, 100, 0 } }, true, true) -- oneWay + flipDirection: only end->start allowed (inbound to the junction only)
  local j1 = junc("j1", { 100, 0, 0 }, { "A", "B", "C" })
  local index = router.buildIndex({ segments = { segA, segB, segC }, junctions = { j1 } })

  local neigh = router.neighbors(index, "A", "start")
  local foundB, foundC = false, false
  for _, n in ipairs(neigh) do
    if n.segId == "B" then foundB = true end
    if n.segId == "C" then foundC = true end
  end
  check("legal one-way segment (outbound) is reachable", foundB == true)
  check("illegal one-way segment (would require driving against its direction) is excluded", foundC == false)
end

print("Test 4: findRoute follows a simple two-segment path")
do
  local segA = seg("A", { { 0, 0, 0 }, { 100, 0, 0 } })
  local segB = seg("B", { { 100, 0, 0 }, { 200, 0, 0 } })
  local j1 = junc("j1", { 100, 0, 0 }, { "A", "B" })
  local index = router.buildIndex({ segments = { segA, segB }, junctions = { j1 } })

  local route = router.findRoute(index, "A", "start", "B")
  check("route found", route ~= nil)
  check("route has 2 steps", route and #route == 2)
  check("route is A then B", route and route[1].segId == "A" and route[2].segId == "B")
end

print("Test 5: findRoute refuses a route that would require driving against a one-way segment")
do
  local segA = seg("A", { { 0, 0, 0 }, { 100, 0, 0 } }) -- two-way
  local segB = seg("B", { { 100, 0, 0 }, { 200, 0, 0 } }, true, true) -- oneWay, only traversable end->start (can't be entered from the junction)
  local j1 = junc("j1", { 100, 0, 0 }, { "A", "B" })
  local index = router.buildIndex({ segments = { segA, segB }, junctions = { j1 } })

  local route = router.findRoute(index, "A", "start", "B")
  check("no legal route exists -> nil, not an illegal shortcut", route == nil)
end

print("Test 6: findRoute picks the shorter of two legal detours (shortest path, not just any path)")
do
  local segA = seg("A", { { 0, 0, 0 }, { 100, 0, 0 } })
  local segB = seg("B", { { 100, 0, 0 }, { 200, 0, 0 } }) -- short leg, length 100
  local segC = seg("C", { { 100, 0, 0 }, { 100, 50, 0 }, { 200, 50, 0 }, { 200, 0, 0 } }) -- long detour, length 200
  local segD = seg("D", { { 200, 0, 0 }, { 300, 0, 0 } })
  local j1 = junc("j1", { 100, 0, 0 }, { "A", "B", "C" })
  local j2 = junc("j2", { 200, 0, 0 }, { "B", "C", "D" })
  local index = router.buildIndex({ segments = { segA, segB, segC, segD }, junctions = { j1, j2 } })

  local route = router.findRoute(index, "A", "start", "D")
  check("route found", route ~= nil)
  check("route has 3 steps", route and #route == 3)
  if route then
    check("route is A then D via the SHORT leg (B), not the long detour (C)",
      route[1].segId == "A" and route[2].segId == "B" and route[3].segId == "D")
  end
end

print("Test 7: findRoute returns nil for a genuinely unreachable (disconnected) segment")
do
  local segA = seg("A", { { 0, 0, 0 }, { 100, 0, 0 } })
  local segZ = seg("Z", { { 5000, 5000, 0 }, { 5100, 5000, 0 } }) -- shares no junction with anything
  local index = router.buildIndex({ segments = { segA, segZ }, junctions = {} })

  local route = router.findRoute(index, "A", "start", "Z")
  check("unreachable destination -> nil", route == nil)
end

print("Test 8: findRoute with start == goal returns a trivial single-step route")
do
  local segA = seg("A", { { 0, 0, 0 }, { 100, 0, 0 } })
  local index = router.buildIndex({ segments = { segA }, junctions = {} })

  local route = router.findRoute(index, "A", "start", "A")
  check("trivial route found", route ~= nil)
  check("single step", route and #route == 1 and route[1].segId == "A")
end

print("Test 9: pickRandomDestination is deterministic under an injected rng and avoids the excluded id")
do
  local segA = seg("A", { { 0, 0, 0 }, { 100, 0, 0 } })
  local segB = seg("B", { { 100, 0, 0 }, { 200, 0, 0 } })
  local segC = seg("C", { { 200, 0, 0 }, { 300, 0, 0 } })
  local graph = { segments = { segA, segB, segC } }

  local fakeRng = function() return 0.0 end -- always picks index 1 -> "A"
  check("rng=0 picks the first segment when it's not excluded", router.pickRandomDestination(graph, "Z", fakeRng) == "A")

  -- A varying rng: first draw lands on the excluded id ("A"), second draw moves on to "B".
  local calls = 0
  local varyingRng = function()
    calls = calls + 1
    return calls == 1 and 0.0 or 0.5 -- 0.5 -> floor(0.5*3)+1 = 2 -> "B"
  end
  check("skips the excluded id and finds another once the draw actually varies",
    router.pickRandomDestination(graph, "A", varyingRng) == "B")

  local fakeRngHigh = function() return 0.999 end -- picks the last index -> "C"
  check("rng near 1 picks the last segment", router.pickRandomDestination(graph, "Z", fakeRngHigh) == "C")
end

print("Test 10: planRandomRoute retries past unreachable picks and finds a reachable one")
do
  local segA = seg("A", { { 0, 0, 0 }, { 100, 0, 0 } })
  local segB = seg("B", { { 100, 0, 0 }, { 200, 0, 0 } })
  local segZ = seg("Z", { { 5000, 5000, 0 }, { 5100, 5000, 0 } }) -- disconnected, unreachable from A
  local j1 = junc("j1", { 100, 0, 0 }, { "A", "B" })
  local index = router.buildIndex({ segments = { segA, segB, segZ }, junctions = { j1 } })

  -- Sequence: first two draws land on the unreachable Z, third on the reachable B.
  local calls = 0
  local scriptedRng = function()
    calls = calls + 1
    if calls <= 2 then
      return 1.0 -- clamped to the last segment index -> "Z" (segments order: A, B, Z)
    end
    return 0.34 -- picks index 2 -> "B" (3 segments: 0.34*3=1.02 -> floor 1 -> idx 2)
  end

  local route = router.planRandomRoute(index, "A", "start", scriptedRng, 5)
  check("eventually finds a reachable route despite unreachable picks first", route ~= nil)
  check("route ends at the reachable destination (B)", route and route[#route].segId == "B")
end

print("Test 11: planRandomRoute gives up cleanly (nil) when nothing reachable turns up within the attempt budget")
do
  local segA = seg("A", { { 0, 0, 0 }, { 100, 0, 0 } })
  local segZ = seg("Z", { { 5000, 5000, 0 }, { 5100, 5000, 0 } })
  local index = router.buildIndex({ segments = { segA, segZ }, junctions = {} })

  local alwaysZ = function() return 0.9 end -- always the last segment -> "Z", never reachable from A
  local route = router.planRandomRoute(index, "A", "start", alwaysZ, 3)
  check("gives up cleanly instead of erroring", route == nil)
end

print("Test 12: findLookaheadPointOnRoute stays on the current leg when the lookahead fits")
do
  local segA = seg("A", { { 0, 0, 0 }, { 100, 0, 0 } })
  local segB = seg("B", { { 100, 0, 0 }, { 200, 0, 0 } })
  local j1 = junc("j1", { 100, 0, 0 }, { "A", "B" })
  local index = router.buildIndex({ segments = { segA, segB }, junctions = { j1 } })
  local route = { { segId = "A", entryEnd = "start" }, { segId = "B", entryEnd = "start" } }

  local proj = { distanceAlong = 40 } -- 40m into A (100m long), travelling start->end
  local point, idx = router.findLookaheadPointOnRoute(index, route, 1, proj, 15.0)
  check("stays on leg 1 (A)", idx == 1)
  check("lookahead point is 15m further along A (x=55)", math.abs(point[1] - 55) < 1e-6)
end

print("Test 13: findLookaheadPointOnRoute crosses into the next planned leg, following the route's chosen branch")
do
  local segA = seg("A", { { 0, 0, 0 }, { 100, 0, 0 } })
  local segB = seg("B", { { 100, 0, 0 }, { 200, 0, 0 } })
  local segC = seg("C", { { 100, 0, 0 }, { 100, 100, 0 } }) -- the OTHER branch at the junction, not on the route
  local j1 = junc("j1", { 100, 0, 0 }, { "A", "B", "C" })
  local index = router.buildIndex({ segments = { segA, segB, segC }, junctions = { j1 } })
  local route = { { segId = "A", entryEnd = "start" }, { segId = "B", entryEnd = "start" } }

  local proj = { distanceAlong = 90 } -- 90m into A (100m long): only 10m left on this leg
  local point, idx = router.findLookaheadPointOnRoute(index, route, 1, proj, 25.0) -- needs 15m more, into B
  check("advances to leg 2 (B), not the untaken branch (C)", idx == 2)
  check("lookahead point is 15m into B (x=115)", math.abs(point[1] - 115) < 1e-6)
end

print("Test 14: findLookaheadPointOnRoute handles a leg travelled backward (end->start)")
do
  local segA = seg("A", { { 0, 0, 0 }, { 100, 0, 0 } })
  local route = { { segId = "A", entryEnd = "end" } } -- travelling from A's end (x=100) toward its start (x=0)
  local index = router.buildIndex({ segments = { segA }, junctions = {} })

  local proj = { distanceAlong = 80 } -- currently at x=80, heading toward x=0
  local point, idx = router.findLookaheadPointOnRoute(index, route, 1, proj, 15.0)
  check("stays on the only leg", idx == 1)
  check("lookahead point moves toward the start (x=65), not the end", math.abs(point[1] - 65) < 1e-6)
end

print("Test 15: findLookaheadPointOnRoute aims at the route's final point once past its last leg")
do
  local segA = seg("A", { { 0, 0, 0 }, { 100, 0, 0 } })
  local route = { { segId = "A", entryEnd = "start" } }
  local index = router.buildIndex({ segments = { segA }, junctions = {} })

  local proj = { distanceAlong = 95 } -- 5m left on the only leg
  local point, idx = router.findLookaheadPointOnRoute(index, route, 1, proj, 30.0) -- asks for far more than remains
  check("clamped to the last step of the route", idx == 1)
  check("aims at the end of the final leg (x=100), not beyond", math.abs(point[1] - 100) < 1e-6)
end

print("Test 16: findRoute scales to a larger, programmatically-built graph and still finds a real shortcut")
do
  -- A long main chain of 40 unit segments (chain_0 .. chain_39, each 10m,
  -- laid out along +X) plus a single "bypass" segment directly connecting
  -- the junction after chain_2 to the junction after chain_35, short-cutting
  -- 33 hops. Exercises the binary min-heap (heapPush/heapPop in router.lua)
  -- with many more nodes/pushes than the small hand-built graphs above --
  -- this is the kind of scale (west_coast_usa has ~1300 segments) where the
  -- previous linear-scan open set was a real, confirmed in-game performance
  -- bug (120 -> 25 FPS the moment several vehicles needed a route at once).
  -- The chain zigzags a little in Y (0 or 3, alternating) so its actual
  -- travelled arc length between two points is slightly MORE than the
  -- straight-line distance between them -- otherwise a "bypass" running
  -- straight between two points already on a straight line could never be
  -- genuinely shorter than the chain itself (a straight line is already the
  -- shortest path between two points), making the "prefers the real
  -- shortcut" assertion below untestable.
  local N = 40
  local function zigzagY(i) return (i % 2) * 3 end
  local segments = {}
  local junctions = {}
  for i = 0, N - 1 do
    segments[#segments + 1] = seg("chain_" .. i, { { i * 10, zigzagY(i), 0 }, { (i + 1) * 10, zigzagY(i + 1), 0 } })
  end
  for i = 1, N - 1 do
    junctions[#junctions + 1] = junc("j_" .. i, { i * 10, zigzagY(i), 0 }, { "chain_" .. (i - 1), "chain_" .. i })
  end
  -- Bypass: a single straight segment directly between the existing
  -- junctions at i=3 (x=30) and i=36 (x=360), instead of the 33 zigzagging
  -- 10m-ish hops between them. Adds "bypass" to those junctions' own
  -- approaches rather than creating new junctions at the same positions:
  -- two junctions occupying the same spot would silently overwrite each
  -- other in buildIndex's per-segment-end lookup (whichever junction is
  -- processed last for a shared segment end wins), breaking the main
  -- chain's own connectivity right where the bypass was meant to attach.
  local j3pos = { 3 * 10, zigzagY(3), 0 }
  local j36pos = { 36 * 10, zigzagY(36), 0 }
  segments[#segments + 1] = seg("bypass", { j3pos, j36pos })
  table.insert(junctions[3].approaches, "bypass")  -- j_3, at x=30
  table.insert(junctions[36].approaches, "bypass") -- j_36, at x=360

  local index = router.buildIndex({ segments = segments, junctions = junctions })
  local route = router.findRoute(index, "chain_0", "start", "chain_" .. (N - 1))
  check("found a route across the whole graph", route ~= nil)
  if route then
    local usesBypass = false
    for _, step in ipairs(route) do
      if step.segId == "bypass" then
        usesBypass = true
      end
    end
    check("takes the bypass instead of all 40 chain hops", usesBypass)
    check("route is much shorter than the full chain (fewer than 15 steps, not ~40)", #route < 15)
  end
end

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
  os.exit(0)
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
