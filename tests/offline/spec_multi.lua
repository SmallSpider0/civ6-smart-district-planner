-- Offline: SDP_Multi, districts for several cities at once.
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

-- Capital at (4,5); another city at (17,5); a far city at (3,11) beyond 7 of
-- both sites; two city-center pins (sites) at (9,6) and (13,9).
local function NewWorld()
  local w = World.New({
    rows = MAP, rivers = { "6,4", "7,4", "7,5", "12,7", "13,7" },
    cities = {
      { id = 1, x = 4, y = 5, population = 6, capital = true, radius = 1 },
      { id = 2, x = 17, y = 5, population = 3, radius = 1 },
      { id = 3, x = 3, y = 11, population = 2, radius = 1 },
    },
    pins = { { 9, 6, "ICON_DISTRICT_CITY_CENTER", "A" }, { 13, 9, "ICON_DISTRICT_CITY_CENTER", "B" } },
  })
  return w
end

test("participants: city-center pins, cities near them, switches", function()
  NewWorld()
  local parts, existing = SDP_Multi.Participants(0)
  T.eq(#parts, 4, "two sites and two nearby cities")
  T.eq(parts[1].Kind, "SITE", "sites first")
  T.eq(parts[1].Index, Map.GetPlotIndex(9, 6), "sites by plot index")
  T.eq(parts[3].CityID, 1, "existing cities by ID")
  T.eq(parts[4].CityID, 2, "second nearby city")
  for _, e in ipairs(existing) do
    if e.CityID == 3 then T.ok(not e.Default and not e.Included, "the far city only neighbours") end
  end
  local switched = SDP_Multi.Participants(0, { Existing = { [2] = false, [3] = true } })
  local keys = {}
  for _, p in ipairs(switched) do keys[#keys + 1] = p.Key end
  T.same(keys, { "S" .. Map.GetPlotIndex(9, 6), "S" .. Map.GetPlotIndex(13, 9), "C1", "C3" }, "switches")
  local cap = SDP_Multi.MAX_CITIES
  SDP_Multi.MAX_CITIES = 3
  local capped, all = SDP_Multi.Participants(0)
  SDP_Multi.MAX_CITIES = cap
  T.eq(#capped, 3, "cap")
  T.eq(capped[3].CityID, 1, "the nearest existing city is kept")
  for _, e in ipairs(all) do
    if e.CityID == 2 then T.eq(e.Reason, "CAP", "the other is left out") end
  end
end)

test("a new city cannot use plots of existing cities", function()
  local w = NewWorld()
  w:Own(7, 6, 0, w:City(1)) -- a plot of the capital two plots from the site
  local scan = SDP_City.ScanSite(0, 9, 6)
  for _, c in ipairs(scan.Candidates) do
    local plot = Map.GetPlotByIndex(c.Index)
    T.eq(plot:GetOwner(), -1, "candidate " .. c.X .. "," .. c.Y .. " is owned")
  end
  T.eq(scan.Excluded[Map.GetPlotIndex(7, 6)], "OTHER_CITY", "the capital's plot")
  T.eq(w:Plot(9, 6):IsCity(), false, "the site is not a city")
end)

local SIX = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER", "DISTRICT_COMMERCIAL_HUB",
  "DISTRICT_INDUSTRIAL_ZONE", "DISTRICT_GOVERNMENT" }

local function Request(extra)
  local r = { PlayerID = 0, Tier = "FAST", Weights = ONES, Districts = SIX }
  for k, v in pairs(extra or {}) do r[k] = v end
  return r
end

test("a planned city's first ring is left to it (issue 26)", function()
  local w = World.New({
    rows = MAP,
    cities = { { id = 1, x = 4, y = 5, population = 6, capital = true, radius = 1 } },
    pins = { { 8, 6, "ICON_DISTRICT_CITY_CENTER", "A" } },
  })
  local ring, shared = SDP_City.PlotsInRange(8, 6, 1), {}
  for _, e in ipairs(ring) do
    if Map.GetPlotDistance(4, 5, e.X, e.Y) <= SDP_City.RADIUS and w:Plot(e.X, e.Y):GetOwner() == -1 then
      shared[#shared + 1] = e
    end
  end
  T.ok(#shared >= 2, "setup: the capital reaches two free plots of the site's first ring")
  local own = shared[1]
  w:Own(own.X, own.Y, 0, w:City(1))
  local scan = SDP_City.Scan(0, 1)
  T.eq(scan.Excluded[own.Index], nil, "a plot the capital owns stays its own")
  for n = 2, #shared do
    T.eq(scan.Excluded[shared[n].Index], "SITE_RING", "free plot " .. shared[n].X .. "," .. shared[n].Y)
  end
  local site = SDP_City.ScanSite(0, 8, 6)
  for _, e in ipairs(ring) do
    T.ok(site.Excluded[e.Index] ~= "SITE_RING", "the site keeps its own first ring")
  end
  local result = SDP_Multi.Solve(Request({ Districts = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER",
    "DISTRICT_COMMERCIAL_HUB" } }))
  T.ok(result.Ok, tostring(result.Error))
  for _, p in ipairs(result.Plan) do
    if p.City == "C1" and Map.GetPlotDistance(8, 6, p.X, p.Y) == 1 then
      T.eq(p.Index, own.Index, "the capital's " .. p.Type .. " in the site's first ring")
    end
  end
end)

test("an empire-limited district every city asks for goes to the first; the others fill their count (issue 28)", function()
  NewWorld()
  local result = SDP_Multi.Solve(Request({
    Districts = { "DISTRICT_GOVERNMENT", "DISTRICT_CAMPUS" },
    Pool = { "DISTRICT_HOLY_SITE", "DISTRICT_THEATER", "DISTRICT_COMMERCIAL_HUB", "DISTRICT_INDUSTRIAL_ZONE" },
    Count = 3,
  }))
  T.ok(result.Ok, tostring(result.Error))
  local perCity, plazas = {}, {}
  for _, p in ipairs(result.Plan) do
    perCity[p.City] = (perCity[p.City] or 0) + 1
    if p.Type == "DISTRICT_GOVERNMENT" then plazas[#plazas + 1] = p.City end
  end
  T.same(plazas, { result.Cities[1].Key }, "one plaza, in the first city of the list")
  for _, c in ipairs(result.Cities) do T.eq(perCity[c.Key], 3, c.Key .. ": three districts") end
  local told = 0
  for _, u in ipairs(result.Unplaced) do
    if u.Type == "DISTRICT_GOVERNMENT" then
      T.eq(u.Reason, "MAX_PER_PLAYER", "why " .. u.City .. " has none")
      told = told + 1
    end
  end
  T.eq(told, #result.Cities - 1, "every other city is told")
end)

test("a multi-city plan: legal plots, one per plot, empire limit, never worse than city by city", function()
  NewWorld()
  local result = SDP_Multi.Solve(Request({ Tier = "STANDARD" }))
  T.ok(result.Ok, tostring(result.Error))
  T.ok(not result.Stats.Mismatch, "incremental and full evaluation agree")
  local used, plazas = {}, 0
  local cities = {}
  for _, c in ipairs(result.Cities) do cities[c.Key] = c end
  for _, p in ipairs(result.Plan) do
    T.ok(not used[p.Index], "plot used twice: " .. p.X .. "," .. p.Y)
    used[p.Index] = true
    if p.Type == "DISTRICT_GOVERNMENT" then plazas = plazas + 1 end
    local city = cities[p.City]
    T.ok(city ~= nil, "plan item without a city")
    T.ok(Map.GetPlotDistance(p.X, p.Y, city.X, city.Y) <= 3, p.Type .. " outside its city's rings")
  end
  T.eq(plazas, 1, "one government plaza for the empire")
  T.ok(result.Gain >= result.FirstGain - 1e-9, "not worse than city by city")
  T.ok(#result.Plan >= 4 * 5, "every city got its districts")
end)

test("existing cities skip what they have built", function()
  local w = NewWorld()
  w:AddDistrict(1, "DISTRICT_CAMPUS", 5, 6)
  local result = SDP_Multi.Solve(Request())
  for _, p in ipairs(result.Plan) do
    T.ok(not (p.City == "C1" and p.Type == "DISTRICT_CAMPUS"), "a second campus for the capital")
  end
end)

test("same request, same plan", function()
  NewWorld()
  local a = SDP_Multi.Solve(Request())
  local b = SDP_Multi.Solve(Request())
  T.same(b.Plan, a.Plan, "plan")
  T.same(b.Stats, a.Stats, "stats")
end)

test("wide joint start: one more start with two cities or more, none for one city", function()
  NewWorld()
  -- The mechanism at FAST (STANDARD turns it on in SDP_Tiers).
  local on = { WideJoint = 2, WideRounds = 0 }
  local two = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE" }
  local wide = SDP_Multi.Solve(Request({ Districts = two, Params = on }))
  local plain = SDP_Multi.Solve(Request({ Districts = two }))
  T.ok(wide.Ok and plain.Ok, "solved")
  T.eq(#wide.Session.Starts, #plain.Session.Starts + 1, "the wide joint start runs once, after the others")
  T.ok(wide.Gain >= plain.Gain - 1e-9, "the starts only grow (FAST has no kicks)")
  local only = Request({ Districts = two, Only = { [1] = true }, Params = on })
  local one = SDP_Multi.Solve(only)
  only.Params = nil
  T.eq(#one.Session.Starts, #SDP_Multi.Solve(only).Session.Starts, "one city: no wide joint start")
  -- The time estimate counts it the same way.
  local params = SDP_Tiers.Params(SDP_Tiers.Multi, "STANDARD")
  local off = SDP_Tiers.Params(SDP_Tiers.Multi, "STANDARD", { WideJoint = 1 })
  T.ok(SDP_Multi.EstimateUnits(3, 4, 0, params) > SDP_Multi.EstimateUnits(3, 4, 0, off), "estimate: two cities or more")
  T.eq(SDP_Multi.EstimateUnits(1, 4, 1, params), SDP_Multi.EstimateUnits(1, 4, 1, off), "estimate: one city")
end)

test("small problem: equals brute force", function()
  NewWorld()
  local request = Request({ Districts = { "DISTRICT_CAMPUS" }, Existing = { [1] = false, [2] = false }, Land = false,
    Params = { ExactLimit = 100000 } })
  local result = SDP_Multi.Solve(request)
  T.ok(result.Ok, tostring(result.Error))
  -- Brute force: every pair of plots for the two sites' campuses.
  local a, b = SDP_City.ScanSite(0, 9, 6), SDP_City.ScanSite(0, 13, 9)
  local best = SDP_Overlay.With(0, function()
    local fixed, seen = {}, {}
    for _, scan in ipairs({ a, b }) do
      for _, s in ipairs(SDP_Overlay.FixedSubjects(scan)) do
        local key = s.X .. "," .. s.Y
        if not seen[key] then seen[key], fixed[#fixed + 1] = true, s end
      end
    end
    table.sort(fixed, function(x, y) return Map.GetPlotIndex(x.X, x.Y) < Map.GetPlotIndex(y.X, y.Y) end)
    local base = SDP_Overlay.Evaluate({}, fixed, ONES).Total
    local top = nil
    for _, p in ipairs(a.Candidates) do
      for _, q in ipairs(b.Candidates) do
        if p.Index ~= q.Index then
          local res = SDP_Overlay.Evaluate({ SDP_Overlay.Subject("DISTRICT_CAMPUS", p.X, p.Y),
            SDP_Overlay.Subject("DISTRICT_CAMPUS", q.X, q.Y) }, fixed, ONES)
          if res.Legal and (top == nil or res.Total - base > top) then top = res.Total - base end
        end
      end
    end
    return top
  end)
  T.eq(result.Gain, best, "gain vs brute force")
end)

test("land part per city: a shared plot counts for the nearer city", function()
  NewWorld()
  local session = SDP_Overlay.With(0, function()
    local s = SDP_Multi.NewSession(Request())
    s.Board:Clear()
    return s
  end)
  local seen = {}
  for p, part in ipairs(session.Participants) do
    for index in pairs(part.Land.ByIndex) do
      T.ok(seen[index] == nil, "plot " .. index .. " counted by two cities")
      seen[index] = p
      local plot = Map.GetPlotByIndex(index)
      local d = Map.GetPlotDistance(part.X, part.Y, plot:GetX(), plot:GetY())
      for q, other in ipairs(session.Participants) do
        if q ~= p then
          local scanHas = false
          for _, i in ipairs(SDP_Land.Workable(other.Scan)) do
            if i == index then scanHas = true end
          end
          if scanHas then
            local e = Map.GetPlotDistance(other.X, other.Y, plot:GetX(), plot:GetY())
            T.ok(d < e or (d == e and p < q), "plot " .. index .. " should go to the nearer city")
          end
        end
      end
    end
  end
end)

test("wonder list: built and pinned wonders are marked, no generic icon", function()
  local w = NewWorld()
  w:AddBuilding(1, "BUILDING_STONEHENGE")
  w:AddPin(6, 3, "ICON_BUILDING_HANGING_GARDENS", "gardens")
  local list = SDP_Wonders.List(0)
  local status = {}
  for _, entry in ipairs(list) do status[entry.Type] = entry.Status or "free" end
  T.eq(status.BUILDING_STONEHENGE, "BUILT", "built in our city")
  T.eq(status.BUILDING_HANGING_GARDENS, "PINNED", "pinned")
  T.eq(status.BUILDING_PYRAMIDS, "free", "free")
  T.eq(status.DISTRICT_WONDER, nil, "no generic wonder icon")
end)

test("wonder list: by era, then production cost, then type (issue 7)", function()
  NewWorld()
  local list = SDP_Wonders.List(0)
  local order = {}
  for _, entry in ipairs(list) do order[#order + 1] = entry.Type end
  -- Ancient: Hanging Gardens 180, Stonehenge 180, Pyramids 220; classical (civics): Colosseum 400, Great Library 400.
  T.same(order, { "BUILDING_HANGING_GARDENS", "BUILDING_STONEHENGE", "BUILDING_PYRAMIDS", "BUILDING_COLOSSEUM",
    "BUILDING_GREAT_LIBRARY" }, "order")
  T.eq(list[1].EraType, "ERA_ANCIENT", "era type")
  T.eq(list[1].Era, 1, "chronology index")
  T.eq(list[1].Cost, 180, "cost")
  T.eq(list[5].EraType, "ERA_CLASSICAL", "a civic's era")
  -- Both prerequisites: the later era; neither: before every era.
  local era, eraType = SDP_Wonders.Era({ PrereqTech = "TECH_MASONRY", PrereqCivic = "CIVIC_RECORDED_HISTORY" })
  T.eq(era, 2, "the later of tech and civic")
  T.eq(eraType, "ERA_CLASSICAL", "its type")
  T.eq(SDP_Wonders.Era({}), 0, "no prerequisite")
end)

test("wonders: legal places, a required district next to it, unplaceable ones reported", function()
  local w = NewWorld()
  for _, xy in ipairs({ { 10, 7 }, { 11, 7 }, { 8, 7 } }) do w:Plot(xy[1], xy[2]).terrain = GameInfo.Terrains.TERRAIN_DESERT end
  w:AddBuilding(1, "BUILDING_STONEHENGE")
  local result = SDP_Multi.Solve(Request({
    Districts = { "DISTRICT_CAMPUS", "DISTRICT_THEATER", "DISTRICT_HOLY_SITE" },
    Wonders = { "BUILDING_PYRAMIDS", "BUILDING_GREAT_LIBRARY", "BUILDING_STONEHENGE", "BUILDING_COLOSSEUM" },
  }))
  T.ok(result.Ok, tostring(result.Error))
  T.ok(not result.Stats.Mismatch, "incremental and full evaluation agree (legality included)")
  local placed, reasons = {}, {}
  for _, p in ipairs(result.Plan) do
    if p.Kind == "WONDER" then placed[p.Type] = p end
  end
  for _, u in ipairs(result.Unplaced) do reasons[u.Type] = u.Reason end
  T.ok(placed.BUILDING_PYRAMIDS ~= nil, "pyramids placed")
  T.eq(Map.GetPlot(placed.BUILDING_PYRAMIDS.X, placed.BUILDING_PYRAMIDS.Y):GetTerrainType(), GameInfo.Terrains.TERRAIN_DESERT.Index,
    "pyramids on desert")
  local library = placed.BUILDING_GREAT_LIBRARY
  T.ok(library ~= nil, "great library placed")
  local nextToCampus = false
  for _, p in ipairs(result.Plan) do
    if p.Type == "DISTRICT_CAMPUS" and Map.GetPlotDistance(p.X, p.Y, library.X, library.Y) == 1 then nextToCampus = true end
  end
  T.ok(nextToCampus, "great library next to a planned campus")
  T.eq(reasons.BUILDING_STONEHENGE, "BUILT", "built wonder not planned")
  T.eq(reasons.BUILDING_COLOSSEUM, "NEEDS_DISTRICT", "no entertainment complex anywhere")
end)

test("repair: a wonder the search left off goes back in, next to its district", function()
  NewWorld()
  local result = SDP_Overlay.With(0, function()
    local s = SDP_Multi.NewSession(Request({
      Districts = { "DISTRICT_CAMPUS", "DISTRICT_THEATER", "DISTRICT_HOLY_SITE" }, Wonders = { "BUILDING_GREAT_LIBRARY" },
    }))
    s:Run()
    local search = s.Search
    local library
    for m = 1, search.K do
      if search.Types[m] == "BUILDING_GREAT_LIBRARY" then library = m end
    end
    T.ok(library ~= nil and search.BestLayout[library] ~= 0, "the search placed it")
    -- What the search can end with when the districts take every plot
    -- around the campus (seen in the comparison, 2026-10-20): the library off.
    -- No start placed it either, so the result can only come from the repair.
    local off = SDP_Search.Copy(search.BestLayout)
    off[library] = 0
    search.BestLayout, search.BestPlaced, search.BestGain = off, SDP_Search.Placed(off), search:Evaluate(off)
    s.Starts = { { Layout = off, Gain = search.BestGain } }
    s:Repair()
    T.eq(search.BestPlaced, search.K, "every slot placed again")
    T.ok(search.BestLayout[library] ~= 0, "the library is back")
    return s:Result()
  end)
  T.ok(result.Ok, tostring(result.Error))
  T.ok(not result.Stats.Mismatch, "incremental and full evaluation agree")
  local library, campuses = nil, {}
  for _, p in ipairs(result.Plan) do
    if p.Type == "BUILDING_GREAT_LIBRARY" then library = p end
    if p.Type == "DISTRICT_CAMPUS" then campuses[#campuses + 1] = p end
  end
  T.ok(library ~= nil, "in the plan")
  local next = false
  for _, c in ipairs(campuses) do
    if Map.GetPlotDistance(c.X, c.Y, library.X, library.Y) == 1 then next = true end
  end
  T.ok(next, "next to a planned campus")
end)

test("several distinct solutions, best first", function()
  NewWorld()
  local result = SDP_Multi.Solve(Request({ Tier = "STANDARD" }))
  T.ok(#result.Solutions >= 2, "at least two solutions on this map")
  T.ok(#result.Solutions <= 3, "at most three")
  T.same(result.Plan, result.Solutions[1].Plan, "the top-level plan is the best solution")
  local need = math.max(2, math.ceil(0.2 * result.Session.Search.K))
  for a = 1, #result.Solutions do
    local sa = result.Solutions[a]
    T.ok(sa.Legal, "solution " .. a .. " legal")
    if a > 1 then T.ok(sa.Gain <= result.Solutions[a - 1].Gain + 1e-9, "sorted by value") end
    for b = 1, a - 1 do
      local at = {}
      for _, p in ipairs(result.Solutions[b].Plan) do at[p.City .. p.Type] = p.Index end
      local diff = 0
      for _, p in ipairs(sa.Plan) do
        if at[p.City .. p.Type] ~= p.Index then diff = diff + 1 end
      end
      T.ok(diff >= need, "solutions " .. b .. " and " .. a .. " differ in " .. diff .. " < " .. need)
    end
  end
end)
