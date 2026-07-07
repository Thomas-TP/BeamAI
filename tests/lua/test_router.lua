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

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
  os.exit(0)
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
