-- Exports a window of the current game as a scene for the offline
-- comparison (tests/compare/scenes/<id>.json, docs/multicity-design.md
-- section 25): the map, rivers, ownership, built districts and wonders,
-- the local player's techs and map tacks, in the shape CmpGame.New takes
-- (tests/compare/cmp_game.lua), plus what DMT says in the game about every
-- plannable district on every owned plot of the chosen cities, so the
-- offline world can be checked against the game (tools/snapshot.py check).
-- tools/snapshot.py loads this file into the SDP_Panel state and calls
-- SDP_Export.Scene; every chunk of output is one line "SDP_SCENE <kind> <json>".
-- Not a test (no test_ prefix).

SDP_Export = {}
local E = SDP_Export

local function Json(v)
  local t = type(v)
  if t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    return string.format("%.10g", v)
  end
  if t == "string" then
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

local function Emit(kind, t) print("SDP_SCENE " .. kind .. " " .. Json(t)) end

-- Lists in chunks, so no single Tuner line gets too long.
local function EmitList(kind, list, size)
  for first = 1, math.max(#list, 1), size do
    local part = {}
    for i = first, math.min(first + size - 1, #list) do part[#part + 1] = list[i] end
    Emit(kind, { first = first, items = part })
  end
end

local WEIGHTS = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }

-- opts: Cities = { city ID }, Radius = n (6), Sample = bool (true)
function E.Scene(opts)
  opts = opts or {}
  local radius = opts.Radius or 6
  local pid = Game.GetLocalPlayer()
  local W, H = Map.GetGridSize()
  local player = Players[pid]

  -- The chosen cities (default: all of the local player's).
  local chosen, chosenSet = {}, {}
  for _, city in player:GetCities():Members() do
    if opts.Cities == nil or opts.Cities[city:GetID()] then
      chosen[#chosen + 1] = city
      chosenSet[city:GetID()] = true
    end
  end
  table.sort(chosen, function(a, b) return a:GetID() < b:GetID() end)
  if #chosen == 0 then error("no cities") end

  -- X distance with wrapping, from the anchor (the first chosen city).
  local ax = chosen[1]:GetX()
  local function Dx(x)
    local d = (x - ax) % W
    if d > W / 2 then d = d - W end
    return d
  end

  -- The window: every plot within `radius` of a chosen city, and the
  -- centers of the cities owning a plot within 4 (so no plot the plan can
  -- touch or see loses its owner).
  local dxmin, dxmax, ymin, ymax = 0, 0, chosen[1]:GetY(), chosen[1]:GetY()
  local function Grow(x, y)
    local dx = Dx(x)
    if dx < dxmin then dxmin = dx end
    if dx > dxmax then dxmax = dx end
    if y < ymin then ymin = y end
    if y > ymax then ymax = y end
  end
  local near = {}
  for _, city in ipairs(chosen) do
    for _, e in ipairs(SDP_City.PlotsInRange(city:GetX(), city:GetY(), radius)) do
      local plot = Map.GetPlotByIndex(e.Index)
      Grow(plot:GetX(), plot:GetY())
      if e.Ring <= 4 then near[e.Index] = true end
    end
  end
  for index in pairs(near) do
    local plot = Map.GetPlotByIndex(index)
    if plot:GetOwner() ~= -1 then
      local owner = Cities.GetPlotPurchaseCity(plot)
      if owner ~= nil then Grow(owner:GetX(), owner:GetY()) end
    end
  end
  local y0 = ymin
  if y0 % 2 == 1 then y0 = y0 - 1 end -- rows keep their parity (odd-r hexes)
  if y0 < 0 then y0 = 0 end
  local width, height = dxmax - dxmin + 1, ymax - y0 + 1
  if width > W then error("window wider than the map") end
  local x0 = (ax + dxmin) % W

  -- Local coordinates and index of a game plot, or nil outside the window.
  local function Local(plot)
    local lx, ly = (plot:GetX() - x0) % W, plot:GetY() - y0
    if lx >= width or ly < 0 or ly >= height then return nil end
    return lx, ly, ly * width + lx
  end
  local gi = GameInfo
  local visibility = PlayersVisibility[pid]
  local plots, owners, cities, players = {}, {}, {}, {}
  local dropped, cityOf = 0, {}
  local function CityKey(city) return city:GetOwner() .. ":" .. city:GetID() end
  local function Describe(city)
    local key = CityKey(city)
    if cities[key] == nil then
      local lx, ly = Local(Map.GetPlot(city:GetX(), city:GetY()))
      if lx == nil then return nil end
      local buildings = {}
      for b in gi.Buildings() do
        if not b.IsWonder and city:GetBuildings():HasBuilding(b.Index) then buildings[#buildings + 1] = b.BuildingType end
      end
      cities[key] = { id = city:GetID(), owner = city:GetOwner(), x = lx, y = ly, name = Locale.Lookup(city:GetName()),
        population = city:GetPopulation(), capital = city:IsCapital() == true, plots = {}, districts = {},
        buildings = buildings }
      players[city:GetOwner()] = true
    end
    return cities[key]
  end
  local wonders = {}
  for ly = 0, height - 1 do
    for lx = 0, width - 1 do
      local plot = Map.GetPlot((x0 + lx) % W, y0 + ly)
      local entry = { t = gi.Terrains[plot:GetTerrainType()].TerrainType }
      if plot:GetFeatureType() ~= -1 then entry.f = gi.Features[plot:GetFeatureType()].FeatureType end
      if plot:GetResourceType() ~= -1 then
        entry.r = gi.Resources[plot:GetResourceType()].ResourceType
        entry.rc = plot:GetResourceCount()
      end
      if plot:GetImprovementType() ~= -1 then entry.imp = gi.Improvements[plot:GetImprovementType()].ImprovementType end
      if plot:IsLake() then entry.lake = true end
      if not visibility:IsRevealed(plot:GetIndex()) then entry.hidden = true end
      if TerrainManager ~= nil and TerrainManager.GetCoastalLowlandType(plot) ~= -1 then
        entry.low = TerrainManager.GetCoastalLowlandType(plot)
        if TerrainManager.IsFlooded(plot) then entry.flooded = true end
        if TerrainManager.IsSubmerged(plot) then entry.submerged = true end
      end
      plots[#plots + 1] = entry
      local index = ly * width + lx
      if plot:GetOwner() ~= -1 then
        players[plot:GetOwner()] = true
        local city = Cities.GetPlotPurchaseCity(plot)
        local c = city and Describe(city)
        if c == nil then
          dropped = dropped + 1
        else
          cityOf[index] = c
          if not plot:IsCity() then c.plots[#c.plots + 1] = index end
          local dt = plot:GetDistrictType()
          if dt ~= -1 and not plot:IsCity() then
            c.districts[#c.districts + 1] = { type = gi.Districts[dt].DistrictType, x = lx, y = ly }
          end
          local wt = plot:GetWonderType()
          if wt ~= -1 then
            wonders[#wonders + 1] = { x = lx, y = ly, building = gi.Buildings[wt].BuildingType, city = c.id, owner = c.owner }
          end
        end
      end
    end
  end

  -- Rivers: the game's rivers cut to the window, edges as local index pairs.
  local function GlobalToLocal(gindex)
    local plot = Map.GetPlotByIndex(gindex)
    local _, _, index = Local(plot)
    return index
  end
  local rivers, edgeSet = {}, {}
  if RiverManager ~= nil then
    -- Gathering Storm: named rivers with their floodplains.
    for i = 0, RiverManager.GetNumRivers() - 1 do
      local river = RiverManager.GetRiverByIndex(i, "edges")
      local entry = { name = RiverManager.GetRiverNameByType(river.TypeID), edges = {}, floodplains = {} }
      for _, pair in ipairs(river.Edges or {}) do
        local a, b = GlobalToLocal(pair[1]), GlobalToLocal(pair[2])
        if a ~= nil and b ~= nil then
          entry.edges[#entry.edges + 1] = { a, b }
          edgeSet[math.min(a, b) .. "_" .. math.max(a, b)] = true
        end
      end
      for _, gindex in ipairs(RiverManager.GetFloodplainPlots(river.TypeID) or {}) do
        local index = GlobalToLocal(gindex)
        if index ~= nil then entry.floodplains[#entry.floodplains + 1] = index end
      end
      if #entry.edges > 0 then rivers[#rivers + 1] = entry end
    end
  end
  -- Every river crossing the game reports between two window plots must be
  -- one of those edges. Without named rivers (base game, Rise and Fall) the
  -- crossings make one river, with the floodplain features as its plain.
  local riverMissed, anonymous = 0, { name = "river", edges = {}, floodplains = {} }
  for ly = 0, height - 1 do
    for lx = 0, width - 1 do
      local plot = Map.GetPlot((x0 + lx) % W, y0 + ly)
      local index = ly * width + lx
      for direction = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
        local n = Map.GetAdjacentPlot(plot:GetX(), plot:GetY(), direction)
        if n ~= nil then
          local _, _, ni = Local(n)
          if ni ~= nil and ni > index and plot:IsRiverCrossingToPlot(n)
              and not edgeSet[index .. "_" .. ni] then
            if RiverManager ~= nil then
              riverMissed = riverMissed + 1
            else
              anonymous.edges[#anonymous.edges + 1] = { index, ni }
            end
          end
        end
      end
      if RiverManager == nil and plot:GetFeatureType() ~= -1
          and gi.Features[plot:GetFeatureType()].FeatureType:match("^FEATURE_FLOODPLAINS") then
        anonymous.floodplains[#anonymous.floodplains + 1] = index
      end
    end
  end
  if #anonymous.edges > 0 then rivers[#rivers + 1] = anonymous end

  -- Players: the local player as 0 with its techs, civics and pantheon;
  -- the others with everything (only the local player's matter).
  players[pid] = true
  local playerList = {}
  local function Pid(id) if id == pid then return 0 elseif id == 0 then return pid else return id end end
  for id in pairs(players) do
    local cfg = PlayerConfigurations[id]
    local p = { id = Pid(id), civ = cfg:GetCivilizationTypeName(), leader = cfg:GetLeaderTypeName(),
      minor = Players[id]:IsMajor() ~= true }
    if id == pid then
      local techs, civics = {}, {}
      for t in gi.Technologies() do
        if player:GetTechs():HasTech(t.Index) then techs[#techs + 1] = t.TechnologyType end
      end
      for c in gi.Civics() do
        if player:GetCulture():HasCivic(c.Index) then civics[#civics + 1] = c.CivicType end
      end
      p.techs, p.civics = techs, civics
      local pantheon = player:GetReligion():GetPantheon()
      if pantheon ~= nil and pantheon >= 0 then p.pantheon = gi.Beliefs[pantheon].BeliefType end
    else
      p.techs, p.civics = "all", "all"
    end
    playerList[#playerList + 1] = p
  end
  table.sort(playerList, function(a, b) return a.id < b.id end)
  local cityList = {}
  for _, c in pairs(cities) do
    c.owner = Pid(c.owner)
    cityList[#cityList + 1] = c
  end
  table.sort(cityList, function(a, b) return a.owner < b.owner or (a.owner == b.owner and a.id < b.id) end)
  for _, wd in ipairs(wonders) do wd.owner = Pid(wd.owner) end

  -- The local player's map tacks in the window.
  local pins = {}
  for _, pin in ipairs(PlayerConfigurations[pid]:GetMapPins()) do
    local plot = Map.GetPlot(pin:GetHexX(), pin:GetHexY())
    local lx, ly = nil, nil
    if plot ~= nil then lx, ly = Local(plot) end -- not "plot and Local(plot)": that keeps one value
    if lx ~= nil then pins[#pins + 1] = { x = lx, y = ly, icon = pin:GetIconName(), name = pin:GetName() } end
  end

  -- Checks for the loader: each chosen city's rings as local indices.
  local rings = {}
  for _, city in ipairs(chosen) do
    local entry = { city = city:GetID(), rings = {} }
    for _, e in ipairs(SDP_City.PlotsInRange(city:GetX(), city:GetY(), 3)) do
      local _, _, index = Local(Map.GetPlotByIndex(e.Index))
      entry.rings[#entry.rings + 1] = { index, e.Ring }
    end
    rings[#rings + 1] = entry
  end

  Emit("head", {
    width = width, height = height, turn = Game.GetCurrentGameTurn(),
    ruleset = GameConfiguration.GetValue("RULESET"),
    meta = { mapWidth = W, mapHeight = H, x0 = x0, y0 = y0, radius = radius, localPlayer = pid,
      droppedOwned = dropped, riverMissed = riverMissed, chosen = (function()
        local ids = {}
        for _, c in ipairs(chosen) do ids[#ids + 1] = c:GetID() end
        return ids
      end)() },
    rivers = rivers, players = playerList, wonders = wonders, pins = pins, rings = rings,
  })
  EmitList("plots", plots, 200)
  EmitList("cities", cityList, 20)

  -- What DMT says in the game: every plannable district on every plot the
  -- chosen cities own within 3 rings.
  if opts.Sample ~= false then
    local sample = {}
    local districts = SDP_Rules.PlannableDistricts(pid)
    for _, city in ipairs(chosen) do
      for _, e in ipairs(SDP_City.PlotsInRange(city:GetX(), city:GetY(), 3)) do
        local plot = Map.GetPlotByIndex(e.Index)
        local _, _, index = Local(plot)
        local owner = plot:GetOwner() == pid and Cities.GetPlotPurchaseCity(plot) or nil
        if owner ~= nil and owner:GetID() == city:GetID() and not plot:IsCity() then
          for _, d in ipairs(districts) do
            local item = SDP_Overlay.With(pid, SDP_Overlay.Evaluate,
              { SDP_Overlay.Subject(d.Type, plot:GetX(), plot:GetY()) }, {}, WEIGHTS).Placements[1]
            local yields = {}
            for k, v in pairs(item.Yields or {}) do if v ~= 0 then yields[k] = v end end
            sample[#sample + 1] = { c = city:GetID(), d = d.Type, i = index, can = item.CanPlace == true,
              engine = item.EngineRefused == true or nil, y = yields }
          end
        end
      end
    end
    EmitList("sample", sample, 100)
  end
  Emit("end", { plots = #plots, cities = #cityList, rivers = #rivers })
end
