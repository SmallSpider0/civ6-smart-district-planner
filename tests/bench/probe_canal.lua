-- Probe for #378: what the game itself requires of a canal, plot by plot.
-- Read-only: it never builds anything, it only asks the engine and this mod.
--
-- Run it in the state that has SDP_* and DMT loaded (SDP_Panel), after
-- tests/fixtures/unlock_all.lua in GameCore_Tuner gave every technology and
-- the city its three rings (the engine lists build targets only for an
-- unlocked district and only on plots the city owns):
--
--   python -I tools/civ6tuner.py exec -s GameCore_Tuner -f tests/fixtures/unlock_all.lua
--   python -I tools/civ6tuner.py exec -s SDP_Panel -f tests/bench/probe_canal.lua
--
-- One CSV row per land plot in the three rings of every city of the local
-- player, plus a summary: engine (the game's own build targets, what the
-- placement lens shows) against ours (DMT's CanPlacePin with this mod's
-- engine check on top), and the neighbourhood that decides it.
--
-- Columns: x,y,city,ring,terrain,hills,feature,district,river,owner,
--   adj_city,adj_canal,water,water_dir,water_kind,engine,ours,refused_by,
--   link,cannot,city_dir,canal_dir
--   engine: allow | refuse | outside (the city does not own it, so the
--           engine gives no answer) | nolist (the engine listed no target)
--   ours:   allow | refuse (this mod's verdict, including the engine check)
--   refused_by: engine (this mod vetoed on the engine's/rule's word),
--               dmt (DMT itself refused), none
--   link: SDP_City.CanalSidesJoin (the rules see a passage), cannot:
--   SDP_City.CanalCannotLink
-- Direction numbers are DirectionTypes; the legend is printed once.

local pid = Game.GetLocalPlayer()
local player = Players[pid]
local CANAL = "DISTRICT_CANAL"
local WEIGHTS = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }

local function DirectionNames()
  local names = {}
  for name, value in pairs(DirectionTypes) do
    if type(value) == "number" then names[value] = name end
  end
  return names
end

local function Describe(plot)
  local terrain = GameInfo.Terrains[plot:GetTerrainType()]
  return terrain ~= nil and terrain.TerrainType or ("TERRAIN_" .. tostring(plot:GetTerrainType()))
end

local function WaterKind(plot)
  local terrain = Describe(plot)
  if plot:IsLake() then return "LAKE" end
  if terrain == "TERRAIN_COAST" then return "COAST" end
  if terrain == "TERRAIN_OCEAN" then return "OCEAN" end
  return terrain
end

local function Feature(plot)
  local index = plot:GetFeatureType()
  if index == nil or index == -1 then return "-" end
  local row = GameInfo.Features[index]
  return row ~= nil and row.FeatureType or ("FEATURE_" .. tostring(index))
end

local function District(plot)
  local index = plot:GetDistrictType()
  if index == nil or index == -1 then return "-" end
  local row = GameInfo.Districts[index]
  return row ~= nil and row.DistrictType or ("DISTRICT_" .. tostring(index))
end

-- Water bodies, one flood fill over the map. The engine refuses a canal whose
-- two water ends are the same body (a spit one tile wide), and Lua has no API
-- for that, so the probe records the body of every water neighbour.
local BODY = {}
local BODIES = 0

