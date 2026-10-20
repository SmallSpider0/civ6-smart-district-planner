-- SDP_Multi: districts for several cities at once (docs/multicity-design.md
-- section 4): the planned cities (city-center map pins) and the existing
-- cities near them.
--
--   Participants  every city-center pin that is not a city yet, plus the
--                 player's cities within NEAR plots of one (default; each
--                 can be switched), at most MAX_CITIES, nearest first.
--   Plots         each city's three rings as SDP_City sees them; a new city
--                 cannot use plots of existing cities. Plots two cities can
--                 reach may go to either, one subject per plot.
--   Slots         (city, district) for every city's plan. A district with an
--                 empire limit (government plaza) gets the slots the limit
--                 leaves, each allowed in every city that plans it.
--   Objective     SDP_Board's exact DMT gain over all fixed subjects of all
--                 participants, plus each city's land part; a plot two
--                 cities could work counts for the nearer one.
--   Search        a start plans city by city (SDP_Search.SolveBlock with the
--                 cities before it fixed), then local search over everything,
--                 block rounds (each city re-solved with the others fixed)
--                 and kicks. Starts differ in city order (in order, reversed,
--                 rotations). Starting from the city-by-city plan and only
--                 accepting improvements, the result is never worse than
--                 planning the cities one after another (design 4.7).
-- Budgets are counts (SDP_Tiers.Multi), all loops over sorted arrays, ties
-- to smaller plot indices: same input, same result (constraint 6).
-- The overlay must be installed while a session computes.

SDP_Multi = {}

SDP_Multi.MAX_CITIES = 8 -- participants, new and existing
SDP_Multi.NEAR = 7       -- existing cities this close to a new city take part by default

local Copy = SDP_Search.Copy

local function DefaultWeights(weights)
  local out = {}
  for _, yieldType in ipairs(SDP_Rules.YIELDS) do
    local w = weights and weights[yieldType]
    out[yieldType] = (w == nil) and 1 or w
  end
  return out
end

