-- Offline: the district count is a target (issue 144). It says how many
-- districts that take population a city ends with, counting the ones built
-- (complete or not) and the city's own district tacks; the panel plans the
-- rest. On the single-city tab the default follows the city (three, or one
-- more than it has) and a count set by hand is kept per city; on the
-- Several cities tab each city fills up to the count. Driven through the
-- panel's own controls.
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

-- City 1: a campus and an unfinished theater square (has 2). City 2: a
-- commercial hub, an industrial zone and a tack of a holy site on a plot it
-- owns (has 3). City 3: nothing (has 0).
local w = World.New({
  rows = MAP,
  cities = {
    { id = 1, x = 4, y = 5, population = 12, capital = true, radius = 2 },
    { id = 2, x = 11, y = 5, population = 12, radius = 2 },
    { id = 3, x = 18, y = 5, population = 12, radius = 2 },
  },
  districts = {
    { city = 1, type = "DISTRICT_CAMPUS", x = 5, y = 5, complete = true },
    { city = 1, type = "DISTRICT_THEATER", x = 3, y = 5, complete = false },
    { city = 2, type = "DISTRICT_COMMERCIAL_HUB", x = 12, y = 5, complete = true },
    { city = 2, type = "DISTRICT_INDUSTRIAL_ZONE", x = 10, y = 5, complete = true },
  },
  pins = { { 11, 4, "ICON_DISTRICT_HOLY_SITE", "" } },
})
UI_Mock.Install()
include("SDP_Panel")
local c = UI_Mock.Controls

local function Specialty(plan, key)
  local n = 0
  for _, p in ipairs(plan) do
    if (key == nil or p.City == key) and GameInfo.Districts[p.Type].RequiresPopulation then n = n + 1 end
  end
  return n
end

local function Shown() return tonumber(c.CountValue:GetText()) end

test("the default target: three, or one more than the city has", function()
  T.eq(SDP_UI.DefaultTarget(0), 3, "none")
  T.eq(SDP_UI.DefaultTarget(2), 3, "two")
  T.eq(SDP_UI.DefaultTarget(3), 4, "three: one more, or nothing would be planned")
  T.eq(SDP_UI.DefaultTarget(5), 6, "five")
end)

test("what a city has: built (complete or not) and its own district tacks", function()
  T.eq(SDP_City.HaveCount(SDP_City.HaveOf(0, 1)), 2, "city 1")
  local have2 = SDP_City.HaveOf(0, 2)
  T.eq(SDP_City.HaveCount(have2), 3, "city 2: the holy site tack counts")
  T.eq(SDP_City.HaveCount(have2, { DISTRICT_HOLY_SITE = true }), 2, "a tacked type planned again counts once")
  T.eq(SDP_City.HaveCount(SDP_City.HaveOf(0, 3)), 0, "city 3")
end)

test("single-city tab: the count is the target, the solver gets the rest", function()
  SDP_Panel.Open()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(1)
  local s = SDP_Panel.State()
  T.eq(s.Have, 2, "city 1 has two")
  T.eq(s.Target, 3, "default three")
  T.eq(Shown(), 3, "the panel shows the target")
  T.eq(s.Count, 1, "one more to plan")
  -- Down to what it has: nothing is required, so 2 and nothing to plan.
  for _ = 1, 5 do c.CountLess:Click() end
  T.eq(Shown(), 2, "not below what the city has")
  T.ok(c.CountLess:IsDisabled(), "less is off at the minimum")
  T.eq(SDP_Panel.State().Count, 0, "nothing to plan")
  c.CountMore:Click()
  T.eq(Shown(), 3, "back to three")
  c.SolveButton:Click()
  local result = SDP_Panel.RunTask(1000) or SDP_Panel.State().Result
  T.ok(result and result.Ok, "result: " .. tostring(result and result.Error))
  for n, sol in ipairs(result.Solutions) do
    T.eq(Specialty(sol.Plan), 1, "one district that takes population in solution " .. n)
  end
end)

