-- Steps of tools/stress.py, the in-game stress test on complex late-game
-- saves (run in the SDP_Panel state, not by run_tests.py). Loading this file
-- defines SDP_Stress; the driver then calls one step per Tuner request and
-- times it. Every step prints one line "SDP_STRESS {json}".
-- Steps undo every pin they place (they count their own batches).
SDP_Stress = {}
local S = SDP_Stress
local pid = Game.GetLocalPlayer()
local ONES = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }
S.Batches = 0

-- JSON for numbers, strings, booleans, arrays and string-keyed objects.
local function Json(v)
  local t = type(v)
  if t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    return string.format("%.10g", v)
  end
  if t == "string" then
    -- %q leaves tabs and other control characters raw (stack traces have tabs).
    local q = string.format("%q", v):gsub("\\\n", "\\n")
    return (q:gsub("%c", function(c) return string.format("\\u%04x", c:byte()) end))
  end
  if t == "boolean" then return tostring(v) end
  if t == "table" then
    if #v > 0 or next(v) == nil then
      local parts = {}
      for i = 1, #v do parts[i] = Json(v[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = string.format("%q", k) .. ":" .. Json(v[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end

local function Emit(t) print("SDP_STRESS " .. Json(t)) end

-- The player's own type for a base district (nil: not available).
local function Own(base)
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do
    if SDP_Rules.BaseDistrict(d.Type) == base then return d.Type end
  end
  return nil
end

