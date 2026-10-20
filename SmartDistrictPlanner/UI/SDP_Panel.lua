-- SDP_Panel: launch bar entry and the planner panel.
-- The panel opens through the popup queue: an AddUserInterfaces context sits
-- at the bottom of the render stack, so SetHide(false) alone shows nothing
-- (requirements pitfall 11).

include("InstanceManager")
include("MapTacks")    -- game file: the player's district list
include("SDP_Rules")
include("SDP_City")
include("SDP_Overlay") -- includes DMT's yield calculator into this state
include("SDP_Tiers")
include("SDP_Task")
include("SDP_Board")
include("SDP_Land")
include("SDP_Search")
include("SDP_Solver")
include("SDP_Wonders")
include("SDP_Multi")
include("SDP_Sites")
include("SDP_SiteSolver")
include("SDP_Pins")
include("SDP_Preview")

local LAUNCH_BAR_STACK = "/InGame/LaunchBar/ButtonStack"
local MAX_WEIGHT = 3

-- Yield icons for the weight row. There are no plain yield icons (only
-- ICON_YIELD_*_1..5, 64 px, which shrink to dots here; requirements pitfalls
-- 13 and 14), so the five city-state envoy bonus icons stand in: one family,
-- all five yields, drawn at their native 26 px.
-- Food and FEATURE (one-time yields of clearing and harvesting) only weigh
-- the land part (SDP_Land); they have no envoy icon and show a font icon or
-- a short word instead.
local WEIGHT_COLUMNS = {
  { Key = "YIELD_SCIENCE", Icon = "ICON_ENVOY_BONUS_SCIENCE" },
  { Key = "YIELD_CULTURE", Icon = "ICON_ENVOY_BONUS_CULTURE" },
  { Key = "YIELD_FAITH", Icon = "ICON_ENVOY_BONUS_FAITH" },
  { Key = "YIELD_GOLD", Icon = "ICON_ENVOY_BONUS_GOLD" },
  { Key = "YIELD_PRODUCTION", Icon = "ICON_ENVOY_BONUS_PRODUCTION" },
  { Key = "YIELD_FOOD", Glyph = "[ICON_Food]", Land = true },
  { Key = "FEATURE", Glyph = "LOC_SDP_WEIGHT_FEATURE_SHORT", ToolTip = "LOC_SDP_WEIGHT_FEATURE", Land = true },
}

local m_launchItem = {}     -- SDP_LaunchBarItem instance in the game's launch bar
local m_launchPin = {}      -- SDP_LaunchBarPin instance next to it

local m_districtIM = InstanceManager:new("DistrictRow", "Root", Controls.DistrictStack)
local m_weightIM = InstanceManager:new("WeightColumn", "Root", Controls.WeightStack)
local m_resultIM = InstanceManager:new("ResultRow", "Root", Controls.ResultStack)

-- Panel state, kept while the game runs.
local m_cityID = nil
local m_selected = {}         -- [DistrictType] = true
local m_weights = {}          -- [YieldType or FEATURE] = 0..MAX_WEIGHT
for _, column in ipairs(WEIGHT_COLUMNS) do m_weights[column.Key] = 1 end
local m_allowFeatureRemoval = true
local m_land = true           -- count the land part (design 4.2)
local m_replace = false       -- plan over this mod's earlier pins for the city and replace them
local m_wonders = {}          -- [BuildingType] = true: wonders to place too (then solved by SDP_Multi, one city)
local m_heat = nil            -- the district whose good places the map shows
local m_heatSpots = nil       -- SDP_Solver.Heat of m_heat (tests)
local m_tier = SDP_Tiers.DEFAULT
local m_launchDone = false    -- a background solve finished while the panel was closed
local m_scan = nil            -- the selected city (district status, specialty slots)
local m_districts = {}        -- SDP_Rules.PlannableDistricts, sorted by type
local m_status = {}           -- SDP_City.DistrictStatus for the selected city
local m_result = nil          -- last solve; cleared whenever an input changes
local m_districtRows = {}     -- what the district list shows, for tests
local m_resultRows = {}       -- what the result list shows, for tests
local m_weightViews = {}      -- [YieldType] = function that redraws that weight
local m_tab = "SINGLE"        -- the open tab: SINGLE, SITES or MULTI

-- ===========================================================================
-- Formatting
-- ===========================================================================
local function Number(value)
  if value == math.floor(value) then return string.format("%d", value) end
  return string.format("%.1f", value)
end

local function Signed(value)
  return (value > 0 and "+" or "") .. Number(value)
end

local function Where(x, y)
  return "(" .. x .. ", " .. y .. ")"
end

