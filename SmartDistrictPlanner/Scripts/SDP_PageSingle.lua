-- SDP_PageSingle: the "single city" tab of the planner panel. Included by
-- SDP_Panel.lua into its context: uses its Controls and the SDP_UI helpers;
-- the weights, tier, preset, fold, switches and tacks through SDP_PageKit,
-- as on the other tabs (issue 251).
--   City      the city selected on the map when the panel opens (issue 63),
--             else the one picked in the pulldown.
--   Districts each with a state (required, candidate, off, automatic:
--             SDP_UI.DefaultState) and how many districts that take
--             population the city ends with (issue 144); wonders to place
--             with them (then solved by SDP_Multi with this one city).
--   Solve     at once, or over several frames (SDP_Task) with the fine tier,
--             wonders or candidates; up to three solutions, the selected one
--             previewed and placed as map tacks.

SDP_PageSingle = {}
local P = SDP_PageSingle
P.Name = "SINGLE"

local m_cellIM = InstanceManager:new("DistrictCell", "Root", Controls.DistrictStack)
local m_utilityIM = InstanceManager:new("DistrictCell", "Root", Controls.UtilityStack)
local m_chipIM = InstanceManager:new("WonderChip", "Root", Controls.WonderChipStack)
local m_weightIM = InstanceManager:new("WeightColumn", "Root", Controls.WeightStack)
local m_solutionIM = InstanceManager:new("SolutionRow", "Root", Controls.SolutionStack)
local m_resultIM = InstanceManager:new("ResultRow", "Root", Controls.ResultStack)