test("single-city tab: the default follows the city, a count set by hand stays with its city", function()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(2)
  T.eq(SDP_Panel.State().Have, 3, "city 2 has three")
  T.eq(Shown(), 4, "default: one more than it has")
  T.eq(SDP_Panel.State().Count, 1, "one to plan")
  SDP_Panel.SelectCity(3)
  T.eq(Shown(), 3, "city 3: three")
  T.eq(SDP_Panel.State().Count, 3, "three to plan")
  -- Set by hand on city 2, then away and back.
  SDP_Panel.SelectCity(2)
  c.CountMore:Click()
  T.eq(Shown(), 5, "five on city 2")
  SDP_Panel.SelectCity(3)
  T.eq(Shown(), 3, "city 3 keeps its default")
  SDP_Panel.SelectCity(2)
  T.eq(Shown(), 5, "city 2 shows what was set")
  T.eq(SDP_Panel.State().Count, 2, "two to plan")
end)

test("single-city tab: the minimum is what the city has plus the required ones not built", function()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(1)
  local function Row(districtType)
    for _, r in ipairs(SDP_Panel.State().DistrictRows) do
      if r.Type == districtType then return r end
    end
  end
  -- Two required districts that take population.
  local must = { "DISTRICT_HOLY_SITE", "DISTRICT_ENCAMPMENT" }
  for _, t in ipairs(must) do
    for _ = 1, 3 do
      if Row(t).State ~= "MUST" then Row(t).Cell:Click() end
    end
    T.eq(Row(t).State, "MUST", t)
  end
  for _ = 1, 6 do c.CountLess:Click() end
  T.eq(Shown(), 4, "two built plus two required")
  T.eq(SDP_Panel.State().Count, 2, "the two required")
  for _, t in ipairs(must) do
    for _ = 1, 3 do
      if Row(t).State ~= "POOL" then Row(t).Cell:Click() end
    end
  end
end)

test("single-city tab: placed tacks count; replacing them does not", function()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(3)
  T.eq(SDP_Panel.State().Have, 0, "nothing yet")
  c.SolveButton:Click()
  local result = SDP_Panel.RunTask(1000) or SDP_Panel.State().Result
  T.ok(result and result.Ok, "result: " .. tostring(result and result.Error))
  local placed = SDP_Panel.PlacePins()
  T.ok(placed >= 3, "placed")
  T.eq(SDP_Panel.State().Have, 3, "the three tacks count")
  T.eq(Shown(), 4, "default now one more")
  T.eq(SDP_Panel.State().Count, 1, "one more to plan")
  c.ReplaceCheck:Toggle()
  T.eq(SDP_Panel.State().Have, 0, "tacks being replaced do not count")
  T.eq(Shown(), 3, "default three again")
  c.ReplaceCheck:Toggle()
  SDP_Panel.UndoPins()
  T.eq(SDP_Panel.State().Have, 0, "undone")
end)

test("several cities tab: each city fills up to the count", function()
  SDP_Panel.SelectTab("MULTI")
  local multi = SDP_Panel.Multi
  multi.Refresh()
  for _, city in ipairs(multi.State().View.Cities) do
    if city.Kind == "CITY" and not city.Included then city.Chip:Click() end
  end
  multi.SetPlanFor("ALL")
  multi.SetTier("FAST")
  T.eq(tonumber(c.MultiCountValue:GetText()), 3, "three a city by default")
  local request = multi.Request()
  T.eq(request.Count, 3, "sent as a target")
  T.eq(request.Target, true, "the solver counts what each city has")
  c.MultiSolveButton:Click()
  local result = SDP_Panel.RunTask(5000) or multi.State().Result
  T.ok(result and result.Ok, "result: " .. tostring(result and result.Error))
  T.eq(Specialty(result.Plan, "C1"), 1, "city 1 (has two) gets one")
  T.eq(Specialty(result.Plan, "C2"), 0, "city 2 (has three) gets none")
  T.eq(Specialty(result.Plan, "C3"), 3, "city 3 (has none) gets three")
  -- A city's own list starts from what the city has.
  multi.SetPlanFor("C2")
  multi.SetSelected("DISTRICT_CAMPUS", true)
  multi.SetSelected("DISTRICT_CAMPUS", false)
  T.eq(tonumber(c.MultiCountValue:GetText()), 3, "city 2's own list: three")
  T.ok(c.MultiCountLess:IsDisabled(), "not below what city 2 has")
  c.MultiCountMore:Click()
  T.eq(tonumber(c.MultiCountValue:GetText()), 4, "four")
  T.eq(multi.Request().Counts.C2, 4, "city 2's target")
  multi.ApplyPlan(nil)
  multi.SetPlanFor("ALL")
end)

