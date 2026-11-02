-- Offline: issue 182. On the Several cities tab a wonder that needs a
-- district next to it gets one supplied (issue 66) when no city has or
-- requires one: to the first city in the list that can take it, where it
-- takes a place in the city's count. When another city picks a district of
-- that kind from its candidates anyway, the supplied one is wasted: the
-- wonder can stand next to the other city's, and the first city can plan
-- another candidate in its place.
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

local EC, CAMPUS, HOLY = "DISTRICT_ENTERTAINMENT_COMPLEX", "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE"
local COLOSSEUM = "BUILDING_COLOSSEUM"

-- Mountains west of city 1: its campus and holy site gain from them.
local MAP = {
  "~~~~~~~~~~~~~~~~~~~~~~~~",
  "~......................~",
  "~......................~",
  "~......................~",
  "~.MM...................~",
  "~.MM...................~",
  "~.MM...................~",
  "~......................~",
  "~......................~",
  "~......................~",
  "~~~~~~~~~~~~~~~~~~~~~~~~",
}

local function NewWorld()
  return World.New({
    rows = MAP,
    cities = {
      { id = 1, x = 5, y = 5, population = 16, capital = true, radius = 3 },
      { id = 2, x = 13, y = 5, population = 16, radius = 3 },
    },
  })
end

-- City 1 is first in the list: the district for the colosseum goes there.
-- City 2 has only the entertainment complex among its candidates, so it
-- picks one whatever the plan.
local function Request()
  return { PlayerID = 0, Tier = "FAST", Existing = { [1] = true, [2] = true }, Districts = {}, Count = 2,
    Plans = { C1 = {}, C2 = {} }, Pools = { C1 = { CAMPUS, HOLY, EC }, C2 = { EC } },
    Counts = { C1 = 2, C2 = 1 }, Wonders = { COLOSSEUM } }
end

local function Count(plan, key, districtType)
  local n = 0
  for _, p in ipairs(plan) do
    if p.City == key and (districtType == nil and p.Kind ~= "WONDER" or p.Type == districtType) then n = n + 1 end
  end
  return n
end

local function Check(result)
  T.ok(result.Ok, tostring(result.Error))
  local plan = result.Plan
  local wonder = nil
  for _, p in ipairs(plan) do
    if p.Type == COLOSSEUM then wonder = p end
  end
  T.ok(wonder ~= nil, "the colosseum is placed")
  T.eq(Count(plan, "C1"), 2, "city 1 plans its two districts")
  T.eq(Count(plan, "C2"), 1, "city 2 plans its one district")
  T.eq(Count(plan, "C1", EC) + Count(plan, "C2", EC), 1,
    "one entertainment complex between the two cities, not one for the wonder and one picked")
  T.eq(Count(plan, "C2", EC), 1, "city 2's own pick")
  -- The wonder next to it, on a tile city 2 can own (the game counts only
  -- the wonder's own city's district).
  for _, p in ipairs(plan) do
    if p.Type == EC then
      T.eq(Map.GetPlotDistance(p.X, p.Y, wonder.X, wonder.Y), 1, "the colosseum next to the entertainment complex")
    end
  end
  T.eq(wonder.City, "C2", "the colosseum is city 2's")
  return plan
end

test("issue 182: another city's pick stands next to the wonder, the first city plans another candidate", function()
  NewWorld()
  local result = SDP_Multi.Solve(Request())
  local plan = Check(result)
  T.eq(Count(plan, "C1", EC), 0, "city 1 gets no entertainment complex")
  T.ok(result.Stats.Again ~= nil and result.Stats.Again.Moved, "the second plan was kept")
  -- Where the district is supplied the result says so.
  T.eq(#result.Supplied, 1, "supplied once")
  T.eq(result.Supplied[1].City, "C2", "to city 2")
  local deterministic = SDP_Multi.Solve(Request())
  T.eq(deterministic.Gain, result.Gain, "same input, same value")
end)

test("issue 182: one solve when no other city picks one", function()
  NewWorld()
  local request = Request()
  request.Pools.C2 = { CAMPUS }
  local result = SDP_Multi.Solve(request)
  T.ok(result.Ok, tostring(result.Error))
  T.eq(result.Stats.Again, nil, "not solved again")
  T.eq(#result.Supplied, 1, "supplied once")
  T.eq(result.Supplied[1].City, "C1", "to the first city, as before")
end)

-- The repair of a wonder left off (Session:Repair) places the districts it
-- must touch again around it: only the ones the layout has, not another
-- city's candidate it did not pick (that city would get more districts than
-- its count).
test("issue 182: repairing a wonder keeps each city's count", function()
  NewWorld()
  local request = Request()
  request.Pools.C2 = { CAMPUS, HOLY, EC }
  local counts = nil
  local ok, err = pcall(SDP_Overlay.With, 0, function()
    local session = SDP_Multi.NewSession(request)
    session:Run()
    local search = session.Search
    T.ok(search.BestLayout ~= nil, "a plan")
    -- Leave the wonder off, as when the search could not fit it.
    local layout = SDP_Search.Copy(search.BestLayout)
    for m = 1, search.K do
      if search.Kinds[m] == "WONDER" then layout[m] = 0 end
    end
    local gain = search:Evaluate(layout)
    search.BestLayout, search.BestGain, search.BestPlaced = layout, gain, SDP_Search.Placed(layout)
    session:Repair()
    counts = {}
    for m = 1, search.K do
      local p = search.Groups[m]
      if search.BestLayout[m] ~= 0 and search.Kinds[m] == "DISTRICT" then counts[p] = (counts[p] or 0) + 1 end
    end
    for m = 1, search.K do
      if search.Kinds[m] == "WONDER" then T.ok(search.BestLayout[m] ~= 0, "the wonder is placed again") end
    end
  end)
  T.ok(ok, tostring(err))
  T.eq(counts[1], 2, "city 1: its two districts")
  T.eq(counts[2], 1, "city 2: its one district")
end)
