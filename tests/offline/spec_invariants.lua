-- Offline: the plan invariants (tests/offline/invariants.lua, issue 242)
-- check every solve, and each check catches the plan it is there for.
local test, T = ...

include("SDP_Rules")
include("SDP_City")
include("SDP_Overlay")
include("SDP_Tiers")
include("SDP_Task")
include("SDP_Board")
include("SDP_Land")
include("SDP_Appeal")
include("SDP_Search")
include("SDP_Solver")
include("SDP_Wonders")
include("SDP_Multi")

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
local ONES = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }

-- The capital at (4,5) with a campus at (7,5); site A at (9,6) can reach
-- the plots next to the campus too (spec_multi, issue 238).
local function NewWorld()
  local w = World.New({
    rows = MAP, rivers = { "6,4", "7,4", "7,5", "12,7", "13,7" },
    cities = {
      { id = 1, x = 4, y = 5, population = 6, capital = true, radius = 1 },
      { id = 2, x = 17, y = 5, population = 3, radius = 1 },
    },
    pins = { { 9, 6, "ICON_DISTRICT_CITY_CENTER", "A" } },
  })
  w:Own(7, 5, 0, w:City(1))
  w:AddDistrict(1, "DISTRICT_CAMPUS", 7, 5, true)
  return w
end

local function Library(extra)
  NewWorld()
  local request = { PlayerID = 0, Tier = "FAST", Weights = ONES, Districts = { "DISTRICT_THEATER" },
    Wonders = { "BUILDING_GREAT_LIBRARY" }, Swap = true }
  for k, v in pairs(extra or {}) do request[k] = v end
  local result = SDP_Multi.Solve(request)
  T.ok(result.Ok, tostring(result.Error))
  local found = {}
  for _, p in ipairs(result.Plan) do found[p.Type] = p end
  return result, found
end

local function Has(found, check)
  for _, line in ipairs(found) do
    if line:find("[" .. check .. "]", 1, true) == 1 then return true end
  end
  return false
end

local function Lines(found) return table.concat(found, "\n") end

test("every solve of both solvers is checked", function()
  local before = SDP_Invariants.Results
  local result = Library()
  T.eq(#SDP_Invariants.Check(result), 0, "a plan of the solver keeps them")
  SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = { "DISTRICT_THEATER" }, Weights = ONES, Tier = "FAST" })
  T.ok(SDP_Invariants.Results >= before + 2, "both results went through the check")
end)

test("a wonder recorded for a city without the district it touches (issue 238)", function()
  local result, plan = Library()
  local library = plan.BUILDING_GREAT_LIBRARY
  T.ok(library ~= nil and library.City == "C1", "placed, for the capital")
  library.City = "S" .. Map.GetPlotIndex(9, 6)
  local found = SDP_Invariants.Check(result)
  T.ok(Has(found, "wonder"), "caught: " .. Lines(found))
end)

test("a district supplied for a wonder away from it (issue 180)", function()
  -- Only the site plans: it gets a campus of its own for the library (issue 66).
  local result, plan = Library({ Existing = { [1] = false, [2] = false } })
  local campus, library = plan.DISTRICT_CAMPUS, plan.BUILDING_GREAT_LIBRARY
  T.ok(campus ~= nil and campus.ForWonder == "BUILDING_GREAT_LIBRARY" and library ~= nil, "supplied and placed")
  T.eq(#SDP_Invariants.Check(result), 0, "as planned")
  campus.X, campus.Y = 9, 8
  campus.Index = Map.GetPlotIndex(9, 8)
  local found = SDP_Invariants.Check(result)
  T.ok(Has(found, "wonder"), "caught: " .. Lines(found))
end)

test("a city over its count (issue 177) and a district placed and listed as not placed", function()
  NewWorld()
  local result = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = { "DISTRICT_THEATER" },
    Pool = { "DISTRICT_HOLY_SITE", "DISTRICT_COMMERCIAL_HUB" }, Count = 2, Weights = ONES, Tier = "FAST" })
  T.ok(result.Ok and #result.Plan == 2, "the theater and one picked")
  T.eq(#SDP_Invariants.Check(result), 0, "as planned")
  result.Session.Request.Count = 1
  local found = SDP_Invariants.Check(result)
  T.ok(Has(found, "count"), "count caught: " .. Lines(found))
  result.Session.Request.Count = 2
  result.Unplaced[#result.Unplaced + 1] = { Type = "DISTRICT_THEATER", Reason = "NO_FREE_PLOT" }
  found = SDP_Invariants.Check(result)
  T.ok(Has(found, "unplaced"), "unplaced caught: " .. Lines(found))
end)

test("two of an empire-unique district, and a district on another's plot", function()
  local result = Library({ Districts = { "DISTRICT_THEATER", "DISTRICT_GOVERNMENT" } })
  local plaza, theater = nil, nil
  for _, p in ipairs(result.Plan) do
    if p.Type == "DISTRICT_GOVERNMENT" then plaza = p end
    if p.Type == "DISTRICT_THEATER" then theater = p end
  end
  T.ok(plaza ~= nil and theater ~= nil, "placed")
  T.eq(#SDP_Invariants.Check(result), 0, "one plaza in the empire")
  local copy = {}
  for k, v in pairs(plaza) do copy[k] = v end
  copy.X, copy.Y, copy.Index, copy.City = theater.X, theater.Y, theater.Index, theater.City
  result.Plan[#result.Plan + 1] = copy
  local found = SDP_Invariants.Check(result)
  T.ok(Has(found, "unique"), "unique caught: " .. Lines(found))
  T.ok(Has(found, "plot"), "plot caught: " .. Lines(found))
end)

test("a district on a plot its city cannot take", function()
  local result, plan = Library()
  local theater = plan.DISTRICT_THEATER
  T.ok(theater ~= nil, "placed")
  -- Next to the far city at (17,5), beyond the planned cities' rings.
  theater.X, theater.Y = 16, 6
  theater.Index = Map.GetPlotIndex(16, 6)
  local found = SDP_Invariants.Check(result)
  T.ok(Has(found, "reach"), "caught: " .. Lines(found))
end)

test("a test opts out of a check with a reason", function()
  local result, plan = Library()
  plan.BUILDING_GREAT_LIBRARY.City = "S" .. Map.GetPlotIndex(9, 6)
  SDP_Invariants.OptOut("spec_invariants: the opt-out itself", { "wonder" })
  T.eq(#SDP_Invariants.Check(result), 0, "the wonder check is off for this test")
  local ok = pcall(SDP_Invariants.OptOut, "")
  T.ok(not ok, "a reason is required")
end)