-- A preset puts the switches back, replace among them: the city's tacks count
-- again (Codex on PR 147).
test("single-city tab: a preset that turns replace off counts the tacks again", function()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(3)
  c.SolveButton:Click()
  local result = SDP_Panel.RunTask(1000) or SDP_Panel.State().Result
  T.ok(result and result.Ok, "result: " .. tostring(result and result.Error))
  T.ok(SDP_Panel.PlacePins() >= 3, "placed")
  c.ReplaceCheck:Toggle()
  T.eq(SDP_Panel.State().Have, 0, "tacks being replaced do not count")
  c.PresetPull._entries[1].Button:Click()
  T.eq(c.ReplaceCheck:IsChecked(), false, "the preset turns replace off")
  T.eq(SDP_Panel.State().Have, 3, "the three tacks count again")
  T.eq(Shown(), 4, "default one more than it has")
  T.eq(SDP_Panel.State().Count, 1, "one more to plan")
  SDP_Panel.UndoPins()
  T.eq(SDP_Panel.State().Have, 0, "undone")
end)

local function MultiRow(districtType)
  for _, r in ipairs(SDP_Panel.Multi.State().View.Districts) do
    if r.Type == districtType then return r end
  end
end

local function MultiMust(districtType)
  for _ = 1, 3 do
    if MultiRow(districtType).State ~= "MUST" then MultiRow(districtType).Cell:Click() end
  end
  T.eq(MultiRow(districtType).State, "MUST", districtType)
end

-- A district the city has built, required in its own list, is in what the
-- city has already: it does not raise the minimum (Codex on PR 147).
test("several cities tab: a built district required in a city's own list counts once", function()
  SDP_Panel.SelectTab("MULTI")
  local multi = SDP_Panel.Multi
  multi.Refresh()
  multi.SetPlanFor("C1")
  MultiMust("DISTRICT_CAMPUS") -- city 1 has built it
  for _ = 1, 5 do c.MultiCountLess:Click() end
  T.eq(tonumber(c.MultiCountValue:GetText()), 2, "down to the two city 1 has")
  T.ok(c.MultiCountLess:IsDisabled(), "less is off at the minimum")
  T.eq(multi.Request().Counts.C1, 2, "city 1's target: nothing new")
  c.MultiCountMore:Click()
  T.eq(multi.Request().Counts.C1, 3, "three: one new district")
  multi.ApplyPlan(nil)
  multi.SetPlanFor("ALL")
end)

-- A city's own count follows its tacks: after placing, undoing, and a
-- preset that turns replace off (Codex on PR 147).
test("several cities tab: a city's own count follows its tacks and the replace switch", function()
  SDP_Panel.SelectTab("MULTI")
  local multi = SDP_Panel.Multi
  multi.Refresh()
  multi.SetPlanFor("C3")
  MultiMust("DISTRICT_CAMPUS")
  T.eq(tonumber(c.MultiCountValue:GetText()), 3, "city 3's own list: three")
  T.ok(not c.MultiCountLess:IsDisabled(), "city 3 has none: less is on")
  c.MultiSolveButton:Click()
  local result = SDP_Panel.RunTask(5000) or multi.State().Result
  T.ok(result and result.Ok, "result: " .. tostring(result and result.Error))
  T.eq(Specialty(result.Plan, "C3"), 3, "city 3 gets three")
  c.MultiPlaceButton:Click()
  T.ok(c.MultiCountLess:IsDisabled(), "placed: city 3 has three, less is off")
  c.MultiReplaceCheck:Toggle()
  T.ok(not c.MultiCountLess:IsDisabled(), "replacing them: less is on")
  c.MultiPresetPull._entries[1].Button:Click()
  T.eq(c.MultiReplaceCheck:IsChecked(), false, "the preset turns replace off")
  T.ok(c.MultiCountLess:IsDisabled(), "the tacks count again: less is off")
  c.MultiUndoButton:Click()
  T.ok(not c.MultiCountLess:IsDisabled(), "undone: less is on")
  multi.ApplyPlan(nil)
  multi.SetPlanFor("ALL")
end)