-- Specialty districts a city can still plan, without an empire limit.
local function Free(cityID)
  local scan = SDP_City.Scan(pid, cityID)
  local plannable = SDP_Rules.PlannableDistricts(pid)
  local status = SDP_City.DistrictStatus(scan, plannable)
  local list = {}
  for _, d in ipairs(plannable) do
    if d.Specialty and status[d.Type] == nil and not (d.MaxPerPlayer and d.MaxPerPlayer > 0) then list[#list + 1] = d.Type end
  end
  return list, scan
end

-- Placements the engine refuses where it answers (owned plots).
local function EngineBad(plan)
  local bad = 0
  for _, p in ipairs(plan or {}) do
    if (p.Kind == nil or p.Kind == "DISTRICT")
        and SDP_Overlay.EngineRefuses(pid, { Type = "DISTRICT", Key = p.Type, X = p.X, Y = p.Y }) then
      bad = bad + 1
    end
  end
  return bad
end

local function Summary(r)
  local out = { Ok = r.Ok == true, Error = r.Error and tostring(r.Error) or nil }
  if not r.Ok then return out end
  out.Gain, out.Adjacency, out.Land, out.Appeal = r.Gain, r.Adjacency, r.LandDelta, r.AppealDelta
  out.Placed, out.Unplaced = #(r.Plan or {}), #(r.Unplaced or {})
  out.Mismatch = r.Stats.Mismatch == true
  out.EngineBad = EngineBad(r.Plan)
  out.Calls, out.Tries, out.Method = r.Stats.Calls, r.Stats.Tries, r.Stats.Method
  out.Exhaustive = r.Quality and r.Quality.Exhaustive or false
  out.Gap = r.Quality and r.Quality.Gap or nil
  out.Picked = r.Picked
  local together = r.Together and #r.Together or 0
  for _, c in ipairs(r.Cities or {}) do together = together + #(c.Together or {}) end
  out.Together = together
  return out
end

-- The player's cities, most populous first (ties by ID), at most `cap`.
local function Cities(cap)
  local list = {}
  for _, city in Players[pid]:GetCities():Members() do list[#list + 1] = city end
  table.sort(list, function(a, b)
    if a:GetPopulation() ~= b:GetPopulation() then return a:GetPopulation() > b:GetPopulation() end
    return a:GetID() < b:GetID()
  end)
  local out = {}
  for i = 1, math.min(cap or #list, #list) do out[i] = list[i] end
  return out
end

function S.Census()
  local player = Players[pid]
  local districts, wonders = 0, 0
  for _, d in player:GetDistricts():Members() do
    if GameInfo.Districts[d:GetType()].DistrictType ~= "DISTRICT_WONDER" then districts = districts + 1 end
  end
  local pins = 0
  for _ in pairs(PlayerConfigurations[pid]:GetMapPins()) do pins = pins + 1 end
  local w, h = Map.GetGridSize()
  for i = 0, w * h - 1 do
    local plot = Map.GetPlotByIndex(i)
    if plot:GetOwner() == pid and plot:GetWonderType() ~= -1 then wonders = wonders + 1 end
  end
  local others, majors = 0, 0
  for _, id in ipairs(PlayerManager.GetAliveIDs()) do
    if id ~= pid then
      for _ in Players[id]:GetCities():Members() do others = others + 1 end
      if Players[id]:IsMajor() then majors = majors + 1 end
    end
  end
  local cities = {}
  for _, city in ipairs(Cities()) do
    local free, scan = Free(city:GetID())
    cities[#cities + 1] = { ID = city:GetID(), Name = Locale.Lookup(city:GetName()), Population = city:GetPopulation(),
      Built = #scan.Built, SpecialtyBuilt = scan.SpecialtyBuilt, Capacity = scan.SpecialtyCapacity, Free = #free,
      Candidates = #scan.Candidates, Pins = #scan.Pins, Coastal = Map.GetPlot(city:GetX(), city:GetY()):IsCoastalLand() }
  end
  Emit({ Step = "Census", Turn = Game.GetCurrentGameTurn(), Era = Game.GetEras():GetCurrentEra(),
    Ruleset = SDP_Rules.Ruleset(), Leader = PlayerConfigurations[pid]:GetLeaderTypeName(), Map = { w, h },
    Cities = cities, Districts = districts, Wonders = wonders, Pins = pins, OtherCities = others, Majors = majors - 0 })
end

-- One city: "POOL" every free specialty district a candidate, as many
-- picked as the city has free slots (2 to 5); "MUST" up to six of them
-- required; "APPEAL" a neighborhood, a preserve and an industrial zone;
-- "HARBOR" the commercial hub and the harbor among the candidates.
function S.Single(cityID, mode, tier, twice)
  local free, scan = Free(cityID)
  local request = { PlayerID = pid, CityID = cityID, Districts = {}, Weights = ONES, Tier = tier, Land = true, Remind = true }
  if mode == "POOL" then
    request.Pool = free
    request.Count = math.max(2, math.min(5, scan.SpecialtyCapacity - scan.SpecialtyBuilt))
  elseif mode == "MUST" then
    for i = 1, math.min(6, #free) do request.Districts[i] = free[i] end
  elseif mode == "APPEAL" then
    for _, base in ipairs({ "DISTRICT_NEIGHBORHOOD", "DISTRICT_PRESERVE", "DISTRICT_INDUSTRIAL_ZONE" }) do
      local t = Own(base)
      if t ~= nil then request.Districts[#request.Districts + 1] = t end
    end
  elseif mode == "HARBOR" then
    request.Pool = {}
    for _, base in ipairs({ "DISTRICT_CAMPUS", "DISTRICT_COMMERCIAL_HUB", "DISTRICT_HARBOR", "DISTRICT_HOLY_SITE" }) do
      local t = Own(base)
      if t ~= nil then request.Pool[#request.Pool + 1] = t end
    end
    request.Count = 2
  end
  local r = SDP_Solver.Solve(request)
  local out = Summary(r)
  out.Step, out.City, out.Mode, out.Tier, out.Asked = "Single", cityID, mode, tier, #request.Districts + (request.Count or 0)
  out.Pool = request.Pool and #request.Pool or 0
  if twice and r.Ok then
    local again = SDP_Solver.Solve(request)
    local same = again.Ok and again.Gain == r.Gain and #again.Plan == #r.Plan
    for i, p in ipairs(again.Plan or {}) do
      if r.Plan[i] == nil or p.Index ~= r.Plan[i].Index or p.Type ~= r.Plan[i].Type then same = false end
    end
    out.Deterministic = same
  end
  if mode == "APPEAL" then
    -- The plan and what it predicts, for tools/stress.py check (the game
    -- builds it and its own appeal and housing are read back).
    out.Housing, out.Plan = {}, {}
    out.ImprovementHousing = r.ImprovementHousing or 0
    for _, p in ipairs(r.Plan or {}) do
      out.Plan[#out.Plan + 1] = { Type = p.Type, X = p.X, Y = p.Y, Index = Map.GetPlotIndex(p.X, p.Y) }
      if p.Housing ~= nil then
        out.Housing[#out.Housing + 1] = { Type = p.Type, X = p.X, Y = p.Y, Housing = p.Housing, Appeal = p.Appeal,
          Now = Map.GetPlot(p.X, p.Y):GetAppeal() }
      end
    end
  end
  Emit(out)
end

-- City sites: K sites within D of the empire, scored with five districts.
function S.Sites(k, d, tier)
  local districts = {}
  for _, base in ipairs({ "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_COMMERCIAL_HUB", "DISTRICT_THEATER",
    "DISTRICT_INDUSTRIAL_ZONE" }) do
    local t = Own(base)
    if t ~= nil then districts[#districts + 1] = t end
  end
  local r = SDP_SiteSolver.Solve({ PlayerID = pid, Tier = tier, K = k, D = d, Districts = districts, PlanCount = 3 })
  local sites = (r.Ok and r.Solutions[1] and r.Solutions[1].Sites) or {}
  S.LastSites = sites
  Emit({ Step = "Sites", Ok = r.Ok == true, Error = r.Error and tostring(r.Error) or nil, Tier = tier, K = k, D = d,
    Found = #sites, Solutions = r.Ok and #r.Solutions or 0, Calls = r.Stats and r.Stats.Calls or nil })
end

function S.PlaceSites()
  local entries, _, count = {}, nil, nil
  _, count = SDP_City.CityNumbers(pid)
  for n, site in ipairs(S.LastSites or {}) do
    entries[n] = { Type = "DISTRICT_CITY_CENTER", X = site.X, Y = site.Y, Name = tostring(count + n) }
  end
  local placed = SDP_Pins.Place(pid, entries)
  if placed > 0 then S.Batches = S.Batches + 1 end
  Emit({ Step = "PlaceSites", Placed = placed })
end

-- Several cities: the new sites plus the `cities` most populous cities, a
-- campus each and `count` districts per city picked from a common pool.
function S.Multi(cities, count, tier)
  local existing = {}
  for _, city in ipairs(Cities(cities)) do existing[city:GetID()] = true end
  local pool = {}
  for _, base in ipairs({ "DISTRICT_HOLY_SITE", "DISTRICT_COMMERCIAL_HUB", "DISTRICT_THEATER", "DISTRICT_INDUSTRIAL_ZONE",
    "DISTRICT_HARBOR", "DISTRICT_ENTERTAINMENT_COMPLEX" }) do
    local t = Own(base)
    if t ~= nil then pool[#pool + 1] = t end
  end
  local request = { PlayerID = pid, Tier = tier, Districts = { Own("DISTRICT_CAMPUS") }, Pool = pool, Count = count,
    Weights = ONES, Land = true, Remind = true, Existing = existing }
  -- Every listed city takes part, not only those near a new site.
  for _, city in Players[pid]:GetCities():Members() do
    if not existing[city:GetID()] then existing[city:GetID()] = false end
  end
  local r = SDP_Multi.Solve(request)
  S.LastMulti = r
  local out = Summary(r)
  out.Step, out.Tier, out.Count, out.Cities = "Multi", tier, count, r.Ok and #r.Cities or 0
  Emit(out)
end

function S.PlaceMulti()
  local r = S.LastMulti
  local entries = {}
  if r ~= nil and r.Ok then
    local number = {}
    for _, c in ipairs(r.Cities) do number[c.Key] = tostring(c.Number or "") end
    for _, p in ipairs(r.Plan) do entries[#entries + 1] = { Type = p.Type, X = p.X, Y = p.Y, Name = number[p.City] or "" } end
  end
  local placed = SDP_Pins.Place(pid, entries)
  if placed > 0 then S.Batches = S.Batches + 1 end
  Emit({ Step = "PlaceMulti", Placed = placed })
end

-- Many pins: n district pins on the player's free plots (deterministic
-- choice), so scans and DMT see a crowded map.
function S.HeavyPins(n)
  local plannable = SDP_Rules.PlannableDistricts(pid)
  local w, h = Map.GetGridSize()
  local entries = {}
  local taken = {}
  for _, pin in pairs(PlayerConfigurations[pid]:GetMapPins()) do taken[Map.GetPlotIndex(pin:GetHexX(), pin:GetHexY())] = true end
  -- Every third free plot first (spread out), then the rest.
  for pass = 1, 2 do
    for i = 0, w * h - 1 do
      if #entries >= n then break end
      local plot = Map.GetPlotByIndex(i)
      if ((i % 3 == 0) == (pass == 1)) and plot:GetOwner() == pid and not plot:IsWater() and not plot:IsMountain()
          and not plot:IsCity() and plot:GetDistrictType() == -1 and plot:GetWonderType() == -1 and not taken[i] then
        local d = plannable[(#entries % #plannable) + 1]
        entries[#entries + 1] = { Type = d.Type, X = plot:GetX(), Y = plot:GetY(), Name = "stress" }
      end
    end
  end
  local placed = SDP_Pins.Place(pid, entries)
  if placed > 0 then S.Batches = S.Batches + 1 end
  Emit({ Step = "HeavyPins", Placed = placed })
end

-- Preserves the players built themselves (every major civilization): the
-- yields the game gives the plots around them, against what the rules
-- (Adjacent_AppealYieldChanges, rows of the buildings the city has) give a
-- plot of that appeal. Yields from other sources add on top, so a plot is
-- "as expected" when it has at least the expected amount of every yield the
-- rows give, and "missing" when it has less.
local TILE_YIELDS = { "YIELD_FOOD", "YIELD_PRODUCTION", "YIELD_GOLD", "YIELD_SCIENCE", "YIELD_CULTURE", "YIELD_FAITH" }
function S.Preserves()
  local rules = SDP_Appeal.Rules()
  local list, expected, seen, missing = {}, 0, 0, 0
  for _, id in ipairs(PlayerManager.GetAliveMajorIDs()) do
    for _, d in Players[id]:GetDistricts():Members() do
      local row = GameInfo.Districts[d:GetType()]
      local rows = row and rules.Tiles[row.DistrictType]
      if rows ~= nil and d:IsComplete() then
        local city = d:GetCity()
        local has = {}
        for _, b in ipairs({ "BUILDING_GROVE", "BUILDING_SANCTUARY" }) do
          local info = GameInfo.Buildings[b]
          has[b] = info ~= nil and city ~= nil and city:GetBuildings():HasBuilding(info.Index) or false
        end
        local own = {}
        for r in GameInfo.Adjacent_AppealYieldChanges() do
          if r.DistrictType == row.DistrictType and has[r.BuildingType] then
            own[#own + 1] = { Min = r.MinimumValue, Max = r.MaximumValue, Yield = r.YieldType, Change = r.YieldChange,
              Unimproved = r.Unimproved == true }
          end
        end
        local entry = { Owner = id, X = d:GetX(), Y = d:GetY(), Grove = has.BUILDING_GROVE, Sanctuary = has.BUILDING_SANCTUARY,
          Tiles = {} }
        for dir = 0, 5 do
          local n = Map.GetAdjacentPlot(d:GetX(), d:GetY(), dir)
          if n ~= nil and not n:IsWater() and n:GetDistrictType() == -1 and n:GetWonderType() == -1 and not n:IsCity() then
            local improved = n:GetImprovementType() ~= -1
            local expect, got = {}, {}
            for _, r in ipairs(own) do
              if n:GetAppeal() >= r.Min and n:GetAppeal() <= r.Max and not (r.Unimproved and improved) then
                expect[r.Yield] = (expect[r.Yield] or 0) + r.Change
              end
            end
            local any, ok = false, true
            for _, y in ipairs(TILE_YIELDS) do
              got[y] = n:GetYield(GameInfo.Yields[y].Index)
              if expect[y] ~= nil then
                any = true
                if got[y] < expect[y] then ok = false end
              end
            end
            if any then
              expected = expected + 1
              if ok then seen = seen + 1 else missing = missing + 1 end
            end
            entry.Tiles[#entry.Tiles + 1] = { X = n:GetX(), Y = n:GetY(), Appeal = n:GetAppeal(), Improved = improved,
              Expect = expect, Got = got, Ok = (not any) or ok }
          end
        end
        list[#list + 1] = entry
      end
    end
  end
  Emit({ Step = "Preserves", Preserves = #list, WithBuildings = (function()
    local c = 0
    for _, e in ipairs(list) do if e.Grove or e.Sanctuary then c = c + 1 end end
    return c
  end)(), Expected = expected, Seen = seen, Missing = missing, List = list })
end

function S.UndoAll()
  local removed = 0
  while S.Batches > 0 and SDP_Pins.CanUndo() do
    removed = removed + SDP_Pins.UndoLast()
    S.Batches = S.Batches - 1
  end
  Emit({ Step = "UndoAll", Removed = removed })
end

-- The panel: open it on the capital, the multi-city tab, the sites tab, close.
function S.Panel()
  local ok, err = pcall(function()
    SDP_Panel.Open()
    SDP_Panel.SelectTab("SINGLE")
    local capital = Players[pid]:GetCities():GetCapitalCity()
    if capital then SDP_Panel.SelectCity(capital:GetID()) end
    SDP_Panel.SelectTab("MULTI")
    SDP_Panel.Multi.Refresh()
    SDP_Panel.SelectTab("SITES")
    SDP_Panel.SelectTab("SINGLE")
    SDP_Panel.Close()
  end)
  Emit({ Step = "Panel", Ok = ok, Error = (not ok) and tostring(err) or nil })
end

Emit({ Step = "Loaded" })
