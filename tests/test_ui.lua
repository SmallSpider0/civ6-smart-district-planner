-- @state SDP_Panel
-- @timeout 60
-- Panel logic: district list, solve from the panel, result rows, inputs.
-- Needs a city: run tests/fixtures/found_capital.lua first on a fresh game.
local test, T = ...

local pid = Game.GetLocalPlayer()

local function Resolve(base)
  local plannable = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do plannable[d.Type] = true end
  if plannable[base] then return base end
  for row in GameInfo.DistrictReplaces() do
    if row.ReplacesDistrictType == base and plannable[row.CivUniqueDistrictType] then return row.CivUniqueDistrictType end
  end
  T.skip(base .. " not available to this civ")
end

-- Fresh panel inputs: capital, nothing selected, weights 1, clearing allowed.
local function Reset()
  local city = Players[pid]:GetCities():GetCapitalCity()
  if city == nil then T.skip("no capital: run tests/fixtures/found_capital.lua") end
  SDP_Panel.SelectCity(city:GetID())
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do SDP_Panel.SetState(d.Type, "OFF") end
  SDP_Panel.SetCount(0)
  SDP_Panel.SetRemind(false)
  for _, y in ipairs(SDP_Rules.YIELDS) do SDP_Panel.SetWeight(y, 1) end
  SDP_Panel.SetAllowFeatureRemoval(true)
  SDP_Panel.SetLand(true)
  SDP_Panel.SetTier("STANDARD")
  SDP_Panel.Refresh()
  return city
end

test("the district list shows every plannable district with its status", function()
  local city = Reset()
  local rows = SDP_Panel.State().DistrictRows
  local districts = SDP_Rules.PlannableDistricts(pid)
  T.eq(#rows, #districts, "row count")
  local status = SDP_City.DistrictStatus(SDP_City.Scan(pid, city:GetID()), districts)
  for _, row in ipairs(rows) do
    T.eq(row.Status, status[row.Type], row.Type .. " status")
    T.eq(row.State, "OFF", row.Type .. " off after reset")
  end
end)

test("solving from the panel lists the plan with DMT tooltips", function()
  Reset()
  local campus, holy = Resolve("DISTRICT_CAMPUS"), Resolve("DISTRICT_HOLY_SITE")
  SDP_Panel.SetSelected(holy, true)
  SDP_Panel.SetSelected(campus, true)
  local result = SDP_Panel.Solve()
  T.ok(result ~= nil and result.Ok, "solve failed")
  local state = SDP_Panel.State()
  T.eq(#state.ResultRows, #result.Plan + #result.Neighbours + #result.Unplaced, "row count")
  -- What the plan leaves out is listed first (issue 60).
  for i, p in ipairs(result.Plan) do
    local row = state.ResultRows[#result.Unplaced + i]
    local expected = p.ToolTip ~= "" and p.ToolTip or Locale.Lookup("LOC_SDP_NO_ADJACENCY")
    T.eq(row.ToolTip, expected, p.Type .. " tooltip")
    T.ok(string.find(row.Name, "(" .. p.X .. ", " .. p.Y .. ")", 1, true) ~= nil, p.Type .. " coordinates")
  end
  T.eq(state.PlaceDisabled, false, "place button disabled with a plan")
end)

test("the panel solves exactly what the solver does, whatever the click order", function()
  local city = Reset()
  local a, b = Resolve("DISTRICT_THEATER"), Resolve("DISTRICT_CAMPUS")
  SDP_Panel.SetSelected(a, true)
  SDP_Panel.SetSelected(b, true)
  SDP_Panel.SetWeight("YIELD_CULTURE", 3)
  local fromPanel = SDP_Panel.Solve()
  local ordered = { a, b }
  table.sort(ordered)
  -- The panel sends its distance weight too (0.5 by default since issue 91).
  local direct = SDP_Solver.Solve({ PlayerID = pid, CityID = city:GetID(), Districts = ordered, Land = true, Tier = "STANDARD",
    Weights = { YIELD_SCIENCE = 1, YIELD_CULTURE = 3, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 },
    Distance = SDP_Panel.State().Weights.DISTANCE })
  T.eq(fromPanel.Session.Request.Distance, SDP_Panel.State().Weights.DISTANCE, "the panel sends its distance weight")
  T.same(fromPanel.Plan, direct.Plan, "plan")
  T.eq(fromPanel.Gain, direct.Gain, "gain")
end)

test("changing any input clears the shown result", function()
  Reset()
  SDP_Panel.SetSelected(Resolve("DISTRICT_CAMPUS"), true)
  SDP_Panel.Solve()
  T.ok(SDP_Panel.State().Result ~= nil, "no result")
  SDP_Panel.SetWeight("YIELD_SCIENCE", 2)
  T.eq(SDP_Panel.State().Result, nil, "weight change kept the result")
  SDP_Panel.Solve()
  SDP_Panel.SetAllowFeatureRemoval(false)
  T.eq(SDP_Panel.State().Result, nil, "feature switch kept the result")
  T.eq(SDP_Panel.State().PlaceDisabled, true, "place button enabled without a plan")
end)

test("weights are clamped to 0..3", function()
  Reset()
  SDP_Panel.SetWeight("YIELD_GOLD", 7)
  T.eq(SDP_Panel.State().Weights.YIELD_GOLD, 3, "upper bound")
  SDP_Panel.SetWeight("YIELD_GOLD", -2)
  T.eq(SDP_Panel.State().Weights.YIELD_GOLD, 0, "lower bound")
  SDP_Panel.SetWeight("YIELD_GOLD", 1)
end)

test("too many specialty districts only warn", function()
  local city = Reset()
  local picked = 0
  local capacity = SDP_City.Scan(pid, city:GetID()).SpecialtyCapacity
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do
    if d.Specialty and picked <= capacity then
      SDP_Panel.SetSelected(d.Type, true)
      picked = picked + 1
    end
  end
  T.ok(picked > capacity, "not enough specialty districts to exceed the cap")
  local note = Controls.SpecialtyNote:GetText()
  T.ok(string.find(note, Locale.Lookup("LOC_SDP_SPECIALTY_OVER"), 1, true) ~= nil, "no warning: " .. note)
  local result = SDP_Panel.Solve()
  T.ok(result.Ok, "solve refused")
  Reset()
end)

test("tier, land switch and continue update the panel", function()
  Reset()
  SDP_Panel.SetSelected(Resolve("DISTRICT_CAMPUS"), true)
  SDP_Panel.SetSelected(Resolve("DISTRICT_HOLY_SITE"), true)
  T.ok(SDP_Panel.State().EstimateText ~= "", "no time estimate")
  local result = SDP_Panel.Solve()
  T.ok(result ~= nil and result.Ok, "solve failed")
  T.ok(SDP_Panel.State().QualityText ~= "", "no quality line")
  T.eq(SDP_Panel.State().ContinueDisabled, not result.Quality.CanContinue, "continue button state")
  SDP_Panel.SetLand(false)
  T.eq(SDP_Panel.State().Result, nil, "switching the land part clears the result")
  local off = SDP_Panel.Solve()
  T.eq(off.LandDelta, 0, "land part off")
  SDP_Panel.SetTier("FAST")
  T.eq(SDP_Panel.State().Result, nil, "changing the tier clears the result")
  T.eq(SDP_Panel.Solve().Stats.Tier, "FAST", "tier used")
  SDP_Panel.SetTier("STANDARD")
  SDP_Panel.SetLand(true)
end)
