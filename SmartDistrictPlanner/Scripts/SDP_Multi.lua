-- SDP_Multi: districts for several cities at once (docs/multicity-design.md
-- section 4): the planned cities (city-center map pins) and the existing
-- cities near them.
--
--   Participants  every city-center pin that is not a city yet, plus the
--                 player's cities within NEAR plots of one (default; each
--                 can be switched), any number of them (issue 142).
--   Plots         each city's three rings as SDP_City sees them; a new city
--                 cannot use plots of existing cities. Plots two cities can
--                 reach may go to either, one subject per plot.
--   Slots         (city, district) for every city's plan. A district with an
--                 empire limit (government plaza) goes to one of the cities
--                 that ask for it, as many as the limit leaves; the others
--                 take a candidate instead (issue 28). Cities asking in a
--                 list of their own come first; among the rest, SolveNow
--                 tries up to HOST_TRIES of them and keeps the best plan
--                 (issue 234). A wonder goes in the city given it
--                 (WonderCities), else in the one with the most production
--                 that has a valid tile for it (issue 234).
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
--   Groups        more than GROUP_ABOVE cities (issue 142): first all of them
--                 city by city, then groups of nearby cities (Groups) one
--                 after another, each searched as above with every other
--                 city's districts fixed where the best plan so far has them,
--                 GROUP_PASSES times over. Each group has the tier's budget,
--                 so the work grows with the number of groups.
-- Budgets are counts (SDP_Tiers.Multi), all loops over sorted arrays, ties
-- to smaller plot indices: same input, same result (constraint 6).
-- The overlay must be installed while a session computes.

SDP_Multi = {}

SDP_Multi.NEAR = 7       -- existing cities this close to a new city take part by default
SDP_Multi.DEFAULT_CITIES = 4 -- the Several cities tab's default group (DefaultGroup, issue 63)
-- More than GROUP_ABOVE cities are planned in groups of nearby cities, at
-- most GROUP_SIZE each, GROUP_PASSES times over; Continue adds a pass
-- (issue 142, numbers from the offline comparison of dense empires in
-- docs/notes/issue-142-all-cities.md: up to 8 cities one search plans best,
-- above that groups of 4 a little better than one search in the same time).
-- Params.GroupAbove, GroupSize and GroupPasses override them (tests, the
-- offline comparison).
SDP_Multi.GROUP_ABOVE = 8
SDP_Multi.GROUP_SIZE = 4
SDP_Multi.GROUP_PASSES = 1
-- An empire-limited district several cities ask for (issue 234): the cities
-- tried as its host, nearest the centre city first. Each one more is one
-- more solve.
SDP_Multi.HOST_TRIES = 4
-- Wonders left automatic go in the city with the most production that can
-- take them (issue 234); false: anywhere, by the plan's value alone
-- (tests of that path, the offline comparison).
SDP_Multi.WONDER_BY_PRODUCTION = true

local Copy = SDP_Search.Copy

