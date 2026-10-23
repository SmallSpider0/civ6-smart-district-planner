-- @state SDP_Panel
-- @timeout 900
-- @setup GameCore_Tuner tests/fixtures/unlock_all_cities.lua
-- Engine audit (issue 42, docs/multicity-design.md section 25): on every
-- city of the local player, for every district the player can plan, the
-- plots the engine lets the city build it on (CityManager.GetOperationTargets,
-- what the placement lens shows) against SDP's candidates + DMT's CanPlace,
-- on the plots the city owns within 3 rings. probe_engine.lua does this for
-- the capital of a new game; this runs on a late save with many cities,
-- after the fixture gave the player every technology and civic, every city
-- its 3 rings and population 25. Then the wonders that need an adjacent
-- district: does the engine accept a district of another city of ours?
-- Not a regular test (no test_ prefix); the fixture changes the game for
-- good, so load a save or new game you will throw away:
--   python3 -I tools/run_tests.py tests/bench/audit_engine.lua
-- Prints one line "SDP_AUDIT <json>" per test with the tallies.
local test, T = ...

local pid = Game.GetLocalPlayer()
local WEIGHTS = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }

local function Json(v)
  local t = type(v)
  if t == "number" then return string.format("%.10g", v) end
  if t == "string" then return (string.format("%q", v):gsub("\\\n", "\\n")) end
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

local function Targets(city, param, hash)
  local params = {}
  params[param] = hash
  local ok, results = pcall(CityManager.GetOperationTargets, city, CityOperationTypes.BUILD, params)
  local set, n = {}, 0
  local plots = ok and type(results) == "table" and results[CityOperationResults.PLOTS] or nil
  for _, id in ipairs(plots or {}) do
    set[id] = true
    n = n + 1
  end
  return set, n
end