-- Plain-text yields such as "科+2 文+1" (requirements pitfall 15).
local function YieldText(yields)
  local parts = {}
  for _, yieldType in ipairs(SDP_Rules.YIELDS) do
    local amount = yields[yieldType]
    if amount ~= nil and amount ~= 0 then
      parts[#parts + 1] = Locale.Lookup("LOC_SDP_YIELD_SHORT_" .. yieldType) .. Signed(amount)
    end
  end
  if #parts == 0 then return Locale.Lookup("LOC_SDP_NO_YIELDS") end
  return table.concat(parts, " ")
end

-- Localized name of a district, improvement or building type.
local function TypeName(typeName)
  local row = GameInfo.Districts[typeName] or GameInfo.Improvements[typeName] or GameInfo.Buildings[typeName]
  return row and Locale.Lookup(row.Name) or typeName
end

-- Helpers shared with the other tabs (SDP_PageSites, SDP_PageMulti).
SDP_UI = {
  MAX_WEIGHT = MAX_WEIGHT, WEIGHT_COLUMNS = WEIGHT_COLUMNS,
  Number = Number, Signed = Signed, Where = Where, YieldText = YieldText, TypeName = TypeName,
}

-- ===========================================================================
-- Open / close
-- ===========================================================================
local Refresh -- defined below
local UpdateReplaceLabel -- defined below
local SetWonder, ShowHeat, PopulateHeat -- defined below
local UpdateEstimate -- defined below

-- The launch bar button's tooltip (progress of a background computation)
-- and the mark that a result is ready.
local function LaunchToolTip(text)
  if m_launchItem.LaunchItemButton ~= nil then
    m_launchItem.LaunchItemButton:SetToolTipString(text or Locale.Lookup("LOC_SDP_LAUNCHBAR_TOOLTIP"))
  end
end

local function SetLaunchMark(on)
  m_launchDone = on
  if m_launchItem.LaunchItemAlert ~= nil then m_launchItem.LaunchItemAlert:SetHide(not on) end
  LaunchToolTip(on and Locale.Lookup("LOC_SDP_LAUNCHBAR_DONE") or nil)
end

local function IsOpen()
  return UIManager:IsInPopupQueue(ContextPtr)
end

local SelectTab -- defined below (tabs)

-- A hidden context gets no SetUpdate calls (checked in the game,
-- 2026-10-20), so a running task would stop when the panel closes. While one
-- runs, a closed panel keeps its context shown with the window hidden
-- (design 6): nothing of it is visible or takes the mouse, and input passes
-- through (OnInput only acts while the panel is open).
local function KeepRunningHidden(on)
  if on then
    Controls.DropShadow:SetHide(true)
    ContextPtr:SetHide(false)
  else
    if not IsOpen() then ContextPtr:SetHide(true) end
    Controls.DropShadow:SetHide(false)
  end
end

local function Open()
  if IsOpen() then return end
  if m_launchDone then SetLaunchMark(false) end
  SelectTab(m_tab)
  Controls.DropShadow:SetHide(false)
  UIManager:QueuePopup(ContextPtr, PopupPriority.Low)
  UI.PlaySound("UI_Screen_Open")
end

local function Close()
  if not IsOpen() then return end
  SDP_Preview.Clear()
  UIManager:DequeuePopup(ContextPtr)
  if SDP_Task.IsRunning() then KeepRunningHidden(true) end
  UI.PlaySound("UI_Screen_Close")
end

local function Toggle()
  if IsOpen() then Close() else Open() end
end

-- ===========================================================================
-- Results
-- ===========================================================================
local function CanContinue()
  return m_result ~= nil and m_result.Ok and m_result.Quality ~= nil and m_result.Quality.CanContinue
    and not m_result.Placed
end

local function UpdateButtons()
  local plan = m_result and m_result.Ok and m_result.Plan or {}
  local running = SDP_Task.IsRunning()
  Controls.SolveButton:SetDisabled(m_cityID == nil or running)
  Controls.ContinueButton:SetDisabled(running or not CanContinue())
  Controls.CancelButton:SetHide(not running)
  Controls.PlaceButton:SetDisabled(running or #plan == 0 or m_result.Placed == true)
  Controls.UndoButton:SetDisabled(running or not SDP_Pins.CanUndo())
end

-- One line on how good the result is (design 7.4).
local function QualityText(result)
  local q = result.Quality
  if q == nil then return "" end
  if q.Exhaustive then return Locale.Lookup("LOC_SDP_QUALITY_EXHAUSTIVE") end
  local parts = {}
  if q.Gap ~= nil then parts[#parts + 1] = Locale.Lookup("LOC_SDP_QUALITY_GAP", Number(math.floor(q.Gap * 100 + 0.5))) end
  if q.Converged then
    parts[#parts + 1] = Locale.Lookup("LOC_SDP_QUALITY_CONVERGED")
  elseif q.CanContinue then
    parts[#parts + 1] = Locale.Lookup("LOC_SDP_QUALITY_MAYBE")
  end
  if q.Truncated then parts[#parts + 1] = Locale.Lookup("LOC_SDP_RESULT_TRUNCATED") end
  return table.concat(parts, Locale.Lookup("LOC_SDP_LIST_SEPARATOR"))
end
SDP_UI.QualityText = QualityText

local function AddResultRow(icon, name, detail, toolTip)
  local inst = m_resultIM:GetInstance()
  inst.Icon:SetIcon(icon, 32)
  inst.Name:SetText(name)
  inst.Detail:SetText(detail)
  inst.Root:SetToolTipString(toolTip)
  m_resultRows[#m_resultRows + 1] = { Icon = icon, Name = name, Detail = detail, ToolTip = toolTip }
end

local function ShowResult()
  m_resultIM:ResetInstances()
  m_resultRows = {}
  local result = m_result
  Controls.Quality:SetText("")
  if result == nil then
    Controls.Summary:SetText(Locale.Lookup("LOC_SDP_RESULT_NONE"))
    Controls.Summary:SetToolTipString("")
  elseif not result.Ok then
    local key = "LOC_SDP_RESULT_" .. tostring(result.Error)
    local text = Locale.Lookup(key)
    if text == key then text = Locale.Lookup("LOC_SDP_RESULT_ERROR", tostring(result.Error)) end
    Controls.Summary:SetText(text)
    Controls.Summary:SetToolTipString("")
  else
    local summary
    local session = result.Session
    if session ~= nil and session.Request ~= nil and session.Request.Land then
      summary = Locale.Lookup("LOC_SDP_RESULT_SUMMARY_LAND", Signed(result.Gain), Signed(result.Adjacency), Signed(result.LandDelta))
    else
      summary = Locale.Lookup("LOC_SDP_RESULT_SUMMARY", Signed(result.Gain))
    end
    Controls.Summary:SetText(summary)
    local stats = result.Stats
    Controls.Summary:SetToolTipString(Locale.Lookup("LOC_SDP_RESULT_STATS",
      Locale.Lookup("LOC_SDP_TIER_" .. stats.Tier), stats.Method or "multi", stats.Calls or 0, stats.Tries or 0,
      stats.Nodes or 0, stats.Continues or 0))
    Controls.Quality:SetText(QualityText(result))
    -- Each planned district: where, its yields, and DMT's own breakdown on hover.
    for _, p in ipairs(result.Plan) do
      local toolTip = (p.ToolTip ~= nil and p.ToolTip ~= "") and p.ToolTip or Locale.Lookup("LOC_SDP_NO_ADJACENCY")
      AddResultRow("ICON_" .. p.Type, TypeName(p.Type) .. "  " .. Where(p.X, p.Y), YieldText(p.Yields), toolTip)
    end
    -- Districts and locked pins whose adjacency the plan changes.
    for _, n in ipairs(result.Neighbours) do
      local s = n.Subject
      AddResultRow("ICON_" .. s.Key, Locale.Lookup("LOC_SDP_RESULT_NEIGHBOUR", TypeName(s.Key), Where(s.X, s.Y)),
        Locale.Lookup("LOC_SDP_RESULT_NEIGHBOUR_DETAIL", Number(n.Before), Number(n.After)),
        (n.ToolTip ~= nil and n.ToolTip ~= "") and n.ToolTip or Locale.Lookup("LOC_SDP_NO_ADJACENCY"))
    end
    for _, u in ipairs(result.Unplaced) do
      AddResultRow("ICON_" .. u.Type, Locale.Lookup("LOC_SDP_RESULT_UNPLACED", TypeName(u.Type)),
        Locale.Lookup("LOC_SDP_REASON_" .. u.Reason), "")
    end
  end
  Controls.ResultStack:CalculateSize()
  Controls.ResultScroll:CalculateSize()
  UpdateButtons()
end

local function ClearResult()
  -- Inputs changed: a computation for the old inputs is of no use any more.
  local job = SDP_Task.Current()
  if job ~= nil and job.Page == "SINGLE" then SDP_Task.Cancel() end
  if m_heat ~= nil then ShowHeat(nil) end -- drawn for the old inputs
  if m_result ~= nil then
    m_result = nil
    ShowResult()
  end
end

-- ===========================================================================
-- Inputs: city, districts, weights, feature switch
-- ===========================================================================
local function UpdateSpecialtyNote()
  if m_scan == nil then
    Controls.SpecialtyNote:SetText("")
    return
  end
  local selected = 0
  for _, d in ipairs(m_districts) do
    if d.Specialty and m_selected[d.Type] and m_status[d.Type] == nil then selected = selected + 1 end
  end
  local text = Locale.Lookup("LOC_SDP_SPECIALTY_NOTE", m_scan.SpecialtyBuilt, selected, m_scan.SpecialtyCapacity)
  if m_scan.SpecialtyBuilt + selected > m_scan.SpecialtyCapacity then
    text = text .. " " .. Locale.Lookup("LOC_SDP_SPECIALTY_OVER")
  end
  Controls.SpecialtyNote:SetText(text)
end

local function SetSelected(districtType, selected)
  if (m_selected[districtType] == true) ~= (selected == true) then
    m_selected[districtType] = selected or nil
    ClearResult()
  end
  for _, row in ipairs(m_districtRows) do
    if row.Type == districtType and row.Check:IsChecked() ~= (selected == true) then row.Check:SetCheck(selected == true) end
  end
  UpdateSpecialtyNote()
  UpdateEstimate()
end

local function RefreshDistricts()
  local playerID = Game.GetLocalPlayer()
  m_districtIM:ResetInstances()
  m_districtRows = {}
  m_districts = SDP_Rules.PlannableDistricts(playerID)
  m_scan = m_cityID and SDP_City.Scan(playerID, m_cityID) or nil
  m_status = m_scan and SDP_City.DistrictStatus(m_scan, m_districts) or {}
  UpdateReplaceLabel()
  PopulateHeat()

  -- Shown in name order; the solver always gets them in type order, so the
  -- plan never depends on the order of clicks.
  local display = {}
  for i, d in ipairs(m_districts) do display[i] = { District = d, Name = Locale.Lookup(d.Name) } end
  table.sort(display, function(a, b)
    if a.Name ~= b.Name then return Locale.Compare(a.Name, b.Name) == -1 end
    return a.District.Type < b.District.Type
  end)

  for _, entry in ipairs(display) do
    local d = entry.District
    local status = m_status[d.Type]
    local inst = m_districtIM:GetInstance()
    inst.Icon:SetIcon(d.Icon, 32)
    inst.Name:SetText(entry.Name)
    inst.Status:SetText(status and Locale.Lookup("LOC_SDP_STATUS_" .. status) or "")
    inst.Check:SetCheck(status == nil and m_selected[d.Type] == true)
    inst.Check:SetDisabled(status ~= nil)
    inst.Root:SetAlpha(status and 0.5 or 1) -- built districts are greyed out
    inst.Check:RegisterCheckHandler(function()
      SetSelected(d.Type, inst.Check:IsChecked())
    end)
    m_districtRows[#m_districtRows + 1] = { Type = d.Type, Name = entry.Name, Status = status, Check = inst.Check }
  end
  Controls.DistrictStack:CalculateSize()
  Controls.DistrictScroll:CalculateSize()
  UpdateSpecialtyNote()
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

local function SetWeight(yieldType, value)
  value = math.max(0, math.min(MAX_WEIGHT, value))
  if m_weights[yieldType] ~= value then
    m_weights[yieldType] = value
    ClearResult()
  end
  if m_weightViews[yieldType] then m_weightViews[yieldType]() end
end

local function BuildWeights()
  m_weightIM:ResetInstances()
  for _, column in ipairs(WEIGHT_COLUMNS) do
    local key = column.Key
    local inst = m_weightIM:GetInstance()
    local function Show()
      local off = column.Land and not m_land -- weighs the land part only
      inst.Value:SetText(tostring(m_weights[key]))
      inst.Less:SetDisabled(off or m_weights[key] <= 0)
      inst.More:SetDisabled(off or m_weights[key] >= MAX_WEIGHT)
      inst.Root:SetAlpha(off and 0.5 or 1)
    end
    if column.Icon then
      inst.Icon:SetIcon(column.Icon)
      inst.Glyph:SetText("")
    else
      inst.Icon:SetHide(true)
      inst.Glyph:SetText(Locale.Lookup(column.Glyph))
    end
    local row = GameInfo.Yields[key]
    inst.Root:SetToolTipString(Locale.Lookup(column.ToolTip or (row and row.Name) or key))
    inst.Less:RegisterCallback(Mouse.eLClick, function() SetWeight(key, m_weights[key] - 1) end)
    inst.More:RegisterCallback(Mouse.eLClick, function() SetWeight(key, m_weights[key] + 1) end)
    m_weightViews[key] = Show
    Show()
  end
  Controls.WeightStack:CalculateSize()
end

-- Weight columns for a tab: `columns` like WEIGHT_COLUMNS, `weights` the
-- tab's table, isOff(column) greys a column out, onChange(key, value).
-- Returns { [key] = redraw function }.
function SDP_UI.BuildWeights(im, stack, columns, weights, isOff, onChange)
  im:ResetInstances()
  local views = {}
  for _, column in ipairs(columns) do
    local key = column.Key
    local inst = im:GetInstance()
    local function Show()
      local off = isOff and isOff(column) or false
      inst.Value:SetText(tostring(weights[key]))
      inst.Less:SetDisabled(off or weights[key] <= 0)
      inst.More:SetDisabled(off or weights[key] >= MAX_WEIGHT)
      inst.Root:SetAlpha(off and 0.5 or 1)
    end
    if column.Icon then
      inst.Icon:SetHide(false)
      inst.Icon:SetIcon(column.Icon)
      inst.Glyph:SetText("")
    else
      inst.Icon:SetHide(true)
      inst.Glyph:SetText(Locale.Lookup(column.Glyph))
    end
    local row = GameInfo.Yields[key]
    inst.Root:SetToolTipString(Locale.Lookup(column.ToolTip or (row and row.Name) or key))
    inst.Less:RegisterCallback(Mouse.eLClick, function() onChange(key, math.max(0, weights[key] - 1)) end)
    inst.More:RegisterCallback(Mouse.eLClick, function() onChange(key, math.min(MAX_WEIGHT, weights[key] + 1)) end)
    views[key] = Show
    Show()
  end
  stack:CalculateSize()
  return views
end

-- A tier pulldown: entries for the three tiers, onSelect(tier).
function SDP_UI.PopulateTierPull(pull, current, onSelect)
  pull:ClearEntries()
  for _, tier in ipairs(SDP_Tiers.ORDER) do
    local entry = {}
    pull:BuildEntry("InstanceOne", entry)
    entry.Button:SetText(Locale.Lookup("LOC_SDP_TIER_" .. tier))
    entry.Button:SetToolTipString(Locale.Lookup("LOC_SDP_TIER_" .. tier .. "_TOOLTIP"))
    entry.Button:RegisterCallback(Mouse.eLClick, function() onSelect(tier) end)
  end
  pull:CalculateInternals()
  pull:GetButton():SetText(Locale.Lookup("LOC_SDP_TIER_" .. current))
end

-- "About X s" for `units` of work.
-- A SolutionRow instance: texts and the selected look (light text on the
-- dark button, dark text on the light selected look).
function SDP_UI.SolutionRow(inst, name, detail, selected)
  inst.Name:SetText(name)
  inst.NameDark:SetText(name)
  inst.Detail:SetText(detail)
  inst.DetailDark:SetText(detail)
  inst.Selected:SetHide(not selected)
  inst.Name:SetHide(selected)
  inst.Detail:SetHide(selected)
  inst.NameDark:SetHide(not selected)
  inst.DetailDark:SetHide(not selected)
end

function SDP_UI.EstimateText(units)
  if units <= 0 then return "" end
  local seconds = SDP_Task.EstimateSeconds(units)
  if seconds < 1 then return Locale.Lookup("LOC_SDP_ESTIMATE_UNDER_ONE") end
  return Locale.Lookup("LOC_SDP_ESTIMATE", Number(math.floor(seconds + 0.5)))
end

local function SetAllowFeatureRemoval(allow)
  Controls.FeatureCheck:SetCheck(allow)
  if m_allowFeatureRemoval ~= allow then
    m_allowFeatureRemoval = allow
    ClearResult()
  end
end

-- This mod's earlier pins for the selected city (the ones "replace" removes).
local function OwnPins()
  if m_cityID == nil then return {} end
  local playerID = Game.GetLocalPlayer()
  return SDP_Pins.Own(playerID, { SDP_City.CityNumbers(playerID)[m_cityID] })
end

UpdateReplaceLabel = function()
  Controls.ReplaceLabel:SetText(Locale.Lookup("LOC_SDP_REPLACE_OWN", #OwnPins()))
end

local function SetReplace(on)
  Controls.ReplaceCheck:SetCheck(on)
  if m_replace ~= on then
    m_replace = on
    ClearResult()
  end
end

-- Wonders to place with the districts (design 18, item 5): selectable ones,
-- in type order.
local function SelectedWonders()
  local list = {}
  for _, w in ipairs(SDP_Wonders.List(Game.GetLocalPlayer())) do
    if m_wonders[w.Type] and w.Status == nil then list[#list + 1] = w.Type end
  end
  return list
end

-- The wonder pulldown: each wonder not built or pinned yet; a click toggles it.
local function PopulateWonders()
  local pull = Controls.WonderPull
  pull:ClearEntries()
  local chosen = {}
  for _, w in ipairs(SDP_Wonders.List(Game.GetLocalPlayer())) do
    if w.Status == nil then
      local entry = {}
      pull:BuildEntry("InstanceOne", entry)
      local name = Locale.Lookup(w.Name)
      local wonderType = w.Type
      local on = m_wonders[wonderType] == true
      entry.Button:SetText(on and Locale.Lookup("LOC_SDP_WONDER_CHOSEN", name) or name)
      entry.Button:RegisterCallback(Mouse.eLClick, function() SetWonder(wonderType, not m_wonders[wonderType]) end)
      if on then chosen[#chosen + 1] = name end
    end
  end
  pull:CalculateInternals()
  pull:GetButton():SetText(#chosen == 0 and Locale.Lookup("LOC_SDP_WONDERS_NONE")
    or table.concat(chosen, Locale.Lookup("LOC_SDP_LIST_SEPARATOR")))
end

SetWonder = function(wonderType, on)
  if (m_wonders[wonderType] == true) ~= (on == true) then
    m_wonders[wonderType] = on or nil
    ClearResult()
  end
  PopulateWonders()
  UpdateEstimate()
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
      AllowFeatureRemoval = m_allowFeatureRemoval, IgnorePins = m_replace and OwnPins() or nil }) or {}
    local best = spots[1] and spots[1].Gain or 0
    local worst = spots[#spots] and spots[#spots].Gain or 0
    local areas, icons = {}, {}
    for shade = 1, 4 do areas[shade] = { Plots = {}, Color = shade } end
    for _, spot in ipairs(spots) do
      local shade = 1
      if best > worst then shade = math.min(4, 1 + math.floor(3 * (best - spot.Gain) / (best - worst) + 1e-9)) end
      local plots = areas[shade].Plots
      plots[#plots + 1] = spot.Index
      icons[#icons + 1] = { X = spot.X, Y = spot.Y, Icon = "ICON_" .. districtType, Text = Signed(spot.Gain) }
    end
    SDP_Preview.Show(playerID, areas, icons)
    m_heatSpots = spots
    label = TypeName(districtType)
  else
    m_heatSpots = nil
  end
  Controls.HeatPull:GetButton():SetText(label)
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
    if m_status[d.Type] == nil then
      local districtType = d.Type
      local e = {}
      pull:BuildEntry("InstanceOne", e)
      e.Button:SetText(Locale.Lookup(d.Name))
      e.Button:RegisterCallback(Mouse.eLClick, function() ShowHeat(districtType) end)
    end
  end
  pull:CalculateInternals()
  pull:GetButton():SetText(m_heat and TypeName(m_heat) or Locale.Lookup("LOC_SDP_HEAT_OFF"))
end

local function SetLand(on)
  Controls.LandCheck:SetCheck(on)
  if m_land ~= on then
    m_land = on
    ClearResult()
  end
  for _, column in ipairs(WEIGHT_COLUMNS) do
    if column.Land and m_weightViews[column.Key] then m_weightViews[column.Key]() end
  end
end

local function SetTier(tier)
  if SDP_Tiers.Single[tier] == nil then return end
  if m_tier ~= tier then
    m_tier = tier
    ClearResult()
  end
  Controls.TierPull:GetButton():SetText(Locale.Lookup("LOC_SDP_TIER_" .. tier))
  UpdateEstimate()
end

local function PopulateTiers()
  local pull = Controls.TierPull
  pull:ClearEntries()
  for _, tier in ipairs(SDP_Tiers.ORDER) do
    local entry = {}
    pull:BuildEntry("InstanceOne", entry)
    entry.Button:SetText(Locale.Lookup("LOC_SDP_TIER_" .. tier))
    entry.Button:SetToolTipString(Locale.Lookup("LOC_SDP_TIER_" .. tier .. "_TOOLTIP"))
    entry.Button:RegisterCallback(Mouse.eLClick, function() SetTier(tier) end)
  end
  pull:CalculateInternals()
  pull:GetButton():SetText(Locale.Lookup("LOC_SDP_TIER_" .. m_tier))
end

-- The districts the solver gets: selected and plannable, in type order, so
-- the plan never depends on the order of clicks.
local function SelectedDistricts()
  local districts = {}
  for _, d in ipairs(m_districts) do
    if m_selected[d.Type] and m_status[d.Type] == nil then districts[#districts + 1] = d.Type end
  end
  return districts
end

-- "About X s" for the selected tier and districts (design 7.5).
UpdateEstimate = function()
  local k, wonders = #SelectedDistricts(), #SelectedWonders()
  if m_scan == nil or k + wonders == 0 then
    Controls.Estimate:SetText("")
    return
  end
  local params = SDP_Tiers.Params(SDP_Tiers.Single, m_tier)
  local units = SDP_Solver.EstimateUnits(#m_scan.Candidates, k, params)
  local sliced = params.Sliced
  if wonders > 0 then
    units = SDP_Multi.EstimateUnits(1, k, wonders, SDP_Tiers.Params(SDP_Tiers.Multi, m_tier))
    sliced = true
  end
  local seconds = SDP_Task.EstimateSeconds(units, not sliced)
  if seconds < 1 then
    Controls.Estimate:SetText(Locale.Lookup("LOC_SDP_ESTIMATE_UNDER_ONE"))
  else
    Controls.Estimate:SetText(Locale.Lookup("LOC_SDP_ESTIMATE", Number(math.floor(seconds + 0.5))))
  end
end

Refresh = function()
  PopulateCities()
  RefreshDistricts()
  BuildWeights()
  PopulateTiers()
  Controls.FeatureCheck:SetCheck(m_allowFeatureRemoval)
  Controls.LandCheck:SetCheck(m_land)
  Controls.ReplaceCheck:SetCheck(m_replace)
  UpdateReplaceLabel()
  PopulateWonders()
  m_heat = nil
  PopulateHeat()
  UpdateEstimate()
  ShowResult()
end

-- ===========================================================================
-- Actions
-- ===========================================================================
-- ---------------------------------------------------------------------------
-- Computations over several frames (SDP_Task): the fine tier and its continues.
-- Closing the panel does not stop them (design 6); the launch bar button's
-- tooltip shows progress and a mark appears when the result is ready.
-- ---------------------------------------------------------------------------
-- Changes whenever the player's map pins change.
local function PinSignature(playerID)
  local count, sum = 0, 0
  for _, pin in pairs(PlayerConfigurations[playerID]:GetMapPins()) do
    count = count + 1
    sum = sum + pin:GetID() * 7 + pin:GetHexX() * 131 + pin:GetHexY() * 3
  end
  return count .. ":" .. sum
end

local function ProgressPercent()
  local progress = SDP_Task.Progress()
  if progress == nil or progress.Estimate == nil or progress.Estimate <= 0 then return 0 end
  return math.min(99, math.floor(100 * progress.Units / progress.Estimate))
end

-- The tabs (filled in below): each { Render, ShowProgress(text), UpdateButtons, OnError(message) }.
local m_pages = {}
local m_taskPage = nil -- the tab whose computation is running

local function UpdateAllButtons()
  for _, page in pairs(m_pages) do page.UpdateButtons() end
end

local function ShowProgress()
  if m_taskPage ~= nil then m_taskPage.ShowProgress(Locale.Lookup("LOC_SDP_RUNNING", ProgressPercent())) end
  LaunchToolTip(Locale.Lookup("LOC_SDP_LAUNCHBAR_RUNNING", ProgressPercent()))
end

local function TaskFinished()
  ContextPtr:ClearUpdate()
  LaunchToolTip(nil)
  if m_taskPage ~= nil then m_taskPage.Render() end
  UpdateAllButtons()
  if not IsOpen() then
    -- Render shows the new result's preview; not on the map of a closed
    -- panel (found in the game, 2026-10-20). Opening the tab shows it again.
    SDP_Preview.Clear()
    KeepRunningHidden(false)
    UI.PlaySound("Confirm_Bed_Positive")
    SetLaunchMark(true)
  end
end

local function OnUpdate()
  if SDP_Task.Step() == "running" then ShowProgress() end
end

-- Run `run` (returns a result) over several frames for `page` (default the
-- single-city tab); `onDone(result)` keeps the result. One at a time.
local function StartTask(run, estimate, onDone, page)
  page = page or m_pages.SINGLE
  local playerID = Game.GetLocalPlayer()
  local turn, pins = Game.GetCurrentGameTurn(), PinSignature(playerID)
  local started = SDP_Task.Start({
    Name = "planner", Page = page.Name, PlayerID = playerID, Run = run, Estimate = estimate,
    IsStale = function() return Game.GetCurrentGameTurn() ~= turn or PinSignature(playerID) ~= pins end,
    OnDone = function(result)
      onDone(result)
      TaskFinished()
    end,
    OnError = function(message)
      page.OnError(message)
      TaskFinished()
    end,
    OnCancel = function() TaskFinished() end,
  })
  if started then
    m_taskPage = page
    ContextPtr:SetUpdate(OnUpdate)
    ShowProgress()
    UpdateAllButtons()
  end
  return started
end
SDP_UI.StartTask = StartTask
SDP_UI.UpdateAllButtons = function() UpdateAllButtons() end

local function Request()
  local districts = SelectedDistricts()
  local wonders = SelectedWonders()
  if m_cityID == nil or (#districts == 0 and #wonders == 0) then return nil end
  local weights = {}
  for key, value in pairs(m_weights) do weights[key] = value end
  return {
    PlayerID = Game.GetLocalPlayer(), CityID = m_cityID, Districts = districts, Weights = weights,
    AllowFeatureRemoval = m_allowFeatureRemoval, Land = m_land, Tier = m_tier,
    IgnorePins = m_replace and OwnPins() or nil, Wonders = wonders,
  }
end

-- With wonders the city is solved as SDP_Multi with this one city (it places
-- wonders next to districts, design 4.4); always over several frames.
local function WonderRequest(request)
  return {
    PlayerID = request.PlayerID, Tier = request.Tier, Districts = request.Districts, Wonders = request.Wonders,
    Only = { [request.CityID] = true }, Weights = request.Weights, Land = request.Land,
    AllowFeatureRemoval = request.AllowFeatureRemoval, IgnorePins = request.IgnorePins,
  }
end

-- Solve now (fast and standard tiers: returns the result) or start a sliced
-- computation (fine tier: returns nil, the result shows when it is done).
local function Solve()
  if SDP_Task.IsRunning() then return nil end
  local request = Request()
  if m_heat ~= nil then ShowHeat(nil) end
  if request ~= nil and #request.Wonders > 0 then
    local multi = WonderRequest(request)
    local estimate = SDP_Multi.EstimateUnits(1, #request.Districts, #request.Wonders, SDP_Tiers.Params(SDP_Tiers.Multi, m_tier))
    m_result = nil
    StartTask(function() return SDP_Multi.SolveNow(multi) end, estimate, function(result) m_result = result end)
    return nil
  end
  local params = SDP_Tiers.Params(SDP_Tiers.Single, m_tier)
  if request ~= nil and params.Sliced then
    local scan = SDP_City.Scan(request.PlayerID, request.CityID, SDP_City.ScanOptions(request))
    if scan ~= nil then
      m_result = nil
      local estimate = SDP_Solver.EstimateUnits(#scan.Candidates, #request.Districts, params)
      StartTask(function() return SDP_Solver.SolveScan(request, scan) end, estimate,
        function(result) m_result = result end)
      return nil
    end
  end
  m_result = request and SDP_Solver.Solve(request) or nil
  ShowResult()
  return m_result
end

-- One more batch of local searches on the shown result (design 7.3).
local function Continue()
  if SDP_Task.IsRunning() or not CanContinue() then return nil end
  local session = m_result.Session
  if session.Params.Sliced then
    -- A continue runs SINGLE_CONTINUE_STARTS local searches; the first run
    -- had Starts + Kicks of them.
    local params = session.Params
    local estimate = SDP_Solver.EstimateUnits(m_scan and #m_scan.Candidates or 30, #(session.Request.Districts or {}), params)
      * SDP_Tiers.SINGLE_CONTINUE_STARTS / math.max(1, params.Starts + (params.Kicks or 0))
    StartTask(function()
      session:Continue()
      return session:Result()
    end, estimate, function(result) m_result = result end)
    return nil
  end
  m_result = SDP_Solver.Continue(m_result)
  ShowResult()
  return m_result
end

local function Cancel()
  return SDP_Task.Cancel()
end

local function PlacePins()
  if SDP_Task.IsRunning() or m_result == nil or not m_result.Ok or m_result.Placed then return 0 end
  local playerID = Game.GetLocalPlayer()
  local number = tostring(SDP_City.CityNumbers(playerID)[m_cityID] or "")
  local entries = {}
  for i, p in ipairs(m_result.Plan) do entries[i] = { Type = p.Type, X = p.X, Y = p.Y, Name = number } end
  -- The plan was made as if this mod's earlier pins were gone: remove them.
  local session = m_result.Session
  local placed = SDP_Pins.Place(playerID, entries, { Replace = session and session.Request.IgnorePins })
  m_result.Placed = true
  UpdateReplaceLabel()
  UpdateButtons()
  return placed
end

local function UndoPins()
  local last = SDP_Pins.LastBatch()
  local removed = SDP_Pins.UndoLast()
  if last ~= nil and last.Replaced and #last.Replaced > 0 then
    -- The replaced pins are back (with new IDs): plan again.
    ClearResult()
  elseif m_result ~= nil and m_result.Ok then
    -- The plots are free again: the shown plan can be placed once more.
    m_result.Placed = false
  end
  UpdateReplaceLabel()
  UpdateButtons()
  return removed
end

-- ===========================================================================
-- Tabs
-- ===========================================================================
m_pages.SINGLE = {
  Name = "SINGLE",
  Render = function() ShowResult() end,
  ShowProgress = function(text)
    Controls.Summary:SetText(text)
    Controls.Quality:SetText("")
  end,
  UpdateButtons = function() UpdateButtons() end,
  OnError = function(message) m_result = { Ok = false, Error = message } end,
}

SDP_Preview.Init(Controls.PreviewWorldIcons, "SDP_PreviewIcon")
include("SDP_PageSites")
include("SDP_PageMulti")
m_pages.SITES = SDP_PageSites
m_pages.MULTI = SDP_PageMulti

local TABS = {
  { Name = "SINGLE", Button = Controls.SingleTab, Selected = Controls.SingleTabSelected, Page = Controls.SinglePage,
    Label = Controls.SingleTabLabel, SelectedLabel = Controls.SingleTabSelectedLabel },
  { Name = "SITES", Button = Controls.SitesTab, Selected = Controls.SitesTabSelected, Page = Controls.SitesPage,
    Label = Controls.SitesTabLabel, SelectedLabel = Controls.SitesTabSelectedLabel },
  { Name = "MULTI", Button = Controls.MultiTab, Selected = Controls.MultiTabSelected, Page = Controls.MultiPage,
    Label = Controls.MultiTabLabel, SelectedLabel = Controls.MultiTabSelectedLabel },
}
SelectTab = function(name)
  if m_tab ~= name then SDP_Preview.Clear() end
  m_tab = name
  for _, tab in ipairs(TABS) do
    local on = tab.Name == name
    tab.Selected:SetHide(not on)
    tab.Label:SetHide(on)
    tab.SelectedLabel:SetHide(not on)
    tab.Page:SetHide(not on)
  end
  if name == "SINGLE" then
    Refresh()
  else
    m_pages[name].Refresh()
  end
end

for _, tab in ipairs(TABS) do
  local name = tab.Name
  tab.Button:RegisterCallback(Mouse.eLClick, function() SelectTab(name) end)
  tab.Button:RegisterCallback(Mouse.eMouseEnter, function() UI.PlaySound("Main_Menu_Mouse_Over") end)
end

-- The game's own placement modes use the preview's lens layer (risk 10).
local function OnInterfaceModeChanged()
  if SDP_Preview.IsShown() then SDP_Preview.Clear() end
end

-- ===========================================================================
-- Launch bar
-- ===========================================================================
-- Mirrors RealizeBacking() in the game's LaunchBar.lua, which lives in
-- another context and cannot be called from here.
local function ResizeLaunchBar(stack)
  stack:CalculateSize()
  local width = stack:GetSizeX()
  local backing = ContextPtr:LookUpControl("/InGame/LaunchBar/LaunchBacking")
  local tile = ContextPtr:LookUpControl("/InGame/LaunchBar/LaunchBackingTile")
  local shadow = ContextPtr:LookUpControl("/InGame/LaunchBar/LaunchBarDropShadow")
  if backing ~= nil then backing:SetSizeX(width + 116) end
  if tile ~= nil then tile:SetSizeX(math.max(0, width - 20)) end
  if shadow ~= nil then shadow:SetSizeX(width) end
  LuaEvents.LaunchBar_Resize(width)
end

local function InjectLaunchButton()
  if m_launchItem.LaunchItemButton ~= nil then return true end
  local stack = ContextPtr:LookUpControl(LAUNCH_BAR_STACK)
  if stack == nil then return false end

  ContextPtr:BuildInstanceForControl("SDP_LaunchBarItem", m_launchItem, stack)
  ContextPtr:BuildInstanceForControl("SDP_LaunchBarPin", m_launchPin, stack)
  m_launchItem.LaunchItemIcon:SetIcon("ICON_MAP_PIN_DISTRICT")
  m_launchItem.LaunchItemButton:RegisterCallback(Mouse.eLClick, Toggle)
  m_launchItem.LaunchItemButton:RegisterCallback(Mouse.eMouseEnter, function()
    UI.PlaySound("Main_Menu_Mouse_Over")
  end)
  ResizeLaunchBar(stack)
  return true
end

-- Remove our controls from the launch bar so a reloaded context does not
-- leave a dead duplicate behind.
local function RemoveLaunchButton()
  local stack = ContextPtr:LookUpControl(LAUNCH_BAR_STACK)
  if stack == nil then return end
  if m_launchItem.LaunchItemButton ~= nil then stack:DestroyChild(m_launchItem.LaunchItemButton) end
  if m_launchPin.Pin ~= nil then stack:DestroyChild(m_launchPin.Pin) end
  m_launchItem, m_launchPin = {}, {}
  ResizeLaunchBar(stack)
end

-- ===========================================================================
-- Context
-- ===========================================================================
local function OnLoadScreenClose()
  InjectLaunchButton()
end

local function OnInput(uiMsg, wParam)
  if uiMsg == KeyEvents.KeyUp and wParam == Keys.VK_ESCAPE and IsOpen() then
    Close()
    return true
  end
  return false
end

local function OnInit(isReload)
  -- After a hot reload the load screen is long gone; inject right away.
  if isReload then InjectLaunchButton() end
end

-- The "open the planner" key (Config/SDP_Input.xml, default Shift+L; the
-- player can change it in the game's options).
local m_openActionId = (Input ~= nil and Input.GetActionId ~= nil) and Input.GetActionId("SDP_OpenPlanner") or nil
local function OnInputActionTriggered(actionId)
  if m_openActionId ~= nil and actionId == m_openActionId then Toggle() end
end

local function OnShutdown()
  Events.InputActionTriggered.Remove(OnInputActionTriggered)
  if SDP_Task.IsRunning() then SDP_Task.Cancel() end
  ContextPtr:ClearUpdate()
  SDP_Preview.Clear()
  Events.LoadScreenClose.Remove(OnLoadScreenClose)
  Events.InterfaceModeChanged.Remove(OnInterfaceModeChanged)
  LuaEvents.SDP_OpenPanel.Remove(Open)
  LuaEvents.SDP_ClosePanel.Remove(Close)
  RemoveLaunchButton()
end

-- Test hooks: tools/run_tests.py runs tests inside this context's Lua state.
SDP_Panel = {
  Open = Open,
  Close = Close,
  IsOpen = IsOpen,
  HandleInput = OnInput,
  LaunchButton = function() return m_launchItem.LaunchItemButton end,
  Refresh = function() Refresh() end,
  SelectCity = function(cityID) SelectCity(cityID) end,
  SetSelected = SetSelected,
  SetWeight = SetWeight,
  SetAllowFeatureRemoval = SetAllowFeatureRemoval,
  SetReplace = SetReplace,
  SetWonder = SetWonder,
  ShowHeat = function(districtType) ShowHeat(districtType) end,
  Heat = function() return m_heatSpots end,
  SetLand = SetLand,
  SetTier = SetTier,
  Solve = Solve,
  Continue = Continue,
  Cancel = Cancel,
  -- Drive a sliced computation to its end now (tests cannot wait for frames).
  RunTask = function(quota)
    while SDP_Task.IsRunning() do SDP_Task.Step(quota) end
    return m_result
  end,
  PlacePins = PlacePins,
  UndoPins = UndoPins,
  SelectTab = function(name) SelectTab(name) end,
  Tab = function() return m_tab end,
  -- The context shown with the window hidden: a task runs on after Close.
  RunsHidden = function() return not ContextPtr:IsHidden() and Controls.DropShadow:IsHidden() end,
  Sites = SDP_PageSites,
  Multi = SDP_PageMulti,
  State = function()
    return {
      CityID = m_cityID, Result = m_result, DistrictRows = m_districtRows, ResultRows = m_resultRows,
      Weights = m_weights, AllowFeatureRemoval = m_allowFeatureRemoval, Land = m_land, Tier = m_tier, Replace = m_replace,
      Wonders = SelectedWonders(), HeatDistrict = m_heat,
      Running = SDP_Task.IsRunning(), QualityText = Controls.Quality:GetText(), EstimateText = Controls.Estimate:GetText(),
      PlaceDisabled = Controls.PlaceButton:IsDisabled(), UndoDisabled = Controls.UndoButton:IsDisabled(),
      ContinueDisabled = Controls.ContinueButton:IsDisabled(), LaunchMark = m_launchDone,
    }
  end,
}

Controls.CloseButton:RegisterCallback(Mouse.eLClick, Close)
Controls.CloseButton:RegisterCallback(Mouse.eMouseEnter, function()
  UI.PlaySound("Main_Menu_Mouse_Over")
end)
Controls.ReplaceCheck:RegisterCheckHandler(function()
  SetReplace(Controls.ReplaceCheck:IsChecked())
end)
Controls.FeatureCheck:RegisterCheckHandler(function()
  SetAllowFeatureRemoval(Controls.FeatureCheck:IsChecked())
end)
Controls.LandCheck:RegisterCheckHandler(function()
  SetLand(Controls.LandCheck:IsChecked())
end)
Controls.SolveButton:RegisterCallback(Mouse.eLClick, function() Solve() end)
Controls.ContinueButton:RegisterCallback(Mouse.eLClick, function() Continue() end)
Controls.CancelButton:RegisterCallback(Mouse.eLClick, function() Cancel() end)
Controls.PlaceButton:RegisterCallback(Mouse.eLClick, function() PlacePins() end)
Controls.UndoButton:RegisterCallback(Mouse.eLClick, function() UndoPins() end)
ContextPtr:SetInputHandler(OnInput, true)
ContextPtr:SetInitHandler(OnInit)
ContextPtr:SetShutdown(OnShutdown)
Events.LoadScreenClose.Add(OnLoadScreenClose)
Events.InputActionTriggered.Add(OnInputActionTriggered)
Events.InterfaceModeChanged.Add(OnInterfaceModeChanged)
LuaEvents.SDP_OpenPanel.Add(Open)
LuaEvents.SDP_ClosePanel.Add(Close)
