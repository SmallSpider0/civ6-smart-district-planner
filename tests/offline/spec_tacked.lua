-- Offline: a city's own district tacks (issue 64). A city counts a tack as
-- its own only on a plot it owns, or on an unowned plot no other city or
-- planned city is nearer to; another city's tack is a fixed neighbour. On
-- the Several cities tab with the shared list, a city that already has a
-- tack of a district skips it and says why; a neighbour's tack no longer
-- takes the district off its plan.
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

local CAMPUS, THEATER = "DISTRICT_CAMPUS", "DISTRICT_THEATER"
local C2X, C2Y = 8, 3 -- city 2, four plots from the capital

-- Two cities four plots apart; the capital owns two rings.
local function NewWorld(pins)
  return World.New({
    rows = MAP, rivers = { "6,4", "7,4", "7,5", "12,7", "13,7" },
    cities = {
      { id = 1, x = 4, y = 5, population = 6, capital = true, radius = 2 },
      { id = 2, x = C2X, y = C2Y, population = 6, radius = 1 },
    },
    pins = pins,
  })
end

-- The panel is built on the first world; the unit tests below make their own.
local m_world = NewWorld()
UI_Mock.Install()
include("SDP_Panel")

local function Has(list, x, y)
  for _, pin in ipairs(list) do
    if pin.X == x and pin.Y == y then return true end
  end
  return false
end

-- The first plot (by index) within RADIUS of city 1 that matches `want`.
local function FindPlot(want)
  for index = 0, Map.GetPlotCount() - 1 do
    local plot = Map.GetPlotByIndex(index)
    local x, y = plot:GetX(), plot:GetY()
    local d1, d2 = Map.GetPlotDistance(4, 5, x, y), Map.GetPlotDistance(C2X, C2Y, x, y)
    if d1 >= 1 and d1 <= SDP_City.RADIUS and not plot:IsWater() and want(plot, d1, d2) then return x, y end
  end
  return nil
end