local function FillBodies()
  if next(BODY) ~= nil then return end
  for i = 0, Map.GetPlotCount() - 1 do
    local plot = Map.GetPlotByIndex(i)
    if plot ~= nil and plot:IsWater() and BODY[i] == nil then
      BODIES = BODIES + 1
      BODY[i] = BODIES
      local stack = { plot }
      while #stack > 0 do
        local q = table.remove(stack)
        for direction = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
          local n = Map.GetAdjacentPlot(q:GetX(), q:GetY(), direction)
          if n ~= nil and n:IsWater() then
            local index = n:GetIndex()
            if BODY[index] == nil then
              BODY[index] = BODIES
              stack[#stack + 1] = n
            end
          end
        end
      end
    end
  end
end

-- The engine's build targets for a canal in one city: the set it lists, or
-- nil when it lists nothing (district locked, no free slot, API missing).
local function EngineTargets(city)
  if CityManager == nil or CityManager.GetOperationTargets == nil then return nil end
  local row = GameInfo.Districts[CANAL]
  if row == nil then return nil end
  local params = {}
  params[CityOperationTypes.PARAM_DISTRICT_TYPE] = row.Hash
  local ok, results = pcall(CityManager.GetOperationTargets, city, CityOperationTypes.BUILD, params)
  local plots = ok and type(results) == "table" and results[CityOperationResults.PLOTS] or nil
  if type(plots) ~= "table" then return nil end
  local set, any = {}, false
  for _, index in ipairs(plots) do set[index], any = true, true end
  if not any then return nil end
  return set
end

local dirName = DirectionNames()
local function Legend()
  local parts = {}
  for direction = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
    parts[#parts + 1] = direction .. "=" .. tostring(dirName[direction])
  end
  return table.concat(parts, " ")
end

local function ProbeCity(city, tally)
  local cx, cy = city:GetX(), city:GetY()
  local terrains = SDP_Rules.ValidTerrains(CANAL)
  local targets = EngineTargets(city)
  local cityWater = {}
  for direction = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
    local n = Map.GetAdjacentPlot(cx, cy, direction)
    if n ~= nil and n:IsWater() then
      cityWater[#cityWater + 1] = direction .. ":" .. tostring(BODY[n:GetIndex()])
    end
  end
  local allowedN = 0
  if targets ~= nil then for _ in pairs(targets) do allowedN = allowedN + 1 end end
  print(string.format("# city %d (%d,%d) pop %d engine_targets %s city_water %s", city:GetID(), cx, cy, city:GetPopulation(),
    targets == nil and "nolist" or tostring(allowedN),
    #cityWater > 0 and table.concat(cityWater, ";") or "-"))

  local rows, ownedRows, answeredRows = 0, 0, 0
  for _, p in ipairs(SDP_City.PlotsInRange(cx, cy, 3)) do
    local plot = Map.GetPlotByIndex(p.Index)
    if plot ~= nil and not plot:IsWater() then
      local water, dirs, kinds, bodyDirs = 0, {}, {}, {}
      local adjCity, adjCanal, cityDirs, canalDirs = 0, 0, {}, {}
      for direction = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
        local n = Map.GetAdjacentPlot(p.X, p.Y, direction)
        if n ~= nil then
          if n:IsWater() then
            water = water + 1
            dirs[#dirs + 1] = tostring(direction)
            kinds[#kinds + 1] = direction .. ":" .. WaterKind(n)
            bodyDirs[#bodyDirs + 1] = direction .. ":" .. tostring(BODY[n:GetIndex()])
          end
          if n:IsCity() then adjCity = adjCity + 1; cityDirs[#cityDirs + 1] = tostring(direction) end
          local index = n:GetDistrictType()
          if index ~= nil and index ~= -1 then
            local row = GameInfo.Districts[index]
            if row ~= nil and SDP_Rules.IsCanal(row.DistrictType) then
              adjCanal = adjCanal + 1
              canalDirs[#canalDirs + 1] = tostring(direction)
            end
          end
        end
      end
      local owner = plot:GetOwner()
      local purchase = owner == pid and Cities.GetPlotPurchaseCity(plot) or nil
      local owned = purchase ~= nil and purchase:GetID() == city:GetID()
      -- The engine only offers plots the city owns: elsewhere it has no answer.
      local engine
      if targets == nil then engine = "nolist"
      elseif not owned then engine = "outside"
      elseif targets[p.Index] then engine = "allow"
      else engine = "refuse" end
      local subject = SDP_Overlay.Subject(CANAL, p.X, p.Y)
      local ok, item = pcall(function()
        return SDP_Overlay.With(pid, SDP_Overlay.Evaluate, { subject }, {}, WEIGHTS).Placements[1]
      end)
      local ours, refusedBy = "error", "error"
      if ok and item ~= nil then
        ours = item.CanPlace == true and "allow" or "refuse"
        if item.EngineRefused == true then refusedBy = "engine"
        elseif item.CanPlace ~= true then refusedBy = "dmt"
        else refusedBy = "none" end
      end
      local sides = SDP_City.CanalSides(plot)
      local link = SDP_City.CanalSidesJoin(sides)
      local cannot = SDP_City.CanalCannotLink(CANAL, plot, sides)
      local dmtOk, dmtCan = pcall(CanPlacePin, pid, subject)
      local dmt = dmtOk and (dmtCan == true and "allow" or "refuse") or "error"
      local rule = "na"
      if terrains ~= nil then rule = cannot and "refuse" or "allow" end
      local ownerText = owner == -1 and "-" or tostring(owner)
      if purchase ~= nil then ownerText = ownerText .. ":" .. purchase:GetID() end
      print(string.format("%d,%d,%d,%d,%s,%d,%s,%s,%d,%s,%d,%d,%d,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s",
        p.X, p.Y, city:GetID(), p.Ring, Describe(plot), plot:IsHills() and 1 or 0, Feature(plot),
        District(plot), plot:IsRiver() and 1 or 0, ownerText, adjCity, adjCanal, water,
        #dirs > 0 and table.concat(dirs, ";") or "-", #kinds > 0 and table.concat(kinds, ";") or "-",
        engine, ours, refusedBy, link and "1" or "0", cannot and "1" or "0",
        #cityDirs > 0 and table.concat(cityDirs, ";") or "-",
        #canalDirs > 0 and table.concat(canalDirs, ";") or "-", dmt, rule,
        #bodyDirs > 0 and table.concat(bodyDirs, ";") or "-"))
      if (engine == "allow" or engine == "refuse") and rule ~= "na"
          and (rule == "allow") ~= (engine == "allow") then
        print(string.format("# MISMATCH %d,%d engine %s rule %s dmt %s", p.X, p.Y, engine, rule, dmt))
        for y = p.Y + 2, p.Y - 2, -1 do
          local line = ""
          for x = p.X - 2, p.X + 2 do
            local q = Map.GetPlot(x, y)
            local c = "?"
            if q ~= nil then
              c = "."
              if q:IsWater() then c = q:IsLake() and "L" or "~" end
              if q:IsHills() then c = "h" end
              local index = q:GetDistrictType()
              if index ~= nil and index ~= -1 then
                local row = GameInfo.Districts[index]
                c = (row ~= nil and SDP_Rules.IsCanal(row.DistrictType)) and "K" or "D"
              end
              if q:IsCity() then c = "C" end
              if x == p.X and y == p.Y then c = "*" end
            end
            line = line .. c
          end
          print("#   " .. line)
        end
      end
      rows = rows + 1
      tally.plots = tally.plots + 1
      if owned then ownedRows = ownedRows + 1 end
      if engine == "allow" then tally.engineAllow = tally.engineAllow + 1 end
      if engine == "refuse" then tally.engineRefuse = tally.engineRefuse + 1 end
      if engine == "nolist" then tally.noList = tally.noList + 1 end
      if ours == "allow" then tally.oursAllow = tally.oursAllow + 1 end
      if ours == "refuse" then tally.oursRefuse = tally.oursRefuse + 1 end
      if engine == "allow" or engine == "refuse" then
        answeredRows = answeredRows + 1
        local agree = (engine == "allow") == (ours == "allow")
        if agree then tally.agree = tally.agree + 1
        elseif ours == "allow" then
          tally.oursOnly = tally.oursOnly + 1
          tally.missed[#tally.missed + 1] = string.format("%d,%d", p.X, p.Y)
        else
          tally.engineOnly = tally.engineOnly + 1
          tally.killed[#tally.killed + 1] = string.format("%d,%d", p.X, p.Y)
        end
      end
    end
  end
  print(string.format("# city %d land plots %d, owned %d, the engine answered for %d", city:GetID(), rows, ownedRows, answeredRows))
end

local tally = { plots = 0, engineAllow = 0, engineRefuse = 0, noList = 0, oursAllow = 0, oursRefuse = 0,
  agree = 0, oursOnly = 0, engineOnly = 0, missed = {}, killed = {} }

print("# directions " .. Legend())
FillBodies()
print("# water bodies " .. BODIES)
print("x,y,city,ring,terrain,hills,feature,district,river,owner,adj_city,adj_canal,water,water_dir,water_kind,engine,ours,refused_by,link,cannot,city_dir,canal_dir,dmt,rule,water_body")
local cities = 0
for _, city in player:GetCities():Members() do
  cities = cities + 1
  ProbeCity(city, tally)
end
print(string.format("# cities %d land plots %d: engine allow %d refuse %d nolist %d; ours allow %d refuse %d",
  cities, tally.plots, tally.engineAllow, tally.engineRefuse, tally.noList, tally.oursAllow, tally.oursRefuse))
print(string.format("# engine has an answer: agree %d, we allow and it refuses (missed) %d, it allows and we refuse (killed) %d",
  tally.agree, tally.oursOnly, tally.engineOnly))
if tally.oursOnly > 0 then print("# missed: " .. table.concat(tally.missed, " ")) end
if tally.engineOnly > 0 then print("# killed: " .. table.concat(tally.killed, " ")) end
