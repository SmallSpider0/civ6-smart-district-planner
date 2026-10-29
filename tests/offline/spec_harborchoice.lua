-- Offline: the harbor or the commercial hub by the city (issue 106). When
-- both sides of a keep-apart pair (SDP_Rules.Apart) are candidates, a city
-- takes only one (always, issue 152): a city whose center is on the coast and
-- has no fresh water takes the coastal side (the harbor, Districts.Coast),
-- every other city the other side. Driven through the panel's own controls.
local test, T = ...

local UI_Mock = include("ui")

-- City 1 at (5, 2): on the coast, no fresh water. City 2 at (14, 2): on the
-- coast, on a river. City 3 at (10, 7): inland, two plots from a bay.
-- A harbor next to a coastal city center gets +2; a hub here gets nothing,
-- so by score the harbor wins wherever it can stand next to the center.
local MAP = {
  "~~~~~~~~~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~",
  "~~~......~~~.....~~~",
  "~~........~.......~~",
  "~~.................~",
  "~~.................~",
  "~~.................~",
  "~~.................~",
  "~~.................~",
  "~~~~~~~~~~~~~~~~~~~~",
}
local w = World.New({
  rows = MAP, rivers = { "14,2" },
  cities = {
    { id = 1, x = 5, y = 2, population = 7, capital = true },
    { id = 2, x = 14, y = 2, population = 7 },
    { id = 3, x = 10, y = 7, population = 7 },
  },
})
UI_Mock.Install()
include("SDP_Panel")

local HUB, HARBOR = "DISTRICT_COMMERCIAL_HUB", "DISTRICT_HARBOR"
local c = UI_Mock.Controls

local function Find(rows, districtType)
  for _, r in ipairs(rows) do
    if r.Type == districtType then return r end
  end
  return nil
end

-- Click a district's cell until it shows `want`.
local function SetTo(rows, districtType, want)
  for _ = 1, 4 do
    local row = Find(rows(), districtType)
    if row.State == want then return end
    row.Cell:Click()
  end
  T.eq(Find(rows(), districtType).State, want, districtType)
end

-- Only the harbor and the hub as candidates, one district to pick.
local function OnlyThePair(rows, count, less, more)
  for _, row in ipairs(rows()) do
    if row.Type == HUB or row.Type == HARBOR then
      SetTo(rows, row.Type, "POOL")
    elseif row.State == "POOL" or row.State == "MUST" then
      SetTo(rows, row.Type, "OFF")
    end
  end
  for _ = 1, 5 do less:Click() end
  while count() < 1 do more:Click() end
  T.eq(count(), 1, "one to pick")
end

local function Types(plan, key)
  local out = {}
  for _, p in ipairs(plan) do
    if (key == nil or p.City == key) and (p.Type == HUB or p.Type == HARBOR) then out[#out + 1] = p.Type end
  end
  return table.concat(out, ",")
end

test("the map: city 1 coastal without fresh water, city 2 coastal on a river, city 3 inland", function()
  local p1, p2, p3 = Map.GetPlot(5, 2), Map.GetPlot(14, 2), Map.GetPlot(10, 7)
  T.ok(p1:IsCoastalLand() and not p1:IsFreshWater(), "city 1")
  T.ok(p2:IsCoastalLand() and p2:IsFreshWater(), "city 2")
  T.ok(not p3:IsCoastalLand() and not p3:IsFreshWater(), "city 3")
  T.ok(w ~= nil, "world")
end)

test("single-city tab: the coastal city without fresh water takes the harbor, the others the hub", function()
  SDP_Panel.SelectTab("SINGLE")
  local rows = function() return SDP_Panel.State().DistrictRows end
  local want = { [1] = HARBOR, [2] = HUB, [3] = HUB }
  for id = 1, 3 do
    SDP_Panel.SelectCity(id)
    OnlyThePair(rows, function() return SDP_Panel.State().Count end, c.CountLess, c.CountMore)
    T.eq(SDP_Panel.Request().Apart, true, "kept apart")
    c.SolveButton:Click()
    local result = SDP_Panel.RunTask(500) or SDP_Panel.State().Result
    T.ok(result and result.Ok, "city " .. id .. ": " .. tostring(result and result.Error))
    for n, sol in ipairs(result.Solutions) do
      T.eq(Types(sol.Plan), want[id], "city " .. id .. ", solution " .. n)
    end
  end
  -- Not kept apart (a request no panel sends since issue 152), the score
  -- decides: the harbor next to city 2's center. So the rule above chose the hub.
  SDP_Panel.SelectCity(2)
  local request = SDP_Panel.Request()
  request.Apart = false
  local off = SDP_Solver.Solve(request)
  T.ok(off and off.Ok, tostring(off and off.Error))
  T.eq(Types(off.Plan), HARBOR, "not kept apart: by score")
end)

test("single-city tab: a required one is placed as asked; a lone candidate is taken", function()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(2)
  local rows = function() return SDP_Panel.State().DistrictRows end
  OnlyThePair(rows, function() return SDP_Panel.State().Count end, c.CountLess, c.CountMore)
  SetTo(rows, HARBOR, "MUST")
  c.SolveButton:Click()
  local result = SDP_Panel.RunTask(500) or SDP_Panel.State().Result
  T.ok(result and result.Ok, tostring(result and result.Error))
  T.ok(Types(result.Plan):find(HARBOR, 1, true) ~= nil, "the required harbor: " .. Types(result.Plan))
  SetTo(rows, HARBOR, "POOL")
  -- The hub not a candidate: the harbor is the only one, and is taken.
  SetTo(rows, HUB, "OFF")
  c.SolveButton:Click()
  local alone = SDP_Panel.RunTask(500) or SDP_Panel.State().Result
  T.ok(alone and alone.Ok, tostring(alone and alone.Error))
  T.eq(Types(alone.Plan), HARBOR, "only the harbor: taken")
  SetTo(rows, HUB, "POOL")
end)

test("several-cities tab: each city by its center", function()
  SDP_Panel.SelectTab("MULTI")
  local multi = SDP_Panel.Multi
  multi.Refresh()
  -- Tick every city's chip.
  for _, city in ipairs(multi.State().View.Cities) do
    if city.Kind == "CITY" and not city.Included then city.Chip:Click() end
  end
  local keys = {}
  for _, part in ipairs(multi.Participants()) do keys[part.CityID or part.Key] = part.Key end
  T.ok(keys[1] and keys[2] and keys[3], "the three cities take part")
  local rows = function() return multi.State().View.Districts end
  OnlyThePair(rows, function() return multi.Request() and multi.Request().Count or 0 end, c.MultiCountLess, c.MultiCountMore)
  T.eq(multi.Request().Apart, true, "kept apart")
  c.MultiSolveButton:Click()
  local result = SDP_Panel.RunTask(500) or multi.State().Result
  T.ok(result and result.Ok, tostring(result and result.Error))
  T.eq(Types(result.Plan, keys[1]), HARBOR, "city 1")
  T.eq(Types(result.Plan, keys[2]), HUB, "city 2")
  T.eq(Types(result.Plan, keys[3]), HUB, "city 3")
end)