test("several cities tab, two batches with the shared list: the second keeps its districts (issue 64)", function()
  local w = m_world
  SDP_Panel.Open()
  SDP_Panel.SelectTab("MULTI")
  local multi = SDP_Panel.Multi
  multi.Refresh()
  multi.SetPlanFor("ALL")
  multi.SetSelected(CAMPUS, true)
  multi.SetSelected(THEATER, true)
  multi.SetTier("FAST")
  local function Solve()
    T.ok(multi.Solve(), "started")
    SDP_Panel.RunTask(2000)
    local result = multi.State().Result
    T.ok(result and result.Ok, "result: " .. tostring(result and result.Error))
    return result
  end
  local function Planned(result, key)
    local types = {}
    for _, p in ipairs(result.Plan) do
      -- The automatic aqueduct (no fresh water here) is not what this is about.
      if p.City == key and p.Type ~= "DISTRICT_AQUEDUCT" then types[#types + 1] = p.Type end
    end
    table.sort(types)
    return types
  end
  -- First batch: the capital.
  multi.SetExisting(1, true)
  multi.SetExisting(2, false)
  local first = Solve()
  T.same(Planned(first, "C1"), { CAMPUS, THEATER }, "the capital's plan")
  T.ok(multi.Place() > 0, "tacked")
  local near = false
  for _, pin in ipairs(w:Pins()) do
    if Map.GetPlotDistance(C2X, C2Y, pin:GetHexX(), pin:GetHexY()) <= SDP_City.RADIUS + 1 then near = true end
  end
  T.ok(near, "a capital's tack within four plots of city 2 (what the issue needs)")
  -- Second batch: city 2 with the same shared list.
  multi.SetExisting(1, false)
  multi.SetExisting(2, true)
  local second = Solve()
  T.same(Planned(second, "C2"), { CAMPUS, THEATER }, "city 2 keeps both districts")
  for _, u in ipairs(second.Unplaced) do T.ok(u.City ~= "C2", "nothing left out of city 2: " .. tostring(u.Type)) end
  -- Both cities: the capital has its tacks, and says so.
  multi.SetExisting(1, true)
  local both = Solve()
  T.same(Planned(both, "C2"), { CAMPUS, THEATER }, "city 2 again")
  for _, t in ipairs(Planned(both, "C1")) do
    T.ok(t ~= CAMPUS and t ~= THEATER, "the capital does not plan its tacked districts again: " .. t)
  end
  local reasons = {}
  for _, u in ipairs(both.Unplaced) do
    if u.City == "C1" and u.Type ~= "DISTRICT_AQUEDUCT" then reasons[#reasons + 1] = u.Type .. " " .. u.Reason end
  end
  table.sort(reasons)
  T.same(reasons, { CAMPUS .. " TACKED", THEATER .. " TACKED" }, "the capital's tacked districts are reported")
  local rows = 0
  for _, row in ipairs(multi.State().View.Results) do
    if row.Detail == "LOC_SDP_REASON_TACKED()" or row.Detail == Locale.Lookup("LOC_SDP_REASON_TACKED", "") then
      rows = rows + 1
    end
  end
  T.eq(rows, 2, "two result rows with the reason")
  T.eq(multi.Undo() > 0, true, "undo")
end)

test("own tacks: the owning city's, or an unowned plot's nearest city; ties count for both", function()
  NewWorld()
  -- A plot within city 1's three rings that city 2 owns (set below).
  local owned2x, owned2y = FindPlot(function(plot, d1, d2) return plot:GetOwner() == -1 and d1 == 3 and d2 == 2 end)
  local tiex, tiey = FindPlot(function(plot, d1, d2) return plot:GetOwner() == -1 and d1 == d2 end)
  local nearx, neary = FindPlot(function(plot, d1, d2) return plot:GetOwner() == -1 and d1 < d2 end)
  local farx, fary = FindPlot(function(plot, d1, d2)
    return plot:GetOwner() == -1 and d1 > d2 and not (plot:GetX() == owned2x and plot:GetY() == owned2y)
  end)
  local foreignx, foreigny = FindPlot(function(plot, d1, d2)
    return plot:GetOwner() == -1 and d1 < d2 and not (plot:GetX() == nearx and plot:GetY() == neary)
  end)
  local function Other(x, y) return (x == owned2x and y == owned2y) or (x == tiex and y == tiey) end
  T.ok(not Other(nearx, neary) and not Other(farx, fary) and not Other(foreignx, foreigny), "distinct plots")
  T.ok(owned2x and tiex and nearx and farx and foreignx, "plots found")
  local w = NewWorld({
    { owned2x, owned2y, "ICON_" .. CAMPUS, "2" }, { tiex, tiey, "ICON_" .. THEATER, "" },
    { nearx, neary, "ICON_DISTRICT_HOLY_SITE", "" }, { farx, fary, "ICON_DISTRICT_COMMERCIAL_HUB", "" },
    { foreignx, foreigny, "ICON_DISTRICT_HARBOR", "" },
  })
  w:Own(foreignx, foreigny, 1, nil)
  w:Own(owned2x, owned2y, 0, w:City(2))
  local own1 = SDP_City.OwnPins(SDP_City.Scan(0, 1))
  local own2 = SDP_City.OwnPins(SDP_City.Scan(0, 2))
  T.ok(not Has(own1, owned2x, owned2y), "a tack on city 2's plot is not city 1's")
  T.ok(Has(own2, owned2x, owned2y), "it is city 2's")
  T.ok(Has(own1, tiex, tiey) and Has(own2, tiex, tiey), "an unowned plot as near to both counts for both")
  T.ok(Has(own1, nearx, neary) and not Has(own2, nearx, neary), "an unowned plot nearer to city 1")
  T.ok(not Has(own1, farx, fary), "an unowned plot nearer to city 2 is not city 1's")
  T.ok(not Has(own1, foreignx, foreigny) and not Has(own2, foreignx, foreigny), "another player's plot is nobody's")
  local tacked = SDP_City.TackedDistricts(SDP_City.Scan(0, 1))
  T.ok(not tacked[CAMPUS] and tacked[THEATER] and tacked.DISTRICT_HOLY_SITE and not tacked.DISTRICT_COMMERCIAL_HUB,
    "city 1's tacked districts")
  T.ok(not SDP_City.PresentDistricts(SDP_City.Scan(0, 1)).DISTRICT_HARBOR, "the single-city tab's pair rule reads the same")
end)

test("own tacks: an unowned plot nearer to a planned city is the planned city's", function()
  NewWorld()
  -- A city-center pin two plots from city 1's edge; a tack next to it.
  local sitex, sitey = 4, 9
  local tackx, tacky = FindPlot(function(plot, d1)
    return plot:GetOwner() == -1 and Map.GetPlotDistance(sitex, sitey, plot:GetX(), plot:GetY()) < d1
  end)
  T.ok(tackx ~= nil, "plot found")
  NewWorld({ { sitex, sitey, "ICON_DISTRICT_CITY_CENTER", "" }, { tackx, tacky, "ICON_" .. CAMPUS, "" } })
  T.ok(not Has(SDP_City.OwnPins(SDP_City.Scan(0, 1)), tackx, tacky), "not city 1's")
  T.ok(Has(SDP_City.OwnPins(SDP_City.ScanSite(0, sitex, sitey)), tackx, tacky), "the planned city's")
end)

test("own tacks: this mod's tack named with a city's number is that city's (SDP_Pins.Own)", function()
  NewWorld()
  local farx, fary = FindPlot(function(plot, d1, d2) return plot:GetOwner() == -1 and d1 > d2 end)
  -- The capital's plots: one city 2 could swap over, one out of city 2's reach.
  local swapx, swapy = FindPlot(function(plot, d1, d2) return plot:GetOwner() == 0 and d2 <= 3 end)
  local ownx, owny = FindPlot(function(plot, d1, d2) return plot:GetOwner() == 0 and d2 > 3 end)
  T.ok(farx and swapx and ownx, "plots found")
  NewWorld({
    { farx, fary, "ICON_" .. CAMPUS, "1" },
    { swapx, swapy, "ICON_" .. THEATER, "2" },
    { ownx, owny, "ICON_DISTRICT_HOLY_SITE", "2" },
  })
  local own1 = SDP_City.OwnPins(SDP_City.Scan(0, 1))
  local own2 = SDP_City.OwnPins(SDP_City.Scan(0, 2))
  T.ok(Has(own1, farx, fary) and not Has(own2, farx, fary), "named 1 on a plot nearer to city 2: the capital's")
  T.ok(Has(own2, swapx, swapy) and not Has(own1, swapx, swapy), "named 2 on the capital's plot: city 2's")
  T.ok(Has(own1, ownx, owny) and not Has(own2, ownx, owny), "named 2 out of city 2's reach: the plot's owner")
end)
