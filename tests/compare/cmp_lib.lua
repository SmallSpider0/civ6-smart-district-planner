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
-- Scenes exported from real games (tools/snapshot.py, design section 25):
-- tests/compare/scenes/index.json lists them; each is a scenario whose world
-- comes from its file instead of the generator.
-- ===========================================================================
local SCENES = (CMP_GAMEINFO or ""):gsub("[/\\]%.cache[/\\]gameinfo%.lua$", "") .. "/scenes/"
do
  local text = cmp_read_file and cmp_read_file(SCENES .. "index.json")
  if text ~= nil then
    -- Only the scenes of the ruleset GameInfo was exported from (compare.mjs
    -- --ruleset): Rise and Fall's adjacency differs from Gathering Storm's.
    local ruleset = CMP_RULESET or "RULESET_EXPANSION_2"
    for _, s in ipairs(Json.Decode(text)) do
      if s.ruleset == nil or s.ruleset == ruleset then
        s.runs = CmpScenarios.Runs(s.kind)
        s.path = SCENES .. s.file
        CmpScenarios.Add(s)
      end
    end
  end
end

-- A late city often has no free district slot for what its scene asks;
-- the plan is for later, as in the generated scenes, whose population
-- leaves room. Each planned city gets the population its built and asked
-- specialty districts need (the judge's slot rule; the city's own
-- population is kept as savedPopulation).
local function RoomForPlan(scn, spec)
  local gi = CmpGame.LoadGameInfo()
  local function Specialty(t)
    local row = gi.Districts[t]
    return row ~= nil and row.RequiresPopulation and not row.CityCenter
  end
  local plans = {}
  for n, id in ipairs(scn.only or {}) do plans[id] = scn.plans and scn.plans[n] or scn.districts end
  local bonus = scn.civ == "CIVILIZATION_GERMANY" and 1 or 0
  for _, c in ipairs(spec.cities) do
    local plan = plans[c.id]
    if plan ~= nil and c.owner == 0 then
      local need = 0
      for _, d in ipairs(c.districts or {}) do
        if Specialty(d.type) then need = need + 1 end
      end
      for _, t in ipairs(plan) do
        if Specialty(t) then need = need + 1 end
      end
      local population = 3 * math.max(0, need - bonus - 1) + 1
      if (c.population or 1) < population then
        c.savedPopulation, c.population = c.population, population
      end
    end
  end
end

local function LoadScene(scn)
  if scn.spec == nil then
    local text = cmp_read_file(scn.path) or error("missing scene file " .. tostring(scn.path))
    scn.spec = Json.Decode(text)
    RoomForPlan(scn, scn.spec)
  end
  return scn.spec
end

