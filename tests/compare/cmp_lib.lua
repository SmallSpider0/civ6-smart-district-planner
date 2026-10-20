-- cmp_lib.lua: scenario dispatch, planner adapters and the judge for
-- tools/compare.mjs. Each run happens in a fresh Lua state:
--   CmpRun.Plan(id, planner, variant)  builds the scenario's world, loads the
--       planner the way the game would, asks it for a plan and emits
--       "PLAN <json>": { placements = { {city, type, x, y} }, stats, notes }
--   CmpRun.Judge(id, planJson)  builds the same world with only DMT loaded
--       (as DMT's own context runs), puts the plan on the map as pins and
--       emits "SCORE <json>": the DMT gain and every rule the plan breaks.

include("cmp_game")
include("cmp_mapgen")
include("cmp_scenarios")

CmpRun = {}
CmpAdapters = CmpAdapters or {}

-- ===========================================================================
-- JSON
-- ===========================================================================
local Json = {}
CmpRun.Json = Json

local function EncodeString(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' elseif c == "\\" then return "\\\\"
    elseif c == "\n" then return "\\n" elseif c == "\t" then return "\\t"
    else return string.format("\\u%04x", c:byte()) end
  end) .. '"'
end

function Json.Encode(v)
  local t = type(v)
  if t == "nil" then return "null"
  elseif t == "boolean" then return v and "true" or "false"
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    if math.floor(v) == v and math.abs(v) < 1e15 then return string.format("%d", v) end
    return string.format("%.6g", v)
  elseif t == "string" then return EncodeString(v)
  elseif t == "table" then
    local n = #v
    local isArray = n > 0 or next(v) == nil
    if isArray then
      for k in pairs(v) do
        if type(k) ~= "number" or k < 1 or k > n or math.floor(k) ~= k then isArray = false break end
      end
    end
    local parts = {}
    if isArray then
      for i = 1, n do parts[i] = Json.Encode(v[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local value = v[k]
      if value == nil then value = v[tonumber(k)] end
      if type(value) ~= "function" and type(value) ~= "userdata" then
        parts[#parts + 1] = EncodeString(k) .. ":" .. Json.Encode(value)
      end
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end

function Json.Decode(s)
  local pos = 1
  local function Skip() pos = s:find("[^ \t\r\n]", pos) or #s + 1 end
  local Value
  local function String()
    pos = pos + 1
    local out = {}
    while true do
      local c = s:sub(pos, pos)
      if c == '"' then pos = pos + 1 break end
      if c == "\\" then
        local e = s:sub(pos + 1, pos + 1)
        if e == "u" then
          out[#out + 1] = utf8 and utf8.char(tonumber(s:sub(pos + 2, pos + 5), 16)) or "?"
          pos = pos + 6
        else
          out[#out + 1] = ({ n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" })[e] or e
          pos = pos + 2
        end
      else
        out[#out + 1] = c
        pos = pos + 1
      end
    end
    return table.concat(out)
  end
  function Value()
    Skip()
    local c = s:sub(pos, pos)
    if c == "{" then
      pos = pos + 1
      local obj = {}
      Skip()
      if s:sub(pos, pos) == "}" then pos = pos + 1 return obj end
      while true do
        Skip()
        local k = String()
        Skip()
        pos = pos + 1 -- :
        obj[k] = Value()
        Skip()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d == "}" then return obj end
      end
    elseif c == "[" then
      pos = pos + 1
      local arr = {}
      Skip()
      if s:sub(pos, pos) == "]" then pos = pos + 1 return arr end
      while true do
        arr[#arr + 1] = Value()
        Skip()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d == "]" then return arr end
      end
    elseif c == '"' then return String()
    elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4 return true
    elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5 return false
    elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4 return nil
    else
      local num = s:match("^-?[%d.eE+-]+", pos)
      pos = pos + #num
      return tonumber(num)
    end
  end
  return Value()
end

-- ===========================================================================
-- Scenario setup shared by planners and the judge
-- ===========================================================================
function CmpRun.List()
  for _, s in ipairs(CmpScenarios.List) do
    local runs = {}
    for _, r in ipairs(s.runs) do runs[#runs + 1] = { planner = r.planner, variant = r.variant } end
    cmp_emit("SCENARIO " .. Json.Encode({ id = s.id, title = s.title, kind = s.kind, runs = runs }))
  end
end

-- The world as the game would have it after loading a save: map, cities,
-- pins, and DMT's subject table for the existing pins (DMT's own context
-- keeps it in the player configuration; planners read it from there).
function CmpRun.Setup(id)
  local scn = CmpScenarios.ById[id] or error("unknown scenario " .. tostring(id))
  local spec = CmpMapgen.Generate(scn)
  local w = CmpGame.New(spec)
  include("dmt_serialize")
  local subjects = {}
  for _, pin in ipairs(PlayerConfigurations[0]:GetMapPins()) do
    local iconType = pin:GetIconName():gsub("ICON_", "")
    local subject = { Id = pin:GetID(), X = pin:GetHexX(), Y = pin:GetHexY(), Key = iconType, Type = "UNKNOWN" }
    if iconType:match("^IMPROVEMENT_") then subject.Type = "IMPROVEMENT"
    elseif iconType:match("^DISTRICT_") then subject.Type = iconType == "DISTRICT_WONDER" and "WONDER" or "DISTRICT"
    elseif iconType:match("^BUILDING_") then subject.Type = "WONDER" end
    if subject.Type ~= "UNKNOWN" then subjects[pin:GetHexX() .. "_" .. pin:GetHexY()] = subject end
  end
  PlayerConfigurations[0]:SetValue("DMT_MapPinSubjects", serialize(subjects))

  -- What the player asks for, in this civilization's own district types.
  local gi = GameInfo
  local unique = CmpMapgen.UniqueFor(gi, scn.civ, scn.leader)
  local cities = {}
  for _, city in Players[0]:GetCities():Members() do cities[#cities + 1] = city end
  table.sort(cities, function(a, b) return a:GetID() < b:GetID() end)
  -- A player asks for a Harbor only where the sea is in reach.
  local function SeaInReach(city)
    for i = 0, w.Width * w.Height - 1 do
      local p = Map.GetPlotByIndex(i)
      if p:IsWater() and not p:IsLake() and Map.GetPlotDistance(p.x, p.y, city:GetX(), city:GetY()) <= 3 then return true end
    end
    return false
  end
  local districts = {}
  for _, base in ipairs(scn.districts) do
    if base ~= "DISTRICT_HARBOR" or SeaInReach(cities[1]) then districts[#districts + 1] = unique[base] or base end
  end
  local weights = {}
  for row in gi.Yields() do weights[row.YieldType] = 1 end
  local request = { playerID = 0, scenario = scn, cities = cities, districts = districts, weights = weights,
    target = cities[1] }
  return scn, w, request
end

-- Counts DMT calls made through the globals from here on.
local function CountDMT(stats)
  stats.dmtCalls = 0
  for _, name in ipairs({ "GetBonusYields", "CanPlacePin" }) do
    local real = _G[name]
    if real ~= nil then
      _G[name] = function(...)
        stats.dmtCalls = stats.dmtCalls + 1
        return real(...)
      end
    end
  end
end
CmpRun.CountDMT = CountDMT

function CmpRun.Plan(id, planner, variant)
  local scn, w, request = CmpRun.Setup(id)
  variant = (variant or ""):gsub("#%d+$", "")
  include("cmp_" .. planner)
  local adapter = CmpAdapters[planner] or error("no adapter for " .. planner)
  local started = cmp_now()
  local out = adapter(request, variant, w)
  out.stats = out.stats or {}
  out.stats.seconds = cmp_now() - started
  local missing = {}
  for k in pairs(CmpGame.Missing) do missing[#missing + 1] = k end
  table.sort(missing)
  out.missingApi = missing
  cmp_emit("PLAN " .. Json.Encode(out))
end

-- ===========================================================================
-- Judge
-- ===========================================================================
local function Subject(districtType, x, y)
  return { Key = districtType, Type = "DISTRICT", X = x, Y = y }
end

-- Every district subject of the local player DMT would score: built
-- districts (city centers included, wonders excluded) and district pins.
local function ScoredSubjects(extra)
  local list, seen = {}, {}
  for _, city in Players[0]:GetCities():Members() do
    for _, d in city:GetDistricts():Members() do
      local row = GameInfo.Districts[d:GetType()]
      if row.DistrictType ~= "DISTRICT_WONDER" then
        local key = d:GetX() .. "_" .. d:GetY()
        seen[key] = true
        list[#list + 1] = Subject(row.DistrictType, d:GetX(), d:GetY())
      end
    end
  end
  for _, pin in ipairs(PlayerConfigurations[0]:GetMapPins()) do
    local key = pin:GetHexX() .. "_" .. pin:GetHexY()
    local subject = GetMapPinSubject(0, pin:GetHexX(), pin:GetHexY())
    if subject and subject.Type == "DISTRICT" and not seen[key] then
      seen[key] = true
      list[#list + 1] = Subject(subject.Key, subject.X, subject.Y)
    end
  end
  return list
end

local function Total(subjects)
  pcall(UpdatePinYields, 0, {})
  local total, byYield = 0, {}
  for _, s in ipairs(subjects) do
    local ok, yields = pcall(GetBonusYields, 0, s)
    if ok and yields then
      for y, amount in pairs(yields) do
        total = total + amount
        byYield[y] = (byYield[y] or 0) + amount
      end
    end
  end
  return total, byYield
end

function CmpRun.Judge(id, planJson)
  local scn, w, request = CmpRun.Setup(id)
  include("dmt_yieldcalculator")
  -- As in DMT's own context after the game loads: modifiers, pin subjects.
  w.Events.LoadGameViewStateDone()
  local plan = Json.Decode(planJson)
  local gi = GameInfo
  local cfg = PlayerConfigurations[0]
  local score = { violations = {}, legal = true, placed = 0 }
  local function Violation(kind, p, detail)
    score.violations[#score.violations + 1] = { kind = kind, type = p and p.type, x = p and p.x, y = p and p.y,
      detail = detail }
    if kind ~= "missing" and kind ~= "not_requested" then score.legal = false end
  end

  local before, beforeByYield = Total(ScoredSubjects())
  score.before = before

  -- City output, a measure that is not this mod's objective: district
  -- adjacency plus what the citizens work, each city working its best
  -- `population` tiles (all yields count 1) among the plots it owns or could
  -- grow into (3 rings, not another city's, not a district, wonder or city
  -- center). A plan that puts districts on the best tiles loses here.
  local function WorkedYield(taken)
    local claimed, total = {}, 0
    for _, c in ipairs(request.cities) do
      local values = {}
      for i = 0, w.Width * w.Height - 1 do
        local plot = Map.GetPlotByIndex(i)
        if not claimed[i] and not taken[i] and Map.GetPlotDistance(plot.x, plot.y, c:GetX(), c:GetY()) <= 3
            and not plot:IsCity() and plot:GetDistrictType() == -1 and plot:GetWonderType() == -1
            and (plot:GetOwner() == -1 or plot.city == c) and PlayersVisibility[0]:IsRevealed(i) then
          local v = 0
          for row in gi.Yields() do v = v + w.BaseYield(plot, row.YieldType) end
          values[#values + 1] = { i = i, v = v }
        end
      end
      table.sort(values, function(a, b) if a.v ~= b.v then return a.v > b.v end return a.i < b.i end)
      for k = 1, math.min(c:GetPopulation(), #values) do
        total = total + values[k].v
        claimed[values[k].i] = true
      end
    end
    return total
  end
  local workedBefore = WorkedYield({})

  local cities = {}
  for _, c in ipairs(request.cities) do cities[c:GetID()] = c end
  local manualPins = {}
  for _, pin in ipairs(cfg:GetMapPins()) do manualPins[pin:GetHexX() .. "_" .. pin:GetHexY()] = pin:GetIconName() end

  -- Tile yields the plan gives up (what the plots produce before).
  local tileLoss, featuresCleared = 0, 0
  local occupied = {}
  local placements = plan.placements or {}
  for _, p in ipairs(placements) do
    local plot = Map.GetPlot(p.x, p.y)
    local key = p.x .. "_" .. p.y
    if plot == nil then
      Violation("off_map", p)
    else
      for row in gi.Yields() do tileLoss = tileLoss + w.BaseYield(plot, row.YieldType) end
      if plot:GetFeatureType() ~= -1 and gi.Features[plot:GetFeatureType()].Removable then featuresCleared = featuresCleared + 1 end
      if occupied[key] then Violation("same_tile", p) end
      occupied[key] = true
      if plot:GetDistrictType() ~= -1 or plot:GetWonderType() ~= -1 or plot:IsCity() then Violation("occupied", p) end
      if manualPins[key] then Violation("overwrites_pin", p, manualPins[key]) end
      local city = cities[p.city]
      if city == nil then
        Violation("no_city", p)
      else
        if Map.GetPlotDistance(p.x, p.y, city:GetX(), city:GetY()) > 3 then Violation("out_of_range", p) end
        local owner = plot:GetOwner()
        if owner ~= -1 and owner ~= 0 then Violation("foreign_tile", p)
        elseif owner == 0 and plot.city ~= city then Violation("other_city_tile", p) end
      end
      if gi.Districts[p.type] == nil then Violation("unknown_type", p) end
      -- The game refuses districts on resources it cannot remove (luxury,
      -- strategic); DMT's CanPlacePin misses this for district pins.
      local rt = plot:GetResourceType()
      if rt ~= -1 then
        local res = gi.Resources[rt]
        local harvest = false
        for _ in gi.Resource_Harvests({ ResourceType = res.ResourceType }) do harvest = true end
        if not harvest and Players[0]:GetResources():IsResourceVisible(res.Hash) then
          Violation("on_resource", p, res.ResourceType)
        end
      end
    end
  end

  -- Put the plan on the map as the player would (pins with district icons).
  for _, p in ipairs(placements) do
    if gi.Districts[p.type] ~= nil and Map.GetPlot(p.x, p.y) ~= nil then
      local pin = cfg:GetMapPin(p.x, p.y)
      pin:SetIconName("ICON_" .. p.type)
      pin:SetName("")
      w.LuaEvents.DMT_MapPinAdded(pin)
      score.placed = score.placed + 1
    end
  end
  pcall(UpdatePinYields, 0, {})
  for _, p in ipairs(placements) do
    if gi.Districts[p.type] ~= nil and Map.GetPlot(p.x, p.y) ~= nil then
      pcall(UpdatePinYields, 0, {})
      local ok, canPlace, reason = pcall(CanPlacePin, 0, Subject(p.type, p.x, p.y))
      if not ok or not canPlace then Violation("dmt_illegal", p, ok and reason or tostring(canPlace)) end
    end
  end

  -- Rules DMT does not check: one per city, empire limits, district slots.
  local requested = {}
  for _, t in ipairs(request.districts) do requested[t] = true end
  local perCity, perPlayer = {}, {}
  for _, c in ipairs(request.cities) do
    perCity[c:GetID()] = {}
    for _, d in c:GetDistricts():Members() do
      local t = GameInfo.Districts[d:GetType()].DistrictType
      perCity[c:GetID()][t] = (perCity[c:GetID()][t] or 0) + 1
      perPlayer[t] = (perPlayer[t] or 0) + 1
    end
  end
  for _, city in Players[0]:GetCities():Members() do
    if perCity[city:GetID()] == nil then
      for _, d in city:GetDistricts():Members() do
        local t = GameInfo.Districts[d:GetType()].DistrictType
        perPlayer[t] = (perPlayer[t] or 0) + 1
      end
    end
  end
  local builtPerCity = {}
  for id, counts in pairs(perCity) do
    builtPerCity[id] = {}
    for t, n in pairs(counts) do builtPerCity[id][t] = n end
  end
  for _, p in ipairs(placements) do
    local row = gi.Districts[p.type]
    if row and perCity[p.city] then
      perCity[p.city][p.type] = (perCity[p.city][p.type] or 0) + 1
      perPlayer[p.type] = (perPlayer[p.type] or 0) + 1
      if row.OnePerCity and perCity[p.city][p.type] > 1 then Violation("twice_in_city", p) end
      if (row.MaxPerPlayer or -1) >= 0 and perPlayer[p.type] > row.MaxPerPlayer then Violation("empire_limit", p) end
      if not requested[p.type] then Violation("not_requested", p) end
    end
  end
  local germany = scn.civ == "CIVILIZATION_GERMANY"
  for _, c in ipairs(request.cities) do
    local used = 0
    for t, n in pairs(perCity[c:GetID()]) do
      local row = gi.Districts[t]
      if row.RequiresPopulation and not row.CityCenter then used = used + n end
    end
    local allowed = 1 + math.floor((c:GetPopulation() - 1) / 3) + (germany and 1 or 0)
    if used > allowed then Violation("slots", { city = c:GetID() }, used .. " > " .. allowed) end
  end
  -- Requested districts left out: per city, minus what it has; a district
  -- limited per player counts once for the whole empire.
  -- A left-out district is "placeable" when, with the plan on the map, the
  -- city still has a slot for it and some plot DMT accepts that no rule above
  -- forbids: then leaving it out was the planner's doing, not the map's.
  local function SlotsFree(c)
    local used = 0
    for t, n in pairs(perCity[c:GetID()]) do
      local row = gi.Districts[t]
      if row.RequiresPopulation and not row.CityCenter then used = used + n end
    end
    return used < 1 + math.floor((c:GetPopulation() - 1) / 3) + (germany and 1 or 0)
  end
  local function Placeable(t, c)
    local row = gi.Districts[t]
    if row.RequiresPopulation and not SlotsFree(c) then return false end
    for i = 0, w.Width * w.Height - 1 do
      local plot = Map.GetPlotByIndex(i)
      local key = plot.x .. "_" .. plot.y
      if Map.GetPlotDistance(plot.x, plot.y, c:GetX(), c:GetY()) <= 3 and not occupied[key] and not manualPins[key]
          and not plot:IsCity() and plot:GetDistrictType() == -1 and plot:GetWonderType() == -1
          and (plot:GetOwner() == -1 or plot.city == c) and PlayersVisibility[0]:IsRevealed(i) then
        local blocked = false
        local rt = plot:GetResourceType()
        if rt ~= -1 then
          local res = gi.Resources[rt]
          local harvest = false
          for _ in gi.Resource_Harvests({ ResourceType = res.ResourceType }) do harvest = true end
          blocked = not harvest and Players[0]:GetResources():IsResourceVisible(res.Hash)
        end
        if not blocked then
          pcall(UpdatePinYields, 0, {})
          local ok, can = pcall(CanPlacePin, 0, Subject(t, plot.x, plot.y))
          if ok and can then return true end
        end
      end
    end
    return false
  end
  local missing, missingPlaceable = 0, 0
  local function Missing(t, cities, cityID)
    local placeable = false
    for _, c in ipairs(cities) do
      if not placeable and Placeable(t, c) then placeable = true end
    end
    missing = missing + 1
    if placeable then missingPlaceable = missingPlaceable + 1 end
    Violation("missing", { type = t, city = cityID }, placeable and "placeable" or "no_plot")
  end
  local scope = {}
  for _, c in ipairs(request.cities) do
    if scn.kind == "multi" or c == request.target then scope[#scope + 1] = c end
  end
  for _, t in ipairs(request.districts) do
    local row = gi.Districts[t]
    if (row.MaxPerPlayer or -1) >= 0 then
      if (perPlayer[t] or 0) == 0 then Missing(t, scope, nil) end
    else
      for _, c in ipairs(scope) do
        if (perCity[c:GetID()][t] or 0) == 0 then Missing(t, { c }, c:GetID()) end
      end
    end
  end

  local after, afterByYield = Total(ScoredSubjects())
  score.after = after
  -- Each placed district's own DMT adjacency (for the report's figures).
  score.items = {}
  for _, p in ipairs(placements) do
    if gi.Districts[p.type] ~= nil and Map.GetPlot(p.x, p.y) ~= nil then
      pcall(UpdatePinYields, 0, {})
      local ok, yields = pcall(GetBonusYields, 0, Subject(p.type, p.x, p.y))
      local sum = 0
      if ok and yields then for _, a in pairs(yields) do sum = sum + a end end
      score.items[#score.items + 1] = { type = p.type, x = p.x, y = p.y, city = p.city, adj = sum }
    end
  end
  score.gain = after - before
  score.byYield = {}
  for row in gi.Yields() do
    local y = row.YieldType
    local d = (afterByYield[y] or 0) - (beforeByYield[y] or 0)
    if d ~= 0 then score.byYield[y] = d end
  end
  score.tileLoss = tileLoss
  local taken = {}
  for _, p in ipairs(placements) do
    if Map.GetPlot(p.x, p.y) then taken[Map.GetPlotIndex(p.x, p.y)] = true end
  end
  local workedAfter = WorkedYield(taken)
  score.worked = workedAfter - workedBefore
  score.output = score.gain + score.worked
  score.featuresCleared = featuresCleared
  score.missing = missing
  score.missingPlaceable = missingPlaceable
  score.requested = #request.districts
  cmp_emit("SCORE " .. Json.Encode(score))
end

-- A text picture of a scenario's map around its first city (debugging).
function CmpRun.Dump(id)
  local scn, w = CmpRun.Setup(id)
  local gi = GameInfo
  local c = w.Cities[1]
  local CH = { TERRAIN_GRASS = ".", TERRAIN_PLAINS = ",", TERRAIN_DESERT = "_", TERRAIN_TUNDRA = "t", TERRAIN_SNOW = "*",
    TERRAIN_COAST = "~", TERRAIN_OCEAN = "=" }
  local FE = { FEATURE_FOREST = "f", FEATURE_JUNGLE = "j", FEATURE_MARSH = "s", FEATURE_OASIS = "o", FEATURE_REEF = "r",
    FEATURE_FLOODPLAINS = "p", FEATURE_FLOODPLAINS_GRASSLAND = "p", FEATURE_FLOODPLAINS_PLAINS = "p", FEATURE_VOLCANO = "V",
    FEATURE_VOLCANIC_SOIL = "v", FEATURE_GEOTHERMAL_FISSURE = "g" }
  local counts = {}
  for y = 0, w.Height - 1 do
    local row = {}
    if y % 2 == 1 then row[1] = " " end
    for x = 0, w.Width - 1 do
      local p = Map.GetPlot(x, y)
      local t = gi.Terrains[p:GetTerrainType()].TerrainType
      local ch = CH[t:gsub("_HILLS", ""):gsub("_MOUNTAIN", "")] or "?"
      if p:IsMountain() then ch = "M" elseif p:IsHills() then ch = ch == "." and "h" or ch == "," and "H" or "^" end
      if p:IsLake() then ch = "L" end
      if p:GetFeatureType() ~= -1 then
        local f = gi.Features[p:GetFeatureType()]
        ch = f.NaturalWonder and "W" or FE[f.FeatureType] or ch
      end
      if p:IsCity() then ch = p:GetOwner() == 0 and "C" or "X" end
      if p:GetDistrictType() ~= -1 and not p:IsCity() then ch = "D" end
      local mark = p:IsRiver() and "'" or " "
      if p:GetOwner() == 0 then mark = p:IsRiver() and "!" or ":" end
      row[#row + 1] = ch .. mark
      counts[ch] = (counts[ch] or 0) + 1
    end
    print(table.concat(row))
  end
  local keys = {}
  for k, v in pairs(counts) do keys[#keys + 1] = k .. "=" .. v end
  table.sort(keys)
  print(table.concat(keys, " "))
  print("rivers " .. #w.Rivers .. ", cities " .. #w.Cities .. ", pins " .. #PlayerConfigurations[0]:GetMapPins()
    .. ", capital " .. c.x .. "," .. c.y .. " pop " .. c.population)
end

-- The map near the player's cities as data, for the report's hex figures.
function CmpRun.Snapshot(id, radius)
  local scn, w = CmpRun.Setup(id)
  local gi = GameInfo
  radius = radius or 4
  local own = {}
  for _, c in ipairs(w.Cities) do
    if c.owner == 0 then own[#own + 1] = c end
  end
  local plots = {}
  for i = 0, w.Width * w.Height - 1 do
    local p = Map.GetPlotByIndex(i)
    local near = false
    for _, c in ipairs(own) do
      if Map.GetPlotDistance(p.x, p.y, c.x, c.y) <= radius then near = true end
    end
    if near then
      local t = gi.Terrains[p:GetTerrainType()]
      local entry = { i = i, x = p.x, y = p.y, t = t.TerrainType, owner = p:GetOwner() }
      if p:GetFeatureType() ~= -1 then entry.f = gi.Features[p:GetFeatureType()].FeatureType end
      if p:GetResourceType() ~= -1 then
        local r = gi.Resources[p:GetResourceType()]
        entry.r, entry.rc = r.ResourceType, r.ResourceClassType
      end
      if p:GetImprovementType() ~= -1 then entry.imp = gi.Improvements[p:GetImprovementType()].ImprovementType end
      if p:IsLake() then entry.lake = true end
      if p:IsCity() then entry.city = true end
      if p:GetDistrictType() ~= -1 and not p:IsCity() then entry.d = gi.Districts[p:GetDistrictType()].DistrictType end
      if p.hidden then entry.hidden = true end
      local rivers = {}
      for dir = 0, 5 do
        local n = Map.GetAdjacentPlot(p.x, p.y, dir)
        if n and p:IsRiverCrossingToPlot(n) then rivers[#rivers + 1] = dir end
      end
      if #rivers > 0 then entry.river = rivers end
      plots[#plots + 1] = entry
    end
  end
  local pins = {}
  for _, pin in ipairs(PlayerConfigurations[0]:GetMapPins()) do
    pins[#pins + 1] = { x = pin:GetHexX(), y = pin:GetHexY(), icon = pin:GetIconName() }
  end
  local cities = {}
  for _, c in ipairs(w.Cities) do
    cities[#cities + 1] = { id = c.id, owner = c.owner, x = c.x, y = c.y, population = c.population }
  end
  cmp_emit("SNAP " .. Json.Encode({ id = id, width = w.Width, height = w.Height, plots = plots, pins = pins,
    cities = cities, civ = scn.civ, leader = scn.leader, biome = scn.biome, stage = scn.stage, kind = scn.kind,
    districts = request and request.districts or nil }))
end

return CmpRun
