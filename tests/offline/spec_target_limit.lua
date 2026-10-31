-- Offline: issue 177. On the Several cities tab with the shared list, the
-- count is how many districts that take population each city ends with,
-- built ones included (issue 144), also when a required district with an
-- empire limit goes to another city (issue 28) and a chosen wonder needs a
-- district next to it (issue 66). The report's setup: two cities, the
-- first with two built districts, the second with one; an empire-limited
-- district and another one required, the rest candidates, four a city, a
-- wonder that needs an entertainment complex. Before v1.6.1 the count was
-- the number of new districts and the second city got four new ones.
-- Issue 180: the district supplied for the wonder is the one next to it.
-- Driven through the panel's own controls.
local test, T = ...

local UI_Mock = include("ui")

local MAP = {
  "~~~~~~~~~~~~~~~~~~~~~~~~",
  "~......................~",
  "~......................~",
  "~......................~",
  "~......................~",
  "~......................~",
  "~......................~",
  "~......................~",
  "~......................~",
  "~......................~",
  "~~~~~~~~~~~~~~~~~~~~~~~~",
}

-- City 1 (first in the list): a holy site and a campus. City 2: a holy site.
local w = World.New({
  rows = MAP,
  cities = {
    { id = 1, x = 5, y = 5, population = 16, capital = true, radius = 3 },
    { id = 2, x = 13, y = 5, population = 16, radius = 3 },
  },
  districts = {
    { city = 1, type = "DISTRICT_HOLY_SITE", x = 6, y = 5, complete = true },
    { city = 1, type = "DISTRICT_CAMPUS", x = 4, y = 5, complete = true },
    { city = 2, type = "DISTRICT_HOLY_SITE", x = 14, y = 5, complete = true },
  },
})
UI_Mock.Install()
include("SDP_Panel")
local c = UI_Mock.Controls