-- The exporter wrote each chosen city's rings as local plot indices; the
-- world built here must put them at the same distances (same hex layout).
local function CheckRings(spec, w)
  for _, entry in ipairs(spec.rings or {}) do
    local city = nil
    for _, c in Players[0]:GetCities():Members() do
      if c:GetID() == entry.city then city = c end
    end
    if city == nil then error("scene city " .. tostring(entry.city) .. " missing") end
    for _, pair in ipairs(entry.rings) do
      local x, y = pair[1] % w.Width, math.floor(pair[1] / w.Width)
      local d = Map.GetPlotDistance(x, y, city:GetX(), city:GetY())
      if d ~= pair[2] then
        error(string.format("scene geometry: plot %d,%d is %d from city %d, the game had %d", x, y, d, entry.city, pair[2]))
      end
    end
  end
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
  local spec = scn.path and LoadScene(scn) or CmpMapgen.Generate(scn)
  local w = CmpGame.New(spec)
  if scn.path then CheckRings(spec, w) end
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
  -- A scene plans only its chosen cities (`only`) and a named target.
  local only = nil
  if scn.only ~= nil then
    only = {}
    for _, cid in ipairs(scn.only) do only[cid] = true end
  end
  local cities, target = {}, nil
  for _, city in Players[0]:GetCities():Members() do
    if only == nil or only[city:GetID()] then cities[#cities + 1] = city end
    if scn.target ~= nil and city:GetID() == scn.target then target = city end
  end
  table.sort(cities, function(a, b) return a:GetID() < b:GetID() end)
  target = target or cities[1]
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
    if base ~= "DISTRICT_HARBOR" or SeaInReach(target) then districts[#districts + 1] = unique[base] or base end
  end
  -- A list per city (V scenarios): { [city ID] = district types }, by city order.
  local plans = nil
  if scn.plans then
    plans = {}
    for n, city in ipairs(cities) do
      local list = {}
      for _, base in ipairs(scn.plans[n] or {}) do list[#list + 1] = unique[base] or base end
      plans[city:GetID()] = list
    end
  end
  -- Yield weights: 1 each, or the scenario's profile (one yield weighted 3).
  local weights = {}
  for row in gi.Yields() do weights[row.YieldType] = 1 end
  for k, v in pairs(scn.weights or {}) do weights[k] = v end
  -- Wonders wanted with the districts (W scenarios), the ones this ruleset has.
  local wonders = {}
  for _, b in ipairs(scn.wantWonders or {}) do
    if gi.Buildings[b] ~= nil then wonders[#wonders + 1] = b end
  end
  local request = { playerID = 0, scenario = scn, cities = cities, districts = districts, weights = weights,
    target = target, wonders = wonders, sites = scn.sites, plans = plans }
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

-- A competitor's own objective for a plan (design 18.1, item 2): the
-- scenario's world, the scorer's code loaded in this state
-- (cmp_cross_<scorer>.lua), CmpCross[scorer](request, plan, w) ->
-- { score, baseline, gain, ... } with gain = score - baseline, higher better.
function CmpRun.Cross(id, planJson, scorer)
  local scn, w, request = CmpRun.Setup(id)
  local plan = Json.Decode(planJson)
  include("cmp_cross_" .. scorer)
  local fn = CmpCross and CmpCross[scorer] or error("no cross scorer " .. scorer)
  local out = fn(request, plan, w) or {}
  cmp_emit("CROSS " .. Json.Encode(out))
end

-- ===========================================================================
-- Judge
-- ===========================================================================
local function IsWonder(t)
  local row = GameInfo.Buildings[t]
  return row ~= nil and row.IsWonder == true
end

-- A district subject, or a wonder's (a building type) as DMT makes it from a pin.
local function Subject(t, x, y)
  return { Key = t, Type = IsWonder(t) and "WONDER" or "DISTRICT", X = x, Y = y }
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

-- Sum of the subjects' DMT adjacency, weighted by `weights` (default 1).
local function Total(subjects, weights)
  pcall(UpdatePinYields, 0, {})
  local total, byYield = 0, {}
  for _, s in ipairs(subjects) do
    local ok, yields = pcall(GetBonusYields, 0, s)
    if ok and yields then
      for y, amount in pairs(yields) do
        total = total + amount * ((weights and weights[y]) or 1)
        byYield[y] = (byYield[y] or 0) + amount
      end
    end
  end
  return total, byYield
end

-- New city sites (kind "sites"), judged by measures no planner optimizes
-- as such, all from the map and DMT:
--   legal         land, not a mountain, explored, nobody else's, more than
--                 CITY_MIN_RANGE from every city and from the other sites;
--                 "too_far" (soft): not linked back to an own city through
--                 steps of at most request.sites.distance
--   tileValue     each site works its best 8 plots (all yields 1) among the
--                 plots within 3 that no city owns, a plot two sites reach
--                 going to the nearer (then the earlier) site
--   freshWater    sites on a river or next to a lake; coastal: next to the sea
--   newLuxuries, newStrategics  kinds in the sites' plots the player's cities
--                 do not have yet
--   districtPotential  per site and per district of the scenario's plan, the
--                 best DMT adjacency of that district alone on a plot the site
--                 gets (city-center pins at the sites, as the player would
--                 mark them), summed
--   overlap       plots within 3 of two sites, or of a site and a city
--   siteValue     tileValue + districtPotential (yield points)
local function JudgeSites(scn, w, request, plan)
  local gi = GameInfo
  local score = { violations = {}, legal = true, placed = 0, requested = request.sites.count }
  local function Violation(kind, p, detail)
    score.violations[#score.violations + 1] = { kind = kind, x = p and p.x, y = p and p.y, detail = detail }
    if kind ~= "missing" and kind ~= "too_far" then score.legal = false end
  end
  local minRange = (GlobalParameters and GlobalParameters.CITY_MIN_RANGE) or 3
  local allCities = {}
  for _, player in pairs(Players) do
    if type(player) == "table" and player.GetCities then
      for _, c in player:GetCities():Members() do allCities[#allCities + 1] = c end
    end
  end
  table.sort(allCities, function(a, b)
    if a:GetOwner() ~= b:GetOwner() then return a:GetOwner() < b:GetOwner() end
    return a:GetID() < b:GetID()
  end)
  local own = request.cities
  local sites = {}
  for _, p in ipairs(plan.placements or {}) do
    local plot = Map.GetPlot(p.x, p.y)
    if plot == nil then
      Violation("off_map", p)
    else
      if plot:IsWater() or plot:IsMountain() or plot:IsImpassable() then Violation("bad_terrain", p) end
      if not PlayersVisibility[0]:IsRevealed(plot:GetIndex()) then Violation("unrevealed", p) end
      if plot:GetOwner() ~= -1 and plot:GetOwner() ~= 0 then Violation("foreign_tile", p) end
      if plot:IsNaturalWonder() then Violation("natural_wonder", p) end
      for _, c in ipairs(allCities) do
        if Map.GetPlotDistance(p.x, p.y, c:GetX(), c:GetY()) <= minRange then Violation("too_close", p, "city") end
      end
      for _, other in ipairs(sites) do
        if Map.GetPlotDistance(p.x, p.y, other.x, other.y) <= minRange then Violation("too_close", p, "site") end
      end
      sites[#sites + 1] = { x = p.x, y = p.y, plot = plot }
      score.placed = score.placed + 1
    end
  end
  for _ = #sites + 1, request.sites.count do Violation("missing", nil) end
  -- Linked back to an own city through steps of at most `distance`.
  local linked, changed = {}, true
  while changed do
    changed = false
    for n, site in ipairs(sites) do
      if not linked[n] then
        for _, c in ipairs(own) do
          if Map.GetPlotDistance(site.x, site.y, c:GetX(), c:GetY()) <= request.sites.distance then linked[n] = true end
        end
        for m, other in ipairs(sites) do
          if linked[m] and Map.GetPlotDistance(site.x, site.y, other.x, other.y) <= request.sites.distance then linked[n] = true end
        end
        if linked[n] then changed = true end
      end
    end
  end
  for n, site in ipairs(sites) do
    if not linked[n] then Violation("too_far", { x = site.x, y = site.y }) end
  end

  -- Plots each site gets.
  local claim, overlap = {}, 0
  for i = 0, w.Width * w.Height - 1 do
    local plot = Map.GetPlotByIndex(i)
    local reach, best, bestD = 0, nil, nil
    for n, site in ipairs(sites) do
      local d = Map.GetPlotDistance(plot.x, plot.y, site.x, site.y)
      if d >= 1 and d <= 3 then
        reach = reach + 1
        if bestD == nil or d < bestD then best, bestD = n, d end
      end
    end
    if reach > 0 then
      local nearCity = false
      for _, c in ipairs(own) do
        if Map.GetPlotDistance(plot.x, plot.y, c:GetX(), c:GetY()) <= 3 then nearCity = true end
      end
      if reach > 1 or nearCity then overlap = overlap + 1 end
      if plot:GetOwner() == -1 and PlayersVisibility[0]:IsRevealed(i) and not plot:IsCity() then claim[i] = best end
    end
  end
  score.overlap = overlap
  -- Tiles worked, fresh water, coast, new resource kinds.
  local ownKinds = {}
  for _, c in ipairs(own) do
    for i = 0, w.Width * w.Height - 1 do
      local plot = Map.GetPlotByIndex(i)
      if plot.city == c and plot:GetResourceType() ~= -1 then ownKinds[plot:GetResourceType()] = true end
    end
  end
  local tileValue, fresh, coastal, newKinds = 0, 0, 0, { LUX = {}, STRAT = {} }
  for n, site in ipairs(sites) do
    local values = {}
    for i, owner in pairs(claim) do
      if owner == n then
        local plot = Map.GetPlotByIndex(i)
        local v = 0
        for row in gi.Yields() do v = v + w.BaseYield(plot, row.YieldType) end
        values[#values + 1] = { i = i, v = v }
        local rt = plot:GetResourceType()
        if rt ~= -1 and not ownKinds[rt] and Players[0]:GetResources():IsResourceVisible(gi.Resources[rt].Hash) then
          local class = gi.Resources[rt].ResourceClassType
          if class == "RESOURCECLASS_LUXURY" then newKinds.LUX[rt] = true end
          if class == "RESOURCECLASS_STRATEGIC" then newKinds.STRAT[rt] = true end
        end
      end
    end
    table.sort(values, function(a, b) if a.v ~= b.v then return a.v > b.v end return a.i < b.i end)
    for k = 1, math.min(8, #values) do tileValue = tileValue + values[k].v end
    if site.plot:IsFreshWater() then fresh = fresh + 1 end
    if site.plot:IsCoastalLand() then coastal = coastal + 1 end
  end
  local function Count(t) local c = 0 for _ in pairs(t) do c = c + 1 end return c end
  score.tileValue, score.freshWater, score.coastal = tileValue, fresh, coastal
  score.newLuxuries, score.newStrategics = Count(newKinds.LUX), Count(newKinds.STRAT)

  -- District potential, with city-center pins at the sites.
  local cfg = PlayerConfigurations[0]
  for _, site in ipairs(sites) do
    local pin = cfg:GetMapPin(site.x, site.y)
    pin:SetIconName("ICON_DISTRICT_CITY_CENTER")
    pin:SetName("")
    w.LuaEvents.DMT_MapPinAdded(pin)
  end
  local potential = 0
  for n, site in ipairs(sites) do
    for _, districtType in ipairs(request.districts) do
      local best = 0
      for i, owner in pairs(claim) do
        local plot = Map.GetPlotByIndex(i)
        if owner == n and not plot:IsCity() then
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
            local subject = Subject(districtType, plot.x, plot.y)
            local ok, can = pcall(CanPlacePin, 0, subject)
            if ok and can then
              local okY, yields = pcall(GetBonusYields, 0, subject)
              local v = 0
              if okY and yields then for y, a in pairs(yields) do v = v + a * (request.weights[y] or 1) end end
              if v > best then best = v end
            end
          end
        end
      end
      potential = potential + best
    end
  end
  score.districtPotential = potential
  score.siteValue = tileValue + potential
  cmp_emit("SCORE " .. Json.Encode(score))
end

function CmpRun.Judge(id, planJson)
  local scn, w, request = CmpRun.Setup(id)
  include("dmt_yieldcalculator")
  -- As in DMT's own context after the game loads: modifiers, pin subjects.
  w.Events.LoadGameViewStateDone()
  local plan = Json.Decode(planJson)
  if scn.kind == "sites" then return JudgeSites(scn, w, request, plan) end
  local gi = GameInfo
  local cfg = PlayerConfigurations[0]
  local score = { violations = {}, legal = true, placed = 0 }
  local function Violation(kind, p, detail)
    score.violations[#score.violations + 1] = { kind = kind, type = p and p.type, x = p and p.x, y = p and p.y,
      detail = detail }
    if kind ~= "missing" and kind ~= "not_requested" then score.legal = false end
  end

  local before, beforeByYield = Total(ScoredSubjects(), request.weights)
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

  -- A plot another of the player's cities owns can be swapped to the city
  -- (issue 54; CityCommandTypes.SWAP_TILE_OWNER, measured 2026-10-23 on every
  -- city of a late save): next to a plot the city owns, no district on it,
  -- not next to the owning city's center.
  local function Swappable(plot, city)
    local owning = plot.city
    if owning == nil or owning == city or plot:GetDistrictType() ~= -1 or plot:IsCity() then return false end
    if Map.GetPlotDistance(plot.x, plot.y, owning:GetX(), owning:GetY()) <= 1 then return false end
    for _, n in ipairs(w.Neighbours(plot)) do
      if n:GetOwner() == 0 and n.city == city then return true end
    end
    return false
  end
  local swapped = {}

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
        elseif owner == 0 and plot.city ~= city then
          if Swappable(plot, city) then swapped[key] = true else Violation("other_city_tile", p) end
        end
      end
      if gi.Districts[p.type] == nil and not IsWonder(p.type) then Violation("unknown_type", p) end
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
      -- Flooded coastal lowland takes no district (issue 44); DMT misses it.
      if plot.lowland ~= -1 and (plot.flooded or plot.submerged) then Violation("flooded", p) end
    end
  end

  -- A city can only grow into or buy a plot next to one it owns (issue 35):
  -- every placement must join its city's plots through unowned plots within
  -- 3 rings that no other city's placement takes.
  local byCity = {}
  for _, p in ipairs(placements) do
    if cities[p.city] ~= nil and Map.GetPlot(p.x, p.y) ~= nil then
      byCity[p.city] = byCity[p.city] or {}
      table.insert(byCity[p.city], p)
    end
  end
  local cityIDs = {}
  for id in pairs(byCity) do cityIDs[#cityIDs + 1] = id end
  table.sort(cityIDs)
  for _, id in ipairs(cityIDs) do
    local city = cities[id]
    local cx, cy = city:GetX(), city:GetY()
    local blocked = {}
    for _, p in ipairs(placements) do
      if p.city ~= id and cities[p.city] ~= nil then blocked[p.x .. "_" .. p.y] = true end
    end
    local reached, queue = {}, {}
    for i = 0, w.Width * w.Height - 1 do
      local plot = Map.GetPlotByIndex(i)
      if (plot.city == city or plot:IsCity() and plot.x == cx and plot.y == cy)
          and Map.GetPlotDistance(plot.x, plot.y, cx, cy) <= 3 and not swapped[plot.x .. "_" .. plot.y] then
        reached[plot.x .. "_" .. plot.y] = true
        queue[#queue + 1] = plot
      end
    end
    local head = 1
    while head <= #queue do
      local plot = queue[head]
      head = head + 1
      for _, n in ipairs(w.Neighbours(plot)) do
        local key = n.x .. "_" .. n.y
        if not reached[key] and not blocked[key] and n:GetOwner() == -1
            and Map.GetPlotDistance(n.x, n.y, cx, cy) <= 3 then
          reached[key] = true
          queue[#queue + 1] = n
        end
      end
    end
    for _, p in ipairs(byCity[id]) do
      -- A swapped plot touches the city's own plots.
      if not reached[p.x .. "_" .. p.y] and not swapped[p.x .. "_" .. p.y] then Violation("unreachable", p) end
    end
  end
  local swaps = 0
  for _ in pairs(swapped) do swaps = swaps + 1 end
  score.swapped = swaps

  -- Put the plan on the map as the player would (pins with district or wonder icons).
  for _, p in ipairs(placements) do
    if (gi.Districts[p.type] ~= nil or IsWonder(p.type)) and Map.GetPlot(p.x, p.y) ~= nil then
      local pin = cfg:GetMapPin(p.x, p.y)
      pin:SetIconName("ICON_" .. p.type)
      pin:SetName("")
      w.LuaEvents.DMT_MapPinAdded(pin)
      score.placed = score.placed + 1
    end
  end
  pcall(UpdatePinYields, 0, {})
  for _, p in ipairs(placements) do
    if (gi.Districts[p.type] ~= nil or IsWonder(p.type)) and Map.GetPlot(p.x, p.y) ~= nil then
      pcall(UpdatePinYields, 0, {})
      local ok, canPlace, reason = pcall(CanPlacePin, 0, Subject(p.type, p.x, p.y))
      if not ok or not canPlace then Violation("dmt_illegal", p, ok and reason or tostring(canPlace)) end
    end
  end

  -- A wonder that needs an adjacent district takes only its own city's
  -- (issue 45): built there, or placed for the same city. DMT counts any.
  local function Serves(t, required)
    if t == required then return true end
    local row = gi.DistrictReplaces[t]
    return row ~= nil and row.ReplacesDistrictType == required
  end
  for _, p in ipairs(placements) do
    local row = IsWonder(p.type) and gi.Buildings[p.type] or nil
    local plot = Map.GetPlot(p.x, p.y)
    if row ~= nil and row.AdjacentDistrict ~= nil and plot ~= nil then
      local own, other = false, false
      for _, n in ipairs(w.Neighbours(plot)) do
        local d = n.district
        if d ~= nil and Serves(d.typeRow.DistrictType, row.AdjacentDistrict) then
          if d.city == cities[p.city] then own = true else other = true end
        end
      end
      for _, q in ipairs(placements) do
        if q ~= p and gi.Districts[q.type] ~= nil and Serves(q.type, row.AdjacentDistrict)
            and Map.GetPlotDistance(p.x, p.y, q.x, q.y) == 1 then
          if q.city == p.city then own = true else other = true end
        end
      end
      if other and not own then Violation("wonder_other_city", p) end
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
      local wanted = requested
      if request.plans then
        wanted = {}
        for _, t in ipairs(request.plans[p.city] or {}) do wanted[t] = true end
      end
      if not wanted[p.type] then Violation("not_requested", p) end
    end
  end
  -- Wonders: each at most once, only the ones asked for count as placed.
  local wantWonder, wonderSeen = {}, {}
  for _, b in ipairs(request.wonders or {}) do wantWonder[b] = true end
  score.wondersRequested, score.wondersPlaced = #(request.wonders or {}), 0
  for _, p in ipairs(placements) do
    if IsWonder(p.type) then
      if wonderSeen[p.type] then Violation("twice_in_city", p) end
      wonderSeen[p.type] = true
      if wantWonder[p.type] then score.wondersPlaced = score.wondersPlaced + 1 else Violation("not_requested", p) end
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
  -- Districts a city cannot have next to what it has (GS: the entertainment
  -- complex and the water park).
  local function ExcludedIn(t, c)
    if gi.MutuallyExclusiveDistricts == nil then return false end
    for row in gi.MutuallyExclusiveDistricts() do
      local other = row.District == t and row.MutuallyExclusiveDistrict
        or row.MutuallyExclusiveDistrict == t and row.District or nil
      if other ~= nil and other ~= t and (perCity[c:GetID()][other] or 0) > 0 then return true end
    end
    return false
  end
  local function Placeable(t, c)
    local row = gi.Districts[t]
    if row.RequiresPopulation and not SlotsFree(c) then return false end
    if ExcludedIn(t, c) then return false end
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
        if plot.lowland ~= -1 and (plot.flooded or plot.submerged) then blocked = true end
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
  if request.plans then
    -- Each city its own list.
    for _, c in ipairs(scope) do
      for _, t in ipairs(request.plans[c:GetID()] or {}) do
        if (perCity[c:GetID()][t] or 0) == 0 then Missing(t, { c }, c:GetID()) end
      end
    end
  else
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
  end

  local after, afterByYield = Total(ScoredSubjects(), request.weights)
  score.after = after
  -- Each placed district's own DMT adjacency (for the report's figures).
  score.items = {}
  for _, p in ipairs(placements) do
    if (gi.Districts[p.type] ~= nil or IsWonder(p.type)) and Map.GetPlot(p.x, p.y) ~= nil then
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

  -- Coverage (design 19.5): the (city, kind) pairs the player's regional
  -- districts reach, before and with the plan. Worked out here from the
  -- rules, not with any planner's code: a kind is a base district, its
  -- range the largest Buildings.RegionalRange of the generic buildings that
  -- need it; a city counts once per kind.
  local reach = {}
  for row in gi.Buildings() do
    if (row.RegionalRange or 0) > 0 and row.PrereqDistrict ~= nil and row.TraitType == nil then
      reach[row.PrereqDistrict] = math.max(reach[row.PrereqDistrict] or 0, row.RegionalRange)
    end
  end
  local function Covered(extra)
    local covered, count = {}, 0
    local function Add(t, x, y)
      local replaces = gi.DistrictReplaces[t]
      local base = replaces and replaces.ReplacesDistrictType or t
      local range = reach[base]
      if range == nil then return end
      for _, city in Players[0]:GetCities():Members() do
        local key = base .. ":" .. city:GetID()
        if not covered[key] and Map.GetPlotDistance(x, y, city:GetX(), city:GetY()) <= range then
          covered[key] = true
          count = count + 1
        end
      end
    end
    for _, d in Players[0]:GetDistricts():Members() do Add(gi.Districts[d:GetType()].DistrictType, d:GetX(), d:GetY()) end
    for _, p in ipairs(extra) do
      if gi.Districts[p.type] ~= nil then Add(p.type, p.x, p.y) end
    end
    return count
  end
  score.coverageBefore = Covered({})
  score.coverage = Covered(placements)
  score.coverageGain = score.coverage - score.coverageBefore
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
