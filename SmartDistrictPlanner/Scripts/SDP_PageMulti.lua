-- SDP_PageMulti: the "several cities" tab of the planner panel
-- (docs/multicity-design.md section 4, step 2). Included by SDP_Panel.lua
-- into its context: uses its Controls and the SDP_UI helpers.
--   Cities    the player's cities and city-center pins as chips, three a
--             row; a click switches one on or off (feedback item 10). By
--             default the centre (the city selected on the map when the
--             panel opened, else the capital) and the nearest ones joined
--             to it within NEAR plots, at most DEFAULT_CITIES
--             (SDP_Multi.DefaultGroup, issue 63); "all cities", "clear all"
--             and "default" buttons. Any number of cities: more than
--             SDP_Multi.GROUP_ABOVE are planned in groups of nearby cities
--             (issue 142).
--   Plans     one district list for every city, or a city's own list (the
--             "plan for" pulldown; role templates from SDP_Rules.Templates).
--             A list gives each district a state (required, candidate, off,
--             automatic: SDP_UI.DefaultState) and how many districts that
--             take population each city plans; above the required ones the
--             solver picks from the candidates (feedback item 11).
--             A district with an empire limit (government plaza) goes to one
--             of the cities that require it: a city requiring it in its own
--             list comes first; otherwise the solver tries each city that
--             requires it in the shared list, at most SDP_Multi.HOST_TRIES
--             nearest the centre, and keeps the best plan (issue 234).
--   Wonders   chosen in a pulldown, shown as tags; each tag has a pulldown
--             for the city it goes in: automatic (the city with the most
--             production that can take it) or one city (issue 234,
--             SDP_Multi's WonderCities).
--   Weights   the five yields, the land part, the distance cost and the
--             coverage part (SDP_Coverage, design 19): 0 = off, the default.
--   Solve     always over several frames (SDP_Task); the result lists up to
--             three distinct solutions; the selected one is previewed on the
--             map (SDP_Preview) and can be placed as map tacks, with reminder
--             pins on the woods and rainforest it relies on (feedback item 5).

SDP_PageMulti = {}
local P = SDP_PageMulti
P.Name = "MULTI"

local m_cityIM = InstanceManager:new("CityChip", "Root", Controls.MultiCityStack)
local m_cellIM = InstanceManager:new("DistrictCell", "Root", Controls.MultiDistrictStack)
local m_utilityIM = InstanceManager:new("DistrictCell", "Root", Controls.MultiUtilityStack)
local m_chipIM = InstanceManager:new("MultiWonderChip", "Root", Controls.MultiWonderChipStack)
local m_weightIM = InstanceManager:new("WeightColumn", "Root", Controls.MultiWeightStack)
local m_solutionIM = InstanceManager:new("SolutionRow", "Root", Controls.MultiSolutionStack)
local m_resultIM = InstanceManager:new("ResultRow", "Root", Controls.MultiResultStack)

-- A district list: States = { [type] = state }, Count = number or nil: how
-- many districts that take population each city ends with (issue 144; nil:
-- SDP_UI.DEFAULT_COUNT).
local m_shared = { States = {}, Count = nil } -- every city without its own
local m_plans = {}     -- [participant Key] = a city's own list
local m_planFor = "ALL" -- the list the grid edits: "ALL" or a participant Key
local m_wonders = {}   -- [BuildingType] = true
local m_wonderCities = {} -- [BuildingType] = participant Key: the city a wonder goes in (issue 234; nil: automatic)
local m_center = nil   -- the city the default group is around (nil: the capital)
local m_existing = {}  -- [cityID] = true | false: switches over the default group
local m_sites = {}     -- [site Key] = true | false: city-center pins switched over the default group
-- The panel's weight columns plus the coverage part, as on the single-city tab.
local COLUMNS, COLUMN_WIDTH = {}, 50 -- nine columns, as on the single-city tab
for _, column in ipairs(SDP_UI.WEIGHT_COLUMNS) do COLUMNS[#COLUMNS + 1] = column end
COLUMNS[#COLUMNS + 1] = SDP_UI.COVERAGE_COLUMN
local m_weights = {}
for _, column in ipairs(COLUMNS) do m_weights[column.Key] = column.Default or 1 end
local m_swap = true -- plots swapped from another of our cities are candidates (issue 54; on by default, issue 162)
local m_replace = false -- plan over this mod's earlier pins for the cities and replace them
local m_remind = true
local m_improve = true -- plan the improvements the districts take adjacency from (issue 227)
local m_worked = false -- tack the improvements of the worked plots too (issue 227)
local m_result = nil
local m_solution = 1
local m_view = { Cities = {}, Districts = {}, Wonders = {}, Solutions = {}, Results = {}, Plans = {}, Templates = {} } -- for tests
local m_lookNext = false -- move the camera to the cities when the next result shows (issue 67)
local m_kit -- SDP_PageKit: weights, tier, preset, fold, switches (made at the end)

local UpdateFold, FitPage -- defined below
local function Remember() m_kit.Remember() end
function P.Restore() m_kit.Restore() end

-- How a participant is called: its number (the name its pins get, see
-- SDP_City.CityNumbers) and the city's name, or "Site n" for a planned city.
function P.CityLabel(city)
  if city.Kind == "CITY" then return Locale.Lookup("LOC_SDP_CITY_N", city.Number or 0, Locale.Lookup(city.Name)) end
  return Locale.Lookup("LOC_SDP_SITE_N", city.Number or city.SiteNumber or 0)
end

local function ClearResult()
  m_kit.CancelTask()
  if m_result ~= nil then
    m_result = nil
    SDP_Preview.Clear()
    P.Render()
  end
end

-- ===========================================================================
-- Inputs
-- ===========================================================================
local function Districts() return SDP_Rules.PlannableDistricts(Game.GetLocalPlayer()) end

-- The list the grid shows and edits, and its key ("ALL": the shared one).
local function EditedList()
  if m_planFor ~= "ALL" and m_plans[m_planFor] ~= nil then return m_plans[m_planFor], m_planFor end
  return m_shared, "ALL"
end

-- Empire-limited districts the player has built up to the limit (issue 108):
-- written as built, with where (greyed out through StatusOf).
local function Built() return SDP_City.EmpireBuilt(Game.GetLocalPlayer(), Districts()) end

-- What the existing city of a participant Key has (SDP_City.SpecialtyHave;
-- nil for the shared list and a planned city), pins being replaced left out.
local function CityOf(key)
  return key ~= nil and tonumber(key:match("^C(%d+)$") or "") or nil
end

local ShowWonders -- defined below
local UpdateEstimate -- defined below

-- The pins being replaced, { [pin ID] = true }, or nil with replace off.
-- They do not count as what a city has, nor a wonder as pinned (issue 154).
local function ReplacedPins()
  local ignore = nil
  if m_replace then
    for _, pin in ipairs(P.OwnPins()) do
      ignore = ignore or {}
      ignore[pin.ID] = true
    end
  end
  return ignore
end

local function HaveOf(key)
  local cityID = CityOf(key)
  if cityID == nil then return nil end
  return SDP_City.HaveOf(Game.GetLocalPlayer(), cityID, ReplacedPins())
end

-- Why each district cannot be planned for participant `key` (a city's own
-- list), as the solver judges it (SDP_City.ListStatus, issue 165, 244):
-- what the city has built (complete or not), cannot share a city with, has
-- tacked, and the empire limit, pins being replaced left out. As the
-- single-city tab's list: these are greyed out, neither required nor
-- candidates. The shared list (key "ALL" or nil): the empire limit only.
-- An empire-limited district built up to its limit reads "built" (issue
-- 108), wherever it stands.
local function StatusOf(key, districts)
  local status = SDP_City.ListStatus(Game.GetLocalPlayer(), CityOf(key), districts, ReplacedPins())
  for districtType, why in pairs(Built()) do
    if status[districtType] ~= nil then status[districtType] = why end
  end
  return status
end

-- The count is a target (issue 144). A city's own list starts from what
-- the city has; the shared list serves cities with different numbers, so
-- it goes up to the number of district types that take population.
local function ListOf(list, key)
  local districts = Districts()
  if key ~= nil and key ~= "ALL" then
    -- What the city has built or tacked is in its count already: such a
    -- district set to required is not counted again (the solver skips it).
    return SDP_UI.ListRequest(districts, list.States, list.Count or SDP_UI.DEFAULT_COUNT, StatusOf(key, districts),
      HaveOf(key))
  end
  local ceiling = 0
  for _, d in ipairs(districts) do
    if d.Specialty then ceiling = ceiling + 1 end
  end
  return SDP_UI.ListRequest(districts, list.States, list.Count or SDP_UI.DEFAULT_COUNT, StatusOf("ALL", districts), nil,
    ceiling)
end

-- The edited list's count. A city's own count starts from what the city
-- has, so show it again whenever its tacks or the replace switch change.
local function ShowCount()
  local counts = ListOf(EditedList())
  Controls.MultiCountValue:SetText(tostring(counts.Target))
  Controls.MultiCountLess:SetDisabled(counts.Target <= counts.Have + counts.MustSpecialty)
  Controls.MultiCountMore:SetDisabled(counts.Target >= counts.Top)
  m_view.Count = counts.Target
end

-- After the tacks or the replace switch change: a city's list greys out
-- what the city has tacked again (issue 165); the shared list shows its
-- count.
local function ShowHave()
  if m_planFor ~= "ALL" then
    P.RefreshLists()
  else
    ShowWonders()
    ShowCount()
  end
end

local function WonderTypes()
  local list = {}
  for _, w in ipairs(SDP_Wonders.List(Game.GetLocalPlayer(), ReplacedPins())) do
    if m_wonders[w.Type] and w.Status == nil then list[#list + 1] = w.Type end
  end
  table.sort(list) -- the solver's slot order, as before the list was sorted by era
  return list
end

-- Who takes part: the default group with the player's switches over it,
-- as an explicit choice for every city and city-center pin (what the
-- request sends, so the solver sees the same cities).
local function Choice()
  local group = SDP_Multi.DefaultGroup(Game.GetLocalPlayer(), m_center)
  local existing, sites = {}, {}
  for _, e in ipairs(group.Order) do
    if e.Kind == "CITY" then
      local on = m_existing[e.CityID]
      if on == nil then on = group.Cities[e.CityID] == true end
      existing[e.CityID] = on
    else
      local on = m_sites[e.Key]
      if on == nil then on = group.Sites[e.Key] == true end
      sites[e.Key] = on
    end
  end
  return existing, sites, group
end

local function Participants()
  local existing, sites = Choice()
  return SDP_Multi.Participants(Game.GetLocalPlayer(), { Existing = existing, Sites = sites })
end
P.Participants = Participants -- tests

function P.Request()
  local playerID = Game.GetLocalPlayer()
  local shared = ListOf(m_shared)
  local weights = {}
  for key, value in pairs(m_weights) do weights[key] = value end
  local existing, sites, group = Choice()
  -- Cities with their own list; lists of cities no longer taking part are
  -- kept for later but not sent.
  local plans, pools, counts, autos, offs = nil, nil, nil, nil, nil
  local anything = #shared.Must > 0 or shared.Pick > 0
  local participants = Participants()
  for _, part in ipairs(participants) do
    local own = m_plans[part.Key]
    if own ~= nil then
      local list = ListOf(own, part.Key)
      plans, pools, counts, autos, offs = plans or {}, pools or {}, counts or {}, autos or {}, offs or {}
      plans[part.Key], pools[part.Key], counts[part.Key], autos[part.Key] = list.Must, list.Pool, list.Target, list.Auto
      offs[part.Key] = SDP_UI.OffSet(own.States)
      if #list.Must > 0 or list.Pick > 0 then anything = true end
    end
  end
  local wonders = WonderTypes()
  if #participants == 0 or (not anything and #wonders == 0) then return nil end
  -- The city each wonder goes in (issue 234), when that city takes part.
  local wonderCities = nil
  for _, wonderType in ipairs(wonders) do
    for _, part in ipairs(participants) do
      if part.Key == m_wonderCities[wonderType] then
        wonderCities = wonderCities or {}
        wonderCities[wonderType] = part.Key
      end
    end
  end
  return {
    PlayerID = playerID, Tier = m_kit.Tier, Districts = shared.Must, Pool = shared.Pool, Count = shared.Target, Auto = shared.Auto, Target = true,
    Plans = plans, Pools = pools, Counts = counts, Autos = autos, Wonders = wonders, Sites = sites,
    WonderCities = wonderCities, Center = group.Center and group.Center.Key or nil,
    Off = SDP_UI.OffSet(m_shared.States), Offs = offs,
    Existing = existing, Weights = weights, Land = m_weights.LAND > 0, Coverage = m_weights.COVERAGE, Distance = m_weights.DISTANCE,
    Remind = m_remind, Apart = true, IgnorePins = m_replace and P.OwnPins() or nil, Swap = m_swap,
    Improvements = m_improve, WorkedImprovements = m_worked,
  }
end

-- This mod's earlier pins for the taking-part cities (named with their numbers).
function P.OwnPins()
  local numbers = {}
  for _, part in ipairs(Participants()) do
    if part.Number ~= nil then numbers[#numbers + 1] = part.Number end
  end
  return SDP_Pins.Own(Game.GetLocalPlayer(), numbers)
end

local function UpdateReplaceLabel()
  Controls.MultiReplaceLabel:SetText(Locale.Lookup("LOC_SDP_REPLACE_OWN_SHORT", #P.OwnPins()))
end

-- With replace on, a city's own count starts from what it has, replaced
-- pins left out; a wonder whose pin is replaced can be chosen again (issue
-- 154), and whether there is something to plan follows it, result or not.
local function ReplaceChanged()
  if m_planFor ~= "ALL" then
    P.RefreshLists()
  else
    ShowWonders()
    UpdateEstimate()
  end
end

-- Districts per city on average and what they pick from, for the estimate.
local function PlanSize(request, participants)
  local total, pick, pool = 0, 0, 0
  for _, part in ipairs(participants) do
    local key = part.Key
    local must = (request.Plans and request.Plans[key]) or request.Districts
    local count = (request.Counts and request.Counts[key]) or request.Count or 0
    local candidates = (request.Pools and request.Pools[key]) or request.Pool or {}
    total = total + #must
    local mustSpecialty = 0
    for _, t in ipairs(must) do
      local row = GameInfo.Districts[t]
      if row and row.RequiresPopulation then mustSpecialty = mustSpecialty + 1 end
    end
    pick = math.max(pick, count - mustSpecialty)
    pool = math.max(pool, #candidates)
  end
  local n = math.max(1, #participants)
  return math.ceil(total / n), pick, pool
end

local function Estimate(request, params)
  local participants = SDP_Multi.Participants(request.PlayerID, { Existing = request.Existing, Sites = request.Sites })
  local size, pick, pool = PlanSize(request, participants)
  return SDP_Multi.EstimateUnits(#participants, size, #request.Wonders, params, pick, pool)
end

UpdateEstimate = function()
  local request = P.Request()
  -- Whether there is something to plan may have changed (issue 67).
  P.UpdateButtons()
  if m_result == nil and not SDP_Task.IsRunning() then
    Controls.MultiSummary:SetText(Locale.Lookup(request == nil and "LOC_SDP_MULTI_NONE" or "LOC_SDP_RESULT_READY"))
  end
  if request == nil then
    Controls.MultiEstimate:SetText("")
    return
  end
  Controls.MultiEstimate:SetText(SDP_UI.EstimateText(Estimate(request, SDP_Tiers.Params(SDP_Tiers.Multi, m_kit.Tier))))
end

-- The first change to a city's list starts it as a copy of the shared one.
local function OwnList()
  if m_planFor ~= "ALL" and m_plans[m_planFor] == nil then
    local copy = { States = {}, Count = m_shared.Count }
    for t, state in pairs(m_shared.States) do copy.States[t] = state end
    m_plans[m_planFor] = copy
  end
  return EditedList()
end

-- Set a district's state in the edited list (MUST, POOL, OFF, AUTO).
function P.SetState(districtType, state)
  local list = OwnList()
  for _, d in ipairs(Districts()) do
    if d.Type == districtType and SDP_UI.StateOf(list.States, d) ~= state then
      list.States[districtType] = state
      ClearResult()
    end
  end
  P.RefreshLists()
end

-- Tests and older callers: selected = MUST, unselected = the default state.
function P.SetSelected(districtType, on)
  for _, d in ipairs(Districts()) do
    if d.Type == districtType then P.SetState(districtType, on and "MUST" or SDP_UI.DefaultState(d)) end
  end
end

-- How many districts that take population each city of the edited list
-- ends with (issue 144): a city with as many or more plans none from the pool.
function P.SetCount(count)
  local list, key = OwnList()
  local before = ListOf(list, key).Target
  local after = ListOf({ States = list.States, Count = count }, key).Target
  list.Count = after
  if after ~= before then ClearResult() end
  P.RefreshLists()
end

-- Which list the grid edits: "ALL" (every city without its own) or a
-- participant Key.
function P.SetPlanFor(key)
  m_planFor = key or "ALL"
  P.RefreshLists()
end

-- The city picked in "Districts for" drops its own list and uses the shared
-- one again (issue 187; the back button beside the pulldown).
function P.UseShared()
  if m_planFor ~= "ALL" and m_plans[m_planFor] ~= nil then
    m_plans[m_planFor] = nil
    ClearResult()
  end
  P.RefreshLists()
end

-- Make the edited list require `types` (a template), everything else at its
-- default; nil on a city: back to the shared list.
function P.ApplyPlan(types)
  -- A template replaces the districts; the count stays as the player set it.
  local list = { States = {}, Count = EditedList().Count }
  for _, t in ipairs(types or {}) do list.States[t] = "MUST" end
  if m_planFor == "ALL" then
    m_shared = list
  elseif types == nil then
    m_plans[m_planFor] = nil
  else
    m_plans[m_planFor] = list
  end
  ClearResult()
  P.RefreshLists()
end

function P.SetWonder(wonderType, on)
  if (m_wonders[wonderType] == true) ~= (on == true) then
    m_wonders[wonderType] = on or nil
    if not on then m_wonderCities[wonderType] = nil end
    ClearResult()
    Remember() -- kept in the save with the other settings (issue 166)
  end
  P.RefreshLists()
  UpdateFold()
end

-- The city a wonder goes in (issue 234): a participant Key, nil: automatic.
function P.SetWonderCity(wonderType, key)
  if m_wonderCities[wonderType] ~= key then
    m_wonderCities[wonderType] = key
    ClearResult()
  end
  ShowWonders()
end

-- A change to who takes part: the result goes only when the cities differ.
local function ChangeCities(change)
  local function Keys()
    local keys = {}
    for _, part in ipairs(Participants()) do keys[#keys + 1] = part.Key end
    return table.concat(keys, ",")
  end
  local before = Keys()
  change()
  if Keys() ~= before then ClearResult() end
  P.RefreshLists()
end

-- Switch a city on or off; nil: back to the default group.
function P.SetExisting(cityID, on)
  ChangeCities(function() m_existing[cityID] = on end)
end

-- Switch a city-center pin on or off (feedback item 10); nil: the default.
function P.SetSite(key, on)
  ChangeCities(function() m_sites[key] = on end)
end

-- The default group around a city (the one selected on the map when the
-- panel opens; nil: the capital). A new centre drops the switches; the
-- same centre named another way (the capital by its ID) keeps them.
function P.SetCenter(cityID)
  local function CenterKey(id)
    local center = SDP_Multi.DefaultGroup(Game.GetLocalPlayer(), id).Center
    return center and center.Key or ""
  end
  if cityID == m_center or CenterKey(cityID) == CenterKey(m_center) then
    m_center = cityID
    return
  end
  ChangeCities(function()
    m_center = cityID
    m_existing, m_sites = {}, {}
  end)
end

-- The buttons over the chips: every city and pin on (issue 142); every city
-- and pin off; the default group.
function P.AllCities()
  ChangeCities(function()
    local _, _, group = Choice()
    for _, e in ipairs(group.Order) do
      if e.Kind == "CITY" then m_existing[e.CityID] = true else m_sites[e.Key] = true end
    end
  end)
end

function P.ClearCities()
  ChangeCities(function()
    local _, _, group = Choice()
    for _, e in ipairs(group.Order) do
      if e.Kind == "CITY" then m_existing[e.CityID] = false else m_sites[e.Key] = false end
    end
  end)
end

function P.DefaultCities()
  ChangeCities(function() m_existing, m_sites = {}, {} end)
end

-- ===========================================================================
-- Lists
-- ===========================================================================
local CHIP_ROWS, CHIP_HEIGHT, CHIP_GAP, CHIP_NAME = 5, 26, 4, 112 -- at most five rows shown, then the list scrolls
local RESULT_ROWS = 80 -- two rows of results
local m_chipRows = 1 -- rows of city chips

-- Keep the page inside the window (issue 71): the result list takes what
-- the page has left (SDP_UI.FitResults); below two rows, the chip list gives
-- way down to two rows first.
FitPage = function()
  local shown = math.min(m_chipRows, CHIP_ROWS)
  local function Apply()
    Controls.MultiCityScroll:SetSizeY(shown * CHIP_HEIGHT + (shown - 1) * CHIP_GAP)
    Controls.MultiCityStack:CalculateSize()
    Controls.MultiCityScroll:CalculateSize()
    return SDP_UI.FitResults(Controls.MultiBody, Controls.MultiPage, Controls.MultiResultScroll,
      Controls.MultiSettingsScroll, Controls.MultiSettingsStack)
  end
  local height = Apply()
  while height < RESULT_ROWS and shown > 2 do
    shown = shown - 1
    height = Apply()
  end
end
P.FitPage = FitPage

-- Under the wonder tags (issue 66): the districts the chosen wonders need
-- that no city of the group has. Before a solve: they go to the city that
-- builds the wonder (issue 234); after it: which city got them.
function P.ShowSupply()
  local lines = {}
  local supplied = m_result ~= nil and m_result.Ok and m_result.Supplied or nil
  if supplied ~= nil then
    local byKey = {}
    for _, city in ipairs(m_result.Cities or {}) do byKey[city.Key] = city end
    for _, s in ipairs(supplied) do
      local city = byKey[s.City]
      lines[#lines + 1] = Locale.Lookup("LOC_SDP_MULTI_SUPPLIED", SDP_UI.TypeName(s.Type), SDP_UI.TypeName(s.Wonder),
        city ~= nil and P.CityLabel(city) or s.City)
    end
  else
    local wonders = WonderTypes()
    if #wonders > 0 then
      local has = {}
      local rows = {}
      for _, w in ipairs(SDP_Wonders.List(Game.GetLocalPlayer(), ReplacedPins())) do rows[w.Type] = w end
      local shared = ListOf(m_shared)
      for _, t in ipairs(shared.Must) do has[SDP_Rules.BaseDistrict(t)] = true end
      for _, own in pairs(m_plans) do
        for _, t in ipairs(ListOf(own).Must) do has[SDP_Rules.BaseDistrict(t)] = true end
      end
      for _, part in ipairs(Participants()) do
        local scan = part.Kind == "CITY" and SDP_City.Scan(Game.GetLocalPlayer(), part.CityID) or nil
        if scan ~= nil then
          for t in pairs(SDP_City.PresentDistricts(scan)) do has[SDP_Rules.BaseDistrict(t)] = true end
        end
      end
      for _, wonderType in ipairs(wonders) do
        local base = rows[wonderType] and rows[wonderType].AdjacentDistrict or nil
        if base ~= nil and not has[base] and GameInfo.Districts[base] ~= nil and not GameInfo.Districts[base].CityCenter then
          has[base] = true
          local own = base
          for _, d in ipairs(Districts()) do
            if SDP_Rules.BaseDistrict(d.Type) == base then own = d.Type end
          end
          lines[#lines + 1] = Locale.Lookup("LOC_SDP_MULTI_SUPPLY", SDP_UI.TypeName(own), SDP_UI.TypeName(wonderType))
        end
      end
    end
  end
  Controls.MultiSupplyNote:SetText(table.concat(lines, "[NEWLINE]"))
  Controls.MultiSupplyNote:SetHide(#lines == 0)
  m_view.Supply = lines
end

-- The fold line's parts (issue 71): what is not as usual.
local function FoldParts()
  local parts = {}
  if m_weights.LAND == 0 then parts[#parts + 1] = Locale.Lookup("LOC_SDP_FOLD_LAND_OFF") end
  if not m_swap then parts[#parts + 1] = Locale.Lookup("LOC_SDP_FOLD_NO_SWAP") end
  if m_replace then parts[#parts + 1] = Locale.Lookup("LOC_SDP_FOLD_REPLACE") end
  local wonders = #WonderTypes()
  if wonders > 0 then parts[#parts + 1] = Locale.Lookup("LOC_SDP_FOLD_WONDERS", wonders) end
  return parts
end
UpdateFold = function() m_kit.UpdateFold() end

-- One city chip: the selected look while it takes part; dimmed when the
-- list is full and it cannot be switched on.
local function ShowChip(inst, label, on, disabled, toolTip)
  inst.Icon:SetIcon("ICON_DISTRICT_CITY_CENTER", 26)
  SDP_UI.FitName(inst.Name, label, CHIP_NAME)
  SDP_UI.FitName(inst.NameDark, label, CHIP_NAME)
  inst.Selected:SetHide(not on)
  inst.Name:SetHide(on)
  inst.NameDark:SetHide(not on)
  inst.Root:SetDisabled(disabled)
  inst.Root:SetAlpha(disabled and 0.55 or 1)
  inst.Root:SetToolTipString(toolTip)
end

-- The cities and city-center pins as chips, in the participants' order:
-- the pins (by plot index), then the cities (by ID). An empire-limited
-- district of the shared list goes to the first that requires it (issue
-- 28), so the list reads in that order. Returns the participants.
function P.RefreshCities()
  local playerID = Game.GetLocalPlayer()
  local existing, sites, group = Choice()
  local participants, cities, siteList = SDP_Multi.Participants(playerID, { Existing = existing, Sites = sites })
  local cityOf, siteOf, taking = {}, {}, {}
  for _, e in ipairs(cities) do cityOf[e.CityID] = e end
  for _, site in ipairs(siteList) do siteOf[site.Key] = site end
  for _, part in ipairs(participants) do taking[part.Key] = true end
  local numbers = SDP_City.CityNumbers(playerID)
  local labels = {}
  for _, e in ipairs(group.Order) do
    if e.Kind == "SITE" then
      local site = siteOf[e.Key]
      labels[e.Key] = P.CityLabel({ Kind = "SITE", Number = site.Number, SiteNumber = site.SiteNumber })
    else
      labels[e.Key] = P.CityLabel({ Kind = "CITY", Number = numbers[e.CityID], Name = cityOf[e.CityID].Name })
    end
  end
  local entryOf, chips = {}, {}
  for _, e in ipairs(group.Order) do entryOf[e.Key] = e end
  for _, site in ipairs(siteList) do chips[#chips + 1] = entryOf[site.Key] end
  for _, c in ipairs(cities) do chips[#chips + 1] = entryOf["C" .. c.CityID] end
  m_cityIM:ResetInstances()
  m_view.Cities = {}
  for _, e in ipairs(chips) do
    local inst = m_cityIM:GetInstance()
    local key = e.Key
    local on = taking[key] == true
    local lines = { labels[key] }
    if e.Kind == "SITE" then lines[#lines + 1] = Locale.Lookup("LOC_SDP_MULTI_SITE_PIN", SDP_UI.Where(e.X, e.Y)) end
    if e == group.Center then
      lines[#lines + 1] = Locale.Lookup("LOC_SDP_MULTI_CENTER")
    else
      lines[#lines + 1] = Locale.Lookup("LOC_SDP_MULTI_FROM_CENTER", e.Distance, labels[group.Center.Key])
    end
    local city = e.Kind == "CITY" and cityOf[e.CityID] or nil
    if on then
      lines[#lines + 1] = Locale.Lookup("LOC_SDP_MULTI_TAKES_PART")
    else
      lines[#lines + 1] = Locale.Lookup("LOC_SDP_MULTI_NEIGHBOUR_ONLY")
    end
    if on and m_plans[key] ~= nil then lines[#lines + 1] = Locale.Lookup("LOC_SDP_MULTI_OWN_PLAN") end
    local hint = Locale.Lookup(e.Kind == "SITE" and "LOC_SDP_MULTI_SITE_TOOLTIP" or "LOC_SDP_MULTI_CITY_TOOLTIP")
    ShowChip(inst, labels[key], on, false, table.concat(lines, "[NEWLINE]") .. "[NEWLINE][NEWLINE]" .. hint)
    local view = { Key = key, Kind = e.Kind, Included = on, Center = e == group.Center, Default = false,
      Chip = inst.Root, Disabled = false }
    if e.Kind == "SITE" then
      view.Default = group.Sites[key] == true
      inst.Root:RegisterCallback(Mouse.eLClick, function() P.SetSite(key, not on) end)
    else
      local cityID = e.CityID
      view.CityID, view.On, view.Default = cityID, city.On, group.Cities[cityID] == true
      inst.Root:RegisterCallback(Mouse.eLClick, function() P.SetExisting(cityID, not city.On) end)
    end
    m_view.Cities[#m_view.Cities + 1] = view
  end
  m_chipRows = math.max(1, math.ceil(#group.Order / 3))
  FitPage()
  local default = true
  for _, view in ipairs(m_view.Cities) do
    if view.Included ~= view.Default then default = false end
  end
  Controls.MultiCityAll:SetDisabled(#participants == #m_view.Cities)
  Controls.MultiCityClear:SetDisabled(#participants == 0)
  Controls.MultiCityDefault:SetDisabled(default)
  m_view.Center = group.Center and group.Center.Key or nil
  return participants
end

-- Wonders: tags and the "add" pulldown, and the districts they bring. Read
-- again when pins come or go or the replace switch changes: a wonder with a
-- pin is left out unless that pin is being replaced (issue 154).
ShowWonders = function()
  local wonders = SDP_Wonders.List(Game.GetLocalPlayer(), ReplacedPins())
  -- Each tag's city pulldown (issue 234): automatic, or one of the cities
  -- taking part; a city that no longer takes part shows as automatic.
  local participants = Participants()
  local pulls, shown, buttons = {}, {}, {}
  local function Decorate(inst, wonderType)
    local pull = inst.City
    pull:ClearEntries()
    local auto = Locale.Lookup("LOC_SDP_WONDER_CITY_AUTO")
    local current, currentKey, entries = auto, nil, {}
    local function Add(label, key)
      local entry = {}
      pull:BuildEntry("InstanceOne", entry)
      entries[#entries + 1] = entry.Button
      entry.Button:SetText(label)
      entry.Button:RegisterCallback(Mouse.eLClick, function() P.SetWonderCity(wonderType, key) end)
      if key ~= nil and key == m_wonderCities[wonderType] then current, currentKey = label, key end
    end
    Add(auto, nil)
    for _, part in ipairs(participants) do Add(P.CityLabel(part), part.Key) end
    pull:CalculateInternals()
    pull:GetButton():SetText(current)
    pull:GetButton():SetToolTipString(Locale.Lookup("LOC_SDP_WONDER_CITY_TOOLTIP"))
    pulls[wonderType], shown[wonderType], buttons[wonderType] = pull, currentKey, entries
  end
  SDP_UI.BuildWonders(Controls.MultiWonderPull, m_chipIM, Controls.MultiWonderChipStack, wonders, m_wonders, P.SetWonder,
    Decorate)
  m_view.Wonders = {}
  for _, w in ipairs(wonders) do
    m_view.Wonders[#m_view.Wonders + 1] = { Type = w.Type, Status = w.Status, Chosen = m_wonders[w.Type] == true,
      CityPull = pulls[w.Type], CityEntries = buttons[w.Type], City = shown[w.Type] }
  end
  P.ShowSupply()
  FitPage() -- the tags take more or fewer rows (issue 199)
end

function P.RefreshLists()
  local playerID = Game.GetLocalPlayer()
  local participants = P.RefreshCities()
  local byKey = {}
  for _, part in ipairs(participants) do byKey[part.Key] = part end
  if m_planFor ~= "ALL" and byKey[m_planFor] == nil then m_planFor = "ALL" end
  -- Plan: whose list, templates, the districts and how many.
  P.PopulatePlanPulls(participants)
  local list, key = EditedList()
  local districts = Districts()
  local built = Built()
  -- A city's list (its own, or the shared one until it is edited) greys
  -- out what that city has built or tacked (issue 165).
  local why = StatusOf(m_planFor, districts)
  local rows = SDP_UI.BuildCells(m_cellIM, m_utilityIM, Controls.MultiDistrictStack, Controls.MultiUtilityStack, districts,
    function(d) return SDP_UI.StateOf(list.States, d) end, function(d) return why[d.Type] end,
    function(d) P.SetState(d.Type, SDP_UI.NextState(d, SDP_UI.StateOf(list.States, d))) end)
  m_view.Districts = {}
  for _, row in ipairs(rows) do
    local d = nil
    for _, dd in ipairs(districts) do
      if dd.Type == row.Type then d = dd end
    end
    local status = ""
    if built[d.Type] then
      -- Built up to the empire's limit (issue 108): greyed out, where it stands.
      local where = SDP_Multi.WhereBuilt(playerID, d.Type)
      status = Locale.Lookup("LOC_SDP_MULTI_EMPIRE_LIMIT", d.MaxPerPlayer)
      if where ~= nil then status = status .. " " .. Locale.Lookup("LOC_SDP_MULTI_LIMITED_BUILT", Locale.Lookup(where)) end
      row.Cell:SetToolTipString(status)
    elseif d.MaxPerPlayer and d.MaxPerPlayer > 0 and why[d.Type] ~= nil then
      -- At the limit with a tack of it (greyed out, StatusOf): the limit.
      status = Locale.Lookup("LOC_SDP_MULTI_EMPIRE_LIMIT", d.MaxPerPlayer)
      row.Cell:SetToolTipString(status)
    elseif d.MaxPerPlayer and d.MaxPerPlayer > 0 then
      -- Where an empire-limited district can go (as SDP_Multi.NewSession,
      -- issue 234): the cities that require it in a list of their own,
      -- else those that require it in the shared list; with several, each
      -- is tried, at most HOST_TRIES nearest the centre.
      local own, shared = {}, {}
      for _, part in ipairs(participants) do
        local list = m_plans[part.Key] or m_shared
        if SDP_UI.StateOf(list.States, d) == "MUST" then
          if m_plans[part.Key] ~= nil then own[#own + 1] = part else shared[#shared + 1] = part end
        end
      end
      local planners = #own > 0 and own or shared
      status = Locale.Lookup("LOC_SDP_MULTI_EMPIRE_LIMIT", d.MaxPerPlayer)
      if #planners == 1 then
        status = status .. " " .. Locale.Lookup("LOC_SDP_MULTI_LIMITED_ONE", P.CityLabel(planners[1]))
      elseif #planners > SDP_Multi.HOST_TRIES then
        status = status .. " " .. Locale.Lookup("LOC_SDP_MULTI_LIMITED_NEAREST", SDP_Multi.HOST_TRIES)
      elseif #planners > 1 then
        status = status .. " " .. Locale.Lookup("LOC_SDP_MULTI_LIMITED_AUTO", #planners)
      end
      -- The only tooltip of a district cell (issue 67): which city may take
      -- it is not written on the cell.
      row.Cell:SetToolTipString(status)
    end
    m_view.Districts[#m_view.Districts + 1] = { Type = row.Type, State = row.State, Status = status, Group = row.Group,
      Cell = row.Cell, Built = built[d.Type] ~= nil or nil, Why = why[d.Type] }
  end
  ShowCount()

  ShowWonders()
  UpdateReplaceLabel()
  m_view.PlanFor = m_planFor
  m_view.Plans = {}
  for key, own in pairs(m_plans) do m_view.Plans[key] = ListOf(own).Must end
  UpdateEstimate()
end

-- The "plan for" pulldown (shared list, or one city's own list) and the
-- template pulldown (role templates, clear, back to the shared list).
function P.PopulatePlanPulls(participants)
  local playerID = Game.GetLocalPlayer()
  local pull = Controls.MultiPlanPull
  pull:ClearEntries()
  local current = Locale.Lookup("LOC_SDP_MULTI_PLAN_ALL")
  local function AddTarget(label, key)
    local entry = {}
    pull:BuildEntry("InstanceOne", entry)
    entry.Button:SetText(label)
    entry.Button:RegisterCallback(Mouse.eLClick, function() P.SetPlanFor(key) end)
    if key == m_planFor then current = label end
  end
  AddTarget(current, "ALL")
  for _, part in ipairs(participants) do
    local label = P.CityLabel(part)
    if m_plans[part.Key] ~= nil then label = label .. " " .. Locale.Lookup("LOC_SDP_MULTI_OWN_PLAN") end
    AddTarget(label, part.Key)
  end
  pull:CalculateInternals()
  pull:GetButton():SetText(current)
  -- The back button shows while the city picked has its own list (issue 187).
  Controls.MultiPlanShared:SetHide(m_planFor == "ALL" or m_plans[m_planFor] == nil)
  Controls.MultiPlanStack:CalculateSize()

  local templates = Controls.MultiTemplatePull
  templates:ClearEntries()
  m_view.Templates = {}
  local function AddTemplate(label, toolTip, types)
    local entry = {}
    templates:BuildEntry("InstanceOne", entry)
    entry.Button:SetText(label)
    entry.Button:SetToolTipString(toolTip)
    entry.Button:RegisterCallback(Mouse.eLClick, function() P.ApplyPlan(types) end)
    m_view.Templates[#m_view.Templates + 1] = { Label = label, Types = types }
  end
  for _, t in ipairs(SDP_Rules.Templates(playerID)) do
    local names = {}
    for _, districtType in ipairs(t.Districts) do names[#names + 1] = SDP_UI.TypeName(districtType) end
    AddTemplate(Locale.Lookup("LOC_SDP_TEMPLATE_YIELD", Locale.Lookup(GameInfo.Yields[t.Yield].Name)),
      SDP_UI.Join(names), t.Districts)
  end
  AddTemplate(Locale.Lookup("LOC_SDP_TEMPLATE_CLEAR"), "", {})
  if m_planFor ~= "ALL" then AddTemplate(Locale.Lookup("LOC_SDP_TEMPLATE_SHARED"), "", nil) end
  templates:CalculateInternals()
  templates:GetButton():SetText(Locale.Lookup("LOC_SDP_TEMPLATE"))
end

function P.Refresh()
  P.Restore()
  P.RefreshLists()
  m_kit.BuildWeights()
  m_kit.ShowTiers()
  m_kit.ShowSwitches()
  UpdateFold()
  P.Render()
end

-- ===========================================================================
-- Results
-- ===========================================================================
local function CityByKey(solution)
  local byKey = {}
  for _, city in ipairs(solution.Cities) do byKey[city.Key] = city end
  return byKey
end

-- Show solution n on the map: each city's rings in its color, the plan's icons.
function P.Preview(n)
  local solution = m_result and m_result.Ok and m_result.Solutions[n]
  if solution == nil then
    SDP_Preview.Clear()
    return
  end
  local areas, icons = {}, {}
  for c, city in ipairs(solution.Cities) do
    local plots = {}
    for _, entry in ipairs(SDP_City.PlotsInRange(city.X, city.Y, SDP_City.RADIUS)) do plots[#plots + 1] = entry.Index end
    areas[#areas + 1] = { Plots = plots, Color = c }
    if city.Kind == "SITE" then icons[#icons + 1] = { X = city.X, Y = city.Y, Icon = "ICON_DISTRICT_CITY_CENTER", Text = P.CityLabel(city) } end
  end
  -- Each pin starts with its city's number (the name its map tack gets), so
  -- the cities' districts can be told apart where their rings overlap (issue 67).
  local byKey = CityByKey(solution)
  for _, p in ipairs(solution.Plan) do
    local city = byKey[p.City]
    local text = SDP_UI.PinText(p.Yields)
    if city ~= nil and city.Number ~= nil then
      text = text == "" and tostring(city.Number) or Locale.Lookup("LOC_SDP_PREVIEW_CITY", city.Number, text)
    end
    icons[#icons + 1] = { X = p.X, Y = p.Y, Icon = "ICON_" .. p.Type, Text = text }
  end
  SDP_UI.SupportIcons(solution.Plan, icons)
  for _, city in ipairs(solution.Cities or {}) do SDP_UI.ImprovementIcons(nil, city.Worked, icons) end
  SDP_UI.ImprovementIcons(solution.Plan, nil, icons)
  for _, r in ipairs(solution.Remind or {}) do
    icons[#icons + 1] = { X = r.X, Y = r.Y, Icon = SDP_Pins.REMIND_ICON, Text = "" }
  end
  m_view.PreviewIcons = icons
  SDP_Preview.Show(Game.GetLocalPlayer(), areas, icons)
  -- A new result or another solution: the cities' middle beside the panel
  -- (issue 67), not on reopening the tab.
  if m_lookNext and SDP_UI.IsOpen() and #solution.Cities > 0 then
    m_lookNext = false
    local x, y = 0, 0
    for _, city in ipairs(solution.Cities) do x, y = x + city.X, y + city.Y end
    SDP_UI.LookAt(math.floor(x / #solution.Cities + 0.5), math.floor(y / #solution.Cities + 0.5))
  end
end

function P.SelectSolution(n)
  if m_result == nil or not m_result.Ok or m_result.Solutions[n] == nil then return end
  m_solution = n
  m_lookNext = true
  P.Render()
end

-- How a coverage target is called: a participant by its label, else as on
-- the single-city tab (SDP_UI.TargetLabel).
local function TargetLabelFor(byKey)
  return function(key)
    local city = byKey[key]
    if city ~= nil then return P.CityLabel(city) end
    return SDP_UI.TargetLabel(key)
  end
end

local function AddRow(icon, name, detail, toolTip, x, y)
  m_view.Results[#m_view.Results + 1] = SDP_UI.ResultRow(m_resultIM:GetInstance(), icon, name, detail, toolTip, x, y)
end

-- The city a reminder belongs to: the one of the first district it serves.
local function RemindCity(solution, remind)
  local first = remind.Losses[1]
  for _, p in ipairs(solution.Plan) do
    if first ~= nil and p.X == first.X and p.Y == first.Y then return p.City end
  end
  return nil
end

function P.Render()
  m_solutionIM:ResetInstances()
  m_resultIM:ResetInstances()
  m_view.Solutions, m_view.Results = {}, {}
  Controls.MultiQuality:SetText("")
  local result = m_result
  if result == nil then
    Controls.MultiSummary:SetText(Locale.Lookup(P.Request() == nil and "LOC_SDP_MULTI_NONE" or "LOC_SDP_RESULT_READY"))
    Controls.MultiSummary:SetToolTipString("")
  elseif not result.Ok then
    local key = "LOC_SDP_RESULT_" .. tostring(result.Error)
    local text = Locale.Lookup(key)
    if text == key then text = Locale.Lookup("LOC_SDP_RESULT_ERROR", tostring(result.Error)) end
    Controls.MultiSummary:SetText(text)
  else
    local solution = result.Solutions[m_solution] or result.Solutions[1]
    local byKey = CityByKey(solution)
    local request = result.Session and result.Session.Request or {}
    -- How the solutions are ranked, and what planning the cities together
    -- adds over planning them one after another (the difference of the
    -- ranked sums; issue 91: no total is shown); the search's counts are for
    -- tests (issue 67).
    local statsText = Locale.Lookup("LOC_SDP_RESULT_RANKED")
    if result.FirstGain ~= nil then
      statsText = statsText .. "[NEWLINE][NEWLINE]"
        .. Locale.Lookup("LOC_SDP_MULTI_FIRST", SDP_UI.Signed(math.floor(((solution.Gain or 0) - result.FirstGain) * 10 + 0.5) / 10))
    end
    local summaryParts = { Land = request.Land ~= false, Coverage = solution.Covered ~= nil,
      Distance = (request.Distance or 0) > 0 }
    Controls.MultiSummary:SetText(SDP_UI.SummaryText(solution, summaryParts))
    local label = TargetLabelFor(byKey)
    if solution.Covered ~= nil then
      statsText = table.concat(SDP_UI.CoverageLines(solution, label), "[NEWLINE]") .. "[NEWLINE][NEWLINE]" .. statsText
    end
    local breakdown = SDP_UI.BreakdownLines(solution, summaryParts)
    if #breakdown > 0 then statsText = table.concat(breakdown, "[NEWLINE]") .. "[NEWLINE][NEWLINE]" .. statsText end
    Controls.MultiSummary:SetToolTipString(statsText)
    Controls.MultiQuality:SetText(SDP_UI.WithRank(SDP_UI.QualityText(result),
      SDP_UI.RankText(result.Solutions, m_solution, summaryParts)))
    -- Solutions.
    for n, s in ipairs(result.Solutions) do
      local inst = m_solutionIM:GetInstance()
      local wonders = 0
      for _, p in ipairs(s.Plan) do
        if p.Kind == "WONDER" then wonders = wonders + 1 end
      end
      SDP_UI.SolutionRow(inst, SDP_UI.SolutionLabel(n, s),
        SDP_UI.WithRank(SDP_UI.SummaryText(s, summaryParts), SDP_UI.RankText(result.Solutions, n, summaryParts))
          .. "[NEWLINE]" .. Locale.Lookup("LOC_SDP_MULTI_SOLUTION_DETAIL", #s.Cities, #s.Plan - wonders, wonders),
        n == m_solution)
      inst.Root:RegisterCallback(Mouse.eLClick, function() P.SelectSolution(n) end)
      m_view.Solutions[n] = { Gain = s.Gain, Selected = n == m_solution, Cell = inst.Root }
    end
    -- What the plan leaves out comes first (issue 60).
    for _, u in ipairs(solution.Unplaced) do
      local city = byKey[u.City]
      local where = city and P.CityLabel(city) or Locale.Lookup("LOC_SDP_MULTI_WONDERS")
      if u.Reason == "POOL_SHORT" then
        AddRow("ICON_DISTRICT_CITY_CENTER", Locale.Lookup("LOC_SDP_RESULT_POOL_SHORT", where),
          Locale.Lookup("LOC_SDP_REASON_POOL_SHORT", u.Count or 1), "")
      else
        AddRow("ICON_" .. u.Type, SDP_UI.UnplacedName(u) .. "  " .. where, SDP_UI.ReasonText(u), SDP_UI.UnplacedTip(u))
      end
    end
    -- The selected solution, city by city.
    for _, city in ipairs(solution.Cities) do
      -- The city's subtotal: the sum of its districts' parts (issue 126).
      AddRow("ICON_DISTRICT_CITY_CENTER", P.CityLabel(city) .. "  " .. SDP_UI.Where(city.X, city.Y),
        SDP_UI.PartsText(city.Parts or { Adjacency = city.Gain }, summaryParts, "LOC_SDP_MULTI_CITY_GAIN"),
        Locale.Lookup("LOC_SDP_MULTI_CITY_TIP"), city.X, city.Y)
      for _, p in ipairs(solution.Plan) do
        if p.City == city.Key then
          local tip = (p.ToolTip ~= nil and p.ToolTip ~= "") and p.ToolTip or Locale.Lookup("LOC_SDP_NO_ADJACENCY")
          local detail
          detail, tip = SDP_UI.CoverageRow(p, SDP_UI.PlanDetail(p), tip, label)
          tip = SDP_UI.PartsTip(p, summaryParts, tip)
          AddRow("ICON_" .. p.Type, "  " .. SDP_UI.TypeName(p.Type) .. "  " .. SDP_UI.Where(p.X, p.Y), detail, tip, p.X, p.Y)
          SDP_UI.SupportRow(p, AddRow, "    ")
          SDP_UI.ImprovementRow(p, AddRow, "    ")
        end
      end
      -- The improvements of the city's worked tiles (issue 227).
      SDP_UI.WorkedRow(city.Worked, AddRow, P.CityLabel(city))
    end
    for _, r in ipairs(solution.Remind or {}) do
      AddRow(SDP_Pins.REMIND_ICON, Locale.Lookup("LOC_SDP_RESULT_REMIND", SDP_UI.TypeName(r.Feature), SDP_UI.Where(r.X, r.Y)),
        SDP_UI.RemindText(r), Locale.Lookup("LOC_SDP_REMIND_TOOLTIP"), r.X, r.Y)
    end
    for _, city in ipairs(solution.Cities) do SDP_UI.TogetherRows(city.Together, P.CityLabel(city), AddRow) end
    SDP_UI.ImprovementHousingRow(solution.ImprovementHousing, AddRow)
    if not Controls.MultiPage:IsHidden() then P.Preview(m_solution) end
  end
  Controls.MultiSolutionStack:CalculateSize()
  Controls.MultiResultStack:CalculateSize()
  P.ShowSupply()
  FitPage()
  P.UpdateButtons()
end

function P.ShowProgress(text)
  Controls.MultiSummary:SetText(text)
  Controls.MultiQuality:SetText("")
end

function P.OnError(message)
  m_result = { Ok = false, Error = message }
end

function P.UpdateButtons()
  local ok = m_result ~= nil and m_result.Ok
  m_kit.ShowButtons({ Solve = P.Request() ~= nil, Continue = ok and m_result.Quality.CanContinue and m_result.Placed ~= true,
    Place = ok and m_result.Placed ~= true })
end

-- ===========================================================================
-- Actions
-- ===========================================================================
function P.Solve()
  if SDP_Task.IsRunning() then return false end
  local request = P.Request()
  if request == nil then return false end
  local params = SDP_Tiers.Params(SDP_Tiers.Multi, m_kit.Tier)
  m_result, m_solution = nil, 1
  m_lookNext = true
  m_kit.SetFold(true) -- the results get the room (issue 71)
  SDP_Preview.Clear()
  return SDP_UI.StartTask(function() return SDP_Multi.SolveNow(request) end, Estimate(request, params),
    function(result) m_result, m_solution = result, 1 end, P)
end

function P.Continue()
  if SDP_Task.IsRunning() or m_result == nil or not m_result.Ok or not m_result.Quality.CanContinue then return false end
  m_lookNext = true
  local session = m_result.Session
  return SDP_UI.StartTask(function()
    session:Continue()
    return session:Result()
  end, Estimate(session.Request, session.Params), function(result) m_result = result end, P)
end

function P.Place()
  if not SDP_PageKit.CanPlace(m_result) then return 0 end
  local solution = m_result.Solutions[m_solution]
  local byKey = CityByKey(solution)
  local entries = {}
  for _, p in ipairs(solution.Plan) do
    local city = byKey[p.City]
    local name = city and tostring(city.Number or "") or ""
    entries[#entries + 1] = { Type = p.Type, X = p.X, Y = p.Y, Name = name }
    entries[#entries + 1] = SDP_UI.SupportEntry(p, name)
    SDP_UI.ImprovementEntries(p.Improvements, name, entries)
  end
  for _, city in ipairs(solution.Cities or {}) do
    SDP_UI.ImprovementEntries(city.Worked, tostring(city.Number or ""), entries)
  end
  if m_remind then
    for _, e in ipairs(SDP_UI.RemindEntries(solution.Remind, function(r)
      local city = byKey[RemindCity(solution, r)]
      return city and city.Number or nil
    end)) do entries[#entries + 1] = e end
  end
  -- The plan was made as if this mod's earlier pins were gone: remove them.
  local placed = SDP_PageKit.Place(m_result, entries, m_result.Session and m_result.Session.Request.IgnorePins)
  UpdateReplaceLabel()
  ShowHave()
  SDP_UI.UpdateAllButtons()
  return placed
end

function P.Undo()
  local removed = SDP_PageKit.Undo(m_result, ClearResult) -- the replaced pins are back: plan again
  UpdateReplaceLabel()
  ShowHave()
  SDP_UI.UpdateAllButtons()
  return removed
end

-- ===========================================================================
-- The settings every tab has (SDP_PageKit)
-- ===========================================================================
-- The weights, these switches and the tier, kept in the save (issue 57).
local SWITCHES = {
  { Key = "SWAP", Default = true, Check = Controls.MultiSwapCheck, Get = function() return m_swap end,
    Put = function(v) m_swap = v end },
  { Key = "REPLACE", Default = false, Check = Controls.MultiReplaceCheck, Get = function() return m_replace end,
    Put = function(v) m_replace = v end, OnChange = function() ReplaceChanged() end },
  { Key = "REMIND", Default = true, Check = Controls.MultiRemindCheck, Get = function() return m_remind end,
    Put = function(v) m_remind = v end },
  -- Improvements with the districts (issue 227): the plan changes.
  { Key = "IMPROVE", Default = true, Check = Controls.MultiImproveCheck, Get = function() return m_improve end,
    Put = function(v) m_improve = v end, OnChange = function() UpdateEstimate() end },
  { Key = "WORKED", Default = false, Check = Controls.MultiWorkedCheck, Get = function() return m_worked end,
    Put = function(v) m_worked = v end },
}
m_kit = SDP_PageKit.New({
  Page = P, Tab = "MULTI", Columns = COLUMNS, Weights = m_weights, Switches = SWITCHES,
  Extra = { SDP_UI.WonderSetting(m_wonders) }, Tiers = SDP_Tiers.Multi,
  WeightRows = { { IM = m_weightIM, Stack = Controls.MultiWeightStack, Columns = COLUMNS } }, WeightWidth = COLUMN_WIDTH,
  TierPull = Controls.MultiTierPull, PresetPull = Controls.MultiPresetPull, PresetTips = { Tips = true },
  Fold = { Button = Controls.MultiFoldButton, Text = Controls.MultiFoldText, Action = Controls.MultiFoldAction,
    Scroll = Controls.MultiSettingsScroll },
  Buttons = { Solve = Controls.MultiSolveButton, Continue = Controls.MultiContinueButton, Cancel = Controls.MultiCancelButton,
    Place = Controls.MultiPlaceButton, Undo = Controls.MultiUndoButton },
  FoldParts = FoldParts, ClearResult = function() ClearResult() end, FitPage = function() FitPage() end,
  Changed = function() UpdateEstimate() end,
  AfterPreset = function()
    ShowHave()
    UpdateEstimate()
  end,
})
P.SetWeight = m_kit.SetWeight
P.SetLand = m_kit.SetLand
P.SetTier = m_kit.SetTier
P.SetPreset = m_kit.SetPreset
P.SetFold = m_kit.SetFold
P.SetSwap = function(on) m_kit.SetSwitch("SWAP", on) end
P.SetReplace = function(on) m_kit.SetSwitch("REPLACE", on) end
P.SetRemind = function(on) m_kit.SetSwitch("REMIND", on) end
P.SetImprove = function(on) m_kit.SetSwitch("IMPROVE", on) end
P.SetWorked = function(on) m_kit.SetSwitch("WORKED", on) end

-- Tests drive the tab through these.
function P.State()
  return {
    Result = m_result, Solution = m_solution, Tier = m_kit.Tier, Land = m_weights.LAND > 0, Replace = m_replace,
    Remind = m_remind, Swap = m_swap, Weights = m_weights, Preset = m_kit.Preset, Fold = m_kit.Fold, Improve = m_improve,
    Worked = m_worked, WeightCells = m_kit.Cells,
    FoldText = Controls.MultiFoldText:GetText(), ResultHeight = Controls.MultiResultScroll:GetSizeY(),
    View = m_view, EstimateText = Controls.MultiEstimate:GetText(), QualityText = Controls.MultiQuality:GetText(),
    PlaceDisabled = Controls.MultiPlaceButton:IsDisabled(), ContinueDisabled = Controls.MultiContinueButton:IsDisabled(),
    SolveDisabled = Controls.MultiSolveButton:IsDisabled(), SummaryText = Controls.MultiSummary:GetText(),
    SummaryToolTip = Controls.MultiSummary:GetToolTipString(),
  }
end

Controls.MultiCityAll:RegisterCallback(Mouse.eLClick, function() P.AllCities() end)
Controls.MultiCityClear:RegisterCallback(Mouse.eLClick, function() P.ClearCities() end)
Controls.MultiCityDefault:RegisterCallback(Mouse.eLClick, function() P.DefaultCities() end)
Controls.MultiPlanShared:RegisterCallback(Mouse.eLClick, function() P.UseShared() end)
Controls.MultiCountLess:RegisterCallback(Mouse.eLClick, function() P.SetCount(ListOf(EditedList()).Target - 1) end)
Controls.MultiCountMore:RegisterCallback(Mouse.eLClick, function() P.SetCount(ListOf(EditedList()).Target + 1) end)