-- The player's city-center map pins that are not cities yet, sorted by plot
-- index: { X, Y, Index, Name, PinID }. A pin is a city center when DMT reads
-- it as one (CreateMapPinSubject: the city center icon, or DMT's own
-- convention for goody hut / barbarian icons named "City...").
function SDP_Multi.Sites(playerID)
  local list = {}
  for _, pin in pairs(PlayerConfigurations[playerID]:GetMapPins()) do
    local subject = CreateMapPinSubject(pin)
    if subject ~= nil and subject.Type == "DISTRICT" and subject.Key == "DISTRICT_CITY_CENTER" then
      local x, y = pin:GetHexX(), pin:GetHexY()
      local plot = Map.GetPlot(x, y)
      if plot ~= nil and not plot:IsCity() then
        list[#list + 1] = { X = x, Y = y, Index = plot:GetIndex(), Name = pin:GetName() or "", PinID = pin:GetID() }
      end
    end
  end
  table.sort(list, function(a, b) return a.Index < b.Index end)
  return list
end

-- Who takes part. options.Existing = { [cityID] = true | false } overrides
-- the default (within NEAR of a new city). options.Only = { [cityID] = true }:
-- exactly these cities and no new ones (the single-city tab with wonders). Returns the participants (new
-- cities by plot index, then existing cities by ID) and every existing city
-- with { CityID, Name, Distance, Default, On, Included, Reason }:
-- Reason "CAP" when switched on but beyond MAX_CITIES.
function SDP_Multi.Participants(playerID, options)
  options = options or {}
  local participants = {}
  local sites = options.Only and {} or SDP_Multi.Sites(playerID)
  local names = {}
  for s, site in ipairs(sites) do names[s] = site.Name end
  local siteNumbers = SDP_City.SiteNumbers(playerID, names)
  local cityNumbers = SDP_City.CityNumbers(playerID)
  for s, site in ipairs(sites) do
    participants[#participants + 1] = {
      Kind = "SITE", Key = "S" .. site.Index, X = site.X, Y = site.Y, Index = site.Index,
      Name = site.Name, SiteNumber = s, Number = siteNumbers[s], PinID = site.PinID,
    }
  end
  local cities = {}
  for _, city in Players[playerID]:GetCities():Members() do cities[#cities + 1] = city end
  table.sort(cities, function(a, b) return a:GetID() < b:GetID() end)
  local existing = {}
  for _, city in ipairs(cities) do
    local distance = math.huge
    for _, site in ipairs(sites) do
      distance = math.min(distance, Map.GetPlotDistance(city:GetX(), city:GetY(), site.X, site.Y))
    end
    local default = distance <= SDP_Multi.NEAR
    local on = options.Existing and options.Existing[city:GetID()]
    if on == nil then on = default end
    if options.Only then on = options.Only[city:GetID()] == true end
    existing[#existing + 1] = {
      CityID = city:GetID(), Name = city:GetName(), X = city:GetX(), Y = city:GetY(),
      Distance = distance, Default = default, On = on, Included = false,
    }
  end
  local wanted = {}
  for _, e in ipairs(existing) do
    if e.On then wanted[#wanted + 1] = e end
  end
  table.sort(wanted, function(a, b)
    if a.Distance ~= b.Distance then return a.Distance < b.Distance end
    return a.CityID < b.CityID
  end)
  local room = SDP_Multi.MAX_CITIES - #participants
  for _, e in ipairs(wanted) do
    if room > 0 then
      e.Included, room = true, room - 1
    else
      e.Reason = "CAP"
    end
  end
  for _, e in ipairs(existing) do
    if e.Included then
      participants[#participants + 1] = {
        Kind = "CITY", Key = "C" .. e.CityID, CityID = e.CityID, X = e.X, Y = e.Y, Name = e.Name,
        Number = cityNumbers[e.CityID], Index = Map.GetPlotIndex(e.X, e.Y),
      }
    end
  end
  return participants, existing
end

-- ===========================================================================
-- Session
-- ===========================================================================
local Session = {}
Session.__index = Session

-- Districts of the player's type with an icon pin within a scan's range.
local function PinnedDistricts(scan)
  local pinned = {}
  for _, pin in ipairs(scan.Pins) do
    local key = (pin.Icon or ""):gsub("^ICON_", "")
    pinned[key] = true
  end
  return pinned
end

-- Request = {
--   PlayerID, Tier, Params (overrides, tests)
--   Districts            default plan of every new city, and of existing cities
--                        minus what they have built or pinned already
--   Plans                { [participant Key] = { district types } } overrides
--   Wonders              wonder types (building types) to place, in any participating city
--   Existing             { [cityID] = bool } who else takes part (see Participants)
--   Only                 { [cityID] = true }: exactly these cities (see Participants)
--   Weights              as for SDP_Solver (five yields; YIELD_FOOD, FEATURE for land)
--   Land                 count the land part (default true)
--   AllowFeatureRemoval  default true
--   IgnorePins           this mod's earlier pins being replaced (see SDP_Solver)
-- }
-- The overlay must be installed.
function SDP_Multi.NewSession(request)
  local self = setmetatable({}, Session)
  SDP_Overlay.HidePins(request.IgnorePins)
  local playerID = request.PlayerID
  local params = SDP_Tiers.Params(SDP_Tiers.Multi, request.Tier, request.Params)
  self.Request, self.Params, self.PlayerID = request, params, playerID
  self.Weights = DefaultWeights(request.Weights)
  local land = request.Land ~= false
  local options = SDP_City.ScanOptions(request)

  local participants, existing = SDP_Multi.Participants(playerID, { Existing = request.Existing, Only = request.Only })
  self.Participants, self.Existing = participants, existing

  -- Plans, scans.
  local plannable, byType = SDP_Rules.PlannableDistricts(playerID), {}
  for _, d in ipairs(plannable) do byType[d.Type] = d end
  local unplaced = {}
  for _, part in ipairs(participants) do
    local wanted = (request.Plans and request.Plans[part.Key]) or request.Districts or {}
    local specialty = 0
    for _, districtType in ipairs(wanted) do
      if byType[districtType] and byType[districtType].Specialty then specialty = specialty + 1 end
    end
    if part.Kind == "SITE" then
      part.Scan = SDP_City.ScanSite(playerID, part.X, part.Y, {
        allowFeatureRemoval = options.allowFeatureRemoval, ignorePins = options.ignorePins, name = part.Name,
        population = SDP_Land.RequiredPopulation(specialty),
      })
    else
      part.Scan = SDP_City.Scan(playerID, part.CityID, options)
    end
    local status = SDP_City.DistrictStatus(part.Scan, plannable)
    local pinned = (part.Kind == "CITY" and not (request.Plans and request.Plans[part.Key])) and PinnedDistricts(part.Scan) or {}
    local plan, seen = {}, {}
    for _, districtType in ipairs(wanted) do
      if not seen[districtType] then
        seen[districtType] = true
        if not byType[districtType] then
          unplaced[#unplaced + 1] = { City = part.Key, Type = districtType, Reason = "NOT_AVAILABLE" }
        elseif status[districtType] then
          -- Existing cities skip what they have built; new cities have built nothing.
          if part.Kind == "SITE" or (request.Plans and request.Plans[part.Key]) then
            unplaced[#unplaced + 1] = { City = part.Key, Type = districtType, Reason = status[districtType] }
          end
        elseif not pinned[districtType] then
          plan[#plan + 1] = districtType
        end
      end
    end
    part.Plan = plan
  end
  self.Unplaced = unplaced

  -- One candidate list for everybody.
  local candidates, at = {}, {}
  for _, part in ipairs(participants) do
    for _, c in ipairs(part.Scan.Candidates) do
      if at[c.Index] == nil then
        at[c.Index] = true
        candidates[#candidates + 1] = { Index = c.Index, X = c.X, Y = c.Y }
      end
    end
  end
  table.sort(candidates, function(a, b) return a.Index < b.Index end)
  local position = {}
  for i, c in ipairs(candidates) do position[c.Index] = i end
  for _, part in ipairs(participants) do
    local allowed = {}
    for _, c in ipairs(part.Scan.Candidates) do allowed[position[c.Index]] = true end
    part.Allowed = allowed
  end
  self.Candidates = candidates

  -- Fixed subjects of every participant, once each.
  local fixed, seenPlot = {}, {}
  for _, part in ipairs(participants) do
    for _, subject in ipairs(SDP_Overlay.FixedSubjects(part.Scan)) do
      local index = Map.GetPlotIndex(subject.X, subject.Y)
      if not seenPlot[index] then
        seenPlot[index] = true
        fixed[#fixed + 1] = subject
      end
    end
  end
  table.sort(fixed, function(a, b) return Map.GetPlotIndex(a.X, a.Y) < Map.GetPlotIndex(b.X, b.Y) end)
  self.Fixed = fixed
  self.Base = SDP_Overlay.Evaluate({}, fixed, self.Weights)
  local bases = {}
  for f, item in ipairs(self.Base.Fixed) do bases[f] = item.Score end
  self.Board = SDP_Board.New(playerID, fixed, self.Weights, bases)
  self.ExtraCalls = #fixed

  -- Land part per city; a plot several cities could work goes to the nearest.
  local lands = {}
  if land then
    local owner = {}
    for p, part in ipairs(participants) do
      for _, index in ipairs(SDP_Land.Workable(part.Scan)) do
        local plot = Map.GetPlotByIndex(index)
        local d = Map.GetPlotDistance(part.X, part.Y, plot:GetX(), plot:GetY())
        local current = owner[index]
        if current == nil or d < current.Distance then owner[index] = { Part = p, Distance = d } end
      end
    end
    for p, part in ipairs(participants) do
      local specialty = part.Scan.SpecialtyBuilt
      for _, districtType in ipairs(part.Plan) do
        if byType[districtType].Specialty then specialty = specialty + 1 end
      end
      local population = math.max(part.Kind == "CITY" and part.Scan.Population or 1, SDP_Land.RequiredPopulation(specialty))
      part.Land = SDP_Land.ForScan(part.Scan, fixed, request.Weights, population, function(index)
        return owner[index] ~= nil and owner[index].Part == p
      end)
      lands[#lands + 1] = part.Land
    end
  end

  -- Slots. Districts with an empire limit get the slots the limit leaves.
  local builtByPlayer = {}
  for _, district in Players[playerID]:GetDistricts():Members() do
    local districtType = GameInfo.Districts[district:GetType()].DistrictType
    builtByPlayer[districtType] = (builtByPlayer[districtType] or 0) + 1
  end
  local pinnedAnywhere = {}
  for _, pin in pairs(PlayerConfigurations[playerID]:GetMapPins()) do
    -- Pins being replaced (this mod's earlier ones) do not count.
    if not (options.ignorePins and options.ignorePins[pin:GetID()]) then
      local key = (pin:GetIconName() or ""):gsub("^ICON_", "")
      pinnedAnywhere[key] = (pinnedAnywhere[key] or 0) + 1
    end
  end
  local slots, slotCity, limited, limitedOrder = {}, {}, {}, {}
  for p, part in ipairs(participants) do
    for _, districtType in ipairs(part.Plan) do
      local row = byType[districtType]
      if row.MaxPerPlayer and row.MaxPerPlayer > 0 then
        if limited[districtType] == nil then
          limited[districtType] = {}
          limitedOrder[#limitedOrder + 1] = districtType
        end
        local list = limited[districtType]
        list[#list + 1] = p
      else
        slots[#slots + 1] = { Key = districtType, Type = "DISTRICT", Group = p, Allowed = part.Allowed }
        slotCity[#slots] = p
      end
    end
  end
  for _, districtType in ipairs(limitedOrder) do
    local parts = limited[districtType]
    local left = byType[districtType].MaxPerPlayer - (builtByPlayer[districtType] or 0) - (pinnedAnywhere[districtType] or 0)
    local allowed = {}
    for _, p in ipairs(parts) do
      for i in pairs(participants[p].Allowed) do allowed[i] = true end
    end
    for n = 1, #parts do
      if n <= left then
        slots[#slots + 1] = { Key = districtType, Type = "DISTRICT", Group = parts[1], Allowed = allowed, Limited = true }
        slotCity[#slots] = parts[1]
      else
        unplaced[#unplaced + 1] = { City = participants[parts[n]].Key, Type = districtType, Reason = "MAX_PER_PLAYER" }
      end
    end
  end

  -- Wonders: one slot each, anywhere in the participating cities, placed
  -- after the districts (design 4.4). Built or pinned ones are left out.
  local wonderGroup = #participants + 1
  self.WonderGroup = wonderGroup
  if request.Wonders and #request.Wonders > 0 then
    local list, byWonder = SDP_Wonders.List(playerID), {}
    for _, w in ipairs(list) do byWonder[w.Type] = w end
    local everywhere = {}
    for _, part in ipairs(participants) do
      for i in pairs(part.Allowed) do everywhere[i] = true end
    end
    -- District types present or planned (a unique district counts as the one it replaces).
    local present = {}
    local function Mark(districtType)
      present[districtType] = true
      local replaces = GameInfo.DistrictReplaces[districtType]
      if replaces then present[replaces.ReplacesDistrictType] = true end
    end
    for _, part in ipairs(participants) do
      for _, districtType in ipairs(part.Plan) do Mark(districtType) end
    end
    for _, subject in ipairs(fixed) do
      if subject.Type == "DISTRICT" then Mark(subject.Key) end
    end
    local seenWonder = {}
    for _, wonderType in ipairs(request.Wonders) do
      local w = byWonder[wonderType]
      if not seenWonder[wonderType] then
        seenWonder[wonderType] = true
        if w == nil then
          unplaced[#unplaced + 1] = { City = "WONDERS", Type = wonderType, Reason = "NOT_AVAILABLE" }
        elseif w.Status ~= nil then
          unplaced[#unplaced + 1] = { City = "WONDERS", Type = wonderType, Reason = w.Status }
        elseif w.AdjacentDistrict ~= nil and not present[w.AdjacentDistrict] then
          unplaced[#unplaced + 1] = { City = "WONDERS", Type = wonderType, Reason = "NEEDS_DISTRICT", District = w.AdjacentDistrict }
        else
          slots[#slots + 1] = { Key = wonderType, Type = "WONDER", Group = wonderGroup, Allowed = everywhere,
            Requires = w.AdjacentDistrict, Wonder = true }
          slotCity[#slots] = nil
        end
      end
    end
  end

  self.Search = SDP_Search.New({
    PlayerID = playerID, Board = self.Board, Weights = self.Weights, Params = params,
    Candidates = candidates, Slots = slots, Lands = lands,
  })
  for _, s in ipairs(self.Search:Singles()) do
    local city = slotCity[s] and participants[slotCity[s]].Key or "WONDERS"
    unplaced[#unplaced + 1] = { City = city, Type = slots[s].Key, Reason = "NO_LEGAL_PLOT" }
  end
  self.SlotSpecs = slots
  -- Blocks: the search's slots of each participant, then the wonders.
  local blocks = {}
  for p = 1, wonderGroup do blocks[p] = {} end
  for m = 1, self.Search.K do
    local p = self.Search.Groups[m]
    blocks[p][#blocks[p] + 1] = m
  end
  self.Blocks = blocks
  self.Stats = self.Search.Stats
  self.Stats.Cities = #participants
  self.Starts = {}
  self.NextStartIndex = 1
  return self
end

-- The starts, a fixed portfolio (constraint 6): which order the cities are
-- planned in and how wide the model beam is for that start. Different beam
-- widths lead the city-by-city plan into different shapes (a narrow beam
-- once found the plan that merges three cities' districts into one
-- cluster); the joint start plans every city in one beam.
--   1 city by city, full beam (the "never worse" reference)
--   2 joint
--   3 city by city, a third of the beam
--   4 reversed, full beam        5 reversed, a third of the beam
--   6+ rotations, alternating full and a third of the beam
function Session:StartPlan(s)
  local count = #self.Participants
  local order, scale = {}, 1
  if s <= 3 then
    for p = 1, count do order[p] = p end
    if s == 3 then scale = 1 / 3 end
  elseif s <= 5 then
    for p = 1, count do order[p] = count - p + 1 end
    if s == 5 then scale = 1 / 3 end
  else
    local shift = math.floor((s - 4) / 2) % math.max(1, count)
    for p = 1, count do order[p] = (p - 1 + shift) % count + 1 end
    if s % 2 == 1 then scale = 1 / 3 end
  end
  order[#order + 1] = self.WonderGroup
  return order, scale
end

-- Place the slots of a block one by one, each on its best free plot (when
-- not all of them fit together).
function Session:Greedy(block, layout)
  local search = self.Search
  layout = Copy(layout)
  for _, m in ipairs(block) do
    local used = {}
    for mm = 1, search.K do
      if layout[mm] ~= 0 then used[layout[mm]] = true end
    end
    local bestI, bestGain = nil, nil
    for i = 1, search.N do
      if search.Legal[m][i] and not used[i] then
        layout[m] = i
        local gain, legal = search:Evaluate(layout)
        if legal and (bestI == nil or gain > bestGain) then bestI, bestGain = i, gain end
      end
    end
    layout[m] = bestI or 0
  end
  return layout
end

-- One start, then local search and block rounds. Returns its layout.
-- Start 2 is joint: one model beam over every city's districts at once, so
-- that clusters can merge across cities (districts of two cities next to
-- each other give each other adjacency), then the wonders. The others go
-- city by city, each with the cities before it fixed.
function Session:RunStart(s)
  local search, params = self.Search, self.Params
  local order, scale = self:StartPlan(s)
  local beam = params.Beam
  params.Beam = math.max(10, math.floor(beam * scale))
  local layout = search:EmptyLayout()
  if s == 2 then
    local districts = {}
    for p = 1, #self.Participants do
      for _, m in ipairs(self.Blocks[p]) do districts[#districts + 1] = m end
    end
    if #districts > 0 and not search:OverBudget() then
      local ranked = search:Shortlist(districts, layout)
      if ranked[1] ~= nil then layout = Copy(ranked[1].Layout) end
    end
    for _, p in ipairs(order) do
      local block = self.Blocks[p]
      local missing = {}
      for _, m in ipairs(block) do
        if layout[m] == 0 then missing[#missing + 1] = m end
      end
      if #missing > 0 and not search:OverBudget() then
        local best = search:SolveBlock(missing, layout)
        layout = best or self:Greedy(missing, layout)
      end
    end
  else
    for _, p in ipairs(order) do
      local block = self.Blocks[p]
      if #block > 0 and not search:OverBudget() then
        local best = search:SolveBlock(block, layout)
        layout = best or self:Greedy(block, layout)
      end
    end
  end
  local gain, legal = search:Evaluate(layout)
  search:Consider(gain, legal, layout)
  if self.First == nil then self.First = { Layout = Copy(layout), Gain = gain } end
  layout, gain = search:LocalSearch(layout, gain)
  local placed = SDP_Search.Placed(layout)
  for _ = 1, params.Rounds do
    local improved = false
    for _, p in ipairs(order) do
      local block = self.Blocks[p]
      if #block > 0 and not search:OverBudget() then
        local base = Copy(layout)
        for _, m in ipairs(block) do base[m] = 0 end
        local trial, trialGain = search:SolveBlock(block, base)
        if trial ~= nil and SDP_Search.Placed(trial) >= placed and trialGain > gain then
          layout, gain, improved = trial, trialGain, true
          search:Consider(gain, true, layout)
        end
      end
    end
    if not improved then break end
    layout, gain = search:LocalSearch(layout, gain)
  end
  params.Beam = beam
  self.Starts[#self.Starts + 1] = { Layout = layout, Gain = gain, Order = order }
  return layout, gain
end

-- First run: Params.Starts starts, then the kicks.
-- The starts of a lighter tier (Params.Prelude), with that tier's search
-- parameters, before a tier's own: a start depends only on the input and its
-- parameters, so the tier then ends at least as high as the lighter tier's
-- starts. Without it the different search paths let FAST beat STANDARD on a
-- map (offline benchmark, 2026-10-20). The board's memo keeps them cheap in
-- DMT calls. They have budgets of their own: the tier's starts still get all
-- of the tier's budget after them.
local PRELUDE_KEYS = { "ExactLimit", "Beam", "BeamOrder", "Shortlist", "MaxPasses", "Rounds", "Swap", "Pair" }

function Session:RunPrelude(tier)
  local inner = SDP_Tiers.Multi[tier]
  if inner == nil then return end
  if inner.Prelude ~= nil then self:RunPrelude(inner.Prelude) end
  local params, saved = self.Params, {}
  for _, key in ipairs(PRELUDE_KEYS) do
    saved[key] = params[key]
    params[key] = inner[key]
  end
  for s = 1, inner.Starts do
    if self.Search:OverBudget() then break end
    self:RunStart(s)
  end
  for _, key in ipairs(PRELUDE_KEYS) do params[key] = saved[key] end
end

function Session:Run()
  local search, params = self.Search, self.Params
  search:SetBudgets()
  if search.K == 0 then return end
  search.Stats.Method = "multi"
  if params.Prelude ~= nil then
    self:RunPrelude(params.Prelude)
    search:SetBudgets() -- the tier's own starts get its whole budget
  end
  for _ = 1, params.Starts do
    if search:OverBudget() then break end
    self:RunStart(self.NextStartIndex)
    self.NextStartIndex = self.NextStartIndex + 1
  end
  search:Kicks(params.Kicks or 0)
  self:Repair()
end

-- A requested slot the best layout left off with a legal plot somewhere: a
-- wonder that must be next to a district whose neighbours all went to other
-- districts (the Great Library around a clustered campus), or a slot whose
-- plots the others took. What the player asks for is placed whenever it fits
-- (design goal G4), so try the slot on its plots, best single value first:
-- the slot on that plot, and placed again around it whatever stood there,
-- the districts the slot must touch and, for a wonder, the other wonders
-- (they compete for the same terrain: the Colossus and the Great Lighthouse
-- for the coast by the harbor). Consider keeps a layout with more slots
-- placed even at a lower value. The repair has its own budget, a quarter of
-- the tier's, so it also runs after a search that used up its own; the first
-- plot that works ends the slot's repair.

local function Serves(slotType, required)
  if slotType == required then return true end
  local row = GameInfo.DistrictReplaces[slotType]
  return row ~= nil and row.ReplacesDistrictType == required
end

function Session:Repair()
  local search, params = self.Search, self.Params
  if search.BestLayout == nil or SDP_Search.Placed(search.BestLayout) == search.K then return end
  local callCap, tryCap = search.CallCap, search.TryCap
  search.CallCap = search.Board.Calls + math.ceil(params.CallLimit / 4)
  search.TryCap = search.Stats.Tries + math.ceil(params.TryLimit / 4)
  for m = 1, search.K do
    if search.BestLayout[m] == 0 and not search:OverBudget() then
      local spec = self.SlotSpecs[search.SlotIndex[m]]
      local single, plots = search.Single[m], {}
      for i = 1, search.N do
        if search.Legal[m][i] then plots[#plots + 1] = i end
      end
      table.sort(plots, function(a, b)
        if single[a] ~= single[b] then return single[a] > single[b] end
        return a < b
      end)
      for _, i in ipairs(plots) do
        if search:OverBudget() then break end
        local base, block = Copy(search.BestLayout), {}
        for mm = 1, search.K do
          local other = self.SlotSpecs[search.SlotIndex[mm]]
          if mm ~= m and (base[mm] == i or (spec.Wonder and other.Wonder)
              or (spec.Requires ~= nil and Serves(search.Types[mm], spec.Requires))) then
            block[#block + 1] = mm
            base[mm] = 0
          end
        end
        base[m] = i
        local trial, gain
        if #block > 0 then
          trial, gain = search:SolveBlock(block, base)
        else
          local value, legal = search:Evaluate(base)
          if legal then trial, gain = base, value end
        end
        if trial ~= nil and SDP_Search.Placed(trial) > search.BestPlaced and search:Consider(gain, true, trial) then
          search:LocalSearch(trial, gain)
          break
        end
      end
    end
  end
  search.CallCap, search.TryCap = callCap, tryCap
end

function Session:CanContinue()
  return self.Search.K > 0
end

-- One more batch: as many new starts as the tier runs, then kicks.
function Session:Continue()
  local search, params = self.Search, self.Params
  if not self:CanContinue() then return false end
  SDP_Overlay.HidePins(self.Request.IgnorePins) -- a new install has the full pin data
  search:SetBudgets()
  local before = search.BestGain
  search.Stats.Continues = search.Stats.Continues + 1
  for _ = 1, params.Starts do
    if search:OverBudget() then break end
    self:RunStart(self.NextStartIndex)
    self.NextStartIndex = self.NextStartIndex + 1
  end
  search:Kicks(params.Kicks or 0)
  self:Repair()
  search.Converged = before ~= nil and search.BestGain == before
  return true
end

-- The participant a placed slot belongs to: its city, or for a slot with an
-- empire limit the first planning city whose rings hold the plot.
function Session:OwnerOf(m, i)
  local spec = self.SlotSpecs[self.Search.SlotIndex[m]]
  if spec.Wonder then
    for p, part in ipairs(self.Participants) do
      if part.Allowed[i] then return p end
    end
  end
  if not spec.Limited then return spec.Group end
  for p, part in ipairs(self.Participants) do
    if part.Allowed[i] and part.Plan then
      for _, districtType in ipairs(part.Plan) do
        if districtType == spec.Key then return p end
      end
    end
  end
  return spec.Group
end

-- Up to `count` layouts that differ enough (design 4.5): the best one and
-- each start's result, best first; a layout is kept when it differs from
-- every kept one in at least max(2, 20% of the slots) positions.
function Session:Distinct(count)
  local search = self.Search
  local pool = {}
  if search.BestLayout ~= nil then pool[1] = { Layout = search.BestLayout, Gain = search.BestGain } end
  for _, start in ipairs(self.Starts) do pool[#pool + 1] = { Layout = start.Layout, Gain = start.Gain } end
  for _, entry in ipairs(pool) do entry.Placed = SDP_Search.Placed(entry.Layout) end
  table.sort(pool, function(a, b)
    if a.Placed ~= b.Placed then return a.Placed > b.Placed end
    return SDP_Search.Better(a.Gain, a.Layout, b.Gain, b.Layout)
  end)
  local need = math.max(2, math.ceil(0.2 * search.K))
  local kept = {}
  for _, entry in ipairs(pool) do
    if #kept >= count then break end
    local distinct = true
    for _, other in ipairs(kept) do
      local diff = 0
      for m = 1, search.K do
        if entry.Layout[m] ~= other.Layout[m] then diff = diff + 1 end
      end
      if diff < need then distinct = false end
    end
    if distinct then kept[#kept + 1] = entry end
  end
  return kept
end

-- Plan, values and neighbours of one layout, with DMT's yields and tooltips.
-- The board must be clear.
function Session:PlanFor(layout)
  local search, base = self.Search, self.Base
  local out = { Plan = {}, Unplaced = {}, Neighbours = {}, Cities = {} }
  for p, part in ipairs(self.Participants) do
    out.Cities[p] = {
      Key = part.Key, Kind = part.Kind, Name = part.Name, X = part.X, Y = part.Y, CityID = part.CityID,
      SiteNumber = part.SiteNumber, Number = part.Number, Plan = part.Plan, Gain = 0,
    }
  end
  local subjects, slotsPlaced = {}, {}
  for m = 1, search.K do
    if layout[m] ~= 0 then
      subjects[#subjects + 1] = search:Subject(m, layout[m])
      slotsPlaced[#slotsPlaced + 1] = m
    else
      local spec = self.SlotSpecs[search.SlotIndex[m]]
      local city = spec.Wonder and "WONDERS" or self.Participants[spec.Group].Key
      out.Unplaced[#out.Unplaced + 1] = { City = city, Type = spec.Key, Reason = "NO_FREE_PLOT" }
    end
  end
  local final = SDP_Overlay.Evaluate(subjects, self.Fixed, self.Weights)
  self.ExtraCalls = self.ExtraCalls + 2 * #subjects + #self.Fixed
  for n, m in ipairs(slotsPlaced) do
    local i = layout[m]
    local item, c = final.Placements[n], search.Candidates[i]
    local p = self:OwnerOf(m, i)
    out.Plan[n] = {
      City = self.Participants[p].Key, Type = search.Types[m], Kind = search.Kinds[m], X = c.X, Y = c.Y, Index = c.Index,
      Yields = item.Yields, ToolTip = item.ToolTip, Score = item.Score,
    }
    out.Cities[p].Gain = out.Cities[p].Gain + item.Score
  end
  for f, item in ipairs(final.Fixed) do
    if item.Score ~= base.Fixed[f].Score then
      out.Neighbours[#out.Neighbours + 1] = {
        Subject = item.Subject, Before = base.Fixed[f].Score, After = item.Score, ToolTip = item.ToolTip,
      }
    end
  end
  out.Adjacency = final.Total - base.Total
  out.LandDelta = search:LandDelta(layout)
  out.Gain = out.Adjacency + out.LandDelta
  out.Total = final.Total
  out.Legal = final.Legal
  return out
end

-- Result: {
--   Ok, Error, Stats, Session, Quality, Existing (every existing city, see Participants)
--   Solutions   up to Params.Solutions distinct plans, best first, each
--               { Gain, Adjacency, LandDelta, Total, Plan, Unplaced, Neighbours, Cities }:
--                 Plan     { City (participant Key), Type, Kind, X, Y, Index, Yields, ToolTip, Score }
--                 Unplaced { City, Type, Reason } (NOT_AVAILABLE, BUILT, PINNED, MAX_PER_PLAYER,
--                          NEEDS_DISTRICT, NO_LEGAL_PLOT, NO_FREE_PLOT; City "WONDERS" for wonders)
--                 Cities   { Key, Kind, Name, X, Y, CityID, SiteNumber, Number (SDP_City city
--                          number, the pins' name), Plan (types asked), Gain }
--   and the best solution's fields copied to the top level (Plan, Gain, ...)
--   Baseline    joint DMT total without any plan
--   FirstGain   value of the city-by-city start (the "never worse" reference)
-- }
function Session:Result()
  local search, board, stats = self.Search, self.Board, self.Stats
  board:Clear()
  local result = {
    Ok = true, Session = self, Existing = self.Existing, Stats = stats, Baseline = self.Base.Total,
    FirstGain = self.First and self.First.Gain or nil, Solutions = {},
    Plan = {}, Unplaced = {}, Neighbours = {}, Cities = {}, Gain = 0, Adjacency = 0, LandDelta = 0, Total = self.Base.Total,
  }
  if search.K > 0 and search.BestLayout == nil then result.Ok, result.Error = false, "NO_LEGAL_LAYOUT" end
  for _, entry in ipairs(self:Distinct(self.Params.Solutions or 3)) do
    local solution = self:PlanFor(entry.Layout)
    for _, u in ipairs(self.Unplaced) do table.insert(solution.Unplaced, 1, u) end
    result.Solutions[#result.Solutions + 1] = solution
  end
  local best = result.Solutions[1]
  if best ~= nil then
    for _, key in ipairs({ "Plan", "Unplaced", "Neighbours", "Cities", "Gain", "Adjacency", "LandDelta", "Total" }) do
      result[key] = best[key]
    end
    stats.Mismatch = (not best.Legal) or math.abs(best.Gain - search.BestGain) > 1e-6 or nil
  else
    for _, u in ipairs(self.Unplaced) do result.Unplaced[#result.Unplaced + 1] = u end
  end
  stats.Calls = board.Calls + self.ExtraCalls
  stats.Hits = board.Hits
  result.Quality = search:Quality(result.Gain)
  result.Quality.CanContinue = self:CanContinue()
  return result
end

-- Expected work in SDP_Tiers units (time estimate, progress bar); rough, it
-- never changes what is computed. About 30 candidate plots per city.
function SDP_Multi.EstimateUnits(cities, districts, wonders, params)
  local slots = cities * districts + wonders
  if slots == 0 then return 0 end
  local n = 30 -- plots a city can use, typically
  local growth = (math.max(2, cities) / 2) ^ SDP_Tiers.MULTI_GROWTH
  local units = (params.Work or 100) * n * slots * growth
  local prelude = params.Prelude and SDP_Tiers.Multi[params.Prelude]
  if prelude ~= nil then units = units + SDP_Multi.EstimateUnits(cities, districts, wonders, prelude) end
  return units
end

-- ===========================================================================
-- Entry points
-- ===========================================================================

-- The solve itself; the overlay must be installed (SDP_Task jobs, tests).
function SDP_Multi.SolveNow(request)
  local session = SDP_Multi.NewSession(request)
  session:Run()
  return session:Result()
end

-- Solve at once with the overlay installed here (tests, small problems).
function SDP_Multi.Solve(request)
  local ok, result = pcall(SDP_Overlay.With, request.PlayerID, SDP_Multi.SolveNow, request)
  if not ok then return { Ok = false, Error = tostring(result) } end
  return result
end

function SDP_Multi.Continue(result)
  local session = result and result.Session
  if session == nil or not session:CanContinue() then return result end
  local ok, out = pcall(SDP_Overlay.With, session.PlayerID, function()
    session:Continue()
    return session:Result()
  end)
  if not ok then return { Ok = false, Error = tostring(out) } end
  return out
end