-- The district types that take population planned for city `key`.
local function Specialty(plan, key)
  local n, types = 0, {}
  for _, p in ipairs(plan) do
    local row = GameInfo.Districts[p.Type]
    if p.City == key and row ~= nil and row.RequiresPopulation then
      n = n + 1
      types[#types + 1] = p.Type
    end
  end
  return n, table.concat(types, " ")
end

local function MultiRow(districtType)
  for _, r in ipairs(SDP_Panel.Multi.State().View.Districts) do
    if r.Type == districtType then return r end
  end
end

local function SetRow(districtType, state)
  for _ = 1, 3 do
    if MultiRow(districtType).State ~= state then MultiRow(districtType).Cell:Click() end
  end
  T.eq(MultiRow(districtType).State, state, districtType)
end

-- The district with an empire limit the fake ruleset has (read, not assumed).
local function Limited()
  for _, d in ipairs(SDP_Rules.PlannableDistricts(0)) do
    if d.Specialty and d.MaxPerPlayer and d.MaxPerPlayer > 0 then return d.Type end
  end
end

-- Every solution: each city ends with at most the count, built ones included.
local function CheckSolutions(result, what)
  T.ok(result and result.Ok, what .. ": " .. tostring(result and result.Error))
  local have = { C1 = 2, C2 = 1 }
  for n, sol in ipairs(result.Solutions) do
    for _, key in ipairs({ "C1", "C2" }) do
      local planned, types = Specialty(sol.Plan, key)
      T.eq(have[key] + planned, 4, what .. ", solution " .. n .. ", " .. key .. ": " .. types)
    end
  end
end

test("shared list: an empire-limited district elsewhere and a wonder's district keep each city at the count", function()
  SDP_Panel.Open()
  SDP_Panel.SelectTab("MULTI")
  local multi = SDP_Panel.Multi
  multi.Refresh()
  for _, city in ipairs(multi.State().View.Cities) do
    if city.Kind == "CITY" and not city.Included then city.Chip:Click() end
  end
  multi.SetPlanFor("ALL")
  local limited = Limited()
  T.ok(limited ~= nil, "the ruleset has an empire-limited district")
  SetRow(limited, "MUST")
  SetRow("DISTRICT_CAMPUS", "MUST")
  c.MultiCountMore:Click()
  T.eq(tonumber(c.MultiCountValue:GetText()), 4, "four a city")
  multi.SetWonder("BUILDING_COLOSSEUM", true)
  multi.SetTier("FAST")
  c.MultiSolveButton:Click()
  local result = SDP_Panel.RunTask(5000) or multi.State().Result
  CheckSolutions(result, "first plan")
  local plan = result.Solutions[1].Plan
  local limitedIn = nil
  for _, p in ipairs(plan) do
    if p.Type == limited then limitedIn = p.City end
  end
  T.eq(limitedIn, "C1", "the empire-limited district goes to the first city")
  local _, c2 = Specialty(plan, "C2")
  T.ok(c2:find("DISTRICT_CAMPUS", 1, true) ~= nil, "city 2 gets the required campus: " .. c2)
end)

-- Issue 180: a district supplied for a wonder (issue 66) stands next to
-- that wonder, in a city the wonder's tile can belong to; and no other
-- district of its kind serves the wonder already (then it is not needed).
local function Base(districtType)
  return SDP_Rules.BaseDistrict(districtType)
end

local function CheckSupplied(result, what)
  for n, sol in ipairs(result.Solutions) do
    local wonders = {}
    for _, p in ipairs(sol.Plan) do
      if p.Kind == "WONDER" then wonders[p.Type] = p end
    end
    for _, p in ipairs(sol.Plan) do
      if p.ForWonder ~= nil then
        local wonder = wonders[p.ForWonder]
        local label = what .. ", solution " .. n .. ", " .. p.Type .. " in " .. p.City
        T.ok(wonder ~= nil, label .. ": its wonder is placed")
        if wonder ~= nil then
          T.eq(Map.GetPlotDistance(p.X, p.Y, wonder.X, wonder.Y), 1, label .. ": next to " .. p.ForWonder)
          for _, q in ipairs(sol.Plan) do
            if q ~= p and q.Kind ~= "WONDER" and Base(q.Type) == Base(p.Type)
                and Map.GetPlotDistance(q.X, q.Y, wonder.X, wonder.Y) == 1 then
              T.ok(false, label .. ": the wonder has another one next to it in " .. q.City)
            end
          end
        end
      end
    end
  end
end

test("issue 180: the district supplied for a wonder is the one next to it", function()
  local multi = SDP_Panel.Multi
  multi.Undo()
  c.MultiSolveButton:Click()
  local result = SDP_Panel.RunTask(5000) or multi.State().Result
  T.ok(result and result.Ok, tostring(result and result.Error))
  T.ok(#result.Supplied > 0, "a district is supplied for the wonder")
  CheckSupplied(result, "shared list")
  CheckSolutions(result, "shared list")
end)

test("issue 180: the single-city tab still supplies the district next to the wonder", function()
  SDP_Panel.Multi.Undo()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(1)
  -- One more than the city has: room for the district supplied (issue 177).
  SDP_Panel.SetCount(SDP_Panel.State().Have + 1)
  SDP_Panel.SetTier("FAST")
  SDP_Panel.SetWonder("BUILDING_COLOSSEUM", true)
  SDP_Panel.Solve()
  local result = SDP_Panel.RunTask(5000)
  T.ok(result and result.Ok, "solved: " .. tostring(result and result.Error))
  local supplied = 0
  for _, p in ipairs(result.Plan) do
    if p.ForWonder == "BUILDING_COLOSSEUM" then supplied = supplied + 1 end
  end
  T.eq(supplied, 1, "one district supplied for the colosseum")
  CheckSupplied({ Solutions = { result } }, "single city")
  SDP_Panel.SetWonder("BUILDING_COLOSSEUM", false)
  SDP_Panel.SelectTab("MULTI")
end)

-- The plan's own pins, replaced, do not count: the same counts again.
test("shared list: after placing, replacing the pins plans the same counts", function()
  local multi = SDP_Panel.Multi
  local pins = #w:Pins()
  c.MultiPlaceButton:Click()
  T.ok(#w:Pins() > pins, "placed")
  c.MultiReplaceCheck:Toggle()
  T.eq(c.MultiReplaceCheck:IsChecked(), true, "replace on")
  T.eq(tonumber(c.MultiCountValue:GetText()), 4, "still four a city")
  c.MultiSolveButton:Click()
  local result = SDP_Panel.RunTask(5000) or multi.State().Result
  CheckSolutions(result, "replacing")
  c.MultiReplaceCheck:Toggle()
  multi.Undo()
end)

-- Issue 177 (v1.6.4): the district supplied for a wonder counts toward the
-- city's count like any other. It goes to the first city that still has
-- room; with none, the wonder is left out and says why. Required districts
-- are never dropped for it. Two required districts: city 1 (two built)
-- ends with four, city 2 (one built) with three.
local MUSTS = { "DISTRICT_COMMERCIAL_HUB", "DISTRICT_INDUSTRIAL_ZONE" }
local WONDER = "BUILDING_COLOSSEUM"

-- The district the wonder needs next to it, read from the rules.
local function Needed()
  for _, w in ipairs(SDP_Wonders.List(0)) do
    if w.Type == WONDER then return SDP_Rules.BaseDistrict(w.AdjacentDistrict) end
  end
end

local function Solve(what)
  c.MultiSolveButton:Click()
  local result = SDP_Panel.RunTask(5000) or SDP_Panel.Multi.State().Result
  T.ok(result and result.Ok, what .. ": " .. tostring(result and result.Error))
  return result
end

local function LeftOut(unplaced)
  for _, u in ipairs(unplaced or {}) do
    if u.Type == WONDER then return u end
  end
end

-- Every solution: city 1 ends with `c1`, city 2 with at most `c2` (built
-- ones included); a supplied district only in a city with room (`room`).
local function CheckRoom(result, what, c1, c2, room)
  for n, sol in ipairs(result.Solutions) do
    local label = what .. ", solution " .. n
    local n1, t1 = Specialty(sol.Plan, "C1")
    local n2, t2 = Specialty(sol.Plan, "C2")
    T.eq(2 + n1, c1, label .. ", city 1: " .. t1)
    T.ok(1 + n2 <= c2, label .. ", city 2 ends with at most " .. c2 .. ": " .. t2)
    for _, t in ipairs(MUSTS) do
      T.ok(t1:find(t, 1, true) ~= nil, label .. ": city 1 keeps the required " .. t)
    end
    for _, p in ipairs(sol.Plan) do
      if p.ForWonder ~= nil then T.eq(p.City, room, label .. ": supplied " .. p.Type .. " in") end
    end
  end
end

local function Reset()
  local multi = SDP_Panel.Multi
  SDP_Panel.SelectTab("MULTI")
  multi.Undo()
  multi.SetPlanFor("C1")
  multi.ApplyPlan(nil)
  multi.SetPlanFor("ALL")
  SetRow(Limited(), "OFF")
  SetRow("DISTRICT_CAMPUS", "POOL")
  for _, t in ipairs(MUSTS) do SetRow(t, "POOL") end
  T.ok(Needed() ~= nil and MultiRow(Needed()) ~= nil, "the wonder needs a district the list has")
  SetRow(Needed(), "POOL")
end

test("issue 177: a city's own list full with its required districts gets no district for a wonder", function()
  Reset()
  local multi = SDP_Panel.Multi
  -- City 1's own list: two required, four in all (two built).
  multi.SetPlanFor("C1")
  for _, t in ipairs(MUSTS) do SetRow(t, "MUST") end
  for _ = 1, 4 do
    if tonumber(c.MultiCountValue:GetText()) > 4 then c.MultiCountLess:Click() end
    if tonumber(c.MultiCountValue:GetText()) < 4 then c.MultiCountMore:Click() end
  end
  T.eq(tonumber(c.MultiCountValue:GetText()), 4, "city 1: four")
  multi.SetPlanFor("ALL")
  T.eq(tonumber(c.MultiCountValue:GetText()), 4, "the shared list: four")
  local result = Solve("own list")
  CheckRoom(result, "own list", 4, 4, "C2")
  T.ok(#result.Supplied > 0, "the district for the wonder goes to city 2")
  for n, sol in ipairs(result.Solutions) do
    T.ok(LeftOut(sol.Unplaced) == nil, "solution " .. n .. ": the wonder is placed")
  end
  multi.SetPlanFor("C1")
  multi.ApplyPlan(nil)
  multi.SetPlanFor("ALL")
end)

test("issue 177: shared list, the district for a wonder goes to the city with room", function()
  Reset()
  for _, t in ipairs(MUSTS) do SetRow(t, "MUST") end
  T.eq(tonumber(c.MultiCountValue:GetText()), 4, "four a city")
  local result = Solve("shared list")
  CheckRoom(result, "shared list", 4, 4, "C2")
  T.ok(#result.Supplied > 0, "the district for the wonder goes to city 2")
end)

test("issue 177: shared list, no city with room leaves the wonder out", function()
  Reset()
  for _, t in ipairs(MUSTS) do SetRow(t, "MUST") end
  c.MultiCountLess:Click()
  T.eq(tonumber(c.MultiCountValue:GetText()), 3, "three a city")
  local result = Solve("no room")
  -- City 1's two required districts are kept although it has two built.
  CheckRoom(result, "no room", 4, 3, "none")
  T.eq(#result.Supplied, 0, "nothing supplied")
  for n, sol in ipairs(result.Solutions) do
    local u = LeftOut(sol.Unplaced)
    T.ok(u ~= nil, "solution " .. n .. ": the wonder is left out")
    T.eq(u and u.Reason, "NO_ROOM_FOR_DISTRICT", "solution " .. n .. ": why")
  end
  c.MultiCountMore:Click()
  SDP_Panel.Multi.SetWonder(WONDER, false)
end)

-- The single-city tab: the district for a wonder is one of the city's.
local function SingleRow(districtType)
  for _, r in ipairs(SDP_Panel.State().DistrictRows) do
    if r.Type == districtType then return r end
  end
end

local function SingleSet(districtType, state)
  for _ = 1, 4 do
    if SingleRow(districtType).State ~= state then SingleRow(districtType).Cell:Click() end
  end
  T.eq(SingleRow(districtType).State, state, districtType)
end

local function SingleCount(target)
  for _ = 1, 8 do
    local now = SDP_Panel.State().Target
    if now > target then c.CountLess:Click() elseif now < target then c.CountMore:Click() end
  end
  T.eq(SDP_Panel.State().Target, target, "the city's count")
end

test("issue 177: single-city tab, the district for a wonder counts toward the city's count", function()
  SDP_Panel.Multi.Undo()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(1)
  SDP_Panel.SetTier("FAST")
  for _, t in ipairs(MUSTS) do SingleSet(t, "MUST") end
  SDP_Panel.SetWonder(WONDER, true)
  -- Two built and two required: full at four.
  SingleCount(4)
  T.eq(SDP_Panel.State().Have, 2, "city 1 has two")
  T.ok(SingleRow(Needed()).State ~= "WONDER", "no room: the district is not shown as for the wonder")
  c.SolveButton:Click()
  local result = SDP_Panel.RunTask(5000) or SDP_Panel.State().Result
  T.ok(result and result.Ok, "full: " .. tostring(result and result.Error))
  local n, types = Specialty(result.Plan, "C1")
  T.eq(n, 2, "full: only the two required: " .. types)
  local u = LeftOut(result.Unplaced)
  T.eq(u and u.Reason, "NO_ROOM_FOR_DISTRICT", "full: the wonder is left out")
  -- One more: the supplied district takes it.
  SingleCount(5)
  T.eq(SingleRow(Needed()).State, "WONDER", "room: the district is shown as for the wonder")
  c.SolveButton:Click()
  result = SDP_Panel.RunTask(5000) or SDP_Panel.State().Result
  T.ok(result and result.Ok, "room: " .. tostring(result and result.Error))
  n, types = Specialty(result.Plan, "C1")
  T.eq(n, 3, "room: the two required and the one for the wonder: " .. types)
  T.ok(LeftOut(result.Unplaced) == nil, "room: the wonder is placed")
  SDP_Panel.SetWonder(WONDER, false)
  for _, t in ipairs(MUSTS) do SingleSet(t, "POOL") end
  SDP_Panel.SelectTab("MULTI")
end)