-- A participant's production per turn (issue 234): an existing city's, as
-- its city panel shows it; a city-center pin's estimated from its tiles:
-- the centre plus the best of the plots it could work, as many as the
-- population its plan needs (part.PlanPopulation), the way the land part
-- picks them.
function SDP_Multi.Production(playerID, part)
  local index = GameInfo.Yields["YIELD_PRODUCTION"].Index
  if part.Kind == "CITY" then
    local city = CityManager.GetCity(playerID, part.CityID)
    return city ~= nil and (city:GetYield(index) or 0) or 0
  end
  local values = {}
  for _, plotIndex in ipairs(SDP_Land.Workable(part.Scan)) do
    values[#values + 1] = Map.GetPlotByIndex(plotIndex):GetYield(index)
  end
  table.sort(values, function(a, b) return a > b end)
  local total = Map.GetPlot(part.X, part.Y):GetYield(index)
  for k = 1, math.min(#values, part.PlanPopulation or 1) do total = total + values[k] end
  return total
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
-- with { CityID, Name, Distance, Default, On, Included }, and every
-- city-center pin with { Key, X, Y, Name, Number, SiteNumber, Included }.
-- Any number of cities may take part (issue 142: before, at most 8).
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
  for _, e in ipairs(existing) do
    e.Included = e.On == true
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

-- Nearby participants in groups of at most `size` (issue 142), as a list of
-- lists of participant indices, in the order they are planned: ceil(n /
-- size) groups, each of ceil(left / groups left) cities. Each one starts from the city
-- farthest from the others left (summed plot distance; ties: the smaller
-- index), so the edges of a block of cities are taken first and the groups
-- stay compact, and grows by the city whose farthest member is nearest
-- (ties: summed distance, then index). Cities 4 or 5 plots apart that are
-- planned in different groups still see each other: each group is searched
-- with the others' districts in place (Session:RunGroups).
function SDP_Multi.Groups(participants, size)
  local n = #participants
  local count = math.max(1, math.ceil(n / size))
  local left, groups = {}, {}
  for p = 1, n do left[p] = true end
  local function D(a, b)
    return Map.GetPlotDistance(participants[a].X, participants[a].Y, participants[b].X, participants[b].Y)
  end
  local remaining = n
  while remaining > 0 do
    local seed, seedSum = nil, nil
    for p = 1, n do
      if left[p] then
        local sum = 0
        for q = 1, n do
          if left[q] then sum = sum + D(p, q) end
        end
        if seed == nil or sum > seedSum then seed, seedSum = p, sum end
      end
    end
    local target = math.ceil(remaining / (count - #groups))
    local group = { seed }
    left[seed], remaining = false, remaining - 1
    while #group < target and remaining > 0 do
      local best, bestFar, bestSum = nil, nil, nil
      for p = 1, n do
        if left[p] then
          local far, sum = 0, 0
          for _, q in ipairs(group) do
            local d = D(p, q)
            far, sum = math.max(far, d), sum + d
          end
          if best == nil or far < bestFar or (far == bestFar and sum < bestSum) then
            best, bestFar, bestSum = p, far, sum
          end
        end
      end
      group[#group + 1] = best
      left[best], remaining = false, remaining - 1
    end
    table.sort(group)
    groups[#groups + 1] = group
  end
  return groups
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
--   Target               true: Count and Counts are how many districts that
--                        take population a city ends with, counting what it
--                        has built or pinned (SDP_City.SpecialtyHave, issue 144)
--   Auto, Autos          { [district type] = true }: districts a city gets when
--                        it needs them (SDP_City.NeedsAuto); Autos per Key
--   Sites                { [site Key] = false }: city-center pins left out
--   Distance             distance cost weight (0 or nil: off)
--   Remind               find the woods and rainforest each solution relies on
--   Wonders              wonder types (building types) to place, in any participating city;
--                        a district one needs next to it that no city has is
--                        supplied (issue 66, see below)
--   WonderCities         { [wonder type] = participant Key }: the city a wonder
--                        goes in, next to that city's districts only (issue
--                        234); the others in the city with the most
--                        production that can take them (WONDER_BY_PRODUCTION)
--   SupplyTo             { [wonder type] = participant Key }: the city tried
--                        first for the district a wonder needs (issue 182,
--                        set by SolveNow)
--   Center               participant Key of the centre city (the panel's);
--                        nil: the capital. Hosts of an empire-limited
--                        district are tried nearest it first (issue 234)
--   UniqueTo             { [district type] = participant Key }: the host of
--                        an empire-limited district (issue 234, set by SolveNow)
--   AutoSkip             { [wonder type] = n }: an automatic wonder skips the n
--                        cities with the most production (issue 234, set by
--                        SolveNow when it has no valid tile there)
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
-- The participant that builds a wonder of slot m on candidate i (issue 238),
-- among the cities that can take the plot (Allowed; with search.Owners,
-- those Owners.Wonder lists): for a wonder that must be next to a district,
-- the cities whose such district it touches (OwnDistrictNext: fixed ones,
-- and with `layout` the planned ones), the one supplied for it first when
-- it touches; then the city owning the plot; then the nearest city; ties
-- go to the first in the participants' order. A wonder given one city
-- (spec.City, issue 234) is that city's. Nil when no city can take i.
local function WonderOwner(participants, playerID, search, m, i, layout)
  local spec = search.SlotSpecs[search.SlotIndex[m]]
  -- A wonder given one city (issue 234) is that city's.
  if spec.City ~= nil then return participants[spec.City].Allowed[i] and spec.City or nil end
  local cities = search.Owners and search.Owners.Wonder[i] or nil
  local pool = {}
  for p, part in ipairs(participants) do
    if part.Allowed[i] and (cities == nil or cities[p]) then pool[#pool + 1] = p end
  end
  if #pool <= 1 then return pool[1] end
  if spec.Requires ~= nil and search.Owners ~= nil then
    -- Next to the district supplied for it: that one's city (as the
    -- search's legality, Search:SuppliedNext; Owners.Wonder[i] is the pool).
    local _, supplied = search:SuppliedNext(m, i, layout)
    if supplied ~= nil then return supplied end
    local touching = {}
    for _, p in ipairs(pool) do
      if search:OwnDistrictNext(spec.Requires, i, layout, p) then touching[#touching + 1] = p end
    end
    if #touching == 1 then return touching[1] end
    if #touching > 1 then pool = touching end
  end
  local c = search.Candidates[i]
  local plot = Map.GetPlotByIndex(c.Index)
  local owner = plot:GetOwner() == playerID and Cities.GetPlotPurchaseCity(plot) or nil
  if owner ~= nil then
    for _, p in ipairs(pool) do
      if participants[p].CityID == owner:GetID() then return p end
    end
  end
  local best, bestDistance = nil, math.huge
  for _, p in ipairs(pool) do
    local d = Map.GetPlotDistance(participants[p].X, participants[p].Y, c.X, c.Y)
    if d < bestDistance then best, bestDistance = p, d end
  end
  return best
end

-- The participant slot m on candidate i is planned for: its group's, or
-- for a wonder the city that builds it (WonderOwner; when none can take i,
-- the wonders' group, no participant). The one answer the search (coverage
-- without a layout, swaps with the layout tried) and the finished plan
-- (Session:OwnerOf, with its layout) both use: they differ only in the
-- layout passed (issue 238).
local function SlotCity(participants, playerID, search, m, i, layout)
  local spec = search.SlotSpecs[search.SlotIndex[m]]
  if spec.Wonder then return WonderOwner(participants, playerID, search, m, i, layout) or spec.Group end
  return spec.Group
end

-- NewSession, step by step (issue 245). Each step reads what the steps
-- before it left on the session and on the participants; the order of the
-- steps is the order of the original single function, so the scans, DMT
-- calls and lists come out the same.

-- Step 1, cities and their lists: scans every participant and turns the
-- request's lists into its plan.
-- In: self.Participants, self.PlayerID; request; scan options.
-- Out: on each participant Scan, Present, ForWonder, Plan, Auto, and for a
-- site PlanPopulation, with Target an existing city's Have; self.Auto.
-- Returns plannable (SDP_Rules.PlannableDistricts), byType (its rows by
-- type), empireCount (SDP_City.EmpireCounts), asked (per participant:
-- Count, Limited, Seen, Kept, Status, PinnedHere) and unplaced (the
-- districts left out so far, appended to by the later steps).
local function PlanCities(self, request, options)
  local participants, playerID = self.Participants, self.PlayerID
  local plannable, byType = SDP_Rules.PlannableDistricts(playerID), {}
  for _, d in ipairs(plannable) do byType[d.Type] = d end
  local unplaced = {}
  self.Auto = {}
  -- Toward each empire limit: built and pinned, pins being replaced left
  -- out (the same count as each city's SDP_City.DistrictStatus).
  local empireCount = SDP_City.EmpireCounts(playerID, options.ignorePins)
  local asked = {} -- per participant: what the candidates below need to know
  for p, part in ipairs(participants) do
    local wanted = (request.Plans and request.Plans[part.Key]) or request.Districts or {}
    local count = (request.Counts and request.Counts[part.Key]) or request.Count or 0
    local specialty = 0
    for _, districtType in ipairs(wanted) do
      if byType[districtType] and byType[districtType].Specialty then specialty = specialty + 1 end
    end
    if part.Kind == "SITE" then
      part.PlanPopulation = SDP_Land.RequiredPopulation(math.max(specialty, count))
      part.Scan = SDP_City.ScanSite(playerID, part.X, part.Y, {
        allowFeatureRemoval = options.allowFeatureRemoval, ignorePins = options.ignorePins, name = part.Name,
        population = part.PlanPopulation,
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
    -- Limited: a count was asked for this city (the panel always asks one).
    local limited = (request.Counts and request.Counts[part.Key] ~= nil) or request.Count ~= nil
    asked[p] = { Count = count, Limited = limited, Seen = seen, Kept = kept, Status = status, PinnedHere = pinnedHere }
    -- request.Target: the count is how many the city ends with (issue 144),
    -- so an existing city plans the rest; a type tacked here and planned
    -- again (in the city's own list) counts once.
    if request.Target and part.Kind == "CITY" then
      local planned = {}
      for _, districtType in ipairs(plan) do planned[districtType] = true end
      part.Have = SDP_City.HaveCount(SDP_City.SpecialtyHave(part.Scan), planned)
      asked[p].Count = count - part.Have
    end
  end
  return plannable, byType, empireCount, asked, unplaced
end

-- Step 2, empire-limited districts:
  -- A district with an empire limit (government plaza, diplomatic quarter)
  -- asked by more cities than the limit leaves (issue 234): the cities that
  -- ask for it in a list of their own (Plans) get it first, then those with
  -- the shared list. Where more of one kind ask than the limit leaves, the
  -- HOST_TRIES of them nearest the centre city (ties: the participants'
  -- order) are its possible hosts: this session gives it to the one
  -- UniqueTo names, else to the nearest, and SolveNow solves again with each
  -- other one and keeps the best plan (self.HostChoices = { { Type, Keys } },
  -- Keys nearest first). The cities left without it drop it and take a
  -- candidate in its place, so every city still gets its count (issue 28).
-- In: self.Participants, self.PlayerID; request (Center, Plans, UniqueTo);
-- byType, empireCount from step 1.
-- Out: each participant's Plan without the limited districts it does not
-- host (those appended to unplaced, dropped from asked[p].Kept);
-- self.HostChoices. Returns left: [district type] = how many more the
-- empire may have (step 4 counts on from it).
local function ShareEmpireLimits(self, request, byType, empireCount, asked, unplaced)
  local participants, playerID = self.Participants, self.PlayerID
  local centerX, centerY = nil, nil
  for _, part in ipairs(participants) do
    if part.Key == request.Center then centerX, centerY = part.X, part.Y end
  end
  if centerX == nil then
    local center = SDP_Multi.DefaultGroup(playerID, nil).Center
    if center ~= nil then centerX, centerY = center.X, center.Y end
  end
  local function FromCenter(p)
    if centerX == nil then return 0 end
    return Map.GetPlotDistance(centerX, centerY, participants[p].X, participants[p].Y)
  end
  local left, limitedTypes, askers = {}, {}, {}
  for p, part in ipairs(participants) do
    for _, districtType in ipairs(part.Plan) do
      local row = byType[districtType]
      if row.MaxPerPlayer and row.MaxPerPlayer > 0 then
        if askers[districtType] == nil then
          askers[districtType] = {}
          limitedTypes[#limitedTypes + 1] = districtType
          left[districtType] = row.MaxPerPlayer - (empireCount[districtType] or 0)
        end
        askers[districtType][#askers[districtType] + 1] = p
      end
    end
  end
  self.HostChoices = {}
  local hosts = {} -- [district type] = { [participant] = true }
  for _, districtType in ipairs(limitedTypes) do
    local own, shared = {}, {}
    for _, p in ipairs(askers[districtType]) do
      if request.Plans and request.Plans[participants[p].Key] then own[#own + 1] = p else shared[#shared + 1] = p end
    end
    local got = {}
    for _, kind in ipairs({ own, shared }) do
      local n = left[districtType]
      if n > 0 and #kind <= n then
        for _, p in ipairs(kind) do got[p] = true end
        left[districtType] = n - #kind
      elseif n > 0 then
        local ranked = {}
        for _, p in ipairs(kind) do ranked[#ranked + 1] = p end
        table.sort(ranked, function(a, b)
          local da, db = FromCenter(a), FromCenter(b)
          if da ~= db then return da < db end
          return a < b
        end)
        local tried = {}
        for k = 1, math.min(#ranked, math.max(n + 1, SDP_Multi.HOST_TRIES)) do tried[k] = ranked[k] end
        local named = request.UniqueTo and request.UniqueTo[districtType]
        local order = {}
        for _, p in ipairs(tried) do
          if participants[p].Key == named then order[#order + 1] = p end
        end
        for _, p in ipairs(tried) do
          if participants[p].Key ~= named then order[#order + 1] = p end
        end
        for k = 1, n do got[order[k]] = true end
        left[districtType] = 0
        local keys = {}
        for _, p in ipairs(tried) do keys[#keys + 1] = participants[p].Key end
        self.HostChoices[#self.HostChoices + 1] = { Type = districtType, Keys = keys }
      end
    end
    hosts[districtType] = got
  end
  for p, part in ipairs(participants) do
    local plan = {}
    for _, districtType in ipairs(part.Plan) do
      if hosts[districtType] ~= nil and not hosts[districtType][p] then
        unplaced[#unplaced + 1] = { City = part.Key, Type = districtType, Reason = "MAX_PER_PLAYER" }
        asked[p].Kept[districtType] = nil
      else
        plan[#plan + 1] = districtType
      end
    end
    part.Plan = plan
  end
  return left
end

-- Whether participant p has or plans a district of a base type.
local function Has(participants, p, base)
    for districtType in pairs(participants[p].Present) do
      if SDP_Rules.BaseDistrict(districtType) == base then return true end
    end
    for _, districtType in ipairs(participants[p].Plan) do
      if SDP_Rules.BaseDistrict(districtType) == base then return true end
    end
    return false
end

-- Step 3, the city of each wonder (issue 234).
-- In: self.Participants, self.PlayerID; request (WonderCities, Wonders,
-- AutoSkip).
-- Out: self.WonderCity, self.AutoWonder, and with automatic wonders
-- self.Production.
local function WonderCities(self, request)
  local participants, playerID = self.Participants, self.PlayerID
  -- Wonders given one city (issue 234): [wonder type] = participant; a
  -- city that does not take part leaves the wonder free.
  self.WonderCity = {}
  for wonderType, key in pairs(request.WonderCities or {}) do
    for p, part in ipairs(participants) do
      if part.Key == key then self.WonderCity[wonderType] = p end
    end
  end
  -- The other wonders ("automatic", issue 234, plan A decided 2026-11-03)
  -- go in the city with the most production (SDP_Multi.Production; ties:
  -- the participants' order), skipping the first AutoSkip[wonder] of that
  -- ranking; within it the tile is still chosen by the plan's value.
  -- self.AutoWonder[wonder] = the city picked; when the wonder cannot go
  -- there (no valid tile, no district for it), self.AutoRetry[wonder] is
  -- set below and SolveNow builds the session again with the next city.
  -- Past the last city the wonder goes in any city, as before.
  self.AutoWonder = {}
  if SDP_Multi.WONDER_BY_PRODUCTION and request.Wonders and #request.Wonders > 0 and #participants > 1 then
    local production, ranked = {}, {}
    for p, part in ipairs(participants) do
      production[p] = SDP_Multi.Production(playerID, part)
      ranked[p] = p
    end
    table.sort(ranked, function(a, b)
      if production[a] ~= production[b] then return production[a] > production[b] end
      return a < b
    end)
    self.Production = production
    local wonders = {}
    for _, wonderType in ipairs(request.Wonders) do wonders[#wonders + 1] = wonderType end
    table.sort(wonders)
    for _, wonderType in ipairs(wonders) do
      if self.WonderCity[wonderType] == nil then
        local p = ranked[(request.AutoSkip and request.AutoSkip[wonderType] or 0) + 1]
        if p ~= nil then self.WonderCity[wonderType], self.AutoWonder[wonderType] = p, p end
      end
    end
  end
end

-- Step 4, districts supplied for the wonders:
  -- Districts the chosen wonders need next to them (issue 66, plan A): when
  -- no participating city has one (built, pinned for it or in its plan),
  -- the first city in the list that can take it plans it as required, so it
  -- counts among the city's districts that take population. Not where the
  -- player set it to "not wanted" (Off, Offs), where the city has or plans
  -- a district it cannot share a city with (a water park), where it has no
  -- valid tile, or past an empire limit; two wonders needing one district
  -- get one. A district that takes population needs room: the city's
  -- required ones (and, with Target, what it has) below its count (issue
  -- 177); required districts are never dropped for it. self.Supplied lists
  -- them { City, Type, Wonder }; Elsewhere[wonder] the city where an
  -- empire-limited district stands already; NoRoom[wonder] true when only
  -- the count kept it out.
-- In: self.Participants, self.PlayerID, self.WonderCity; request (Wonders,
-- SupplyTo, Off, Offs); scan options; plannable, byType, empireCount,
-- asked from step 1; left from step 2 (counted down here).
-- Out: the supplied districts added to Plan, ForWonder, asked[p].Seen and
-- Kept; self.Supplied, self.Elsewhere, self.NoRoom.
local function SupplyForWonders(self, request, options, plannable, byType, empireCount, asked, left)
  local participants, playerID = self.Participants, self.PlayerID
  self.Supplied, self.Elsewhere, self.NoRoom = {}, {}, {}
  if request.Wonders and #request.Wonders > 0 then
    local wonderRows = {}
    for _, w in ipairs(SDP_Wonders.List(playerID, options.ignorePins)) do wonderRows[w.Type] = w end
    local have = {} -- base types some participant has or plans
    for _, part in ipairs(participants) do
      for districtType in pairs(part.Present) do have[SDP_Rules.BaseDistrict(districtType)] = true end
      for _, districtType in ipairs(part.Plan) do have[SDP_Rules.BaseDistrict(districtType)] = true end
    end
    local wonders = {}
    for _, wonderType in ipairs(request.Wonders) do wonders[#wonders + 1] = wonderType end
    table.sort(wonders)
    -- Districts that take population the city may still plan: its count
    -- less what it requires (asked[p].Count is already less what it has).
    local function Room(p, part)
      if not asked[p].Limited then return math.huge end
      local n = 0
      for _, districtType in ipairs(part.Plan) do
        if byType[districtType].Specialty then n = n + 1 end
      end
      return asked[p].Count - n
    end
    local function Placeable(part, districtType)
      for _, c in ipairs(part.Scan.Candidates) do
        if SDP_Overlay.CanPlace(SDP_Overlay.Subject(districtType, c.X, c.Y)) then return true end
      end
      return false
    end
    for _, wonderType in ipairs(wonders) do
      local w = wonderRows[wonderType]
      local base = (w ~= nil and w.Status == nil) and w.AdjacentDistrict or nil
      -- A wonder given one city (issue 234) needs that city's district.
      local only = self.WonderCity[wonderType]
      local function Missing()
        if only ~= nil then return not Has(participants, only, base) end
        return not have[base]
      end
      if base ~= nil and Missing() then
        -- The player's own district where a unique one replaces it (Rome: the Bath).
        local own = byType[base] ~= nil and base or nil
        for _, d in ipairs(plannable) do
          if SDP_Rules.BaseDistrict(d.Type) == base and d.Type ~= base then own = d.Type end
        end
        local row = own ~= nil and byType[own] or nil
        if row ~= nil and not row.CityCenter then
          local limited = row.MaxPerPlayer and row.MaxPerPlayer > 0
          if limited and left[own] == nil then
            left[own] = row.MaxPerPlayer - (empireCount[own] or 0)
          end
          local full = false
          -- SupplyTo (issue 182, SolveNow): that city first, then the list.
          local first, order = request.SupplyTo and request.SupplyTo[wonderType], {}
          for p, part in ipairs(participants) do
            if part.Key == first and only == nil then order[#order + 1] = p end
          end
          for p, part in ipairs(participants) do
            if part.Key ~= first and (only == nil or p == only) then order[#order + 1] = p end
          end
          for _, p in ipairs(order) do
            local part = participants[p]
            local off = (request.Offs and request.Offs[part.Key]) or request.Off or {}
            local a = asked[p]
            local fits = Missing() and not off[own] and not (limited and left[own] <= 0)
                and a.Status[own] == nil and not a.PinnedHere[own]
                and SDP_Rules.ExcludedBy(own, a.Kept) == nil and SDP_Rules.ExcludedBy(own, part.Present) == nil
                and Placeable(part, own)
            if fits and row.Specialty and Room(p, part) <= 0 then
              full = true
            elseif fits then
              part.Plan[#part.Plan + 1] = own
              a.Seen[own], a.Kept[own] = true, true
              part.ForWonder[own] = wonderType
              have[base] = true
              if limited then left[own] = left[own] - 1 end
              self.Supplied[#self.Supplied + 1] = { City = part.Key, Type = own, Wonder = wonderType }
            end
          end
          if Missing() and limited and left[own] <= 0 then
            self.Elsewhere[wonderType] = SDP_Multi.WhereBuilt(playerID, own)
          elseif Missing() and full then
            self.NoRoom[wonderType] = true
          end
        end
      end
    end
  end
end

-- Step 5, candidate districts (feedback item 11): districts that take
-- population, not required, plannable here, without an empire limit.
-- In: self.Participants; request (Pools, Pool); byType, asked.
-- Out: each participant's Pick (how many to pick) and Pool.
local function CandidateDistricts(self, request, byType, asked)
  local participants = self.Participants
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
end

-- Step 6, candidate plots: one candidate list for everybody.
-- In: each participant's Scan.Candidates.
-- Out: self.Candidates (sorted by plot index), each participant's Allowed
-- ([candidate] = true). Returns the candidates.
local function CandidatePlots(self)
  local participants = self.Participants
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
  return candidates
end

-- Step 7, fixed neighbours: the fixed subjects of every participant, once
-- each.
-- In: each participant's Scan; self.Weights, self.PlayerID.
-- Out: self.Fixed (sorted by plot index), self.Base, self.Board,
-- self.ExtraCalls. Returns the fixed subjects.
local function FixedNeighbours(self)
  local participants, playerID = self.Participants, self.PlayerID
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
  return fixed
end

-- Step 8, population and land: the population each city's plan needs (its
-- land part's worked plots and its housing target, issue 55), then the
-- land part per city.
-- In: self.Participants, self.PlayerID; request (Land, Weights); byType;
-- the fixed subjects.
-- Out: each participant's Population, and with the land part its Land.
-- Returns lands (each city's Land; empty without the land part).
local function PopulationAndLand(self, request, byType, fixed)
  local participants, playerID = self.Participants, self.PlayerID
  local land = request.Land ~= false
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
  return lands
end

-- Step 9, coverage part (design 19): the player's cities and the new ones;
-- off (no model at all) unless a weight is given.
-- In: self.Participants, self.PlayerID; request (Coverage, Only); scan options.
-- Out: self.Coverage.
local function CoveragePart(self, request, options)
  local participants, playerID = self.Participants, self.PlayerID
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
end

-- Step 10, district slots: every city's plan (an empire limit already
-- shared out above), then its candidates.
-- In: each participant's Plan, ForWonder, Allowed, Pool, Pick.
-- Returns slots, slotCity ([slot] = participant) and pools ([participant]
-- = how many to pick; nil when no city picks).
local function DistrictSlots(self)
  local participants = self.Participants
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
  return slots, slotCity, pools
end

-- Step 11, wonder slots:
  -- Wonders: one slot each, anywhere in the participating cities, placed
  -- after the districts (design 4.4). Built or pinned ones are left out
  -- (a pin being replaced does not count, issue 154).
-- In: self.Participants, self.PlayerID, self.WonderCity, self.Elsewhere,
-- self.NoRoom; request (Wonders); scan options; plannable; the fixed
-- subjects and candidates; slots, slotCity from step 10.
-- Out: the wonders' slots appended to slots (slotCity nil), the wonders
-- left out appended to unplaced; self.WonderGroup; an unavailable wonder
-- off self.AutoWonder. Returns wonderSlot ([wonder type] = its slot).
local function WonderSlots(self, request, options, plannable, fixed, candidates, slots, slotCity, unplaced)
  local participants, playerID = self.Participants, self.PlayerID
  local wonderGroup = #participants + 1
  self.WonderGroup = wonderGroup
  local wonderSlot = {} -- [wonder type] = its slot
  if request.Wonders and #request.Wonders > 0 then
    local list, byWonder = SDP_Wonders.List(playerID, options.ignorePins), {}
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
      if byWonder[wonderType] == nil or byWonder[wonderType].Status ~= nil then self.AutoWonder[wonderType] = nil end
      local w = byWonder[wonderType]
      if not seenWonder[wonderType] then
        seenWonder[wonderType] = true
        if w == nil then
          unplaced[#unplaced + 1] = { City = "WONDERS", Type = wonderType, Reason = "NOT_AVAILABLE" }
        elseif w.Status ~= nil then
          unplaced[#unplaced + 1] = { City = "WONDERS", Type = wonderType, Reason = w.Status }
        elseif w.AdjacentDistrict ~= nil and not (self.WonderCity[wonderType] == nil and present[w.AdjacentDistrict])
            and not (self.WonderCity[wonderType] ~= nil and Has(participants, self.WonderCity[wonderType], w.AdjacentDistrict)) then
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
          elseif self.NoRoom[wonderType] then
            -- Every city that could take the district has its count (issue 177).
            unplaced[#unplaced + 1] = { City = "WONDERS", Type = wonderType, Reason = "NO_ROOM_FOR_DISTRICT",
              District = w.AdjacentDistrict, Other = own }
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
            -- The district supplied for this wonder, if any: the wonder goes
            -- next to it, not next to another city's (issue 180).
            local requiresSlot = nil
            for s, spec in ipairs(slots) do
              if requiresSlot == nil and spec.ForWonder == wonderType then requiresSlot = s end
            end
            -- Given one city (issue 234): that city's plots, next to its districts.
            local only = self.WonderCity[wonderType]
            wonderSlot[wonderType] = #slots + 1
            slots[#slots + 1] = { Key = wonderType, Type = "WONDER", Group = wonderGroup,
              Allowed = only ~= nil and participants[only].Allowed or everywhere, City = only,
              Requires = w.AdjacentDistrict, RequiresSlot = requiresSlot, Support = support, Wonder = true }
            slotCity[#slots] = nil
          end
        end
      end
    end
  end
  return wonderSlot
end

-- Whose districts a wonder may count (issue 45): a wonder's plot goes to
-- a city that can take it, a fixed district belongs to the cities whose
-- territory or reach holds its plot. Returns { Wonder, Fixed } for
-- SDP_Search's Owners.
local function SearchOwners(participants, fixed)
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
  return owners
end

-- Each city's housing (issue 55); a fixed district's housing goes to the
-- participant that owns its plot, an unowned one's to the nearest.
-- Returns the cities for SDP_Search's Appeal.Cities and the function for
-- its FixedGroup.
local function HousingCities(participants, playerID)
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
  return housingCities, HousingGroup
end

-- Step 12, the search.
-- In: the session (Participants, PlayerID, Board, Weights, Coverage);
-- request (Swap, Distance, Apart, Weights); params; the candidates, slots,
-- lands, pools and fixed subjects from the steps before.
-- Out: self.Search.
local function BuildSearch(self, request, params, candidates, slots, lands, pools, fixed)
  local participants, playerID = self.Participants, self.PlayerID
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
  local owners = SearchOwners(participants, fixed)
  local housingCities, HousingGroup = HousingCities(participants, playerID)
  -- The city a slot's placement is planned for is not counted as covered by
  -- it (issue 91): SlotCity, as Session:OwnerOf; with `layout` counting its
  -- planned districts too.
  local function SlotOwner(search, m, i, layout)
    return participants[SlotCity(participants, playerID, search, m, i, layout)]
  end
  local function CoverOwner(search, m, i)
    local part = SlotOwner(search, m, i)
    return part ~= nil and part.Key or nil
  end
  -- Slot m on candidate i takes the plot from another of the player's
  -- cities (as Session:PlanFor's Swap); ties take the plots that need no
  -- swap (issue 162). Only with the swap switch on. A wonder's city counts
  -- the districts planned in `layout` (issue 238), as PlanFor does.
  local plotCity = {} -- [candidate] = the ID of the player's city owning it, or false
  local function Swapped(search, m, i, layout)
    local owner = plotCity[i]
    if owner == nil then
      local plot = Map.GetPlotByIndex(candidates[i].Index)
      local city = plot:GetOwner() == playerID and Cities.GetPlotPurchaseCity(plot) or nil
      owner = city ~= nil and city:GetID() or false
      plotCity[i] = owner
    end
    if owner == false then return false end
    local part = SlotOwner(search, m, i, layout)
    return part ~= nil and part.CityID ~= nil and part.CityID ~= owner
  end
  self.Search = SDP_Search.New({
    PlayerID = playerID, Board = self.Board, Weights = self.Weights, Params = params,
    Candidates = candidates, Slots = slots, Lands = lands, Coverage = self.Coverage, CoverOwner = CoverOwner,
    Swapped = request.Swap == true and Swapped or nil,
    Pools = pools, Costs = SDP_City.DistanceCosts(playerID, candidates, request.Distance, centers), Apart = apart,
    Exclusive = SDP_Rules.Exclusive(), Reach = reach, Owners = owners,
    Improve = request.Improvements and self.Improve or nil,
    Appeal = { Fixed = fixed, Weights = request.Weights, Workable = workable, Cities = housingCities,
      FixedGroup = HousingGroup },
  })
end

-- Step 13, slots with no legal plot: the required ones go to unplaced
-- (NO_LEGAL_PLOT), and an automatic wonder with no slot or no plot in the
-- city picked for it is tried in the next city (issue 234).
-- In: self.Search, self.Participants, self.AutoWonder; request (Wonders);
-- slots, slotCity, wonderSlot.
-- Out: self.AutoRetry; unplaced appended to.
local function NoLegalPlot(self, request, slots, slotCity, wonderSlot, unplaced)
  local participants = self.Participants
  local singles = self.Search:Singles()
  local noPlot = {}
  for _, s in ipairs(singles) do noPlot[s] = true end
  -- A wonder that cannot go in the city picked for it (no slot: no district
  -- for it there; or no valid tile): the next city (issue 234).
  for _, wonderType in ipairs(request.Wonders or {}) do
    local s = wonderSlot[wonderType]
    if self.AutoWonder[wonderType] ~= nil and (s == nil or noPlot[s]) then
      self.AutoRetry = self.AutoRetry or {}
      self.AutoRetry[wonderType] = true
    end
  end
  for _, s in ipairs(singles) do
    if not slots[s].Optional then
      local city = slotCity[s] and participants[slotCity[s]].Key or "WONDERS"
      local auto = slotCity[s] and participants[slotCity[s]].Auto[slots[s].Key] or nil
      unplaced[#unplaced + 1] = { City = city, Type = slots[s].Key, Reason = "NO_LEGAL_PLOT", Auto = auto,
        ForWonder = slots[s].ForWonder }
    end
  end
end

-- Step 14, blocks and groups: the search's required slots of each
-- participant, then the wonders (a city's candidates are in
-- Search.PoolSlots); with many cities, the groups planned one after
-- another (issue 142).
-- In: self.Search, self.Participants, self.WonderGroup; params.
-- Out: self.Blocks, self.Stats, self.Starts, self.NextStartIndex, and with
-- groups self.GroupList.
local function BlocksAndGroups(self, params)
  local participants, wonderGroup = self.Participants, self.WonderGroup
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
  if #participants > (params.GroupAbove or SDP_Multi.GROUP_ABOVE) then
    self.GroupList = SDP_Multi.Groups(participants, params.GroupSize or SDP_Multi.GROUP_SIZE)
    self.Stats.Groups = #self.GroupList
  end
end

function SDP_Multi.NewSession(request)
  local self = setmetatable({}, Session)
  SDP_Overlay.HidePins(request.IgnorePins)
  local playerID = request.PlayerID
  local params = SDP_Tiers.Params(SDP_Tiers.Multi, request.Tier, request.Params)
  self.Request, self.Params, self.PlayerID = request, params, playerID
  self.Weights = SDP_Rules.YieldWeights(request.Weights)
  local options = SDP_City.ScanOptions(request)

  local participants, existing, siteList = SDP_Multi.Participants(playerID,
    { Existing = request.Existing, Only = request.Only, Sites = request.Sites })
  self.Participants, self.Existing, self.SiteList = participants, existing, siteList

  local plannable, byType, empireCount, asked, unplaced = PlanCities(self, request, options)
  local left = ShareEmpireLimits(self, request, byType, empireCount, asked, unplaced)
  WonderCities(self, request)
  SupplyForWonders(self, request, options, plannable, byType, empireCount, asked, left)
  CandidateDistricts(self, request, byType, asked)
  self.Unplaced = unplaced
  local candidates = CandidatePlots(self)
  local fixed = FixedNeighbours(self)
  local lands = PopulationAndLand(self, request, byType, fixed)
  -- Improvements planned with the districts (issue 227).
  local scans = {}
  for p, part in ipairs(self.Participants) do scans[p] = part.Scan end
  self.Improve = SDP_Solver.ImproveModel(request, playerID, scans, fixed, self.Weights, lands,
    SDP_Land.PlotWeights(SDP_Land.Scale(request.Weights)), request.Land ~= false)
  CoveragePart(self, request, options)
  local slots, slotCity, pools = DistrictSlots(self)
  local wonderSlot = WonderSlots(self, request, options, plannable, fixed, candidates, slots, slotCity, unplaced)
  BuildSearch(self, request, params, candidates, slots, lands, pools, fixed)
  NoLegalPlot(self, request, slots, slotCity, wonderSlot, unplaced)
  self.SlotSpecs = slots
  BlocksAndGroups(self, params)
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
  local members = self:Members()
  local count = #members
  local order, scale = {}, 1
  if s <= 3 then
    for p = 1, count do order[p] = members[p] end
    if s == 3 then scale = 1 / 3 end
  elseif s <= 5 then
    for p = 1, count do order[p] = members[count - p + 1] end
    if s == 5 then scale = 1 / 3 end
  else
    local shift = math.floor((s - 4) / 2) % math.max(1, count)
    for p = 1, count do order[p] = members[(p - 1 + shift) % count + 1] end
    if s % 2 == 1 then scale = 1 / 3 end
  end
  order[#order + 1] = self.WonderGroup
  return order, scale
end

-- The participants being searched: the group in focus (Session:RunGroups),
-- else all of them.
function Session:Members()
  if self.Focus ~= nil then return self.Focus end
  local all = {}
  for p = 1, #self.Participants do all[p] = p end
  return all
end

-- Search one group (a list of participant indices) with every other city's
-- slots fixed where the best layout so far has them: the starts begin from
-- that layout with the group's and the wonders' slots off, and only those
-- slots move (SDP_Search's Active). nil: back to all participants.
function Session:SetFocus(group)
  local search = self.Search
  if group == nil then
    self.Focus, self.FocusBase, search.Active, search.ActiveGroups = nil, nil, nil, nil
    return
  end
  local members = { [self.WonderGroup] = true }
  for _, p in ipairs(group) do members[p] = true end
  local base = search.BestLayout ~= nil and Copy(search.BestLayout) or search:EmptyLayout()
  local active = {}
  for m = 1, search.K do
    if members[search.Groups[m]] then
      active[m] = true
      base[m] = 0
    end
  end
  self.Focus, self.FocusBase, search.Active, search.ActiveGroups = group, base, active, members
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
  local layout = self.FocusBase ~= nil and Copy(self.FocusBase) or search:EmptyLayout()
  local function Pooled(p) return (search.PoolCount[p] or 0) > 0 end
  if s == 2 then
    -- Each city with candidates takes its best ranked combination here.
    local active = {}
    local members = self:Members()
    for _, p in ipairs(members) do
      active[p] = Pooled(p) and search:ActiveOrder(p, search:Combos(p)[1].Slots) or self.Blocks[p]
    end
    active[self.WonderGroup] = self.Blocks[self.WonderGroup]
    local districts = {}
    for _, p in ipairs(members) do
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
  if self.GroupList ~= nil then
    self:RunGroups()
    return
  end
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

-- Many cities (issue 142): every city planned city by city (start 1 of the
-- whole plan: what the result is never worse than, design 4.7), then each
-- group in turn searched like a session of its own (its own budget, the
-- lighter tier's starts first, the tier's starts, the wide joint start and
-- the kicks) with the other cities' districts where the best plan so far has
-- them, GROUP_PASSES times over; a city at the edge of a group sees its
-- neighbours in the next one. Only the last pass's starts are alternatives:
-- they are whole plans with every group at its best but one.
function Session:RunGroups()
  local search, params = self.Search, self.Params
  local layout = search:EmptyLayout()
  for _, p in ipairs(self:StartPlan(1)) do
    if (#self.Blocks[p] > 0 or (search.PoolCount[p] or 0) > 0) and not search:OverBudget() then
      local best = self:SolveCity(p, layout, true)
      layout = best or self:Greedy(self.Blocks[p], layout)
    end
  end
  local gain, legal = search:Evaluate(layout)
  search:Consider(gain, legal, layout)
  self.First = { Layout = Copy(layout), Gain = gain }
  for _ = 1, params.GroupPasses or SDP_Multi.GROUP_PASSES do self:RunGroupPass(1, true) end
  self.NextStartIndex = params.Starts + 1
  self:Repair()
end

-- One pass over the groups: in each, the starts from `first` on (with
-- `prelude`, the lighter tier's starts before and the wide joint start
-- after, as Session:Run), then the kicks.
function Session:RunGroupPass(first, prelude)
  local search, params = self.Search, self.Params
  self.Starts = {}
  for _, group in ipairs(self.GroupList) do
    self:SetFocus(group)
    search:SetBudgets()
    if prelude and params.Prelude ~= nil then
      self:RunPrelude(params.Prelude)
      search:SetBudgets()
    end
    for s = first, first + params.Starts - 1 do
      if search:OverBudget() then break end
      self:RunStart(s)
    end
    if prelude then self:RunWideJoint() end
    search:Kicks(params.Kicks or 0)
  end
  self:SetFocus(nil)
end

-- The joint start once more with a wider beam (Params.WideJoint times the
-- tier's), on top of the fixed starts: widening start 2 itself is not
-- monotone (a wider beam's best model layout can polish to less), so the
-- portfolio only grows. It merges clusters across cities that the narrower
-- beam misses (offline benchmark, 2026-10-21).
function Session:RunWideJoint()
  local wide = self.Params.WideJoint
  if wide == nil or wide <= 1 or #self:Members() < 2 or self.Search:OverBudget() then return end
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
        -- A candidate the layout does not pick stays out: placing it would
        -- give its city more districts than its count (issue 182).
        for mm = 1, search.K do
          local other = self.SlotSpecs[search.SlotIndex[mm]]
          local active = not search.Optional[mm] or base[mm] ~= 0
          if mm ~= m and active and (base[mm] == i or (spec.Wonder and other.Wonder)
              or (spec.Requires ~= nil and SDP_Rules.Serves(search.Types[mm], spec.Requires))) then
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

-- For each district supplied for a wonder, the first other city whose
-- candidates in the best layout include one of its kind: { [wonder type] =
-- participant Key }, or nil when there is none (issue 182).
function Session:OtherHosts()
  local search, layout, hosts = self.Search, self.Search.BestLayout, nil
  if layout == nil or #self.Supplied == 0 then return nil end
  for _, supplied in ipairs(self.Supplied) do
    local base, best = SDP_Rules.BaseDistrict(supplied.Type), nil
    -- A wonder given one city (issue 234) keeps its district there.
    local only = self.WonderCity[supplied.Wonder] ~= nil
    for m = 1, only and 0 or search.K do
      local p = search.Groups[m]
      if layout[m] ~= 0 and search.Optional[m] and self.Participants[p].Key ~= supplied.City
          and SDP_Rules.BaseDistrict(search.Types[m]) == base and (best == nil or p < best) then
        best = p
      end
    end
    if best ~= nil then
      hosts = hosts or {}
      hosts[supplied.Wonder] = self.Participants[best].Key
    end
  end
  return hosts
end

-- Whether some district for a wonder goes to another city here than in
-- `other` (a session of the same request).
function Session:SuppliedElsewhere(other)
  local before = {}
  for _, supplied in ipairs(other.Supplied) do before[supplied.Wonder] = supplied.City end
  for _, supplied in ipairs(self.Supplied) do
    if before[supplied.Wonder] ~= supplied.City then return true end
  end
  return false
end

-- Whether this session's best layout is better than `other`'s (another
-- session of the same request, SolveNow): more wonders placed, then more
-- slots placed, then a higher value. Ties keep `other`.
function Session:WondersPlaced()
  local search, count = self.Search, 0
  for m = 1, search.K do
    if search.Kinds[m] == "WONDER" and search.BestLayout[m] ~= 0 then count = count + 1 end
  end
  return count
end

-- The automatic wonders (AutoWonder, issue 234) the best layout leaves out,
-- by type, sorted.
function Session:AutoUnplaced()
  local search, out = self.Search, {}
  if search.BestLayout == nil then return out end
  for m = 1, search.K do
    if search.Kinds[m] == "WONDER" and self.AutoWonder[search.Types[m]] ~= nil and search.BestLayout[m] == 0 then
      out[#out + 1] = search.Types[m]
    end
  end
  table.sort(out)
  return out
end

function Session:Beats(other)
  local a, b = self.Search, other.Search
  if a.BestLayout == nil then return false end
  if b.BestLayout == nil then return true end
  local wa, wb = self:WondersPlaced(), other:WondersPlaced()
  if wa ~= wb then return wa > wb end
  if a.BestPlaced ~= b.BestPlaced then return a.BestPlaced > b.BestPlaced end
  return a.BestGain > b.BestGain + 1e-9
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
  if self.GroupList ~= nil then
    self:RunGroupPass(self.NextStartIndex, false)
    self.NextStartIndex = self.NextStartIndex + params.Starts
    self:Repair()
    search.Converged = before ~= nil and search.BestGain == before
    return true
  end
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
-- city that builds it (SlotCity, with the layout's districts).
function Session:OwnerOf(m, i, layout)
  return SlotCity(self.Participants, self.PlayerID, self.Search, m, i, layout)
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
  -- Untangled first (ties take no swap, issue 162), the best of them first;
  -- the plans taken are ranked again (issue 189).
  return search:Pick(pool, count)
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
      -- A district the city needs that no plot is left for says so, as on
      -- the single-city path (issue 250).
      out.Unplaced[#out.Unplaced + 1] = { City = city, Type = spec.Key, Reason = "NO_FREE_PLOT", ForWonder = spec.ForWonder,
        Auto = (not spec.Wonder) and self.Participants[spec.Group].Auto[spec.Key] or nil }
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
  -- The improvements planned with the districts (issue 227): on the layer
  -- for the final evaluation, as in the search.
  local placed = {}
  for n, m in ipairs(slotsPlaced) do
    placed[n] = { Type = search.Types[m], Kind = search.Kinds[m], Index = search.Candidates[layout[m]].Index }
  end
  local improvePlan, forced = search:ImprovePlan(layout)
  local byPlaced, improveExtra = SDP_Solver.ImproveEntries(self.Improve, placed, improvePlan)
  local withoutExtra = {}
  for _, subject in ipairs(extra) do withoutExtra[#withoutExtra + 1] = subject end
  for _, subject in ipairs(improveExtra) do extra[#extra + 1] = subject end
  local final = SDP_Overlay.Evaluate(subjects, self.Fixed, self.Weights, extra)
  self.ExtraCalls = self.ExtraCalls + 2 * #subjects + #self.Fixed
  local without = nil
  if #improveExtra > 0 then
    without = SDP_Overlay.Evaluate(subjects, self.Fixed, self.Weights, withoutExtra)
    self.ExtraCalls = self.ExtraCalls + 2 * #subjects + #self.Fixed
  end
  local appeal = {}
  if search.AppealModel ~= nil then out.AppealDelta = search:AppealDelta(layout, appeal) end
  for n, m in ipairs(slotsPlaced) do
    local i = layout[m]
    local item, c = final.Placements[n], search.Candidates[i]
    local p = self:OwnerOf(m, i, layout)
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
      Improvements = byPlaced[n],
      ImprovementYields = without and SDP_Solver.YieldDifference(item.Yields, without.Placements[n].Yields) or nil,
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
    local city = out.Cities[self:OwnerOf(slotsPlaced[n], layout[slotsPlaced[n]], layout)]
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
  -- The improvements of each city's worked plots (issue 227 question 3).
  if self.Improve ~= nil and self.Improve.WorkedOn then
    local boosts = nil
    if search.AppealModel ~= nil then
      local _, b = search.AppealModel:Score(layout)
      boosts = b
    end
    for p, part in ipairs(self.Participants) do
      if part.Land ~= nil then
        out.Cities[p].Worked = SDP_Solver.WorkedImprovements(self.Improve, part.Land, placed, improvePlan, forced,
          boosts and boosts[p] or nil)
      end
    end
    if search.AppealModel ~= nil then search.AppealModel:ClearBoosts() end
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
--                          NEEDS_DISTRICT, NO_ROOM_FOR_DISTRICT (every city that could take it has its
--                          count, issue 177), DISTRICT_ELSEWHERE (Where: the city's name), NEEDS_IMPROVEMENT
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
  -- Distinct untangles each layout (ties take no swap, issue 162), which
  -- moves the board: clear it again before the plans.
  local entries = self:Distinct(self.Params.Solutions or 3)
  board:Clear()
  for _, entry in ipairs(entries) do
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
    stats.Mismatch = (not best.Legal) or math.abs(best.Gain - entries[1].Gain) > 1e-6 or nil
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
  if cities > (params.GroupAbove or SDP_Multi.GROUP_ABOVE) then
    -- In groups (Session:RunGroups): each group a session of its own, every pass.
    local groups = math.ceil(cities / (params.GroupSize or SDP_Multi.GROUP_SIZE))
    local passes = params.GroupPasses or SDP_Multi.GROUP_PASSES
    local inner = {}
    for k, v in pairs(params) do inner[k] = v end
    inner.GroupAbove = math.huge
    return passes * groups * SDP_Multi.EstimateUnits(math.ceil(cities / groups), districts, wonders, inner, pick, pool)
  end
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

-- A copy of `request` with map[key] = value in its table `field`.
local function With(request, field, key, value)
  local again, map = {}, {}
  for k, v in pairs(request) do again[k] = v end
  for k, v in pairs(request[field] or {}) do map[k] = v end
  map[key] = value
  again[field] = map
  return again
end

-- Solve `request` as well and keep the better of it and `session`
-- (Session:Beats; ties keep `session`). Returns the kept session, whether
-- it is the new one, the DMT calls of the one dropped and the new one. One overlay for
-- both: each board's subjects leave it before the other session evaluates
-- anything (its last layout would be neighbours).
-- A session for `request`, built again with the next city for every
-- automatic wonder that cannot go in the one picked (Session.AutoRetry,
-- issue 234); before it runs. The overlay holds no other session's subjects.
local function Prepared(request)
  local session = SDP_Multi.NewSession(request)
  while session.AutoRetry ~= nil do
    session.Board:Clear()
    local again = {}
    for k, v in pairs(request) do again[k] = v end
    local skip = {}
    for k, v in pairs(request.AutoSkip or {}) do skip[k] = v end
    for wonderType in pairs(session.AutoRetry) do skip[wonderType] = (skip[wonderType] or 0) + 1 end
    again.AutoSkip = skip
    request = again
    session = SDP_Multi.NewSession(request)
  end
  return session
end

local function TryAgain(session, request, needed)
  session.Board:Clear()
  local other = Prepared(request)
  if needed ~= nil and not needed(other) then return session, false, 0 end
  -- The progress shown: another solve takes about as long again.
  local job = SDP_Task ~= nil and SDP_Task.Current() or nil
  if job ~= nil and job.Estimate ~= nil then job.Estimate = job.Units + job.Estimate end
  other:Run()
  local kept, dropped = session, other
  if other:Beats(session) then kept, dropped = other, session end
  dropped.Board:Clear()
  return kept, kept == other, dropped.Board.Calls + dropped.ExtraCalls, other
end

-- The solve itself; the overlay must be installed (SDP_Task jobs, tests).
-- An empire-limited district several cities ask for (issue 234,
-- NewSession's HostChoices): solved with each host in turn, nearest the
-- centre first, keeping the best plan; with two such districts the second
-- is tried with the first's best host. Stats.Hosts on the kept session:
-- { Tried = solves, Calls = the DMT calls of those dropped, [district type]
-- = the host's Key }.
-- A district supplied for a wonder goes to the first city in the list that
-- can take it, as a required one, and the wonder next to it. Where another
-- city picks the same district from its candidates in the best plan, it is
-- supplied to that city instead and the request solved again (issue 182):
-- that city's own pick stands next to the wonder and the first city has the
-- place for another candidate. The better plan is kept (Session:Beats).
-- Stats.Again on the kept session: { Moved = whether the second plan was
-- kept, Calls = the DMT calls of the one dropped }.
SDP_Multi.SUPPLY_AGAIN = true -- false: one solve, as before issue 182 (offline comparison)
SDP_Multi.HOSTS_AGAIN = true -- false: the nearest host only (offline comparison)

function SDP_Multi.SolveNow(request)
  local session = Prepared(request)
  session:Run()
  local hostStats = nil
  if SDP_Multi.HOSTS_AGAIN and #session.HostChoices > 0 then
    hostStats = { Tried = 1, Calls = 0 }
    for _, choice in ipairs(session.HostChoices) do
      local best = choice.Keys[1]
      local named = session.Request.UniqueTo and session.Request.UniqueTo[choice.Type]
      if named ~= nil then best = named end
      for _, key in ipairs(choice.Keys) do
        if key ~= best then
          -- From the kept session's request (its AutoSkip included).
          local again = With(session.Request, "UniqueTo", choice.Type, key)
          local moved, calls
          session, moved, calls = TryAgain(session, again)
          hostStats.Tried, hostStats.Calls = hostStats.Tried + 1, hostStats.Calls + calls
          if moved then best = key end
        end
      end
      hostStats[choice.Type] = best
    end
  end
  -- An automatic wonder the plan leaves out although it has a valid tile
  -- in its city (the city's districts took the room): the next city,
  -- solved again, kept when it is better (Session:Beats). The ranking
  -- moves on from the last solve, kept or not, until it places the wonders
  -- or no city is left (past the last one a wonder is not automatic, so
  -- at most cities x wonders solves; issue 234).
  local tried = session
  while true do
    local missing = tried:AutoUnplaced()
    if #missing == 0 then break end
    local again = {}
    for k, v in pairs(tried.Request) do again[k] = v end
    local skip = {}
    for k, v in pairs(tried.Request.AutoSkip or {}) do skip[k] = v end
    for _, wonderType in ipairs(missing) do skip[wonderType] = (skip[wonderType] or 0) + 1 end
    again.AutoSkip = skip
    local _
    session, _, _, tried = TryAgain(session, again)
  end
  request = session.Request
  local hosts = SDP_Multi.SUPPLY_AGAIN and session:OtherHosts() or nil
  if hosts ~= nil then
    local again = {}
    for key, value in pairs(request) do again[key] = value end
    again.SupplyTo = hosts
    local first, moved, calls = session, false, 0
    session, moved, calls = TryAgain(session, again, function(other) return other:SuppliedElsewhere(first) end)
    if moved or calls > 0 then session.Stats.Again = { Moved = moved, Calls = calls } end
  end
  if hostStats ~= nil then session.Stats.Hosts = hostStats end
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
