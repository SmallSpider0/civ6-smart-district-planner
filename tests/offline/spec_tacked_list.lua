-- Offline: districts a city already has are not offered again (issue 165).
-- A district placed in the city (complete or still being built) and a
-- district type tacked for the city that is not built yet are greyed out in
-- the city's list, on the single-city tab and in a city's own list on the
-- Several cities tab: neither a candidate nor required, so the plan never
-- puts a second one beside the tack (requirement 7: the tack stays). This
-- mod's tacks being replaced are planned anew. Driven through the panel's
-- own controls.
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

-- City 1: a theater square still being built. City 2: the player's own tack
-- of a holy site on a plot it owns. City 3: nothing.
local w = World.New({
  rows = MAP,
  cities = {
    { id = 1, x = 4, y = 5, population = 12, capital = true, radius = 2 },
    { id = 2, x = 11, y = 5, population = 12, radius = 2 },
    { id = 3, x = 18, y = 5, population = 12, radius = 2 },
  },
  districts = {
    { city = 1, type = "DISTRICT_THEATER", x = 3, y = 5, complete = false },
  },
  pins = { { 11, 4, "ICON_DISTRICT_HOLY_SITE", "" } },
})
UI_Mock.Install()
include("SDP_Panel")
local c = UI_Mock.Controls
local multi = SDP_Panel.Multi

local function Has(list, x)
  for _, v in ipairs(list or {}) do
    if v == x then return true end
  end
  return false
end

local function Planned(plan, key, districtType)
  for _, p in ipairs(plan) do
    if (key == nil or p.City == key) and p.Type == districtType then return true end
  end
  return false
end

local function SingleRow(districtType)
  for _, r in ipairs(SDP_Panel.State().DistrictRows) do
    if r.Type == districtType then return r end
  end
end

local function MultiRow(districtType)
  for _, r in ipairs(multi.State().View.Districts) do
    if r.Type == districtType then return r end
  end
end

-- The Several cities tab with every city taking part and `key`'s own list.
local function OwnList(key)
  SDP_Panel.SelectTab("MULTI")
  multi.Refresh()
  for _, city in ipairs(multi.State().View.Cities) do
    if city.Kind == "CITY" and not city.Included then city.Chip:Click() end
  end
  multi.SetTier("FAST")
  multi.SetPlanFor(key)
  -- A click on a cell starts the city's own list.
  MultiRow("DISTRICT_CAMPUS").Cell:Click()
  multi.SetSelected("DISTRICT_CAMPUS", false)
end

test("single-city tab: a district type tacked for the city is greyed out and not planned again", function()
  SDP_Panel.Open()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(2)
  T.eq(SingleRow("DISTRICT_HOLY_SITE").Status, "TACKED", "the tacked holy site")
  T.eq(SingleRow("DISTRICT_CAMPUS").Status, nil, "the campus can be planned")
  for _ = 1, 9 do c.CountMore:Click() end
  local request = SDP_Panel.Request()
  T.ok(not Has(request.Pool, "DISTRICT_HOLY_SITE"), "not a candidate")
  T.ok(not Has(request.Districts, "DISTRICT_HOLY_SITE"), "not required")
  c.SolveButton:Click()
  local result = SDP_Panel.RunTask(1000) or SDP_Panel.State().Result
  T.ok(result and result.Ok, "result: " .. tostring(result and result.Error))
  for n, sol in ipairs(result.Solutions) do
    T.ok(not Planned(sol.Plan, nil, "DISTRICT_HOLY_SITE"), "no second holy site in solution " .. n)
  end
  -- A district still being built: greyed out as before.
  SDP_Panel.SelectCity(1)
  T.eq(SingleRow("DISTRICT_THEATER").Status, "BUILT", "the theater square being built")
end)

