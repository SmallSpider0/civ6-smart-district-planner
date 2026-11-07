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
    -- The tooltip is the district's own parts line (issue 126), a blank line,
    -- then DMT's tooltip untouched (requirement 8).
    local request = result.Session.Request
    local parts = { Land = request.Land, Distance = (request.Distance or 0) > 0, Coverage = false }
    local first = SDP_UI.PartsText(p.Parts, parts, "LOC_SDP_PARTS_DISTRICT")
    T.ok(first ~= nil and first ~= "", p.Type .. " has a parts line")
    local head = first .. "[NEWLINE][NEWLINE]"
    T.eq(string.sub(row.ToolTip, 1, #head), head, p.Type .. " tooltip starts with its parts line")
    T.eq(string.sub(row.ToolTip, #head + 1), expected, p.Type .. " tooltip continues with DMT's tooltip")
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

-- Issue 199: with wonders ticked, the settings pushed the solve button below
-- the window on low screens. The real layout: every selectable wonder
-- ticked, on this screen and on the shortest page (the window's minimum).
test("issue 199: ticked wonders keep the solve button on the page", function()
  Reset()
  SDP_Panel.Open()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SetFold(false)
  local ticked = 0
  for _, w in ipairs(SDP_Wonders.List(pid, nil)) do
    if w.Status == nil then
      SDP_Panel.SetWonder(w.Type, true)
      ticked = ticked + 1
    end
  end
  local ok, err = pcall(function()
    T.ok(ticked >= 8, "selectable wonders: " .. ticked)
    local function Check(label)
      local page, body = Controls.SinglePage:GetSizeY(), Controls.Body:GetSizeY()
      local _, pageTop = Controls.SinglePage:GetScreenOffset()
      local _, solveTop = Controls.SolveButton:GetScreenOffset()
      local solveBottom = solveTop + Controls.SolveButton:GetSizeY()
      local _, screen = UIManager:GetScreenSizeVal()
      print(string.format("issue 199 %s: wonders %d, page %d, body %d, settings %d of %d, solve bottom %d, page bottom %d, screen %d",
        label, ticked, page, body, Controls.SettingsScroll:GetSizeY(), Controls.SettingsStack:GetSizeY(),
        solveBottom, pageTop + page, screen))
      T.ok(body <= page, label .. ": the body " .. body .. " fits the page " .. page)
      T.ok(solveBottom <= pageTop + page, label .. ": the solve button ends at " .. solveBottom .. ", the page at " .. (pageTop + page))
      T.ok(solveBottom <= screen, label .. ": the solve button ends at " .. solveBottom .. " on a " .. screen .. " screen")
      for _, button in ipairs({ Controls.PlaceButton, Controls.UndoButton }) do
        local _, top = button:GetScreenOffset()
        T.ok(top + button:GetSizeY() <= pageTop + page, label .. ": the tacks' buttons end at " .. (top + button:GetSizeY())
          .. ", the page at " .. (pageTop + page))
      end
    end
    SDP_Panel.FitWindow()
    Check("this screen")
    Controls.SinglePage:SetSizeY(SDP_UI.WINDOW_MIN - SDP_UI.PAGE_INSET)
    -- The page fits itself again, as when the player folds and unfolds the settings.
    SDP_Panel.SetFold(true)
    SDP_Panel.SetFold(false)
    T.ok(Controls.SettingsScroll:GetSizeY() < Controls.SettingsStack:GetSizeY(), "the shortest page: the settings scroll")
    Check("the shortest page")
  end)
  for _, w in ipairs(SDP_Wonders.List(pid, nil)) do SDP_Panel.SetWonder(w.Type, false) end
  SDP_Panel.FitWindow()
  SDP_Panel.Close()
  if not ok then error(err, 0) end
end)

-- Issue 314: the Diplomatic Quarter and the Preserve gave the district grid
-- a row more and pushed the tacks' buttons off the shortest page. Whatever
-- the rules give, the grid scrolls: on the shortest page, and on pages up to
-- three grid rows shorter still (a ruleset or mod with more districts), the
-- solve and the tacks' buttons end on the page on every tab.
local function Tabs314()
  return {
    { Tab = "SINGLE", Page = Controls.SinglePage, Body = Controls.Body, Grid = Controls.DistrictScroll,
      Area = Controls.DistrictArea, Fold = SDP_Panel.SetFold,
      Buttons = { Controls.SolveButton, Controls.PlaceButton, Controls.UndoButton } },
    { Tab = "SITES", Page = Controls.SitesPage, Body = Controls.SitesBody, Grid = Controls.SitesDistrictScroll,
      Area = Controls.SitesDistrictArea, Fold = SDP_Panel.Sites.SetFold,
      Buttons = { Controls.SitesSolveButton, Controls.SitesPlaceButton, Controls.SitesUndoButton } },
    { Tab = "MULTI", Page = Controls.MultiPage, Body = Controls.MultiBody, Grid = Controls.MultiDistrictScroll,
      Area = Controls.MultiDistrictArea, Fold = SDP_Panel.Multi.SetFold,
      Buttons = { Controls.MultiSolveButton, Controls.MultiPlaceButton, Controls.MultiUndoButton } },
  }
end

-- The page of tab `t` made `extra` shorter than the shortest window gives:
-- the body and the buttons end on it, the grid keeps two rows.
local function Fits314(t, extra)
  t.Page:SetSizeY(SDP_UI.WINDOW_MIN - SDP_UI.PAGE_INSET - extra)
  -- The page fits itself again, as when the player folds and unfolds the settings.
  t.Fold(true)
  t.Fold(false)
  local page, body = t.Page:GetSizeY(), t.Body:GetSizeY()
  local _, pageTop = t.Page:GetScreenOffset()
  local label = string.format("%s, page %d", t.Tab, page)
  print(string.format("issue 314 %s: body %d, grid %d of %d", label, body, t.Grid:GetSizeY(), t.Area:GetSizeY()))
  T.ok(body <= page, label .. ": the body " .. body .. " fits the page")
  for _, button in ipairs(t.Buttons) do
    local _, top = button:GetScreenOffset()
    T.ok(top + button:GetSizeY() <= pageTop + page, label .. ": a button ends at " .. (top + button:GetSizeY())
      .. ", the page at " .. (pageTop + page))
  end
  T.ok(t.Grid:GetSizeY() >= math.min(t.Area:GetSizeY(), SDP_UI.DISTRICT_MIN), label .. ": the grid keeps two rows")
end

-- An earlier test's plan on the Several cities tab takes room (issue 320):
-- changing a switch clears it, as it does for the player.
local function ClearMulti()
  local remind = SDP_Panel.Multi.State().Remind
  SDP_Panel.Multi.SetRemind(not remind)
  SDP_Panel.Multi.SetRemind(remind)
  T.eq(SDP_Panel.Multi.State().Result, nil, "no plan on the Several cities tab")
end

test("issue 314: the buttons stay on the shortest page however many district rows", function()
  Reset()
  SDP_Panel.Open()
  local ok, err = pcall(function()
    ClearMulti()
    for _, t in ipairs(Tabs314()) do
      SDP_Panel.SelectTab(t.Tab)
      for _, extra in ipairs({ 0, 30, 60, 90 }) do Fits314(t, extra) end
    end
  end)
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.FitWindow()
  SDP_Panel.Close()
  if not ok then error(err, 0) end
end)

-- With a plan shown the summary and the solutions' buttons above the list
-- take room too (issue 320): the shortest page still has the buttons.
test("issue 320: with a plan on the Several cities tab the buttons stay on the shortest page", function()
  local city = Reset()
  local multi = SDP_Panel.Multi
  SDP_Panel.Open()
  SDP_Panel.SelectTab("MULTI")
  local tier = multi.State().Tier
  local ok, err = pcall(function()
    multi.Refresh()
    multi.SetExisting(city:GetID(), true)
    multi.SetPlanFor("ALL")
    multi.ApplyPlan({ Resolve("DISTRICT_CAMPUS"), Resolve("DISTRICT_HOLY_SITE") })
    multi.SetTier("FAST")
    T.ok(multi.Solve(), "started")
    SDP_Panel.RunTask(5000)
    local result = multi.State().Result
    T.ok(result and result.Ok, "result: " .. tostring(result and result.Error))
    local t = Tabs314()[3]
    Fits314(t, 0)
    T.ok(multi.State().Result ~= nil, "the plan is still shown")
    T.ok(multi.State().ResultHeight >= SDP_UI.RESULT_MIN, "the list keeps a row")
  end)
  multi.ApplyPlan({})
  multi.SetExisting(city:GetID(), nil)
  multi.SetTier(tier)
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.FitWindow()
  SDP_Panel.Close()
  if not ok then error(err, 0) end
end)
