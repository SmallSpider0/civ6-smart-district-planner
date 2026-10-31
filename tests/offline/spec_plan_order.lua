-- Offline: issue 189. The plan buttons show each plan's weighted adjacency,
-- but plans are ranked by how many districts and wonders they place, then
-- by the adjacency plus the items in brackets. A later plan that leaves a
-- wonder out showed a higher number than the first with nothing to say
-- why. Each plan after the first now says why it comes after the one
-- before it (on its button's hover and under the summary when selected),
-- and the whole list is ranked after tile swaps are tidied (issue 162).
-- Driven through the panel's own controls.
local test, T = ...

local UI_Mock = include("ui")

local MAP = {
  "~~~~~~~~~~~~~~~~~~~~~~",
  "~..f.M..h...f..M..h..~",
  "~.fMj..p.d...fMj..p..~",
  "~h..f.j..M.h..f.j..M.~",
  "~.pM...f.h..pM...f.h.~",
  "~..j.p..q....j.p..q..~",
  "~f..h.M.j..f..h.M.j..~",
  "~.s..f..p...s..f..p..~",
  "~..p...h...p...h.....~",
  "~.M..f..j..M..f..j...~",
  "~..h..p...h..p...h...~",
  "~.f..M..p..f..M..p...~",
  "~..j...h..j...h..j...~",
  "~~~~~~~~~~~~~~~~~~~~~~",
}

World.New({
  rows = MAP, rivers = { "6,4", "7,4", "7,5", "12,7", "13,7" },
  cities = {
    { id = 1, x = 4, y = 5, population = 16, capital = true, radius = 1 },
    { id = 2, x = 9, y = 6, population = 16, radius = 1 },
  },
})
UI_Mock.Install()
include("SDP_Panel")
local c = UI_Mock.Controls

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

local DISTRICTS = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER", "DISTRICT_COMMERCIAL_HUB",
  "DISTRICT_INDUSTRIAL_ZONE" }
local WONDERS = { "BUILDING_HANGING_GARDENS", "BUILDING_STONEHENGE", "BUILDING_GREAT_LIBRARY" }

-- Both cities, the first `districts` of DISTRICTS required in each (shared
-- list), the wonders `wonders`, fast; solved with the Solve button.
local function Solve(districts, wonders)
  SDP_Panel.Open()
  SDP_Panel.SelectTab("MULTI")
  local multi = SDP_Panel.Multi
  multi.Refresh()
  for _, city in ipairs(multi.State().View.Cities) do
    if city.Kind == "CITY" and not city.Included then city.Chip:Click() end
  end
  multi.SetPlanFor("ALL")
  for i, d in ipairs(DISTRICTS) do SetRow(d, i <= districts and "MUST" or "OFF") end
  local chosen = {}
  for _, w in ipairs(wonders) do chosen[w] = true end
  for _, w in ipairs(WONDERS) do multi.SetWonder(w, chosen[w] == true) end
  multi.SetTier("FAST")
  c.MultiSolveButton:Click()
  local result = SDP_Panel.RunTask(5000) or multi.State().Result
  T.ok(result and result.Ok, "solved: " .. tostring(result and result.Error))
  return result, multi
end

