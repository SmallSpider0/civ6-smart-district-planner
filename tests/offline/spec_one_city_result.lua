-- Offline: the One city tab shows a plan the same way whichever solver made
-- it (issue 250). Without wonders the city is solved by SDP_Solver, with
-- wonders by SDP_Multi with this city alone; before the fix the tab read
-- the two results differently:
--   - a pool that falls short: SDP_Multi's POOL_SHORT entry showed as a
--     district named "POOL" with a broken reason, SDP_Solver's plan said
--     nothing;
--   - the plan buttons named the districts picked from the pool only for
--     SDP_Solver ("N districts" for SDP_Multi);
--   - what a plan leaves out: SDP_Solver's list was the first plan's, shown
--     under every plan; SDP_Multi did not say that a district with no plot
--     left had been added by itself (the Aqueduct).
-- Wonders, the count, solving and choosing a plan go through the controls'
-- own callbacks; the district states are set up through the panel's hooks.
local test, T = ...

local UI_Mock = include("ui")

-- A city among mountains: five flat plots in its range.
local MAP = {
  "MMMMMMMMMMM",
  "MMMMMMMMMMM",
  "MMMMMMMMMMM",
  "MMMMM.MMMMM",
  "MMM.....MMM",
  "MMMMMMMMMMM",
  "MMMMMMMMMMM",
  "MMMMMMMMMMM",
  "MMMMMMMMMMM",
}

local w = World.New({
  rows = MAP,
  cities = { { id = 1, x = 5, y = 4, population = 12, capital = true, radius = 3 } },
})
UI_Mock.Install()
include("SDP_Panel")
local c = UI_Mock.Controls

local WONDER = "BUILDING_STONEHENGE"

local function PickWonder(wonderType)
  for _, entry in ipairs(c.WonderPull._entries) do
    if entry.Button:GetText() == "LOC_" .. wonderType .. "_NAME" then
      entry.Button:Click()
      return true
    end
  end
  return false
end

local function Solve()
  c.SolveButton:Click()
  return SDP_Panel.RunTask(500)
end

local function Rows()
  return SDP_Panel.State().ResultRows
end

local SPECIALTY = { "DISTRICT_CAMPUS", "DISTRICT_THEATER", "DISTRICT_HOLY_SITE", "DISTRICT_INDUSTRIAL_ZONE",
  "DISTRICT_ENTERTAINMENT_COMPLEX", "DISTRICT_COMMERCIAL_HUB", "DISTRICT_ENCAMPMENT" }

local function Setup(states)
  SDP_Panel.Open()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(1)
  SDP_Panel.SetWonder(WONDER, false) -- a failed test may leave it ticked
  SDP_Panel.ForgetCounts()
  -- Each test from the defaults: the specialty districts in the pool, the
  -- Aqueduct added when the city needs it.
  for _, districtType in ipairs(SPECIALTY) do SDP_Panel.SetState(districtType, states[districtType] or "POOL") end
  SDP_Panel.SetState("DISTRICT_AQUEDUCT", states.DISTRICT_AQUEDUCT or "AUTO")
  SDP_Panel.SetTier("STANDARD")
end