local function Describe(plot)
  local parts = { GameInfo.Terrains[plot:GetTerrainType()].TerrainType }
  if plot:GetFeatureType() ~= -1 then parts[#parts + 1] = GameInfo.Features[plot:GetFeatureType()].FeatureType end
  if plot:GetResourceType() ~= -1 then parts[#parts + 1] = GameInfo.Resources[plot:GetResourceType()].ResourceType end
  if plot:GetImprovementType() ~= -1 then parts[#parts + 1] = GameInfo.Improvements[plot:GetImprovementType()].ImprovementType end
  if plot:GetDistrictType() ~= -1 then parts[#parts + 1] = GameInfo.Districts[plot:GetDistrictType()].DistrictType end
  if plot:GetWonderType() ~= -1 then parts[#parts + 1] = GameInfo.Buildings[plot:GetWonderType()].BuildingType end
  if plot:IsRiver() then parts[#parts + 1] = "river" end
  if plot:IsLake() then parts[#parts + 1] = "lake" end
  return table.concat(parts, " ")
end

-- The plots a city owns within 3 rings, without the center.
local function Owned(city)
  local owned = {}
  for _, p in ipairs(SDP_City.PlotsInRange(city:GetX(), city:GetY(), 3)) do
    local plot = Map.GetPlotByIndex(p.Index)
    local owner = plot:GetOwner() == pid and Cities.GetPlotPurchaseCity(plot) or nil
    if owner ~= nil and owner:GetID() == city:GetID() and not plot:IsCity() then owned[#owned + 1] = p end
  end
  return owned
end

local function OwnCities()
  local list = {}
  for _, city in Players[pid]:GetCities():Members() do list[#list + 1] = city end
  table.sort(list, function(a, b) return a:GetID() < b:GetID() end)
  return list
end

local cfg = PlayerConfigurations[pid]
local HEAD = { civ = cfg:GetCivilizationTypeName(), leader = cfg:GetLeaderTypeName(),
  ruleset = GameConfiguration.GetValue("RULESET"), turn = Game.GetCurrentGameTurn() }

test("engine placement targets vs SDP candidates and DMT on every city", function()
  local cities = OwnCities()
  T.ok(#cities > 0, "no cities")
  local perDistrict, diffs, shown = {}, {}, 0
  local total = { cities = #cities, plots = 0, pairs = 0, agree = 0, sdpOnly = 0, engineOnly = 0, vetoed = 0, sdpWrong = 0,
    noTargets = 0, built = 0 }
  for _, city in ipairs(cities) do
    local scan = SDP_City.Scan(pid, city:GetID())
    local candidate, built = {}, {}
    for _, c in ipairs(scan.Candidates) do candidate[c.Index] = true end
    for _, b in ipairs(scan.Built or {}) do built[b.Type] = true end
    local owned = Owned(city)
    total.plots = total.plots + #owned
    SDP_Overlay.ResetEngine()
    for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do
      local tally = perDistrict[d.Type]
      if tally == nil then
        tally = { pairs = 0, agree = 0, sdpOnly = 0, engineOnly = 0, noTargets = 0, built = 0, reasons = {} }
        perDistrict[d.Type] = tally
      end
      if built[d.Type] then
        tally.built, total.built = tally.built + 1, total.built + 1
      else
        local targets, n = Targets(city, CityOperationTypes.PARAM_DISTRICT_TYPE, GameInfo.Districts[d.Type].Hash)
        if n == 0 then
          tally.noTargets, total.noTargets = tally.noTargets + 1, total.noTargets + 1
        else
          for _, p in ipairs(owned) do
            local plot = Map.GetPlotByIndex(p.Index)
            local item = SDP_Overlay.With(pid, SDP_Overlay.Evaluate, { SDP_Overlay.Subject(d.Type, p.X, p.Y) }, {}, WEIGHTS).Placements[1]
            local dmt = item.CanPlace == true or item.EngineRefused == true
            if item.EngineRefused then total.vetoed = total.vetoed + 1 end
            if candidate[p.Index] == true and item.CanPlace == true and targets[p.Index] ~= true then
              total.sdpWrong = total.sdpWrong + 1
            end
            local sdp = candidate[p.Index] == true and dmt
            local engine = targets[p.Index] == true
            tally.pairs, total.pairs = tally.pairs + 1, total.pairs + 1
            if sdp == engine then
              tally.agree, total.agree = tally.agree + 1, total.agree + 1
            else
              local who = sdp and "sdpOnly" or "engineOnly"
              tally[who], total[who] = tally[who] + 1, total[who] + 1
              local reason = sdp and ("engine refuses: " .. Describe(plot))
                or ("SDP refuses: " .. tostring(scan.Excluded[p.Index] or (item.CanPlace and "?" or item.Reason)) .. " (" .. Describe(plot) .. ")")
              tally.reasons[reason] = (tally.reasons[reason] or 0) + 1
              diffs[#diffs + 1] = { d = d.Type, city = city:GetID(), x = p.X, y = p.Y, who = who, why = reason }
              if shown < 60 then
                shown = shown + 1
                print(string.format("%s %s at %d,%d (city %d): %s", who, d.Type, p.X, p.Y, city:GetID(), reason))
              end
            end
          end
        end
      end
    end
  end
  for dt, tally in pairs(perDistrict) do
    local reasons = {}
    for r, n in pairs(tally.reasons) do reasons[#reasons + 1] = { r, n } end
    table.sort(reasons, function(a, b) return a[2] > b[2] or (a[2] == b[2] and a[1] < b[1]) end)
    tally.reasons = reasons
    print(string.format("%-32s pairs %4d agree %4d SDP-only %3d engine-only %3d (no targets in %d cities, built in %d)",
      dt, tally.pairs, tally.agree, tally.sdpOnly, tally.engineOnly, tally.noTargets, tally.built))
  end
  print(string.format("%d cities, %d owned plots, %d district x plot: agree %d, SDP-only %d, engine-only %d; SDP's engine check refused %d, SDP allows what the engine refuses %d",
    total.cities, total.plots, total.pairs, total.agree, total.sdpOnly, total.engineOnly, total.vetoed, total.sdpWrong))
  print("SDP_AUDIT " .. Json({ head = HEAD, test = "districts", total = total, districts = perDistrict, diffs = diffs }))
  T.eq(total.sdpWrong, 0, "SDP allows plots the engine refuses")
end)

-- Wonders that need an adjacent district (Buildings.AdjacentDistrict): the
-- plots the engine offers a city, split by whether the required district
-- next to the plot belongs to this city or to another city of ours.
test("wonders needing an adjacent district: whose district counts", function()
  local cities = OwnCities()
  local mine = {}
  for _, city in ipairs(cities) do mine[city:GetID()] = true end
  local function Base(dt)
    local row = GameInfo.DistrictReplaces[dt]
    return row and row.ReplacesDistrictType or dt
  end
  local wonders, out = {}, {}
  for b in GameInfo.Buildings() do
    if b.IsWonder and b.AdjacentDistrict ~= nil then wonders[#wonders + 1] = b end
  end
  table.sort(wonders, function(a, b) return a.BuildingType < b.BuildingType end)
  for _, b in ipairs(wonders) do
    local row = { wonder = b.BuildingType, district = b.AdjacentDistrict, citiesWithTargets = 0,
      sameCityAllowed = 0, sameCityRefused = 0, otherCityAllowed = 0, otherCityRefused = 0, dmtOtherCityAllowed = 0 }
    for _, city in ipairs(cities) do
      local targets, n = Targets(city, CityOperationTypes.PARAM_BUILDING_TYPE, b.Hash)
      if n > 0 then
        row.citiesWithTargets = row.citiesWithTargets + 1
        for _, p in ipairs(Owned(city)) do
          local plot = Map.GetPlotByIndex(p.Index)
          -- The required district next to this plot: this city's, or another city of ours.
          local same, other = false, false
          for direction = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
            local n2 = Map.GetAdjacentPlot(p.X, p.Y, direction)
            if n2 ~= nil and n2:GetDistrictType() ~= -1
                and Base(GameInfo.Districts[n2:GetDistrictType()].DistrictType) == b.AdjacentDistrict then
              local owner = n2:GetOwner() == pid and Cities.GetPlotPurchaseCity(n2) or nil
              if owner ~= nil and owner:GetID() == city:GetID() then same = true
              elseif owner ~= nil and mine[owner:GetID()] then other = true end
            end
          end
          if same or other then
            local allowed = targets[p.Index] == true
            if same then
              if allowed then row.sameCityAllowed = row.sameCityAllowed + 1 else row.sameCityRefused = row.sameCityRefused + 1 end
            else
              if allowed then row.otherCityAllowed = row.otherCityAllowed + 1 else row.otherCityRefused = row.otherCityRefused + 1 end
              local item = SDP_Overlay.With(pid, SDP_Overlay.Evaluate,
                { { Key = b.BuildingType, Type = "WONDER", X = p.X, Y = p.Y } }, {}, WEIGHTS).Placements[1]
              if item.CanPlace == true then row.dmtOtherCityAllowed = row.dmtOtherCityAllowed + 1 end
              if not allowed and item.CanPlace == true then
                print(string.format("%s at %d,%d (city %d): only another city's %s next to it; engine refuses, DMT allows (%s)",
                  b.BuildingType, p.X, p.Y, city:GetID(), b.AdjacentDistrict, Describe(plot)))
              end
            end
          end
        end
      end
    end
    out[#out + 1] = row
    if row.citiesWithTargets > 0 then
      print(string.format("%-28s needs %-26s cities %d: same city %d/%d allowed, other city %d/%d allowed (DMT allows %d)",
        b.BuildingType, b.AdjacentDistrict, row.citiesWithTargets, row.sameCityAllowed, row.sameCityAllowed + row.sameCityRefused,
        row.otherCityAllowed, row.otherCityAllowed + row.otherCityRefused, row.dmtOtherCityAllowed))
    end
  end
  print("SDP_AUDIT " .. Json({ head = HEAD, test = "wonders", wonders = out }))
  T.ok(#wonders > 0, "no wonders with an adjacent district requirement in this ruleset")
end)