test("several cities tab: a city's own list greys out what it has built or tacked", function()
  OwnList("C1")
  local row = MultiRow("DISTRICT_THEATER")
  T.eq(row.Why, "BUILT", "city 1's theater square being built")
  T.ok(row.Cell:IsDisabled(), "its cell cannot be clicked")
  for _ = 1, 9 do c.MultiCountMore:Click() end
  OwnList("C2")
  row = MultiRow("DISTRICT_HOLY_SITE")
  T.eq(row.Why, "TACKED", "city 2's tacked holy site")
  T.ok(row.Cell:IsDisabled(), "its cell cannot be clicked")
  T.eq(MultiRow("DISTRICT_THEATER").Why, nil, "city 2 has no theater square")
  -- Every candidate can be planned: the count goes no higher than that.
  for _ = 1, 9 do c.MultiCountMore:Click() end
  local request = multi.Request()
  T.ok(not Has(request.Pools.C1, "DISTRICT_THEATER"), "city 1: the theater square is no candidate")
  T.ok(not Has(request.Pools.C2, "DISTRICT_HOLY_SITE"), "city 2: the holy site is no candidate")
  T.eq(request.Counts.C2, 1 + #request.Pools.C2, "city 2's count: the tack and the candidates")
  c.MultiSolveButton:Click()
  local result = SDP_Panel.RunTask(5000) or multi.State().Result
  T.ok(result and result.Ok, "result: " .. tostring(result and result.Error))
  T.ok(not Planned(result.Plan, "C1", "DISTRICT_THEATER"), "no second theater square in city 1")
  T.ok(not Planned(result.Plan, "C2", "DISTRICT_HOLY_SITE"), "no second holy site in city 2")
  multi.ApplyPlan(nil)
  multi.SetPlanFor("C1")
  multi.ApplyPlan(nil)
  multi.SetPlanFor("ALL")
end)

test("several cities tab: a template that requires a tacked district leaves it out", function()
  OwnList("C2")
  multi.ApplyPlan({ "DISTRICT_HOLY_SITE", "DISTRICT_CAMPUS" })
  local request = multi.Request()
  T.ok(Has(request.Plans.C2, "DISTRICT_CAMPUS"), "the campus is required")
  T.ok(not Has(request.Plans.C2, "DISTRICT_HOLY_SITE"), "the tacked holy site is not planned again")
  multi.ApplyPlan(nil)
  multi.SetPlanFor("ALL")
end)

test("single-city tab: this mod's tacks count until they are replaced", function()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(3)
  c.SolveButton:Click()
  local result = SDP_Panel.RunTask(1000) or SDP_Panel.State().Result
  T.ok(result and result.Ok, "result: " .. tostring(result and result.Error))
  local first = result.Solutions[1].Plan[1].Type
  T.ok(SDP_Panel.PlacePins() >= 3, "placed")
  T.eq(SingleRow(first).Status, "TACKED", "placed: " .. first .. " greyed out")
  c.ReplaceCheck:Toggle()
  T.eq(SingleRow(first).Status, nil, "being replaced: planned anew")
  SDP_Panel.SelectCity(2)
  T.eq(SingleRow("DISTRICT_HOLY_SITE").Status, "TACKED", "the player's own tack is not replaced")
  SDP_Panel.SelectCity(3)
  c.ReplaceCheck:Toggle()
  T.eq(SingleRow(first).Status, "TACKED", "kept again")
  SDP_Panel.UndoPins()
  T.eq(SingleRow(first).Status, nil, "undone")
end)

test("several cities tab: a city's own list follows its tacks and the replace switch", function()
  OwnList("C3")
  c.MultiSolveButton:Click()
  local result = SDP_Panel.RunTask(5000) or multi.State().Result
  T.ok(result and result.Ok, "result: " .. tostring(result and result.Error))
  local first = nil
  for _, p in ipairs(result.Plan) do
    if p.City == "C3" and first == nil then first = p.Type end
  end
  T.ok(first ~= nil, "city 3 has a plan")
  c.MultiPlaceButton:Click()
  T.eq(MultiRow(first).Why, "TACKED", "placed: " .. first .. " greyed out")
  c.MultiReplaceCheck:Toggle()
  T.eq(MultiRow(first).Why, nil, "being replaced: planned anew")
  c.MultiReplaceCheck:Toggle()
  T.eq(MultiRow(first).Why, "TACKED", "kept again")
  c.MultiUndoButton:Click()
  T.eq(MultiRow(first).Why, nil, "undone")
  multi.ApplyPlan(nil)
  multi.SetPlanFor("ALL")
end)