local function Names(rows)
  local out = {}
  for _, r in ipairs(rows) do out[#out + 1] = tostring(r.Name) .. " | " .. tostring(r.Detail) end
  return table.concat(out, "; ")
end

local function Planned(plan)
  local set = {}
  for _, p in ipairs(plan) do set[p.Type] = true end
  return set
end

-- Solve without wonders, then with the wonder ticked: check(result, path)
-- after each (the wonder unticked at the end).
local function BothPaths(check)
  local r = Solve()
  T.ok(r and r.Ok, "without wonders: " .. tostring(r and r.Error))
  check(r, "without wonders")
  T.ok(PickWonder(WONDER), "the wonder is in the pulldown")
  r = Solve()
  T.ok(r and r.Ok, "with the wonder: " .. tostring(r and r.Error))
  check(r, "with the wonder")
  SDP_Panel.SetWonder(WONDER, false)
end

test("a pool that falls short says so, with or without wonders", function()
  -- The Campus and five more from the pool: four plots are left for them.
  Setup({ DISTRICT_CAMPUS = "MUST", DISTRICT_AQUEDUCT = "OFF" })
  for _ = 1, 3 do c.CountMore:Click() end
  T.eq(SDP_Panel.State().Count, 6, "six asked")
  BothPaths(function(r, path)
    local short = nil
    for _, row in ipairs(Rows()) do
      T.ok(row.Name ~= "LOC_SDP_RESULT_UNPLACED(POOL)", path .. ": no district called POOL: " .. Names(Rows()))
      if row.Name == "LOC_SDP_RESULT_POOL_SHORT(LOC_SDP_CITY_N(1,CITY_1))" then short = row end
    end
    T.ok(short ~= nil, path .. ": the pool's shortfall is a row: " .. Names(Rows()))
    local picked = 0
    for _, p in ipairs(r.Plan) do
      if p.Picked then picked = picked + 1 end
    end
    T.eq(short and short.Detail, "LOC_SDP_REASON_POOL_SHORT(" .. (5 - picked) .. ")", path .. ": by how many")
  end)
end)

test("the plan buttons name the districts picked from the pool, with or without wonders", function()
  Setup({ DISTRICT_CAMPUS = "MUST", DISTRICT_AQUEDUCT = "OFF" })
  for _ = 1, 2 do c.CountMore:Click() end
  BothPaths(function(r, path)
    local cells = SDP_Panel.State().SolutionCells
    T.ok(#cells > 1, path .. ": several plans")
    for n, cell in ipairs(cells) do
      T.ok(cell:GetToolTipString():find("LOC_SDP_SOLUTION_PICKED(", 1, true) ~= nil,
        path .. ": plan " .. n .. " names its picks: " .. cell:GetToolTipString())
    end
  end)
end)

test("each plan lists what it leaves out, with or without wonders", function()
  -- Six required, the Aqueduct added by itself: five plots.
  Setup({ DISTRICT_CAMPUS = "MUST", DISTRICT_THEATER = "MUST", DISTRICT_HOLY_SITE = "MUST",
    DISTRICT_INDUSTRIAL_ZONE = "MUST", DISTRICT_ENTERTAINMENT_COMPLEX = "MUST", DISTRICT_COMMERCIAL_HUB = "MUST" })
  BothPaths(function(r, path)
    T.ok(#r.Solutions > 1, path .. ": several plans")
    for n = 1, #r.Solutions do
      SDP_Panel.State().SolutionCells[n]:Click()
      local planned, listed = Planned(r.Solutions[n].Plan), {}
      for _, row in ipairs(Rows()) do
        local what = row.Name:match("^LOC_SDP_RESULT_UNPLACED%((.-)%)$") or row.Name:match("^LOC_SDP_RESULT_UNPLACED_AUTO%((.-)%)$")
        if what ~= nil then
          local districtType = what:match("^LOC_(.*)_NAME$")
          T.ok(not planned[districtType], path .. ", plan " .. n .. ": " .. districtType .. " is planned, not left out")
          listed[districtType] = row.Name
        end
      end
      for _, districtType in ipairs({ "DISTRICT_CAMPUS", "DISTRICT_THEATER", "DISTRICT_HOLY_SITE", "DISTRICT_INDUSTRIAL_ZONE",
        "DISTRICT_ENTERTAINMENT_COMPLEX", "DISTRICT_COMMERCIAL_HUB", "DISTRICT_AQUEDUCT" }) do
        T.ok(planned[districtType] or listed[districtType], path .. ", plan " .. n .. ": " .. districtType .. " planned or listed")
      end
      -- The Aqueduct came by itself, and its row says so either way.
      T.eq(listed.DISTRICT_AQUEDUCT, planned.DISTRICT_AQUEDUCT == nil and "LOC_SDP_RESULT_UNPLACED_AUTO(LOC_DISTRICT_AQUEDUCT_NAME)" or nil,
        path .. ", plan " .. n .. ": the Aqueduct added by itself")
    end
  end)
end)