-- Plans are ranked: more placed first, then the higher value.
local function CheckOrder(result)
  for n = 2, #result.Solutions do
    local a, b = result.Solutions[n - 1], result.Solutions[n]
    T.ok(#a.Plan > #b.Plan or (#a.Plan == #b.Plan and a.Gain >= b.Gain - 1e-9),
      string.format("plan %d (%d placed, %.2f) after plan %d (%d placed, %.2f)", n, #b.Plan, b.Gain, n - 1, #a.Plan, a.Gain))
  end
end

-- The reason plan n comes after plan n - 1: on its button's hover, and
-- under the summary once its button is clicked.
local function CheckReason(multi, n, expected)
  local view = multi.State().View.Solutions[n]
  T.ok(view.Cell:GetToolTipString():find(expected, 1, true) ~= nil,
    "plan " .. n .. "'s hover says " .. expected .. ": " .. view.Cell:GetToolTipString())
  view.Cell:Click()
  T.eq(multi.State().View.Solutions[n].Selected, true, "plan " .. n .. " selected")
  T.ok(multi.State().QualityText:find(expected, 1, true) ~= nil,
    "under the summary: " .. tostring(multi.State().QualityText))
  multi.State().View.Solutions[1].Cell:Click()
  T.ok(multi.State().QualityText:find("LOC_SDP_RANK_", 1, true) == nil, "plan 1: no reason")
end

-- The report's case: a later plan leaves a wonder out and shows a higher
-- weighted adjacency than the plan before it.
test("several cities: a plan that places fewer says so (issue 189)", function()
  local result, multi = Solve(5, { "BUILDING_HANGING_GARDENS", "BUILDING_STONEHENGE" })
  CheckOrder(result)
  local found = false
  for n = 2, #result.Solutions do
    local a, b = result.Solutions[n - 1], result.Solutions[n]
    if #b.Plan < #a.Plan then
      found = found or b.Adjacency > a.Adjacency
      CheckReason(multi, n, "LOC_SDP_RANK_FEWER(" .. (n - 1) .. "," .. (#a.Plan - #b.Plan) .. ")")
    end
  end
  T.ok(found, "setup: a later plan places fewer and shows a higher adjacency")
end)

-- The same number placed: ranked by the adjacency plus the items in
-- brackets, while the button shows the adjacency alone.
test("several cities: a plan ranked lower by the items in brackets says so (issue 189)", function()
  local result, multi = Solve(3, { "BUILDING_HANGING_GARDENS", "BUILDING_STONEHENGE", "BUILDING_GREAT_LIBRARY" })
  CheckOrder(result)
  local found = false
  for n = 2, #result.Solutions do
    local a, b = result.Solutions[n - 1], result.Solutions[n]
    if #b.Plan == #a.Plan then
      found = found or b.Adjacency > a.Adjacency
      local lower = math.floor((a.Gain - b.Gain) * 10 + 0.5) / 10
      local text = lower > 0 and ("LOC_SDP_RANK_LOWER(" .. (n - 1) .. "," .. (lower == math.floor(lower) and
        string.format("%d", lower) or string.format("%.1f", lower)) .. ")") or ("LOC_SDP_RANK_SAME(" .. (n - 1) .. ")")
      CheckReason(multi, n, text)
    end
  end
  T.ok(found, "setup: a later plan with as many placed shows a higher adjacency")
end)

-- The single-city tab says the same on its plan buttons and under its summary.
test("single city: each plan after the first says why (issue 189)", function()
  SDP_Panel.Open()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(1)
  for _, d in ipairs({ "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER" }) do SDP_Panel.SetState(d, "MUST") end
  SDP_Panel.SetCount(3)
  SDP_Panel.SetTier("STANDARD")
  local result = SDP_Panel.Solve()
  T.ok(result ~= nil and result.Ok, "solved: " .. tostring(result and result.Error))
  CheckOrder(result)
  T.ok(#result.Solutions >= 2, "setup: several plans")
  for n = 2, #result.Solutions do
    local a, b = result.Solutions[n - 1], result.Solutions[n]
    local expected
    if #b.Plan < #a.Plan then
      expected = "LOC_SDP_RANK_FEWER(" .. (n - 1) .. "," .. (#a.Plan - #b.Plan) .. ")"
    else
      expected = "LOC_SDP_RANK_" .. ((a.Gain - b.Gain) >= 0.05 and "LOWER" or "SAME") .. "(" .. (n - 1)
    end
    local cell = SDP_Panel.State().SolutionCells[n]
    T.ok(cell:GetToolTipString():find(expected, 1, true) ~= nil, "plan " .. n .. "'s hover: " .. cell:GetToolTipString())
    cell:Click()
    T.eq(SDP_Panel.State().Solution, n, "plan " .. n .. " shown")
    T.ok(SDP_Panel.State().QualityText:find(expected, 1, true) ~= nil, "under the summary: " .. SDP_Panel.State().QualityText)
  end
  SDP_Panel.State().SolutionCells[1]:Click()
  T.ok(SDP_Panel.State().QualityText:find("LOC_SDP_RANK_", 1, true) == nil, "plan 1: no reason")
end)
