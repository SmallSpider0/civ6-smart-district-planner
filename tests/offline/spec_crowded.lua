-- Offline: crowded cities, as in late-game saves (stress test 2026-10-21).
-- A city whose candidates have no legal plot at all used to make the
-- multi-city plan fail (SDP_Multi PlanFor took a number minus nil).
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
include("SDP_Remind")
include("SDP_Solver")
include("SDP_Wonders")
include("SDP_Multi")

local ONES = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }

-- Land only: a harbor has no legal plot anywhere.
local LAND = {
  "................",
  "................",
  "................",
  "................",
  "................",
  "................",
  "................",
  "................",
  "................",
  "................",
}

local function NewWorld()
  return World.New({ rows = LAND, cities = { { id = 1, x = 4, y = 4, population = 10, capital = true } },
    pins = { { 11, 5, "ICON_DISTRICT_CITY_CENTER", "2" } } })
end

test("single city: candidates without any legal plot give a plan without them, not an error", function()
  NewWorld()
  for _, tier in ipairs({ "FAST", "STANDARD" }) do
    local r = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = { "DISTRICT_CAMPUS" }, Pool = { "DISTRICT_HARBOR" },
      Count = 2, Weights = ONES, Tier = tier })
    T.ok(r.Ok, tier .. ": " .. tostring(r.Error))
    T.eq(#r.Plan, 1, tier .. ": the campus")
    T.eq(r.Plan[1].Type, "DISTRICT_CAMPUS", tier .. ": campus placed")
  end
end)

test("several cities: a city whose candidates have no legal plot is reported short, the plan stands", function()
  NewWorld()
  for _, tier in ipairs({ "FAST", "STANDARD" }) do
    local r = SDP_Multi.Solve({ PlayerID = 0, Tier = tier, Districts = { "DISTRICT_CAMPUS" }, Pool = { "DISTRICT_HARBOR" },
      Count = 2, Weights = ONES, Existing = { [1] = true } })
    T.ok(r.Ok, tier .. ": " .. tostring(r.Error))
    local campuses, short = 0, 0
    for _, p in ipairs(r.Plan) do
      if p.Type == "DISTRICT_CAMPUS" then campuses = campuses + 1 end
    end
    for _, u in ipairs(r.Unplaced) do
      if u.Reason == "POOL_SHORT" then short = short + 1 end
    end
    T.eq(campuses, 2, tier .. ": a campus in each city")
    T.eq(short, 2, tier .. ": both cities reported short of candidates")
  end
end)
