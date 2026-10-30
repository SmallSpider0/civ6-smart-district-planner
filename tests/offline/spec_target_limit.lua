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
  SDP_Panel.SetCount(0)
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