-- The panel's weight columns, then the coverage part.
local COLUMNS, COLUMN_WIDTH = {}, 50 -- nine columns: a little narrower than the 520 page
for _, column in ipairs(SDP_UI.WEIGHT_COLUMNS) do COLUMNS[#COLUMNS + 1] = column end
COLUMNS[#COLUMNS + 1] = SDP_UI.COVERAGE_COLUMN

-- The tab's state, kept while the game runs.
local m_cityID = nil
local m_states = {}           -- [DistrictType] = "MUST" | "POOL" | "OFF" | "AUTO" (chosen; else SDP_UI.DefaultState)
local m_counts = {}           -- [cityID] = the target the player set (SDP_UI.ListRequest; none: SDP_UI.DefaultTarget, issue 144)
local m_have = nil            -- SDP_City.SpecialtyHave of the selected city, pins being replaced left out
local m_weights = {}          -- [YieldType, DISTANCE, HOUSING or COVERAGE] = 0..SDP_UI.MAX_WEIGHT
for _, column in ipairs(COLUMNS) do m_weights[column.Key] = column.Default or 1 end
local m_allowFeatureRemoval = true
local m_swap = true           -- plots swapped from another of our cities are candidates (issue 54; on by default, issue 162)
local m_replace = false       -- plan over this mod's earlier pins for the city and replace them
local m_remind = true         -- reminder pins on the woods and rainforest the plan relies on (feedback item 5)
local m_improve = true        -- plan the improvements the districts take adjacency from (issue 227)
local m_worked = false        -- tack the improvements of the worked plots too (issue 227)
local m_wonders = {}          -- [BuildingType] = true: wonders to place too (then solved by SDP_Multi, one city)
local m_heat = nil            -- the district whose good places the map shows
local m_heatSpots = nil       -- SDP_Solver.Heat of m_heat (tests)
local m_scan = nil            -- the selected city (district status, specialty slots)
local m_districts = {}        -- SDP_Rules.PlannableDistricts, sorted by type
local m_scanStatus = {}       -- SDP_City.DistrictStatus for the selected city (the heat map's list)
local m_status = {}           -- the list's greyed-out types (SDP_City.ListStatus)
local m_result = nil          -- last solve; cleared whenever an input changes
local m_solution = 1          -- the solution shown (and previewed)
local m_districtRows = {}     -- what the district grid shows, for tests
local m_resultRows = {}       -- what the result list shows, for tests
local m_solutionCells = {}    -- the solution rows' buttons, for real-click tests
local m_lookNext = false      -- move the camera to the city when the next result shows (a solve, a continue)
local m_kit                   -- SDP_PageKit: weights, tier, preset, fold, switches (made at the end)

local function FitPage()
  SDP_UI.FitResults(Controls.Body, Controls.SinglePage, Controls.ResultScroll, Controls.SettingsScroll, Controls.SettingsStack,
    Controls.DistrictScroll, Controls.DistrictArea)
  SDP_UI.CheckFit("SINGLE", Controls.SinglePage, Controls.Body)
end
P.FitPage = FitPage
function P.Restore() m_kit.Restore() end

local Refresh -- defined below
local UpdateReplaceLabel -- defined below
local SetWonder, ShowHeat, PopulateHeat -- defined below
local UpdateEstimate -- defined below
-- Follow the city selected on the map (SDP_Panel, Open; issue 63, 178).
local m_followed = nil -- the selected city (ID) when the panel last opened
local m_reselected = false -- one of our cities selected on the map since then
local FollowSelection -- defined below (after SelectCity)

-- ===========================================================================
-- Results
-- ===========================================================================
local function CanContinue()
  return m_result ~= nil and m_result.Ok and m_result.Quality ~= nil and m_result.Quality.CanContinue
    and not m_result.Placed
end

local Request -- defined below

local function UpdateButtons()
  local plan = m_result and m_result.Ok and m_result.Plan or {}
  -- Nothing to plan (no required district, the count 0, no wonder): greyed
  -- out, and the summary says what to do (issue 67).
  m_kit.ShowButtons({ Solve = m_cityID ~= nil and Request() ~= nil, Continue = CanContinue(),
    Place = #plan > 0 and m_result.Placed ~= true })
end
P.UpdateButtons = UpdateButtons

local function AddResultRow(icon, name, detail, toolTip, x, y)
  m_resultRows[#m_resultRows + 1] = SDP_UI.ResultRow(m_resultIM:GetInstance(), icon, name, detail, toolTip, x, y)
end

-- Show solution n on the map: the city's rings, the plan's icons and values.
local function Preview(n)
  local solution = m_result and m_result.Ok and m_result.Solutions and m_result.Solutions[n]
  if solution == nil or m_scan == nil or Controls.SinglePage:IsHidden() then
    if m_heat == nil then SDP_Preview.Clear() end
    return
  end
  local plots = {}
  for _, entry in ipairs(SDP_City.PlotsInRange(m_scan.X, m_scan.Y, SDP_City.RADIUS)) do plots[#plots + 1] = entry.Index end
  SDP_Preview.Show(Game.GetLocalPlayer(), { { Plots = plots, Color = 1 } }, SDP_UI.CityIcons(solution))
end

local function ShowResult()
  m_resultIM:ResetInstances()
  m_solutionIM:ResetInstances()
  m_resultRows, m_solutionCells = {}, {}
  local result = m_result
  Controls.Quality:SetText("")
  if result == nil then
    -- What to do next: something to plan first, or press Solve (issue 67).
    Controls.Summary:SetText(Locale.Lookup(Request() == nil and "LOC_SDP_RESULT_NONE" or "LOC_SDP_RESULT_READY"))
    Controls.Summary:SetToolTipString("")
  elseif not result.Ok then
    local key = "LOC_SDP_RESULT_" .. tostring(result.Error)
    local text = Locale.Lookup(key)
    if text == key then text = Locale.Lookup("LOC_SDP_RESULT_ERROR", tostring(result.Error)) end
    Controls.Summary:SetText(text)
    Controls.Summary:SetToolTipString("")
  else
    local solutions = result.Solutions or { result }
    if solutions[m_solution] == nil then m_solution = 1 end
    local shown = SDP_UI.CitySolution(result, m_solution)
    local request = result.PanelRequest or {}
    local summaryParts = { Land = request.Land, Distance = (request.Distance or 0) > 0, Coverage = shown.Covered ~= nil }
    Controls.Summary:SetText(SDP_UI.SummaryText(shown, summaryParts))
    -- How the solutions are ranked, and the cities the plan covers; the
    -- search's counts (result.Stats) are for tests, not the player (issue 67).
    local tip = Locale.Lookup("LOC_SDP_RESULT_RANKED")
    if shown.Covered ~= nil then tip = tip .. "[NEWLINE][NEWLINE]" .. table.concat(SDP_UI.CoverageLines(shown), "[NEWLINE]") end
    local breakdown = SDP_UI.BreakdownLines(shown, summaryParts)
    if #breakdown > 0 then tip = table.concat(breakdown, "[NEWLINE]") .. "[NEWLINE][NEWLINE]" .. tip end
    Controls.Summary:SetToolTipString(tip)
    Controls.Quality:SetText(SDP_UI.WithRank(SDP_UI.QualityText(result), SDP_UI.RankText(solutions, m_solution, summaryParts)))
    -- The solutions (feedback item 1): a click shows one and previews it.
    if #solutions > 1 then
      for n, sol in ipairs(solutions) do
        local inst = m_solutionIM:GetInstance()
        m_solutionCells[n] = inst.Root
        SDP_UI.SolutionRow(inst, SDP_UI.SolutionLabel(n, sol),
          SDP_UI.WithRank(SDP_UI.SummaryText(sol, summaryParts), SDP_UI.RankText(solutions, n, summaryParts))
            .. "[NEWLINE]" .. SDP_UI.SolutionDetail(sol), n == m_solution)
        inst.Root:RegisterCallback(Mouse.eLClick, function()
          m_solution = n
          m_lookNext = true
          ShowResult()
        end)
      end
    end
    SDP_UI.CityRows(shown, summaryParts, AddResultRow, m_cityID)
    Preview(m_solution)
    -- A new result or another solution: the city beside the panel (issue
    -- 67); not on reopening the panel or changing a setting.
    if m_lookNext and SDP_UI.IsOpen() and m_scan ~= nil then
      m_lookNext = false
      SDP_UI.LookAt(m_scan.X, m_scan.Y)
    end
  end
  Controls.SolutionStack:CalculateSize()
  Controls.ResultStack:CalculateSize()
  Controls.ResultScroll:CalculateSize()
  FitPage()
  UpdateButtons()
end

local function ClearResult()
  -- Inputs changed: a computation for the old inputs is of no use any more.
  m_kit.CancelTask()
  if m_heat ~= nil then ShowHeat(nil) end -- drawn for the old inputs
  if m_result ~= nil then
    m_result, m_solution = nil, 1
    SDP_Preview.Clear()
    ShowResult()
  end
end

-- ===========================================================================
-- Inputs: city, districts and how many, weights, switches
-- ===========================================================================
local function StatusOf(d) return m_status[d.Type] end

local function List()
  return SDP_UI.ListRequest(m_districts, m_states, m_cityID and m_counts[m_cityID], m_status, m_have)
end

local function UpdateSpecialtyNote()
  if m_scan == nil then
    Controls.SpecialtyNote:SetText("")
    return
  end
  local count = List().Count
  local text = Locale.Lookup("LOC_SDP_SPECIALTY_NOTE", m_scan.SpecialtyBuilt, count, m_scan.SpecialtyCapacity)
  if m_scan.SpecialtyBuilt + count > m_scan.SpecialtyCapacity then
    text = text .. " " .. Locale.Lookup("LOC_SDP_SPECIALTY_OVER")
  end
  Controls.SpecialtyNote:SetText(text)
end

local function ShowCount()
  local list = List()
  Controls.CountValue:SetText(tostring(list.Target))
  Controls.CountLess:SetDisabled(list.Target <= list.Have + list.MustSpecialty)
  Controls.CountMore:SetDisabled(list.Target >= list.Top)
end

local SetState -- defined below

local SelectedWonders -- defined below
local ReplacedPins -- defined below
local PopulateWonders -- defined below

local function ShowCells()
  -- A district a chosen wonder needs shows "for wonder" (issue 66); a click
  -- goes on from its own state.
  local needs = SDP_UI.WonderNeeds(Game.GetLocalPlayer(), SelectedWonders(), m_districts, m_states, m_scan, m_status,
    ReplacedPins(), List().Pick)
  m_districtRows = SDP_UI.BuildCells(m_cellIM, m_utilityIM, Controls.DistrictStack, Controls.UtilityStack, m_districts,
    function(d)
      local state = SDP_UI.StateOf(m_states, d)
      if needs[d.Type] ~= nil and state ~= "MUST" then return "WONDER" end
      return state
    end, StatusOf, function(d)
      SetState(d.Type, SDP_UI.NextState(d, SDP_UI.StateOf(m_states, d)))
    end)
  ShowCount()
  UpdateSpecialtyNote()
  FitPage() -- the grid's rows and the note take room (issue 314)
end

-- Set a district's state (MUST, POOL, OFF, AUTO).
SetState = function(districtType, state)
  local d = nil
  for _, row in ipairs(m_districts) do
    if row.Type == districtType then d = row end
  end
  if d == nil then return end
  if SDP_UI.StateOf(m_states, d) ~= state then
    m_states[districtType] = state
    ClearResult()
  end
  ShowCells()
  UpdateEstimate()
end

-- Tests and older callers: selected = MUST, unselected = the default state.
local function SetSelected(districtType, selected)
  local state = nil
  for _, d in ipairs(m_districts) do
    if d.Type == districtType then state = selected and "MUST" or SDP_UI.DefaultState(d) end
  end
  if state ~= nil then SetState(districtType, state) end
end

-- How many districts that take population the city should end with
-- (issue 144), kept for this city; clamped to what it has and what the
-- states allow (at the required number nothing is picked).
local function SetCount(count)
  if m_cityID == nil then return end
  local list = SDP_UI.ListRequest(m_districts, m_states, count, m_status, m_have)
  local changed = list.Count ~= List().Count
  m_counts[m_cityID] = list.Target
  if changed then ClearResult() end
  if #SelectedWonders() > 0 then
    -- The district for a wonder needs room in the count (issue 177).
    ShowCells()
  else
    ShowCount()
    UpdateSpecialtyNote()
  end
  UpdateEstimate()
end

local function RefreshDistricts()
  local playerID = Game.GetLocalPlayer()
  m_districts = SDP_Rules.PlannableDistricts(playerID)
  m_scan = m_cityID and SDP_City.Scan(playerID, m_cityID) or nil
  m_scanStatus = m_scan and SDP_City.DistrictStatus(m_scan, m_districts) or {}
  UpdateReplaceLabel()
  PopulateHeat()
  ShowCells()
  UpdateEstimate()
end

local function PlayerCities(playerID)
  local cities = {}
  for _, city in Players[playerID]:GetCities():Members() do cities[#cities + 1] = city end
  table.sort(cities, function(a, b) return a:GetID() < b:GetID() end)
  return cities
end

-- The city selected on the map if it is ours, else the capital.
local function DefaultCityID(playerID)
  local selected = UI.GetHeadSelectedCity()
  if selected ~= nil and selected:GetOwner() == playerID then return selected:GetID() end
  local capital = Players[playerID]:GetCities():GetCapitalCity()
  if capital ~= nil then return capital:GetID() end
  local cities = PlayerCities(playerID)
  return cities[1] and cities[1]:GetID() or nil
end

local SelectCity -- defined below

local function PopulateCities()
  local playerID = Game.GetLocalPlayer()
  if m_cityID == nil or CityManager.GetCity(playerID, m_cityID) == nil then
    m_cityID = DefaultCityID(playerID)
  end
  local numbers = SDP_City.CityNumbers(playerID)
  local pull = Controls.CityPull
  pull:ClearEntries()
  for _, city in ipairs(PlayerCities(playerID)) do
    local entry = {}
    local cityID = city:GetID()
    pull:BuildEntry("InstanceOne", entry)
    entry.Button:SetText(Locale.Lookup("LOC_SDP_CITY_N", numbers[cityID] or 0, Locale.Lookup(city:GetName())))
    entry.Button:RegisterCallback(Mouse.eLClick, function() SelectCity(cityID) end)
  end
  pull:CalculateInternals()
  local current = m_cityID and CityManager.GetCity(playerID, m_cityID)
  pull:GetButton():SetText(current and Locale.Lookup("LOC_SDP_CITY_N", numbers[m_cityID] or 0,
    Locale.Lookup(current:GetName())) or "")
end

SelectCity = function(cityID)
  if cityID ~= m_cityID then
    m_cityID = cityID
    ClearResult()
    if m_heat ~= nil then ShowHeat(nil) end
  end
  PopulateCities()
  RefreshDistricts()
  UpdateButtons()
end

FollowSelection = function()
  local playerID = Game.GetLocalPlayer()
  local selected = UI.GetHeadSelectedCity()
  local cityID = nil
  if selected ~= nil and selected:GetOwner() == playerID then cityID = selected:GetID() end
  local reselected = m_reselected
  m_reselected = false
  if cityID == m_followed and not reselected then return false end
  m_followed = cityID
  if cityID == nil or SDP_Task.IsRunning() then return false end
  if cityID ~= m_cityID then
    m_cityID = cityID
    ClearResult()
    if m_heat ~= nil then ShowHeat(nil) end
  end
  SDP_PageMulti.SetCenter(cityID)
  return true
end

function P.OnCitySelectionChanged(owner, cityID, _, _, _, isSelected)
  if isSelected and owner == Game.GetLocalPlayer() then m_reselected = true end
end

-- This mod's earlier pins for the selected city (the ones "replace" removes).
local function OwnPins()
  if m_cityID == nil then return {} end
  local playerID = Game.GetLocalPlayer()
  return SDP_Pins.Own(playerID, { SDP_City.CityNumbers(playerID)[m_cityID] })
end

-- The pins being replaced, { [pin ID] = true }, or nil with replace off.
-- They do not count as what the city has, nor a wonder as pinned (issue 154).
ReplacedPins = function()
  local ignore = nil
  if m_replace then
    for _, pin in ipairs(OwnPins()) do
      ignore = ignore or {}
      ignore[pin.ID] = true
    end
  end
  return ignore
end

-- What the selected city has (issue 144): read again whenever its pins or
-- the replace switch change. Pins being replaced do not count.
local function UpdateHave()
  local playerID, ignore = Game.GetLocalPlayer(), ReplacedPins()
  m_have = m_cityID and SDP_City.HaveOf(playerID, m_cityID, ignore) or nil
  -- What the solver will not plan here is greyed out, a type tacked for
  -- the city too (issue 165, 244).
  m_status = m_cityID and SDP_City.ListStatus(playerID, m_cityID, m_districts, ignore) or {}
  ShowCells()
end

UpdateReplaceLabel = function()
  Controls.ReplaceLabel:SetText(Locale.Lookup("LOC_SDP_REPLACE_OWN_SHORT", #OwnPins()))
  -- The label's width follows the count: lay the switches out again (issue 293)
  Controls.ReplaceStack:CalculateSize()
  Controls.SwitchStack:CalculateSize()
  UpdateHave()
  PopulateWonders() -- a wonder's pin may have come, gone or be replaced (issue 154)
end

-- Wonders to place with the districts (design 18, item 5): selectable ones,
-- in type order (the solver's slot order, independent of the list's order).
SelectedWonders = function()
  local list = {}
  for _, w in ipairs(SDP_Wonders.List(Game.GetLocalPlayer(), ReplacedPins())) do
    if m_wonders[w.Type] and w.Status == nil then list[#list + 1] = w.Type end
  end
  table.sort(list)
  return list
end

PopulateWonders = function()
  SDP_UI.BuildWonders(Controls.WonderPull, m_chipIM, Controls.WonderChipStack,
    SDP_Wonders.List(Game.GetLocalPlayer(), ReplacedPins()),
    m_wonders, function(wonderType, on) SetWonder(wonderType, on) end)
  FitPage() -- the tags take more or fewer rows (issue 199)
end

SetWonder = function(wonderType, on)
  if (m_wonders[wonderType] == true) ~= (on == true) then
    m_wonders[wonderType] = on or nil
    ClearResult()
    m_kit.Remember() -- kept in the save with the other settings (issue 166)
  end
  PopulateWonders()
  ShowCells()
  UpdateEstimate()
  m_kit.UpdateFold()
end

-- The fold line's parts: what is not as usual (land part off, clearing
-- off, swaps off, replacing, wonders, the good places shown).
local function FoldParts()
  local parts = {}
  if m_weights.LAND == 0 then parts[#parts + 1] = Locale.Lookup("LOC_SDP_FOLD_LAND_OFF") end
  if not m_allowFeatureRemoval then parts[#parts + 1] = Locale.Lookup("LOC_SDP_FOLD_NO_REMOVAL") end
  if not m_swap then parts[#parts + 1] = Locale.Lookup("LOC_SDP_FOLD_NO_SWAP") end
  if m_replace then parts[#parts + 1] = Locale.Lookup("LOC_SDP_FOLD_REPLACE") end
  local wonders = #SelectedWonders()
  if wonders > 0 then parts[#parts + 1] = Locale.Lookup("LOC_SDP_FOLD_WONDERS", wonders) end
  if m_heat ~= nil then parts[#parts + 1] = Locale.Lookup("LOC_SDP_FOLD_HEAT", SDP_UI.TypeName(m_heat)) end
  return parts
end

-- Where one district is good (design 18, item 6): its legal plots colored in
-- four shades from the best gain down, each with its value. nil: off.
ShowHeat = function(districtType)
  m_heat = districtType
  SDP_Preview.Clear()
  local label = Locale.Lookup("LOC_SDP_HEAT_OFF")
  if districtType ~= nil and m_cityID ~= nil then
    local playerID = Game.GetLocalPlayer()
    local weights = {}
    for key, value in pairs(m_weights) do weights[key] = value end
    local spots = SDP_Solver.Heat({ PlayerID = playerID, CityID = m_cityID, District = districtType, Weights = weights,
      AllowFeatureRemoval = m_allowFeatureRemoval, Swap = m_swap, IgnorePins = m_replace and OwnPins() or nil }) or {}
    local best = spots[1] and spots[1].Gain or 0
    local worst = spots[#spots] and spots[#spots].Gain or 0
    local areas, icons = {}, {}
    for shade = 1, 4 do areas[shade] = { Plots = {}, Color = shade } end
    for _, spot in ipairs(spots) do
      local shade = 1
      if best > worst then shade = math.min(4, 1 + math.floor(3 * (best - spot.Gain) / (best - worst) + 1e-9)) end
      local plots = areas[shade].Plots
      plots[#plots + 1] = spot.Index
      icons[#icons + 1] = { X = spot.X, Y = spot.Y, Icon = "ICON_" .. districtType, Text = SDP_UI.PinText(spot.Yields) }
    end
    SDP_Preview.Show(playerID, areas, icons)
    m_heatSpots = spots
    label = SDP_UI.TypeName(districtType)
  else
    m_heatSpots = nil
  end
  Controls.HeatPull:GetButton():SetText(label)
  m_kit.UpdateFold()
end

-- The heat map pulldown: off, or a district the city can still plan.
PopulateHeat = function()
  local pull = Controls.HeatPull
  pull:ClearEntries()
  local entry = {}
  pull:BuildEntry("InstanceOne", entry)
  entry.Button:SetText(Locale.Lookup("LOC_SDP_HEAT_OFF"))
  entry.Button:RegisterCallback(Mouse.eLClick, function() ShowHeat(nil) end)
  for _, d in ipairs(m_districts) do
    if m_scanStatus[d.Type] == nil then
      local districtType = d.Type
      local e = {}
      pull:BuildEntry("InstanceOne", e)
      e.Button:SetText(Locale.Lookup(d.Name))
      e.Button:RegisterCallback(Mouse.eLClick, function() ShowHeat(districtType) end)
    end
  end
  pull:CalculateInternals()
  pull:GetButton():SetText(m_heat and SDP_UI.TypeName(m_heat) or Locale.Lookup("LOC_SDP_HEAT_OFF"))
end

-- The districts the solver must place: in type order, so the plan never
-- depends on the order of clicks.
local function SelectedDistricts()
  return List().Must
end

-- Whether a request runs over several frames: the fine tier, wonders, or
-- picking districts from the pool.
local function Sliced(request)
  return SDP_Tiers.Params(SDP_Tiers.Single, request.Tier).Sliced or #request.Wonders > 0
    or (request.Count or 0) > (request.MustSpecialty or 0)
end

-- Expected work of a request (time estimate, progress).
local function EstimateFor(request)
  local params = SDP_Tiers.Params(SDP_Tiers.Single, request.Tier)
  local pick = (request.Count or 0) - (request.MustSpecialty or 0)
  if #request.Wonders > 0 then
    return SDP_Multi.EstimateUnits(1, #request.Districts, #request.Wonders, SDP_Tiers.Params(SDP_Tiers.Multi, request.Tier),
      pick, #(request.Pool or {}))
  end
  local n = m_scan and #m_scan.Candidates or 30
  return SDP_Solver.EstimateUnits(n, #request.Districts, params, #(request.Pool or {}), pick)
end

-- "About X s" for the selected tier and districts (design 7.5).
UpdateEstimate = function()
  local request = m_scan and Request() or nil
  -- Whether there is something to plan may have changed (issue 67).
  UpdateButtons()
  if m_result == nil and not SDP_Task.IsRunning() then
    Controls.Summary:SetText(Locale.Lookup(Request() == nil and "LOC_SDP_RESULT_NONE" or "LOC_SDP_RESULT_READY"))
  end
  if request == nil then
    Controls.Estimate:SetText("")
    return
  end
  Controls.Estimate:SetText(SDP_UI.EstimateText(EstimateFor(request), not Sliced(request)))
end

Refresh = function()
  m_kit.Restore()
  PopulateCities()
  RefreshDistricts()
  m_kit.BuildWeights()
  m_kit.ShowTiers()
  m_kit.ShowSwitches()
  UpdateReplaceLabel()
  PopulateWonders()
  m_heat = nil
  PopulateHeat()
  UpdateEstimate()
  m_kit.UpdateFold()
  ShowResult()
end
P.Refresh = Refresh

-- ===========================================================================
-- Actions
-- ===========================================================================
Request = function()
  local list = List()
  local wonders = SelectedWonders()
  if m_cityID == nil or (#list.Must == 0 and list.Pick == 0 and #wonders == 0) then return nil end
  local weights = {}
  for key, value in pairs(m_weights) do weights[key] = value end
  return {
    PlayerID = Game.GetLocalPlayer(), CityID = m_cityID, Districts = list.Must, Weights = weights,
    Pool = list.Pool, Count = list.Count, MustSpecialty = list.MustSpecialty, Auto = list.Auto,
    Distance = m_weights.DISTANCE, Coverage = m_weights.COVERAGE, Remind = m_remind, Apart = true,
    AllowFeatureRemoval = m_allowFeatureRemoval, Land = m_weights.LAND > 0, Tier = m_kit.Tier, Swap = m_swap,
    IgnorePins = m_replace and OwnPins() or nil, Wonders = wonders, Off = SDP_UI.OffSet(m_states),
    Improvements = m_improve, WorkedImprovements = m_worked,
  }
end

-- With wonders the city is solved as SDP_Multi with this one city (it places
-- wonders next to districts, design 4.4); always over several frames.
local function WonderRequest(request)
  local key = "C" .. request.CityID
  return {
    PlayerID = request.PlayerID, Tier = request.Tier, Districts = request.Districts, Wonders = request.Wonders,
    Pool = request.Pool, Count = request.Count, Auto = request.Auto, Distance = request.Distance, Remind = request.Remind,
    Coverage = request.Coverage,
    Only = { [request.CityID] = true }, Weights = request.Weights, Land = request.Land, Apart = request.Apart,
    AllowFeatureRemoval = request.AllowFeatureRemoval, IgnorePins = request.IgnorePins, Swap = request.Swap,
    Plans = { [key] = request.Districts }, Off = request.Off,
    Improvements = request.Improvements, WorkedImprovements = request.WorkedImprovements,
  }
end

-- Keep a result of either solver (issue 250): one shape (SDP_UI.CityResult),
-- and the panel's request it was solved for (the summary's parts, the pins
-- to replace, a continue's estimate).
local function Keep(result, request)
  if result ~= nil then result.PanelRequest = result.PanelRequest or request end
  m_result = SDP_UI.CityResult(result, request and request.CityID)
end

-- Solve now (fast and standard tiers without picking: returns the result) or
-- start a sliced computation (returns nil, the result shows when it is done).
function P.Solve()
  if SDP_Task.IsRunning() then return nil end
  local request = Request()
  if m_heat ~= nil then ShowHeat(nil) end
  m_solution = 1
  m_lookNext = true
  -- The settings fold away after a solve (M2): the results get the room.
  if request ~= nil then m_kit.SetFold(true) end
  if request ~= nil and #request.Wonders > 0 then
    local multi = WonderRequest(request)
    m_result = nil
    SDP_UI.StartTask(function() return SDP_Multi.SolveNow(multi) end, EstimateFor(request),
      function(result) Keep(result, request) end, P)
    return nil
  end
  if request ~= nil and Sliced(request) then
    local scan = SDP_City.Scan(request.PlayerID, request.CityID, SDP_City.ScanOptions(request))
    if scan ~= nil then
      m_result = nil
      SDP_UI.StartTask(function() return SDP_Solver.SolveScan(request, scan) end, EstimateFor(request),
        function(result) Keep(result, request) end, P)
      return nil
    end
  end
  Keep(request and SDP_Solver.Solve(request) or nil, request)
  ShowResult()
  return m_result
end

-- One more batch on the shown result (design 7.3).
function P.Continue()
  if SDP_Task.IsRunning() or not CanContinue() then return nil end
  m_lookNext = true
  local session = m_result.Session
  if session.Params.Sliced or session.Pick ~= nil and session.Pick > 0 or session.Participants ~= nil then
    -- A continue runs SINGLE_CONTINUE_STARTS local searches; the first run
    -- had Starts + Kicks of them.
    local params, request = session.Params, m_result.PanelRequest
    local estimate = EstimateFor(request) * SDP_Tiers.SINGLE_CONTINUE_STARTS / math.max(1, params.Starts + (params.Kicks or 0))
    SDP_UI.StartTask(function()
      session:Continue()
      return session:Result()
    end, estimate, function(result) Keep(result, request) end, P)
    return nil
  end
  Keep(SDP_Solver.Continue(m_result), m_result.PanelRequest)
  ShowResult()
  return m_result
end

-- Map tacks for the shown solution, with its reminder pins when asked for.
function P.Place()
  if not SDP_PageKit.CanPlace(m_result) then return 0 end
  local solution = SDP_UI.CitySolution(m_result, m_solution)
  local entries = SDP_UI.CityTacks(solution, SDP_City.CityNumbers(Game.GetLocalPlayer())[m_cityID], m_remind)
  -- The plan was made as if this mod's earlier pins were gone: remove them.
  local request = m_result.PanelRequest
  local placed = SDP_PageKit.Place(m_result, entries, request and request.IgnorePins)
  UpdateReplaceLabel()
  UpdateButtons()
  return placed
end

-- The replaced pins are back (with new IDs): plan again; else the plots
-- are free again and the shown plan can be placed once more.
function P.Undo()
  local removed = SDP_PageKit.Undo(m_result, ClearResult)
  UpdateReplaceLabel()
  UpdateButtons()
  return removed
end

-- ===========================================================================
-- The panel's calls (SDP_Panel: tabs, computations) and the tests' (SDP_Panel's hooks)
-- ===========================================================================
P.Render = function() ShowResult() end
function P.ShowProgress(text)
  Controls.Summary:SetText(text)
  Controls.Quality:SetText("")
end
function P.OnError(message) m_result = { Ok = false, Error = message } end
P.FollowSelection = function() return FollowSelection() end
P.SelectCity = function(cityID) SelectCity(cityID) end
P.SetState = function(districtType, state) SetState(districtType, state) end
P.SetSelected = SetSelected
P.SetCount = SetCount
P.Request = function() return Request() end
-- Forget the counts set in this game session, so each city shows its default again.
function P.ForgetCounts()
  m_counts = {}
  ClearResult()
  ShowCount()
  UpdateSpecialtyNote()
  UpdateEstimate()
end
function P.SelectSolution(n)
  if m_result ~= nil and m_result.Ok and m_result.Solutions and m_result.Solutions[n] then
    m_solution = n
    m_lookNext = true
    ShowResult()
  end
end
P.SetWonder = function(wonderType, on) SetWonder(wonderType, on) end
P.ShowHeat = function(districtType) ShowHeat(districtType) end
P.Heat = function() return m_heatSpots end
-- The tab as a new game shows it (tests: SDP_Panel.Defaults, issue 327): the
-- selected or capital city, every district at its default state and count,
-- the kept settings at their defaults (wonders none), the good places off,
-- no result. This mod's tacks stay (undo takes them off).
function P.Defaults()
  if m_heat ~= nil then ShowHeat(nil) end
  m_cityID = nil
  m_states, m_counts = {}, {}
  m_kit.Defaults()
  m_result, m_solution, m_lookNext = nil, 1, false
  Refresh()
end

function P.State()
  local list = List()
  return {
    CityID = m_cityID, Result = m_result, DistrictRows = m_districtRows, ResultRows = m_resultRows,
    SolutionCells = m_solutionCells, WeightCells = m_kit.Cells,
    Count = list.Count, Target = list.Target, Have = list.Have, Solution = m_solution, Remind = m_remind,
    Weights = m_weights, AllowFeatureRemoval = m_allowFeatureRemoval, Land = m_weights.LAND > 0, Tier = m_kit.Tier,
    Replace = m_replace, Swap = m_swap, Improve = m_improve, Worked = m_worked,
    Wonders = SelectedWonders(), HeatDistrict = m_heat,
    Running = SDP_Task.IsRunning(), QualityText = Controls.Quality:GetText(), EstimateText = Controls.Estimate:GetText(),
    PlaceDisabled = Controls.PlaceButton:IsDisabled(), UndoDisabled = Controls.UndoButton:IsDisabled(),
    ContinueDisabled = Controls.ContinueButton:IsDisabled(),
    SolveDisabled = Controls.SolveButton:IsDisabled(), SummaryText = Controls.Summary:GetText(),
    SummaryToolTip = Controls.Summary:GetToolTipString(),
    Fold = m_kit.Fold, FoldText = Controls.FoldText:GetText(), Preset = m_kit.Preset,
    ResultHeight = Controls.ResultScroll:GetSizeY(),
  }
end

-- ===========================================================================
-- The settings every tab has (SDP_PageKit) and the controls
-- ===========================================================================
-- The switches kept in the save with the weights and the tier (issue 57).
local SWITCHES = {
  { Key = "ALLOW_REMOVAL", Default = true, Check = Controls.FeatureCheck, Get = function() return m_allowFeatureRemoval end,
    Put = function(v) m_allowFeatureRemoval = v end },
  { Key = "SWAP", Default = true, Check = Controls.SwapCheck, Get = function() return m_swap end,
    Put = function(v) m_swap = v end },
  { Key = "REPLACE", Default = false, Check = Controls.ReplaceCheck, Get = function() return m_replace end,
    Put = function(v) m_replace = v end,
    OnChange = function()
      UpdateHave()
      PopulateWonders()
      ShowCells()
      UpdateEstimate()
    end },
  -- Reminder pins only change what "place" puts on the map.
  { Key = "REMIND", Default = true, Check = Controls.RemindCheck, Get = function() return m_remind end,
    Put = function(v) m_remind = v end },
  -- Improvements with the districts (issue 227): the plan changes.
  { Key = "IMPROVE", Default = true, Check = Controls.ImproveCheck, Get = function() return m_improve end,
    Put = function(v) m_improve = v end, OnChange = function() UpdateEstimate() end },
  { Key = "WORKED", Default = false, Check = Controls.WorkedCheck, Get = function() return m_worked end,
    Put = function(v) m_worked = v end },
}
m_kit = SDP_PageKit.New({
  Page = P, Tab = "SINGLE", Columns = COLUMNS, Weights = m_weights, Switches = SWITCHES,
  Extra = { SDP_UI.WonderSetting(m_wonders) }, Tiers = SDP_Tiers.Single,
  WeightRows = { { IM = m_weightIM, Stack = Controls.WeightStack, Columns = COLUMNS } }, WeightWidth = COLUMN_WIDTH,
  TierPull = Controls.TierPull, PresetPull = Controls.PresetPull, PresetTips = { Tips = true },
  Fold = { Button = Controls.FoldButton, Text = Controls.FoldText, Action = Controls.FoldAction, Scroll = Controls.SettingsScroll },
  Buttons = { Solve = Controls.SolveButton, Continue = Controls.ContinueButton, Cancel = Controls.CancelButton,
    Place = Controls.PlaceButton, Undo = Controls.UndoButton },
  FoldParts = FoldParts, ClearResult = function() ClearResult() end, FitPage = FitPage,
  Changed = function() UpdateEstimate() end,
  -- A preset may turn replace off: the city's tacks count again (issue 144).
  AfterPreset = function()
    UpdateHave()
    UpdateEstimate()
  end,
})
P.SetWeight = m_kit.SetWeight
P.SetLand = m_kit.SetLand
P.SetTier = m_kit.SetTier
P.SetPreset = m_kit.SetPreset
P.SetFold = m_kit.SetFold
P.SetSwap = function(on) m_kit.SetSwitch("SWAP", on) end
P.SetAllowFeatureRemoval = function(on) m_kit.SetSwitch("ALLOW_REMOVAL", on) end
P.SetReplace = function(on) m_kit.SetSwitch("REPLACE", on) end
P.SetRemind = function(on) m_kit.SetSwitch("REMIND", on) end
P.SetImprove = function(on) m_kit.SetSwitch("IMPROVE", on) end
P.SetWorked = function(on) m_kit.SetSwitch("WORKED", on) end

Controls.CountLess:RegisterCallback(Mouse.eLClick, function() SetCount(List().Target - 1) end)
Controls.CountMore:RegisterCallback(Mouse.eLClick, function() SetCount(List().Target + 1) end)
