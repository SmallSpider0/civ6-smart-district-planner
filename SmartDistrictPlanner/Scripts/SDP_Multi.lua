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
--                 empire limit (government plaza) goes to the first cities
--                 that ask for it, as many as the limit leaves; the others
--                 take a candidate instead (issue 28).
--   Objective     SDP_Board's exact DMT gain over all fixed subjects of all
--                 participants, plus each city's land part (a plot two
--                 cities could work counts for the nearer one), plus, when
--                 asked for, the coverage part (SDP_Coverage, design 19).
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
SDP_Multi.DEFAULT_CITIES = 4 -- the Several cities tab's default group (DefaultGroup, issue 63)

local Copy = SDP_Search.Copy

local function DefaultWeights(weights)
  local out = {}
  for _, yieldType in ipairs(SDP_Rules.YIELDS) do
    local w = weights and weights[yieldType]
    out[yieldType] = (w == nil) and 1 or w
  end
  return out
end

-- The planned cities: SDP_City.Sites.
function SDP_Multi.Sites(playerID)
  return SDP_City.Sites(playerID)
end

-- The Several cities tab's default group around a city (issue 63): the
-- player's cities and city-center pins, ordered by distance from the centre
-- (ties: cities first, then by city ID or plot index). Starting from the
-- centre, the nearest one within NEAR plots of a member joins, until
-- DEFAULT_CITIES take part or nobody is that close. centerID: a city of the
-- player; nil or not the player's: the capital (else the first city, else
-- the first city-center pin). Returns { Center = entry or nil, Order =
-- entries, Cities = { [cityID] = true }, Sites = { [site Key] = true } };
-- an entry is { Kind = "CITY" | "SITE", Key, CityID, X, Y, Distance }.
function SDP_Multi.DefaultGroup(playerID, centerID)
  local entries = {}
  local player = Players[playerID]
  local capital = player:GetCities():GetCapitalCity()
  local cities = {}
  for _, city in player:GetCities():Members() do cities[#cities + 1] = city end
  table.sort(cities, function(a, b) return a:GetID() < b:GetID() end)
  local center = nil
  for _, city in ipairs(cities) do
    local e = { Kind = "CITY", Key = "C" .. city:GetID(), CityID = city:GetID(), X = city:GetX(), Y = city:GetY(),
      Order = city:GetID() }
    entries[#entries + 1] = e
    if centerID ~= nil and city:GetID() == centerID then center = e end
  end
  if center == nil and capital ~= nil then
    for _, e in ipairs(entries) do
      if e.CityID == capital:GetID() then center = e end
    end
  end
  for _, site in ipairs(SDP_Multi.Sites(playerID)) do
    entries[#entries + 1] = { Kind = "SITE", Key = "S" .. site.Index, X = site.X, Y = site.Y, Order = site.Index }
  end
  if center == nil then center = entries[1] end
  local group = { Center = center, Order = {}, Cities = {}, Sites = {} }
  if center == nil then return group end
  for _, e in ipairs(entries) do
    e.Distance = Map.GetPlotDistance(center.X, center.Y, e.X, e.Y)
    e.Rank = (e == center) and -1 or e.Distance -- the centre first, even with a pin on it
  end
  local order = {}
  for _, e in ipairs(entries) do order[#order + 1] = e end
  table.sort(order, function(a, b)
    if a.Rank ~= b.Rank then return a.Rank < b.Rank end
    if a.Kind ~= b.Kind then return a.Kind == "CITY" end
    return a.Order < b.Order
  end)
  group.Order = order
  local members = { center }
  local taken = { [center.Key] = true }
  while #members < SDP_Multi.DEFAULT_CITIES do
    local found = nil
    for _, e in ipairs(order) do
      if found == nil and not taken[e.Key] then
        for _, m in ipairs(members) do
          if Map.GetPlotDistance(m.X, m.Y, e.X, e.Y) <= SDP_Multi.NEAR then found = e end
        end
      end
    end
    if found == nil then break end
    members[#members + 1] = found
    taken[found.Key] = true
  end
  for _, m in ipairs(members) do
    if m.Kind == "CITY" then group.Cities[m.CityID] = true else group.Sites[m.Key] = true end
  end
  return group
end

-- Who takes part. options.Existing = { [cityID] = true | false } overrides
-- the default (within NEAR of a new city). options.Sites = { [site Key] =
-- false }: city-center pins left out (feedback item 10): no districts are
-- planned for them, they do not count as new cities, and their pins stay
-- fixed neighbours like any pin. options.Only = { [cityID] = true }:
-- exactly these cities and no new ones (the single-city tab with wonders). Returns the participants (new
-- cities by plot index, then existing cities by ID), every existing city
-- with { CityID, Name, Distance, Default, On, Included, Reason } (Reason
-- "CAP" when switched on but beyond MAX_CITIES), and every city-center pin
-- with { Key, X, Y, Name, Number, SiteNumber, Included }.
function SDP_Multi.Participants(playerID, options)
  options = options or {}
  local participants = {}
  local allSites = options.Only and {} or SDP_Multi.Sites(playerID)
  local names = {}
  for s, site in ipairs(allSites) do names[s] = site.Name end
  local siteNumbers = SDP_City.SiteNumbers(playerID, names)
  local cityNumbers = SDP_City.CityNumbers(playerID)
  local sites, siteList = {}, {}
  for s, site in ipairs(allSites) do
    local key = "S" .. site.Index
    local included = not (options.Sites and options.Sites[key] == false)
    siteList[#siteList + 1] = { Key = key, X = site.X, Y = site.Y, Name = site.Name, Number = siteNumbers[s],
      SiteNumber = s, Included = included }
    if included then
      sites[#sites + 1] = site
      participants[#participants + 1] = {
        Kind = "SITE", Key = key, X = site.X, Y = site.Y, Index = site.Index,
        Name = site.Name, SiteNumber = s, Number = siteNumbers[s], PinID = site.PinID,
      }
    end
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
  return participants, existing, siteList
end

-- The city (its name) where the player has built or pinned a district of
-- `districtType`, or nil: where an empire-limited district a wonder needs
-- stands already (issue 66).
function SDP_Multi.WhereBuilt(playerID, districtType)
  local function CityAt(x, y)
    local plot = Map.GetPlot(x, y)
    local city = plot ~= nil and Cities.GetPlotPurchaseCity(plot) or nil
    return city ~= nil and city:GetName() or nil
  end
  for _, district in Players[playerID]:GetDistricts():Members() do
    if GameInfo.Districts[district:GetType()].DistrictType == districtType then
      local name = CityAt(district:GetX(), district:GetY())
      if name ~= nil then return name end
    end
  end
  local pins = {}
  for _, pin in pairs(PlayerConfigurations[playerID]:GetMapPins()) do
    if pin:GetIconName() == "ICON_" .. districtType then pins[#pins + 1] = pin end
  end
  table.sort(pins, function(a, b) return a:GetID() < b:GetID() end)
  for _, pin in ipairs(pins) do
    local name = CityAt(pin:GetHexX(), pin:GetHexY())
    if name ~= nil then return name end
  end
  return nil
end

-- ===========================================================================
-- Session
-- ===========================================================================
local Session = {}
Session.__index = Session

-- Request = {
--   PlayerID, Tier, Params (overrides, tests)
--   Districts            default plan of every new city, and of existing cities
--                        minus what they have built or pinned already (required)
--   Plans                { [participant Key] = { district types } } overrides
--   Pool, Count          default candidates and number of districts that take
--                        population per city (required ones included): each
--                        city picks the rest from its pool (feedback item 11)
--   Pools, Counts        { [participant Key] = ... } overrides of Pool, Count
--   Auto, Autos          { [district type] = true }: districts a city gets when
--                        it needs them (SDP_City.NeedsAuto); Autos per Key
--   Sites                { [site Key] = false }: city-center pins left out
--   Distance             distance cost weight (0 or nil: off)
--   Remind               find the woods and rainforest each solution relies on
--   Wonders              wonder types (building types) to place, in any participating city;
--                        a district one needs next to it that no city has is
--                        supplied (issue 66, see below)
--   Off, Offs            { [district type] = true }: districts the player set to
--                        "not wanted" (not by default) in the shared list, per Key;
--                        never supplied for a wonder there
--   Existing             { [cityID] = bool } who else takes part (see Participants)
--   Only                 { [cityID] = true }: exactly these cities (see Participants)
--   Weights              as for SDP_Solver (five yields, HOUSING, LAND)
--   Land                 count the land part (default true)
--   Coverage             weight 0..3 of the coverage part (default 0: off); with
--                        Only, every city-center pin is a target too
--   AllowFeatureRemoval  default true
--   IgnorePins           this mod's earlier pins being replaced (see SDP_Solver)
--   Apart                false: no keeping partner districts apart (see SDP_Solver)
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

  local participants, existing, siteList = SDP_Multi.Participants(playerID,
    { Existing = request.Existing, Only = request.Only, Sites = request.Sites })
  self.Participants, self.Existing, self.SiteList = participants, existing, siteList

  -- Plans, scans.
  local plannable, byType = SDP_Rules.PlannableDistricts(playerID), {}
  for _, d in ipairs(plannable) do byType[d.Type] = d end
  local unplaced = {}
  self.Auto = {}
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
  local asked = {} -- per participant: what the candidates below need to know
  for p, part in ipairs(participants) do
    local wanted = (request.Plans and request.Plans[part.Key]) or request.Districts or {}
    local count = (request.Counts and request.Counts[part.Key]) or request.Count or 0
    local specialty = 0
    for _, districtType in ipairs(wanted) do
      if byType[districtType] and byType[districtType].Specialty then specialty = specialty + 1 end
    end
    if part.Kind == "SITE" then
      part.Scan = SDP_City.ScanSite(playerID, part.X, part.Y, {
        allowFeatureRemoval = options.allowFeatureRemoval, ignorePins = options.ignorePins, name = part.Name,
        population = SDP_Land.RequiredPopulation(math.max(specialty, count)),
      })
    else
      part.Scan = SDP_City.Scan(playerID, part.CityID, options)
    end
    local status = SDP_City.DistrictStatus(part.Scan, plannable)
    part.Present = SDP_City.PresentDistricts(part.Scan)
    part.ForWonder = {} -- [district type] = the wonder it is supplied for (issue 66)
    -- With the shared list an existing city skips what it has pinned
    -- already; pins of other cities are only neighbours (issue 64).
    local pinnedHere = SDP_City.TackedDistricts(part.Scan)
    local pinned = (part.Kind == "CITY" and not (request.Plans and request.Plans[part.Key])) and pinnedHere or {}
    local plan, seen, kept = {}, {}, {}
    for _, districtType in ipairs(wanted) do
      if not seen[districtType] then
        seen[districtType] = true
        local excluded = SDP_Rules.ExcludedBy(districtType, kept)
        if not byType[districtType] then
          unplaced[#unplaced + 1] = { City = part.Key, Type = districtType, Reason = "NOT_AVAILABLE" }
        elseif status[districtType] then
          -- Existing cities skip what they have built; new cities have built nothing.
          if part.Kind == "SITE" or (request.Plans and request.Plans[part.Key]) then
            unplaced[#unplaced + 1] = { City = part.Key, Type = districtType, Reason = status[districtType] }
          end
        elseif excluded ~= nil then
          -- Two required districts one city cannot have: the first one asked stays.
          unplaced[#unplaced + 1] = { City = part.Key, Type = districtType, Reason = "EXCLUSIVE", Other = excluded }
        elseif pinned[districtType] then
          -- Shown as LOC_SDP_REASON_TACKED.
          unplaced[#unplaced + 1] = { City = part.Key, Type = districtType, Reason = "TACKED" }
        else
          plan[#plan + 1] = districtType
          kept[districtType] = true
        end
      end
    end
    -- Districts the city needs (feedback item 4), unless built or pinned.
    local auto = (request.Autos and request.Autos[part.Key]) or request.Auto or {}
    part.Auto = {}
    for _, d in ipairs(plannable) do
      if auto[d.Type] and not seen[d.Type] and not status[d.Type] and not pinnedHere[d.Type]
          and SDP_City.NeedsAuto(part.Scan, d.Type) then
        seen[d.Type] = true
        plan[#plan + 1] = d.Type
        part.Auto[d.Type] = true
      end
    end
    part.Plan = plan
    asked[p] = { Count = count, Seen = seen, Kept = kept, Status = status, PinnedHere = pinnedHere }
  end

  -- A district with an empire limit (government plaza, diplomatic quarter)
  -- asked by more cities than the limit leaves goes to the first of them in
  -- participant order (the top of the panel's list); the others drop it and
  -- take a candidate in its place, so every city still gets its count (issue
  -- 28). To put it in another city, give that city a list of its own.
  local left = {}
  for p, part in ipairs(participants) do
    local plan = {}
    for _, districtType in ipairs(part.Plan) do
      local row = byType[districtType]
      if row.MaxPerPlayer and row.MaxPerPlayer > 0 then
        if left[districtType] == nil then
          left[districtType] = row.MaxPerPlayer - (builtByPlayer[districtType] or 0) - (pinnedAnywhere[districtType] or 0)
        end
        if left[districtType] > 0 then
          left[districtType] = left[districtType] - 1
          plan[#plan + 1] = districtType
        else
          unplaced[#unplaced + 1] = { City = part.Key, Type = districtType, Reason = "MAX_PER_PLAYER" }
          asked[p].Kept[districtType] = nil
        end
      else
        plan[#plan + 1] = districtType
      end
    end
    part.Plan = plan
  end

  -- Districts the chosen wonders need next to them (issue 66, plan A): when
  -- no participating city has one (built, pinned for it or in its plan),
  -- the first city in the list that can take it plans it as required, so it
  -- counts among the city's districts that take population. Not where the
  -- player set it to "not wanted" (Off, Offs), where the city has or plans
  -- a district it cannot share a city with (a water park), where it has no
  -- valid tile, or past an empire limit; two wonders needing one district
  -- get one. self.Supplied lists them { City, Type, Wonder }; Elsewhere[wonder]
  -- the city where an empire-limited district stands already.
  self.Supplied, self.Elsewhere = {}, {}
  if request.Wonders and #request.Wonders > 0 then
    local wonderRows = {}
    for _, w in ipairs(SDP_Wonders.List(playerID)) do wonderRows[w.Type] = w end
    local have = {} -- base types some participant has or plans
    for _, part in ipairs(participants) do
      for districtType in pairs(part.Present) do have[SDP_Rules.BaseDistrict(districtType)] = true end
      for _, districtType in ipairs(part.Plan) do have[SDP_Rules.BaseDistrict(districtType)] = true end
    end
    local wonders = {}
    for _, wonderType in ipairs(request.Wonders) do wonders[#wonders + 1] = wonderType end
    table.sort(wonders)
    local function Placeable(part, districtType)
      for _, c in ipairs(part.Scan.Candidates) do
        if SDP_Overlay.CanPlace(SDP_Overlay.Subject(districtType, c.X, c.Y)) then return true end
      end
      return false
    end
    for _, wonderType in ipairs(wonders) do
      local w = wonderRows[wonderType]
      local base = (w ~= nil and w.Status == nil) and w.AdjacentDistrict or nil
      if base ~= nil and not have[base] then
        -- The player's own district where a unique one replaces it (Rome: the Bath).
        local own = byType[base] ~= nil and base or nil
        for _, d in ipairs(plannable) do
          if SDP_Rules.BaseDistrict(d.Type) == base and d.Type ~= base then own = d.Type end
        end
        local row = own ~= nil and byType[own] or nil
        if row ~= nil and not row.CityCenter then
          local limited = row.MaxPerPlayer and row.MaxPerPlayer > 0
          if limited and left[own] == nil then
            left[own] = row.MaxPerPlayer - (builtByPlayer[own] or 0) - (pinnedAnywhere[own] or 0)
          end
          for p, part in ipairs(participants) do
            local off = (request.Offs and request.Offs[part.Key]) or request.Off or {}
            local a = asked[p]
            if not have[base] and not off[own] and not (limited and left[own] <= 0)
                and a.Status[own] == nil and not a.PinnedHere[own]
                and SDP_Rules.ExcludedBy(own, a.Kept) == nil and SDP_Rules.ExcludedBy(own, part.Present) == nil
                and Placeable(part, own) then
              part.Plan[#part.Plan + 1] = own
              a.Seen[own], a.Kept[own] = true, true
              part.ForWonder[own] = wonderType
              have[base] = true
              if limited then left[own] = left[own] - 1 end
              self.Supplied[#self.Supplied + 1] = { City = part.Key, Type = own, Wonder = wonderType }
            end
          end
          if not have[base] and limited and left[own] <= 0 then
            self.Elsewhere[wonderType] = SDP_Multi.WhereBuilt(playerID, own)
          end
        end
      end
    end
  end

  for p, part in ipairs(participants) do
    local count, seen, kept, status, pinnedHere =
      asked[p].Count, asked[p].Seen, asked[p].Kept, asked[p].Status, asked[p].PinnedHere
    local plan = part.Plan
    -- Candidates (feedback item 11): districts that take population, not
    -- required, plannable here, without an empire limit.
    local requiredSpecialty = 0
    for _, districtType in ipairs(plan) do
      if byType[districtType].Specialty then requiredSpecialty = requiredSpecialty + 1 end
    end
    -- As in SDP_Solver: candidates the required ones exclude stay out, and
    -- the pick is capped by how many candidates can stand together.
    local pool, together, fit = {}, {}, 0
    for _, districtType in ipairs((request.Pools and request.Pools[part.Key]) or request.Pool or {}) do
      local row = byType[districtType]
      if row ~= nil and not seen[districtType] and not status[districtType] and not pinnedHere[districtType]
          and row.Specialty and not (row.MaxPerPlayer and row.MaxPerPlayer > 0)
          and SDP_Rules.ExcludedBy(districtType, kept) == nil then
        seen[districtType] = true
        pool[#pool + 1] = districtType
        if SDP_Rules.ExcludedBy(districtType, together) == nil then
          together[districtType] = true
          fit = fit + 1
        end
      end
    end
    part.Pick = math.max(0, math.min(count - requiredSpecialty, fit))
    part.Pool = part.Pick > 0 and pool or {}
  end
  self.Unplaced = unplaced

  -- One candidate list for everybody.
  local candidates, at = {}, {}
  for _, part in ipairs(participants) do
    for _, c in ipairs(part.Scan.Candidates) do
      if at[c.Index] == nil then
        at[c.Index] = true
        -- Unowned and RemoveTech are the same whichever scan lists the plot
        -- (a plot one city owns is a candidate of another only by swapping,
        -- worked out with the plan).
        candidates[#candidates + 1] = { Index = c.Index, X = c.X, Y = c.Y, Unowned = c.Unowned, RemoveTech = c.RemoveTech,
          ClearFirst = c.ClearFirst }
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

  -- The population each city's plan needs: its land part's worked plots
  -- and its housing target (issue 55).
  for _, part in ipairs(participants) do
    local specialty = part.Scan.SpecialtyBuilt + part.Pick
    for _, districtType in ipairs(part.Plan) do
      if byType[districtType].Specialty then specialty = specialty + 1 end
    end
    part.Population = math.max(part.Kind == "CITY" and part.Scan.Population or 1, SDP_Land.RequiredPopulation(specialty))
  end

  -- Land part per city; a plot several cities could work goes to the nearest.
  local lands = {}
  if land then
    -- A plot a participating city owns stays that city's, also when another
    -- can swap it (issue 54).
    local owner, byCity = {}, {}
    for p, part in ipairs(participants) do
      if part.CityID ~= nil then byCity[part.CityID] = p end
    end
    for p, part in ipairs(participants) do
      for _, index in ipairs(SDP_Land.Workable(part.Scan)) do
        local plot = Map.GetPlotByIndex(index)
        local owningCity = plot:GetOwner() == playerID and Cities.GetPlotPurchaseCity(plot) or nil
        local holder = owningCity ~= nil and byCity[owningCity:GetID()] or nil
        local d = Map.GetPlotDistance(part.X, part.Y, plot:GetX(), plot:GetY())
        if holder == p then d = -1 elseif holder ~= nil then d = math.huge end
        local current = owner[index]
        if current == nil or d < current.Distance then owner[index] = { Part = p, Distance = d } end
      end
    end
    for p, part in ipairs(participants) do
      part.Land = SDP_Land.ForScan(part.Scan, fixed, SDP_Land.PlotWeights(SDP_Land.Scale(request.Weights)), part.Population, function(index)
        return owner[index] ~= nil and owner[index].Part == p
      end)
      lands[#lands + 1] = part.Land
    end
  end

  -- Coverage part (design 19): the player's cities and the new ones; off
  -- (no model at all) unless a weight is given.
  if (request.Coverage or 0) > 0 then
    local sites = {}
    if request.Only then
      -- The single-city tab (wonders): no new city takes part, every
      -- city-center pin is a target, as without wonders (SDP_Solver).
      sites = SDP_Coverage.SiteTargets(playerID)
    end
    for _, part in ipairs(participants) do
      if part.Kind == "SITE" then sites[#sites + 1] = { Key = part.Key, X = part.X, Y = part.Y, Name = part.Name } end
    end
    self.Coverage = SDP_Coverage.New({ PlayerID = playerID, Weight = request.Coverage, Sites = sites,
      IgnorePins = options.ignorePins })
  end

  -- Slots: every city's plan (an empire limit already shared out above),
  -- then its candidates.
  local slots, slotCity = {}, {}
  for p, part in ipairs(participants) do
    for _, districtType in ipairs(part.Plan) do
      slots[#slots + 1] = { Key = districtType, Type = "DISTRICT", Group = p, Allowed = part.Allowed,
        ForWonder = part.ForWonder[districtType] }
      slotCity[#slots] = p
    end
  end
  local pools = nil
  for p, part in ipairs(participants) do
    for _, districtType in ipairs(part.Pool) do
      slots[#slots + 1] = { Key = districtType, Type = "DISTRICT", Group = p, Allowed = part.Allowed, Optional = true }
      slotCity[#slots] = p
    end
    if part.Pick > 0 then
      pools = pools or {}
      pools[p] = part.Pick
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
    -- Where the improvement a wonder needs next to it may go (issue 51):
    -- tiles a participating city can come to own, or the player's own.
    local ownable, taken = {}, {}
    for _, part in ipairs(participants) do
      for index in pairs(part.Scan.Reach.Reached) do ownable[index] = true end
      for _, pin in ipairs(part.Scan.Pins) do taken[pin.Index] = true end
    end
    for _, subject in ipairs(fixed) do taken[Map.GetPlotIndex(subject.X, subject.Y)] = true end
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
          -- Other names the district the player would set to Must: their own
          -- unique district where it replaces the one the wonder needs (Rome: the Bath).
          local own = w.AdjacentDistrict
          for _, d in ipairs(plannable) do
            if d.Type ~= own and SDP_Rules.BaseDistrict(d.Type) == w.AdjacentDistrict then own = d.Type end
          end
          if self.Elsewhere[wonderType] ~= nil then
            -- An empire-limited district in a city that does not take part.
            unplaced[#unplaced + 1] = { City = "WONDERS", Type = wonderType, Reason = "DISTRICT_ELSEWHERE",
              District = w.AdjacentDistrict, Other = own, Where = self.Elsewhere[wonderType] }
          else
            unplaced[#unplaced + 1] = { City = "WONDERS", Type = wonderType, Reason = "NEEDS_DISTRICT",
              District = w.AdjacentDistrict, Other = own }
          end
        else
          local support = w.AdjacentImprovement and SDP_Wonders.Support(playerID, w.AdjacentImprovement, candidates,
            everywhere, ownable, taken, fixed) or nil
          if support ~= nil and not support.Any then
            unplaced[#unplaced + 1] = { City = "WONDERS", Type = wonderType, Reason = "NEEDS_IMPROVEMENT",
              Other = w.AdjacentImprovement }
          else
            slots[#slots + 1] = { Key = wonderType, Type = "WONDER", Group = wonderGroup, Allowed = everywhere,
              Requires = w.AdjacentDistrict, Support = support, Wonder = true }
            slotCity[#slots] = nil
          end
        end
      end
    end
  end

  local centers = {}
  for _, part in ipairs(participants) do
    if part.Kind == "SITE" then centers[#centers + 1] = { X = part.X, Y = part.Y } end
  end
  local workable = {}
  for _, part in ipairs(participants) do
    for _, index in ipairs(SDP_Land.Workable(part.Scan)) do workable[index] = true end
  end
  -- Partner districts kept apart in each city (SDP_Rules.Apart).
  local apart = nil
  if request.Apart ~= false and pools ~= nil and #SDP_Rules.Apart().Pairs > 0 then
    apart = { Partners = SDP_Rules.Apart().Partners, Present = {}, Avoid = {} }
    for p, part in ipairs(participants) do
      apart.Present[p] = part.Present
      apart.Avoid[p] = SDP_Rules.ApartAvoid(Map.GetPlot(part.X, part.Y))
    end
  end
  -- Each city's districts must stay joined to its territory, the other
  -- cities' planned districts in the way (issue 35; SDP_City.Reach).
  local reach = {}
  for p, part in ipairs(participants) do reach[p] = part.Scan.Reach end
  -- Whose districts a wonder may count (issue 45): a wonder's plot goes to
  -- a city that can take it, a fixed district belongs to the cities whose
  -- territory or reach holds its plot.
  local owners = { Wonder = {}, Fixed = {} }
  for p, part in ipairs(participants) do
    for i in pairs(part.Allowed) do
      owners.Wonder[i] = owners.Wonder[i] or {}
      owners.Wonder[i][p] = true
    end
  end
  for _, subject in ipairs(fixed) do
    if subject.Type == "DISTRICT" then
      local index = Map.GetPlotIndex(subject.X, subject.Y)
      local groups = {}
      for p, part in ipairs(participants) do
        if part.Scan.Reach.Through[index] then groups[p] = true end
      end
      owners.Fixed[index] = { Type = subject.Key, Groups = groups }
    end
  end
  -- Each city's housing (issue 55); a fixed district's housing goes to the
  -- participant that owns its plot, an unowned one's to the nearest.
  local housingCities = {}
  for p, part in ipairs(participants) do
    -- A city-center pin is a city of 1 (issue 91: SDP_Land.HousingValue).
    housingCities[p] = { Housing = SDP_Land.ScanHousing(part.Scan), Target = part.Population,
      Population = part.Kind == "CITY" and part.Scan.Population or 1 }
  end
  local function HousingGroup(index)
    local plot = Map.GetPlotByIndex(index)
    local owner = plot:GetOwner() == playerID and Cities.GetPlotPurchaseCity(plot) or nil
    local best, bestDistance = nil, math.huge
    for p, part in ipairs(participants) do
      if owner ~= nil then
        if part.CityID == owner:GetID() then return p end
      else
        local d = Map.GetPlotDistance(part.X, part.Y, plot:GetX(), plot:GetY())
        if d <= SDP_City.RADIUS and d < bestDistance then best, bestDistance = p, d end
      end
    end
    return best
  end
  -- The city a slot's placement is planned for is not counted as covered by
  -- it (issue 91): its group's, or for a wonder the city whose tile it is
  -- (as Session:OwnerOf).
  local function CoverOwner(search, m, i)
    local spec = slots[search.SlotIndex[m]]
    local p = spec.Group
    if spec.Wonder then
      p = nil
      for q, part in ipairs(participants) do
        if p == nil and part.Allowed[i] then p = q end
      end
    end
    return p ~= nil and participants[p] ~= nil and participants[p].Key or nil
  end
  self.Search = SDP_Search.New({
    PlayerID = playerID, Board = self.Board, Weights = self.Weights, Params = params,
    Candidates = candidates, Slots = slots, Lands = lands, Coverage = self.Coverage, CoverOwner = CoverOwner,
    Pools = pools, Costs = SDP_City.DistanceCosts(playerID, candidates, request.Distance, centers), Apart = apart,
    Exclusive = SDP_Rules.Exclusive(), Reach = reach, Owners = owners,
    Appeal = { Fixed = fixed, Weights = request.Weights, Workable = workable, Cities = housingCities,
      FixedGroup = HousingGroup },
  })
  for _, s in ipairs(self.Search:Singles()) do
    if not slots[s].Optional then
      local city = slotCity[s] and participants[slotCity[s]].Key or "WONDERS"
      local auto = slotCity[s] and participants[slotCity[s]].Auto[slots[s].Key] or nil
      unplaced[#unplaced + 1] = { City = city, Type = slots[s].Key, Reason = "NO_LEGAL_PLOT", Auto = auto,
        ForWonder = slots[s].ForWonder }
    end
  end
  self.SlotSpecs = slots
  -- Blocks: the search's required slots of each participant, then the
  -- wonders (a city's candidates are in Search.PoolSlots).
  local blocks = {}
  for p = 1, wonderGroup do blocks[p] = {} end
  for m = 1, self.Search.K do
    local p = self.Search.Groups[m]
    if not self.Search.Optional[m] then blocks[p][#blocks[p] + 1] = m end
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

-- The slots of city p in a layout's plan: its required ones and the
-- candidates the layout places.
function Session:BlockOf(p, layout)
  local search = self.Search
  if (search.PoolCount[p] or 0) == 0 then return self.Blocks[p] end
  return search:ActiveOrder(p, search:ChosenOf(p, layout))
end

-- Plan city p with everything else in `base` fixed (its own slots off).
-- With candidates (feedback item 11) and `choose`, the best Params.Combos
-- combinations by optimistic value are each solved and the best kept;
-- otherwise the city keeps the candidates of `keep` (a layout). Returns the
-- layout and value, or nil.
function Session:SolveCity(p, base, choose, keep)
  local search = self.Search
  if (search.PoolCount[p] or 0) == 0 then return search:SolveBlock(self.Blocks[p], base) end
  if not choose then return search:SolveBlock(search:ActiveOrder(p, search:ChosenOf(p, keep)), base) end
  local best, bestGain = nil, nil
  local tried = 0
  for _, combo in ipairs(search:Combos(p)) do
    if tried >= (self.Params.Combos or 3) or search:OverBudget() then break end
    tried = tried + 1
    local layout, gain = search:SolveBlock(search:ActiveOrder(p, combo.Slots), base)
    if layout ~= nil and (best == nil or SDP_Search.Placed(layout) > SDP_Search.Placed(best)
        or (SDP_Search.Placed(layout) == SDP_Search.Placed(best) and SDP_Search.Better(gain, layout, bestGain, best))) then
      best, bestGain = layout, gain
    end
  end
  return best, bestGain
end

-- Local search, then (with candidates) swap a city's candidate for another
-- while that improves, each swap followed by local search.
function Session:Polish(layout, gain)
  local search = self.Search
  layout, gain = search:LocalSearch(layout, gain)
  if not search:HasPools() then return layout, gain end
  for _ = 1, 4 do
    if search:OverBudget() then break end
    local swapped, swappedGain = search:TypeSwaps(layout, gain)
    if swapped == nil then break end
    layout, gain = search:LocalSearch(swapped, swappedGain)
  end
  return layout, gain
end

-- One start, then local search and block rounds. Returns its layout.
-- Start 2 is joint: one model beam over every city's districts at once, so
-- that clusters can merge across cities (districts of two cities next to
-- each other give each other adjacency), then the wonders. The others go
-- city by city, each with the cities before it fixed. `wide` (start 2 only)
-- multiplies the joint beam's width (Params.WideJoint).
function Session:RunStart(s, wide)
  local search, params = self.Search, self.Params
  local order, scale = self:StartPlan(s)
  local beam = params.Beam
  params.Beam = math.max(10, math.floor(beam * scale))
  local layout = search:EmptyLayout()
  local function Pooled(p) return (search.PoolCount[p] or 0) > 0 end
  if s == 2 then
    -- Each city with candidates takes its best ranked combination here.
    local active = {}
    for p = 1, #self.Participants do
      active[p] = Pooled(p) and search:ActiveOrder(p, search:Combos(p)[1].Slots) or self.Blocks[p]
    end
    active[self.WonderGroup] = self.Blocks[self.WonderGroup]
    local districts = {}
    for p = 1, #self.Participants do
      for _, m in ipairs(active[p]) do districts[#districts + 1] = m end
    end
    if #districts > 0 and not search:OverBudget() then
      params.Beam = math.max(10, math.floor(beam * scale * (wide or 1)))
      local ranked = search:Shortlist(districts, layout)
      params.Beam = math.max(10, math.floor(beam * scale))
      if ranked[1] ~= nil then layout = Copy(ranked[1].Layout) end
    end
    for _, p in ipairs(order) do
      local block = active[p]
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
      if (#self.Blocks[p] > 0 or Pooled(p)) and not search:OverBudget() then
        local best = self:SolveCity(p, layout, true)
        layout = best or self:Greedy(self.Blocks[p], layout)
      end
    end
  end
  local gain, legal = search:Evaluate(layout)
  search:Consider(gain, legal, layout)
  if self.First == nil then self.First = { Layout = Copy(layout), Gain = gain } end
  layout, gain = self:Polish(layout, gain)
  local placed = SDP_Search.Placed(layout)
  for _ = 1, (wide and params.WideRounds) or params.Rounds do
    local improved = false
    for _, p in ipairs(order) do
      local block = self:BlockOf(p, layout)
      if #block > 0 and not search:OverBudget() then
        local base = Copy(layout)
        for m = 1, search.K do
          if search.Groups[m] == p then base[m] = 0 end
        end
        local trial, trialGain = self:SolveCity(p, base, false, layout)
        if trial ~= nil and SDP_Search.Placed(trial) >= placed and trialGain > gain then
          layout, gain, improved = trial, trialGain, true
          search:Consider(gain, true, layout)
        end
      end
    end
    if not improved then break end
    layout, gain = self:Polish(layout, gain)
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
local PRELUDE_KEYS = { "ExactLimit", "Beam", "BeamOrder", "Shortlist", "MaxPasses", "Rounds", "Swap", "Pair", "WideJoint",
  "WideRounds" }

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
  self:RunWideJoint()
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
  self:RunWideJoint()
  search:Kicks(params.Kicks or 0)
  self:Repair()
end

-- The joint start once more with a wider beam (Params.WideJoint times the
-- tier's), on top of the fixed starts: widening start 2 itself is not
-- monotone (a wider beam's best model layout can polish to less), so the
-- portfolio only grows. It merges clusters across cities that the narrower
-- beam misses (offline benchmark, 2026-10-21).
function Session:RunWideJoint()
  local wide = self.Params.WideJoint
  if wide == nil or wide <= 1 or #self.Participants < 2 or self.Search:OverBudget() then return end
  self:RunStart(2, wide)
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
  if search.BestLayout == nil or SDP_Search.Placed(search.BestLayout) == search.Selected then return end
  local callCap, tryCap = search.CallCap, search.TryCap
  search.CallCap = search.Board.Calls + math.ceil(params.CallLimit / 4)
  search.TryCap = search.Stats.Tries + math.ceil(params.TryLimit / 4)
  for m = 1, search.K do
    if search.BestLayout[m] == 0 and not search.Optional[m] and not search:OverBudget() then
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

-- The participant a placed slot belongs to: its city, or for a wonder the
-- first city whose plots hold it.
function Session:OwnerOf(m, i)
  local spec = self.SlotSpecs[self.Search.SlotIndex[m]]
  if spec.Wonder then
    for p, part in ipairs(self.Participants) do
      if part.Allowed[i] then return p end
    end
  end
  return spec.Group
end

-- Up to `count` layouts that differ enough (design 4.5): the best one and
-- each start's result, best first; a layout is kept when it differs from
-- every kept one in at least max(2, 20% of the slots) positions, or picks
-- other candidate districts (SDP_Search IsDistinct).
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
  local kept = {}
  for _, entry in ipairs(pool) do
    if #kept >= count then break end
    local distinct = true
    for _, other in ipairs(kept) do
      if not search:IsDistinct(entry.Layout, other.Layout) then distinct = false end
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
      SiteNumber = part.SiteNumber, Number = part.Number, Plan = part.Plan, Gain = 0, Picked = {},
    }
  end
  local subjects, slotsPlaced = {}, {}
  for m = 1, search.K do
    if layout[m] ~= 0 then
      subjects[#subjects + 1] = search:Subject(m, layout[m])
      slotsPlaced[#slotsPlaced + 1] = m
    elseif not search.Optional[m] then
      local spec = self.SlotSpecs[search.SlotIndex[m]]
      local city = spec.Wonder and "WONDERS" or self.Participants[spec.Group].Key
      out.Unplaced[#out.Unplaced + 1] = { City = city, Type = spec.Key, Reason = "NO_FREE_PLOT", ForWonder = spec.ForWonder }
    end
  end
  -- A city that could not fit as many candidates as asked.
  -- PoolCount[p] is nil when none of the city's candidates has a legal plot
  -- (a crowded late-game city; stress test 2026-10-21).
  for p, part in ipairs(self.Participants) do
    local pooled = search.PoolCount[p] or 0
    local short = pooled - #search:ChosenOf(p, layout)
    if (part.Pick or 0) > pooled then short = short + part.Pick - pooled end
    if short > 0 then
      out.Unplaced[#out.Unplaced + 1] = { City = part.Key, Type = "POOL", Reason = "POOL_SHORT", Count = short }
    end
  end
  -- The improvements wonders need next to them (issue 51): on the map for
  -- DMT, not scored, tacked with the wonder.
  local supportAt, extra = {}, {}
  local supportPlots = search:SupportPlots(layout)
  for _, m in ipairs(search.SupportList or {}) do
    local index = supportPlots[m]
    if index ~= nil then
      supportAt[m] = index
      extra[#extra + 1] = search:SupportSubject(search.SupportOf[m].Type, index)
    end
  end
  local final = SDP_Overlay.Evaluate(subjects, self.Fixed, self.Weights, extra)
  self.ExtraCalls = self.ExtraCalls + 2 * #subjects + #self.Fixed
  local appeal = {}
  if search.AppealModel ~= nil then out.AppealDelta = search:AppealDelta(layout, appeal) end
  for n, m in ipairs(slotsPlaced) do
    local i = layout[m]
    local item, c = final.Placements[n], search.Candidates[i]
    local p = self:OwnerOf(m, i)
    local spec = self.SlotSpecs[search.SlotIndex[m]]
    local a = appeal[m] or {}
    -- A plot another of the player's cities owns is swapped from it (issue 54).
    local plot = Map.GetPlotByIndex(c.Index)
    local owningCity = plot:GetOwner() == self.PlayerID and Cities.GetPlotPurchaseCity(plot) or nil
    local swap = owningCity ~= nil and self.Participants[p].CityID ~= nil and owningCity:GetID() ~= self.Participants[p].CityID
      and owningCity:GetID() or nil
    out.Plan[n] = {
      City = self.Participants[p].Key, Type = search.Types[m], Kind = search.Kinds[m], X = c.X, Y = c.Y, Index = c.Index,
      Yields = item.Yields, ToolTip = item.ToolTip, Score = item.Score,
      Unowned = c.Unowned, RemoveTech = c.RemoveTech, Swap = swap, ClearFirst = c.ClearFirst,
      Appeal = a.Appeal, Housing = a.Housing, Tiles = a.Tiles, TilesCounted = a.TilesCounted,
      TilesReason = a.TilesReason,
      Reach = self.Coverage and self.Coverage:Reach(search.Types[m], c.X, c.Y, self.Participants[p].Key) or nil,
      Picked = search.Optional[m], Auto = (not spec.Wonder) and self.Participants[p].Auto[search.Types[m]] or nil,
      ForWonder = spec.ForWonder,
    }
    if supportAt[m] ~= nil then
      local support = Map.GetPlotByIndex(supportAt[m])
      out.Plan[n].Support = { Type = search.SupportOf[m].Type, X = support:GetX(), Y = support:GetY(), Index = supportAt[m],
        Unowned = support:GetOwner() ~= self.PlayerID or nil }
    end
    out.Cities[p].Gain = out.Cities[p].Gain + item.Score
    if search.Optional[m] then
      local picked = out.Cities[p].Picked
      picked[#picked + 1] = search.Types[m]
    end
  end
  for f, item in ipairs(final.Fixed) do
    if item.Score ~= base.Fixed[f].Score then
      out.Neighbours[#out.Neighbours + 1] = {
        Subject = item.Subject, Before = base.Fixed[f].Score, After = item.Score, ToolTip = item.ToolTip,
      }
    end
  end
  if self.Request.Apart ~= false then
    for p, part in ipairs(self.Participants) do
      local types = {}
      for _, item in ipairs(out.Plan) do
        if item.City == part.Key and item.Kind == "DISTRICT" then types[#types + 1] = item.Type end
      end
      out.Cities[p].Together = SDP_Rules.Together(types, part.Present)
    end
  end
  out.Adjacency = final.Total - base.Total
  out.LandDelta = search:LandDelta(layout)
  out.CoverageDelta = search:CoverageDelta(layout)
  if self.Coverage ~= nil then
    -- The newly covered cities by group (base district or wonder).
    out.Covered, out.CoveredBy = self.Coverage:Summary(search:CoveragePairs(layout))
  end
  out.CostDelta = search:CostDelta(layout)
  out.Gain = out.Adjacency + out.LandDelta + out.CoverageDelta + out.CostDelta + (out.AppealDelta or 0)
  search:Breakdown(out, layout, slotsPlaced, final, base)
  -- Each city's subtotal: the sum of its districts' parts (issue 126).
  for n, item in ipairs(out.Plan) do
    local city = out.Cities[self:OwnerOf(slotsPlaced[n], layout[slotsPlaced[n]])]
    local sum = city.Parts or {}
    for _, key in ipairs(SDP_Search.PART_KEYS) do
      if item.Parts[key] ~= nil then sum[key] = (sum[key] or 0) + item.Parts[key] end
    end
    city.Parts = sum
  end
  out.Total = final.Total
  out.Legal = final.Legal
  local taken = {}
  for n, item in ipairs(out.Plan) do taken[n] = item.Index end
  local lost = SDP_Appeal.ImprovementHousing(self.PlayerID, taken)
  if lost < 0 then out.ImprovementHousing = lost end
  if self.Request.Remind then
    local plan = {}
    for n, item in ipairs(out.Plan) do plan[n] = { Type = item.Type, Kind = item.Kind, X = item.X, Y = item.Y } end
    out.Remind = SDP_Remind.Find(self.PlayerID, plan)
  end
  return out
end

-- Result: {
--   Ok, Error, Stats, Session, Quality, Existing (every existing city, see Participants)
--   Solutions   up to Params.Solutions distinct plans, best first, each
--               { Gain, Adjacency, LandDelta, CoverageDelta, Covered, Total, Plan, Unplaced, Neighbours, Cities }:
--                 Gain = Adjacency + LandDelta + CoverageDelta + CostDelta + AppealDelta
--                          (SDP_Appeal; nil when no district depends on appeal); Covered: the
--                          (city, group) pairs newly covered, CoveredBy: { Group,
--                          Keys (target keys) } by group (both nil when coverage is off)
--                 Plan     { City (participant Key), Type, Kind, X, Y, Index, Yields, ToolTip, Score,
--                          Reach (keys of the targets it newly covers; coverage on, types with a reach) }
--                 Unplaced { City, Type, Reason } (NOT_AVAILABLE, BUILT, PINNED, TACKED (an existing
--                          city with the shared list has a pin of it, SDP_City.OwnPins), MAX_PER_PLAYER,
--                          NEEDS_DISTRICT, DISTRICT_ELSEWHERE (Where: the city's name), NEEDS_IMPROVEMENT
--                          (Other: the improvement), NO_LEGAL_PLOT, NO_FREE_PLOT; City "WONDERS" for
--                          wonders; ForWonder: a district supplied for that wonder, issue 66)
--                 Plan entries of supplied districts carry ForWonder too
--                 A wonder's plan entry may carry Support = { Type, X, Y, Index, Unowned }: the
--                          improvement it needs next to it (issue 51), tacked with it
--                 Cities   { Key, Kind, Name, X, Y, CityID, SiteNumber, Number (SDP_City city
--                          number, the pins' name), Plan (types asked), Gain, Picked,
--                          Together (unless Request.Apart is false: SDP_Rules.Together) }
--   and the best solution's fields copied to the top level (Plan, Gain, ...)
--   Supplied    { City, Type, Wonder }: districts supplied for wonders (issue 66)
--   Baseline    joint DMT total without any plan
--   FirstGain   value of the city-by-city start (the "never worse" reference)
-- }
function Session:Result()
  local search, board, stats = self.Search, self.Board, self.Stats
  board:Clear()
  local result = {
    Ok = true, Session = self, Existing = self.Existing, Stats = stats, Baseline = self.Base.Total,
    FirstGain = self.First and self.First.Gain or nil, Solutions = {},
    Plan = {}, Unplaced = {}, Neighbours = {}, Cities = {}, Gain = 0, Adjacency = 0, LandDelta = 0, CoverageDelta = 0,
    CostDelta = 0, Total = self.Base.Total, Sites = self.SiteList, Supplied = self.Supplied,
  }
  if search.K > 0 and search.BestLayout == nil then result.Ok, result.Error = false, "NO_LEGAL_LAYOUT" end
  for _, entry in ipairs(self:Distinct(self.Params.Solutions or 3)) do
    local solution = self:PlanFor(entry.Layout)
    for _, u in ipairs(self.Unplaced) do table.insert(solution.Unplaced, 1, u) end
    result.Solutions[#result.Solutions + 1] = solution
  end
  local best = result.Solutions[1]
  if best ~= nil then
    for _, key in ipairs({ "Plan", "Unplaced", "Neighbours", "Cities", "Gain", "Adjacency", "LandDelta", "CoverageDelta",
      "CostDelta", "AppealDelta", "ImprovementHousing", "Covered", "CoveredBy", "Total", "Remind", "Rest",
      "YieldAdjacency", "YieldWeighted" }) do
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
-- pick: districts each city picks from a pool of `pool` (0: none).
function SDP_Multi.EstimateUnits(cities, districts, wonders, params, pick, pool)
  pick, pool = pick or 0, pool or 0
  local slots = cities * (districts + pick) + wonders
  if slots == 0 then return 0 end
  local n = 30 -- plots a city can use, typically
  local growth = (math.max(2, cities) / 2) ^ SDP_Tiers.MULTI_GROWTH
  -- The wide joint start (Session:RunWideJoint) runs with two cities or more.
  local wide = cities >= 2 and (params.WideJoint or 1) > 1
  local work = (params.Work or 100) + (wide and (params.WideWork or 0) or 0)
  local units = work * n * slots * growth
  if pick > 0 and pool > pick then
    -- Each city's block is solved for several combinations, and swaps.
    units = units * (1 + 0.5 * (params.Combos or 3)) + 3 * n * cities * pool
  end
  local prelude = params.Prelude and SDP_Tiers.Multi[params.Prelude]
  if prelude ~= nil then units = units + SDP_Multi.EstimateUnits(cities, districts, wonders, prelude, pick, pool) end
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
