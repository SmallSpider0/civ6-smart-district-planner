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
  local others = {}
  for _, u in ipairs(result.Unplaced) do reasons[u.Type], others[u.Type] = u.Reason, u.Other end
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
  -- No city has an entertainment complex: the first city of the list that
  -- can take one plans it for the colosseum (issue 66, plan A).
  local ENT = "DISTRICT_ENTERTAINMENT_COMPLEX"
  T.eq(reasons.BUILDING_COLOSSEUM, nil, "the colosseum is not left out")
  T.eq(#result.Supplied, 1, "one district supplied")
  local supplied = result.Supplied[1]
  T.eq(supplied.Type, ENT, "an entertainment complex")
  T.eq(supplied.Wonder, "BUILDING_COLOSSEUM", "for the colosseum")
  T.eq(supplied.City, SDP_Multi.Participants(0)[1].Key, "in the first city of the list")
  local colosseum, complex = placed.BUILDING_COLOSSEUM, nil
  for _, p in ipairs(result.Plan) do
    if p.Type == ENT then complex = p end
  end
  T.ok(colosseum ~= nil and complex ~= nil, "both placed")
  T.eq(complex.ForWonder, "BUILDING_COLOSSEUM", "the district's entry says what it is for")
  T.eq(complex.City, supplied.City, "in that city")
  T.eq(Map.GetPlotDistance(colosseum.X, colosseum.Y, complex.X, complex.Y), 1, "the colosseum next to it")

  -- The player's own "not wanted" stands: in the shared list no city gets
  -- one, and the reason names the district (it was empty before, #73).
  local request = Request({ Districts = { "DISTRICT_CAMPUS" }, Wonders = { "BUILDING_COLOSSEUM" } })
  request.Off = { [ENT] = true }
  local off = SDP_Multi.Solve(request)
  T.ok(off.Ok, tostring(off.Error))
  local reason, other = nil, nil
  for _, u in ipairs(off.Unplaced) do
    if u.Type == "BUILDING_COLOSSEUM" then reason, other = u.Reason, u.Other end
  end
  T.eq(reason, "NEEDS_DISTRICT", "not wanted anywhere: left out")
  T.eq(other, ENT, "the missing district named")
  T.eq(#off.Supplied, 0, "nothing supplied")
  -- In the first city's own list only: the next city gets it.
  local first, second = SDP_Multi.Participants(0)[1].Key, SDP_Multi.Participants(0)[2].Key
  request = Request({ Districts = { "DISTRICT_CAMPUS" }, Wonders = { "BUILDING_COLOSSEUM" } })
  request.Offs = { [first] = { [ENT] = true } }
  local next = SDP_Multi.Solve(request)
  T.eq(next.Supplied[1] and next.Supplied[1].City, second, "the next city of the list")
  -- A first city that plans a water park cannot have one too.
  request = Request({ Districts = { "DISTRICT_CAMPUS" }, Wonders = { "BUILDING_COLOSSEUM" },
    Plans = { [first] = { "DISTRICT_WATER_ENTERTAINMENT_COMPLEX" } } })
  local park = SDP_Multi.Solve(request)
  T.ok(park.Supplied[1] == nil or park.Supplied[1].City ~= first, "not next to a planned water park")
  -- A city that plans one already: nothing is supplied.
  request = Request({ Districts = { "DISTRICT_CAMPUS", ENT }, Wonders = { "BUILDING_COLOSSEUM" } })
  T.eq(#SDP_Multi.Solve(request).Supplied, 0, "planned already: nothing supplied")
end)

test("a wonder counts only its own city's district (issue 45)", function()
  -- The capital's campus at (7,5), two plots from site A at (9,6).
  local function Library(existing)
    local w = NewWorld()
    w:Own(7, 5, 0, w:City(1))
    w:AddDistrict(1, "DISTRICT_CAMPUS", 7, 5, true)
    local result = SDP_Multi.Solve(Request({
      Districts = { "DISTRICT_THEATER" }, Wonders = { "BUILDING_GREAT_LIBRARY" }, Existing = existing,
    }))
    T.ok(result.Ok, tostring(result.Error))
    T.ok(not result.Stats.Mismatch, "incremental and full evaluation agree")
    for _, p in ipairs(result.Plan) do
      if p.Type == "BUILDING_GREAT_LIBRARY" then return p, result end
    end
    return nil, result
  end
  local library = Library(nil)
  T.ok(library ~= nil, "with the capital planning: placed")
  T.eq(Map.GetPlotDistance(library.X, library.Y, 7, 5), 1, "next to the campus")
  T.ok(Map.GetPlotDistance(library.X, library.Y, 4, 5) <= 3, "where the capital can build it")
  -- Only the sites planning: the capital's campus does not count, so a site
  -- gets a campus of its own for the library (issue 66).
  local alone, result = Library({ [1] = false, [2] = false })
  T.eq(result.Supplied[1] and result.Supplied[1].Type, "DISTRICT_CAMPUS", "a campus supplied")
  local campus = nil
  for _, p in ipairs(result.Plan) do
    if p.Type == "DISTRICT_CAMPUS" then campus = p end
  end
  T.ok(alone ~= nil and campus ~= nil, "the library and the supplied campus placed")
  T.eq(campus.City:sub(1, 1), "S", "in a site")
  T.eq(Map.GetPlotDistance(alone.X, alone.Y, campus.X, campus.Y), 1, "next to the site's own campus")
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
    World.CheckParts(T, sa, "solution " .. a)
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

-- Independent check of issue 35: every district of a city joins the city's
-- plots (a planned city: its center and first ring) through unowned plots
-- within 3 rings that no other city's district takes.
local function Joined(result)
  local cities = {}
  for _, c in ipairs(result.Cities) do cities[c.Key] = c end
  local taken = {}
  for _, p in ipairs(result.Plan) do
    if p.Kind == "DISTRICT" then taken[p.Index] = p.City end
  end
  for _, city in ipairs(result.Cities) do
    local reached, queue = {}, {}
    local function Start(plot)
      reached[plot:GetIndex()] = true
      queue[#queue + 1] = plot
    end
    local center = Map.GetPlot(city.X, city.Y)
    Start(center)
    for _, e in ipairs(SDP_City.PlotsInRange(city.X, city.Y, 3)) do
      local plot = Map.GetPlotByIndex(e.Index)
      local own = (city.Kind == "SITE" and e.Ring <= 1 and plot:GetOwner() == -1)
        or (city.Kind == "CITY" and plot:GetOwner() == 0 and Cities.GetPlotPurchaseCity(plot) ~= nil
          and Cities.GetPlotPurchaseCity(plot):GetID() == city.CityID)
      if own then Start(plot) end
    end
    local head = 1
    while head <= #queue do
      local plot = queue[head]
      head = head + 1
      for _, n in ipairs(Map.GetAdjacentPlots(plot:GetX(), plot:GetY())) do
        if n ~= nil and not reached[n:GetIndex()] and n:GetOwner() == -1
            and Map.GetPlotDistance(n:GetX(), n:GetY(), city.X, city.Y) <= 3
            and (taken[n:GetIndex()] == nil or taken[n:GetIndex()] == city.Key) then
          reached[n:GetIndex()] = true
          queue[#queue + 1] = n
        end
      end
    end
    for _, p in ipairs(result.Plan) do
      if p.City == city.Key and p.Kind == "DISTRICT" then
        T.ok(reached[p.Index], p.Type .. " of " .. tostring(city.Key) .. " at " .. p.X .. "," .. p.Y .. " is cut off")
      end
    end
  end
end

test("every city's districts stay joined to its territory (issue 35)", function()
  NewWorld()
  for _, tier in ipairs({ "FAST", "STANDARD" }) do
    local result = SDP_Multi.Solve(Request({ Tier = tier }))
    T.ok(result.Ok, tostring(result.Error))
    Joined(result)
  end
  -- Sites close together, more districts each: cities compete for the same plots.
  World.New({
    rows = MAP, rivers = { "6,4", "7,4", "7,5", "12,7", "13,7" },
    cities = { { id = 1, x = 4, y = 5, population = 6, capital = true, radius = 1 } },
    pins = { { 8, 5, "ICON_DISTRICT_CITY_CENTER", "A" }, { 7, 8, "ICON_DISTRICT_CITY_CENTER", "B" },
      { 11, 7, "ICON_DISTRICT_CITY_CENTER", "C" } },
  })
  local result = SDP_Multi.Solve({ PlayerID = 0, Tier = "FAST", Weights = ONES, Land = false,
    Districts = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER", "DISTRICT_COMMERCIAL_HUB" } })
  T.ok(result.Ok, tostring(result.Error))
  Joined(result)
end)

test("a layout whose district is walled in by other cities' districts is illegal (issue 35)", function()
  NewWorld()
  local meta = SDP_Overlay.With(0, function() return getmetatable(SDP_Multi.NewSession(Request({ Tier = "FAST" })).Search) end)
  -- A ring-3 plot of the capital and the plots around it within its rings.
  local cx, cy = 4, 5
  local target = nil
  for _, e in ipairs(SDP_City.PlotsInRange(cx, cy, 3)) do
    if e.Ring == 3 and target == nil and not Map.GetPlotByIndex(e.Index):IsWater() then target = e end
  end
  local around = {}
  for _, n in ipairs(Map.GetAdjacentPlots(target.X, target.Y)) do
    if n ~= nil and Map.GetPlotDistance(n:GetX(), n:GetY(), cx, cy) <= 3 then
      around[#around + 1] = { Index = n:GetIndex(), X = n:GetX(), Y = n:GetY() }
    end
  end
  T.ok(#around >= 2, "neighbours within the rings")
  local candidates = { { Index = target.Index, X = target.X, Y = target.Y } }
  for _, a in ipairs(around) do candidates[#candidates + 1] = a end
  table.sort(candidates, function(a, b) return a.Index < b.Index end)
  local position = {}
  for i, c in ipairs(candidates) do position[c.Index] = i end
  -- Group 1: the capital (owns ring 1, may run over unowned plots in 3 rings).
  local start, through = {}, {}
  start[Map.GetPlotIndex(cx, cy)], through[Map.GetPlotIndex(cx, cy)] = true, true
  for _, e in ipairs(SDP_City.PlotsInRange(cx, cy, 3)) do
    local plot = Map.GetPlotByIndex(e.Index)
    if plot:GetOwner() == 0 then start[e.Index], through[e.Index] = true, true
    elseif plot:GetOwner() == -1 then through[e.Index] = true end
  end
  -- Group 2: another city whose own plots lie elsewhere (an empty reach here).
  local groups, k = { 1 }, 1 + #around
  for _ = 1, #around do groups[#groups + 1] = 2 end
  local search = setmetatable({
    Candidates = candidates, N = #candidates, Groups = groups, K = k,
    ReachSpec = { [1] = { Start = start, Through = through }, [2] = { Start = {}, Through = {} } },
  }, meta)
  search:PrepareReach()
  local layout = { position[target.Index] }
  for _, a in ipairs(around) do layout[#layout + 1] = position[a.Index] end
  T.eq(search:Reachable(layout), false, "walled in")
  layout[2] = 0
  T.eq(search:Reachable(layout), true, "one gap is enough")
  for m = 2, k do layout[m] = 0 end
  T.eq(search:Reachable(layout), true, "nobody in the way")
  -- The other group's districts do not need a path of their own here.
  layout[1] = 0
  for m = 2, k do layout[m] = position[around[m - 1].Index] end
  T.eq(search:Reachable(layout), true, "a group without reach plots is not checked")
end)

include("cmp_oracle")

test("oracle with a wonder: the optimum equals brute force (issue 48)", function()
  NewWorld()
  -- One city, as the single-city tab plans districts with wonders.
  local result = SDP_Multi.Solve(Request({ Districts = { "DISTRICT_CAMPUS", "DISTRICT_THEATER" },
    Wonders = { "BUILDING_GREAT_LIBRARY" }, Only = { [1] = true } }))
  T.ok(result.Ok, tostring(result.Error))
  local search = result.Session.Search
  local kinds = {}
  for m = 1, search.K do kinds[search.Kinds[m]] = (kinds[search.Kinds[m]] or 0) + 1 end
  T.eq(kinds.WONDER, 1, "a wonder slot")
  -- No incumbent: the bound alone must lead to the optimum.
  local o = SDP_Overlay.With(0, CmpOracle.Run, search, nil, {})
  local brute, count = SDP_Overlay.With(0, CmpOracle.BruteForce, search, 1e6, {})
  T.ok(count ~= nil and count > 100, "layouts tried: " .. tostring(count))
  T.ok(o.Proven, "proven")
  T.eq(o.Violations, 0, "no layout above its bound")
  T.near(o.Value, brute, 1e-9, "optimum vs brute force")
  T.ok(o.Value >= result.Adjacency - 1e-9, "not below the tier's plan")
  -- The library stands next to the campus in the optimum.
  local at = {}
  for m = 1, search.K do at[search.Types[m]] = search.Candidates[o.Layout[m]] end
  local lib, campus = at.BUILDING_GREAT_LIBRARY, at.DISTRICT_CAMPUS
  T.eq(Map.GetPlotDistance(lib.X, lib.Y, campus.X, campus.Y), 1, "great library next to the campus")
end)

-- Issue 162: with the swap switch on, a plot another city owns and a plot
-- of the planned city's own worth the same: the plan takes the own one. The
-- swapped plot (3,1) has the smallest plot index (the plain tie rule's pick).
-- Off, the plans are as before (no swapped plot is a candidate).
test("several cities: a tie between a swapped plot and the city's own takes no swap (issue 162)", function()
  local w = World.New({ rows = {
    "~~~~~~~~~~~~",
    "~~~.~~~~~~~~",
    "~~..........",
    "~...........",
    "~...........",
    "~~~~~~~~~~~~",
  }, cities = { { id = 1, x = 3, y = 2, population = 7, capital = true, radius = 1 },
    { id = 2, x = 9, y = 3, population = 4, radius = 1 } } })
  w:Own(3, 1, 0, w:City(2))
  local swapIndex = Map.GetPlotIndex(3, 1)
  local function Solve(swap)
    return SDP_Multi.Solve(Request({ Plans = { C1 = { "DISTRICT_CAMPUS" }, C2 = {} }, Only = { [1] = true, [2] = true }, Land = false,
      Swap = swap }))
  end
  local on = Solve(true)
  T.ok(on.Ok, tostring(on.Error))
  T.ok(not on.Stats.Mismatch, "board and full evaluation agree")
  local campus = nil
  for _, p in ipairs(on.Plan) do
    if p.Type == "DISTRICT_CAMPUS" then campus = p end
  end
  T.ok(campus ~= nil, "a campus")
  T.ok(campus.Index ~= swapIndex, "not on the swapped plot")
  T.eq(campus.Swap, nil, "no swap")
  local off = Solve(false)
  T.eq(on.Gain, off.Gain, "the same value as without swaps")
  -- The swapped plot is worth as much: it is the plain tie rule's pick
  -- among the city's candidates.
  local heat = SDP_Solver.Heat({ PlayerID = 0, CityID = 1, District = "DISTRICT_CAMPUS", Weights = ONES, Swap = true })
  T.eq(heat[1].Index, swapIndex, "best first, ties by plot: the swapped plot first")
  T.eq(heat[1].Gain, on.Gain, "a tie")
end)

-- Issue 162 (Codex review of PR 164): untangling can raise a later layout
-- above the first. The search is made to miss the best plan: its best has
-- no swap and is worth 2, and a lower start (1) takes the swapped plot
-- (3,1); untangling that one moves its campus to (2,3), next to the holy
-- site, worth 3. The plan shown first must be that one.
test("several cities: a layout that untangles to a higher value comes first (issue 162)", function()
  local w = World.New({ rows = {
    "~~~~~~~~~~~~",
    "~~~.M~~~~~~~",
    "~~..........",
    "~...........",
    "~..M........",
    "~~~~~~~~~~~~",
  }, cities = { { id = 1, x = 3, y = 2, population = 7, capital = true, radius = 1 },
    { id = 2, x = 9, y = 3, population = 4, radius = 1 } } })
  w:Own(3, 1, 0, w:City(2))
  local swapIndex = Map.GetPlotIndex(3, 1)
  local request = Request({ Plans = { C1 = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE" }, C2 = {} }, Only = { [1] = true, [2] = true },
    Land = false, Swap = true })
  local result, missed, start = SDP_Overlay.With(0, function()
    local session = SDP_Multi.NewSession(request)
    session:Run()
    local search = session.Search
    local function Layout(spots)
      local layout = {}
      for m = 1, search.K do
        local x, y = spots[search.Types[m]][1], spots[search.Types[m]][2]
        for i, c in ipairs(search.Candidates) do
          if c.X == x and c.Y == y then layout[m] = i end
        end
      end
      return layout
    end
    local best = Layout({ DISTRICT_CAMPUS = { 2, 4 }, DISTRICT_HOLY_SITE = { 5, 2 } })
    local alt = Layout({ DISTRICT_CAMPUS = { 3, 1 }, DISTRICT_HOLY_SITE = { 2, 2 } })
    local bestGain, bestLegal = search:Evaluate(best)
    local altGain, altLegal = search:Evaluate(alt)
    T.ok(bestLegal and altLegal, "both layouts are legal")
    search.BestLayout, search.BestGain, search.BestPlaced = best, bestGain, 2
    session.Starts = { { Layout = alt, Gain = altGain } }
    return session:Result(), bestGain, altGain
  end)
  T.eq(missed, 2, "the missed search's best")
  T.eq(start, 1, "the start, before untangling")
  T.ok(result.Ok, tostring(result.Error))
  T.ok(not result.Stats.Mismatch, "board and full evaluation agree")
  T.eq(result.Gain, 3, "the untangled start's value")
  for n, solution in ipairs(result.Solutions) do
    T.ok(solution.Gain <= result.Gain, "solution " .. n .. " is not better than the first")
  end
  for _, p in ipairs(result.Plan) do
    T.ok(p.Index ~= swapIndex, p.Type .. " not on the swapped plot")
    T.eq(p.Swap, nil, p.Type .. ": no swap")
  end
end)

-- Issue 189: the plans are shown in the order Pick returns them. Untangling
-- (issue 162) can raise a later layout above an earlier one other than the
-- first; and a pool given without swaps may come unsorted (the single-city
-- tab adds the alternatives after the solved combinations). The plans taken
-- are the same as before (the best first, then the pool's order), ranked:
-- more placed, then the higher value, then fewer swaps, then the pool's
-- order. Search:Pick on stand-ins for the search's own steps.
test("plans: the plans taken are ranked after untangling (issue 189)", function()
  NewWorld()
  local result = SDP_Multi.Solve(Request({ Districts = { "DISTRICT_CAMPUS" }, Only = { [1] = true } }))
  T.ok(result.Ok, tostring(result.Error))
  local Pick = getmetatable(result.Session.Search).Pick
  local raised = { ["1,2,5"] = 4.5 }
  local stub = {
    Swapped = function() return false end,
    Untangle = function(_, layout, gain) return layout, raised[table.concat(layout, ",")] or gain end,
    SwapCount = function() return 0 end,
    IsDistinct = function() return true end,
  }
  local function Order(kept)
    local list = {}
    for _, e in ipairs(kept) do list[#list + 1] = e.Name end
    return table.concat(list, " ")
  end
  local function Pool()
    return {
      { Name = "A", Layout = { 1, 2, 3 }, Gain = 5 },
      { Name = "B", Layout = { 1, 2, 4 }, Gain = 4 },
      { Name = "C", Layout = { 1, 2, 5 }, Gain = 3 },
      { Name = "D", Layout = { 1, 2, 0 }, Gain = 10 },
      { Name = "E", Layout = { 1, 2, 6 }, Gain = 4 },
    }
  end
  T.eq(Order(Pick(stub, Pool(), 5)), "A C B E D", "untangled: C rises above B; ties by pool order; fewer placed last")
  T.eq(Order(Pick(stub, Pool(), 2)), "A B", "the same two plans as before: the best, then the pool's order")
  stub.Swapped = nil
  local unsorted = { { Name = "B", Layout = { 1, 2, 4 }, Gain = 4 }, { Name = "A", Layout = { 1, 2, 3 }, Gain = 5 } }
  T.eq(Order(Pick(stub, unsorted, 3)), "A B", "without swaps: ranked too")
end)
