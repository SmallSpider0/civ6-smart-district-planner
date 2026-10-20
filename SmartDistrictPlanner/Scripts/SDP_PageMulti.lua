-- SDP_PageMulti: the "several cities" tab of the planner panel
-- (docs/multicity-design.md section 4, step 2). Included by SDP_Panel.lua
-- into its context: uses its Controls and the SDP_UI helpers.
--   Cities    new cities (city-center pins) and the existing cities near them,
--             which can be switched; the plan and the wonders to place
--   Plans     one district list for every city, or a city's own list (the
--             "plan for" pulldown; role templates from SDP_Rules.Templates).
--             A district with an empire limit (government plaza) goes to one
--             of the cities that plan it: in the shared list, the solver
--             picks the city; in one city's own list only, it stays there.
--   Weights   the five yields, the land part, and the coverage part
--             (SDP_Coverage, design 19): 0 = off, the default.
--   Solve     always over several frames (SDP_Task); the result lists up to
--             three distinct solutions; the selected one is previewed on the
--             map (SDP_Preview) and can be placed as map tacks.

SDP_PageMulti = {}
local P = SDP_PageMulti
P.Name = "MULTI"

local m_cityIM = InstanceManager:new("CityRow", "Root", Controls.MultiCityStack)
local m_districtIM = InstanceManager:new("CheckRow", "Root", Controls.MultiDistrictStack)
local m_wonderIM = InstanceManager:new("CheckRow", "Root", Controls.WonderStack)
local m_weightIM = InstanceManager:new("WeightColumn", "Root", Controls.MultiWeightStack)
local m_solutionIM = InstanceManager:new("SolutionRow", "Root", Controls.MultiSolutionStack)
local m_resultIM = InstanceManager:new("ResultRow", "Root", Controls.MultiResultStack)

local m_selected = {}  -- [DistrictType] = true: the plan of every city without its own
local m_plans = {}     -- [participant Key] = { [DistrictType] = true }: a city's own plan
local m_planFor = "ALL" -- the list the district checks edit: "ALL" or a participant Key
local m_wonders = {}   -- [BuildingType] = true
local m_existing = {}  -- [cityID] = true | false: switches over the default
-- The panel's weight columns plus the coverage part, a little narrower so
-- that eight fit.
local COLUMNS, COLUMN_WIDTH = {}, 60
for _, column in ipairs(SDP_UI.WEIGHT_COLUMNS) do COLUMNS[#COLUMNS + 1] = column end
COLUMNS[#COLUMNS + 1] = { Key = "COVERAGE", Glyph = "LOC_SDP_WEIGHT_COVERAGE_SHORT", ToolTip = "LOC_SDP_WEIGHT_COVERAGE" }
local m_weights = {}
for _, column in ipairs(COLUMNS) do m_weights[column.Key] = 1 end
m_weights.COVERAGE = 0
local m_weightViews = {}
local m_tier = SDP_Tiers.DEFAULT
local m_land = true
local m_replace = false -- plan over this mod's earlier pins for the cities and replace them
local m_result = nil
local m_solution = 1
local m_view = { Cities = {}, Districts = {}, Wonders = {}, Solutions = {}, Results = {}, Plans = {}, Templates = {} } -- for tests

-- How a participant is called: its number (the name its pins get, see
-- SDP_City.CityNumbers) and the city's name, or "Site n" for a planned city.
function P.CityLabel(city)
  if city.Kind == "CITY" then return Locale.Lookup("LOC_SDP_CITY_N", city.Number or 0, Locale.Lookup(city.Name)) end
  return Locale.Lookup("LOC_SDP_SITE_N", city.Number or city.SiteNumber or 0)
end

local function ClearResult()
  local job = SDP_Task.Current()
  if job ~= nil and job.Page == P.Name then SDP_Task.Cancel() end
  if m_result ~= nil then
    m_result = nil
    SDP_Preview.Clear()
    P.Render()
  end
end

-- ===========================================================================
-- Inputs
-- ===========================================================================
-- A district set as a list in PlannableDistricts order.
local function TypesOf(set)
  local list = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(Game.GetLocalPlayer())) do
    if set[d.Type] then list[#list + 1] = d.Type end
  end
  return list
end

local function PlannedTypes() return TypesOf(m_selected) end

-- The set the district checks show and edit.
local function EditedSet()
  if m_planFor ~= "ALL" and m_plans[m_planFor] ~= nil then return m_plans[m_planFor] end
  return m_selected
end

local function WonderTypes()
  local list = {}
  for _, w in ipairs(SDP_Wonders.List(Game.GetLocalPlayer())) do
    if m_wonders[w.Type] and w.Status == nil then list[#list + 1] = w.Type end
  end
  return list
end

function P.Request()
  local playerID = Game.GetLocalPlayer()
  local districts = PlannedTypes()
  local weights, existing = {}, {}
  for key, value in pairs(m_weights) do weights[key] = value end
  for id, on in pairs(m_existing) do existing[id] = on end
  -- Cities with their own list; lists of cities no longer taking part are kept
  -- for later but not sent.
  local plans, anything = nil, #districts > 0
  for _, part in ipairs(SDP_Multi.Participants(playerID, { Existing = existing })) do
    if m_plans[part.Key] ~= nil then
      plans = plans or {}
      plans[part.Key] = TypesOf(m_plans[part.Key])
      if #plans[part.Key] > 0 then anything = true end
    end
  end
  local wonders = WonderTypes()
  if not anything and #wonders == 0 then return nil end
  return {
    PlayerID = playerID, Tier = m_tier, Districts = districts, Plans = plans, Wonders = wonders,
    Existing = existing, Weights = weights, Land = m_land, Coverage = m_weights.COVERAGE,
    IgnorePins = m_replace and P.OwnPins() or nil,
  }
end

-- This mod's earlier pins for the taking-part cities (named with their numbers).
function P.OwnPins()
  local playerID = Game.GetLocalPlayer()
  local numbers = {}
  for _, part in ipairs(SDP_Multi.Participants(playerID, { Existing = m_existing })) do
    if part.Number ~= nil then numbers[#numbers + 1] = part.Number end
  end
  return SDP_Pins.Own(playerID, numbers)
end

local function UpdateReplaceLabel()
  Controls.MultiReplaceLabel:SetText(Locale.Lookup("LOC_SDP_REPLACE_OWN", #P.OwnPins()))
end

function P.SetReplace(on)
  Controls.MultiReplaceCheck:SetCheck(on)
  if m_replace ~= on then
    m_replace = on
    ClearResult()
  end
end

-- Districts per city on average, for the estimate.
local function PlanSize(request, participants)
  if #participants == 0 then return #request.Districts end
  local total = 0
  for _, part in ipairs(participants) do
    total = total + #((request.Plans and request.Plans[part.Key]) or request.Districts)
  end
  return math.ceil(total / #participants)
end

local function UpdateEstimate()
  local request = P.Request()
  if request == nil then
    Controls.MultiEstimate:SetText("")
    return
  end
  local participants = SDP_Multi.Participants(request.PlayerID, { Existing = request.Existing })
  local units = SDP_Multi.EstimateUnits(#participants, PlanSize(request, participants), #request.Wonders,
    SDP_Tiers.Params(SDP_Tiers.Multi, m_tier))
  Controls.MultiEstimate:SetText(SDP_UI.EstimateText(units))
end

-- Check or uncheck a district in the edited list. The first change to a
-- city's list starts it as a copy of the shared one.
function P.SetSelected(districtType, on)
  if m_planFor ~= "ALL" and m_plans[m_planFor] == nil then
    local copy = {}
    for t in pairs(m_selected) do copy[t] = true end
    m_plans[m_planFor] = copy
  end
  local set = EditedSet()
  if (set[districtType] == true) ~= (on == true) then
    set[districtType] = on or nil
    ClearResult()
  end
  P.RefreshLists()
end

-- Which list the district checks edit: "ALL" (every city without its own)
-- or a participant Key.
function P.SetPlanFor(key)
  m_planFor = key or "ALL"
  P.RefreshLists()
end

-- Replace the edited list with `types`; nil on a city: back to the shared list.
function P.ApplyPlan(types)
  local set = {}
  for _, t in ipairs(types or {}) do set[t] = true end
  if m_planFor == "ALL" then
    m_selected = set
  elseif types == nil then
    m_plans[m_planFor] = nil
  else
    m_plans[m_planFor] = set
  end
  ClearResult()
  P.RefreshLists()
end

function P.SetWonder(wonderType, on)
  if (m_wonders[wonderType] == true) ~= (on == true) then
    m_wonders[wonderType] = on or nil
    ClearResult()
  end
  P.RefreshLists()
end

function P.SetExisting(cityID, on)
  if m_existing[cityID] ~= on then
    m_existing[cityID] = on
    ClearResult()
  end
  P.RefreshLists()
end

function P.SetTier(tier)
  if SDP_Tiers.Multi[tier] == nil then return end
  if m_tier ~= tier then
    m_tier = tier
    ClearResult()
  end
  Controls.MultiTierPull:GetButton():SetText(Locale.Lookup("LOC_SDP_TIER_" .. tier))
  UpdateEstimate()
end

function P.SetLand(on)
  Controls.MultiLandCheck:SetCheck(on)
  if m_land ~= on then
    m_land = on
    ClearResult()
  end
  for _, column in ipairs(SDP_UI.WEIGHT_COLUMNS) do
    if column.Land and m_weightViews[column.Key] then m_weightViews[column.Key]() end
  end
end

function P.SetWeight(key, value)
  value = math.max(0, math.min(SDP_UI.MAX_WEIGHT, value))
  if m_weights[key] ~= value then
    m_weights[key] = value
    ClearResult()
  end
  if m_weightViews[key] then m_weightViews[key]() end
end

-- ===========================================================================
-- Lists
-- ===========================================================================
function P.RefreshLists()
  local playerID = Game.GetLocalPlayer()
  -- Cities.
  m_cityIM:ResetInstances()
  m_view.Cities = {}
  local participants, existing = SDP_Multi.Participants(playerID, { Existing = m_existing })
  local byKey, keyOfCity = {}, {}
  for _, part in ipairs(participants) do
    byKey[part.Key] = part
    if part.CityID ~= nil then keyOfCity[part.CityID] = part.Key end
  end
  if m_planFor ~= "ALL" and byKey[m_planFor] == nil then m_planFor = "ALL" end
  local function OwnPlan(key)
    return (key and m_plans[key] ~= nil) and (" " .. Locale.Lookup("LOC_SDP_MULTI_OWN_PLAN")) or ""
  end
  for _, part in ipairs(participants) do
    if part.Kind == "SITE" then
      local inst = m_cityIM:GetInstance()
      inst.Icon:SetIcon("ICON_DISTRICT_CITY_CENTER", 26)
      inst.Name:SetText(P.CityLabel(part))
      inst.Detail:SetText(Locale.Lookup("LOC_SDP_MULTI_SITE_PIN", SDP_UI.Where(part.X, part.Y)) .. OwnPlan(part.Key))
      inst.Check:SetCheck(true)
      inst.Check:SetDisabled(true)
      m_view.Cities[#m_view.Cities + 1] = { Key = part.Key, Kind = "SITE", Included = true }
    end
  end
  for _, e in ipairs(existing) do
    local inst = m_cityIM:GetInstance()
    local cityID = e.CityID
    inst.Icon:SetIcon("ICON_DISTRICT_CITY_CENTER", 26)
    inst.Name:SetText(Locale.Lookup(e.Name))
    local detail
    if e.Distance == math.huge then
      detail = ""
    else
      detail = Locale.Lookup("LOC_SDP_MULTI_DISTANCE", e.Distance)
    end
    if e.Reason == "CAP" then detail = detail .. " " .. Locale.Lookup("LOC_SDP_MULTI_CAP", SDP_Multi.MAX_CITIES) end
    if not e.On then detail = detail .. " " .. Locale.Lookup("LOC_SDP_MULTI_NEIGHBOUR_ONLY") end
    inst.Detail:SetText(detail .. OwnPlan(keyOfCity[cityID]))
    inst.Check:SetDisabled(false)
    inst.Check:SetCheck(e.On == true)
    inst.Check:RegisterCheckHandler(function() P.SetExisting(cityID, inst.Check:IsChecked()) end)
    m_view.Cities[#m_view.Cities + 1] = { CityID = cityID, Kind = "CITY", On = e.On, Included = e.Included, Reason = e.Reason }
  end
  Controls.MultiCityStack:CalculateSize()
  Controls.MultiCityScroll:CalculateSize()

  -- Plan: whose list, templates, the districts.
  P.PopulatePlanPulls(participants)
  local edited = EditedSet()
  m_districtIM:ResetInstances()
  m_view.Districts = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(playerID)) do
    local inst = m_districtIM:GetInstance()
    local districtType = d.Type
    inst.Icon:SetIcon(d.Icon, 26)
    inst.Name:SetText(Locale.Lookup(d.Name))
    local status = ""
    if d.MaxPerPlayer and d.MaxPerPlayer > 0 then
      -- Where an empire-limited district can go: the cities whose list has it.
      local planners = {}
      for _, part in ipairs(participants) do
        local set = m_plans[part.Key] or m_selected
        if set[districtType] then planners[#planners + 1] = part end
      end
      status = Locale.Lookup("LOC_SDP_MULTI_EMPIRE_LIMIT", d.MaxPerPlayer)
      if #planners == 1 then
        status = status .. " " .. Locale.Lookup("LOC_SDP_MULTI_LIMITED_ONE", P.CityLabel(planners[1]))
      elseif #planners > 1 then
        status = status .. " " .. Locale.Lookup("LOC_SDP_MULTI_LIMITED_AUTO", #planners)
      end
    end
    inst.Status:SetText(status)
    inst.Check:SetDisabled(false)
    inst.Check:SetCheck(edited[districtType] == true)
    inst.Root:SetAlpha(1)
    inst.Check:RegisterCheckHandler(function() P.SetSelected(districtType, inst.Check:IsChecked()) end)
    m_view.Districts[#m_view.Districts + 1] = { Type = districtType, Check = inst.Check, Status = status }
  end
  Controls.MultiDistrictStack:CalculateSize()
  Controls.MultiDistrictScroll:CalculateSize()

  -- Wonders.
  m_wonderIM:ResetInstances()
  m_view.Wonders = {}
  for _, w in ipairs(SDP_Wonders.List(playerID)) do
    local inst = m_wonderIM:GetInstance()
    local wonderType = w.Type
    inst.Icon:SetIcon(w.Icon, 26)
    inst.Name:SetText(Locale.Lookup(w.Name))
    inst.Status:SetText(w.Status and Locale.Lookup("LOC_SDP_WONDER_" .. w.Status) or "")
    inst.Check:SetDisabled(w.Status ~= nil)
    inst.Check:SetCheck(w.Status == nil and m_wonders[wonderType] == true)
    inst.Root:SetAlpha(w.Status and 0.5 or 1)
    inst.Check:RegisterCheckHandler(function() P.SetWonder(wonderType, inst.Check:IsChecked()) end)
    m_view.Wonders[#m_view.Wonders + 1] = { Type = wonderType, Status = w.Status, Check = inst.Check }
  end
  Controls.WonderStack:CalculateSize()
  Controls.WonderScroll:CalculateSize()
  UpdateReplaceLabel()
  m_view.PlanFor = m_planFor
  m_view.Plans = {}
  for key, set in pairs(m_plans) do m_view.Plans[key] = TypesOf(set) end
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
      table.concat(names, Locale.Lookup("LOC_SDP_LIST_SEPARATOR")), t.Districts)
  end
  AddTemplate(Locale.Lookup("LOC_SDP_TEMPLATE_CLEAR"), "", {})
  if m_planFor ~= "ALL" then AddTemplate(Locale.Lookup("LOC_SDP_TEMPLATE_SHARED"), "", nil) end
  templates:CalculateInternals()
  templates:GetButton():SetText(Locale.Lookup("LOC_SDP_TEMPLATE"))
end

function P.Refresh()
  P.RefreshLists()
  m_weightViews = SDP_UI.BuildWeights(m_weightIM, Controls.MultiWeightStack, COLUMNS, m_weights,
    function(column) return column.Land and not m_land end, P.SetWeight, COLUMN_WIDTH)
  SDP_UI.PopulateTierPull(Controls.MultiTierPull, m_tier, P.SetTier)
  Controls.MultiLandCheck:SetCheck(m_land)
  Controls.MultiReplaceCheck:SetCheck(m_replace)
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
  for _, p in ipairs(solution.Plan) do
    icons[#icons + 1] = { X = p.X, Y = p.Y, Icon = "ICON_" .. p.Type, Text = SDP_UI.Signed(p.Score) }
  end
  SDP_Preview.Show(Game.GetLocalPlayer(), areas, icons)
end

function P.SelectSolution(n)
  if m_result == nil or not m_result.Ok or m_result.Solutions[n] == nil then return end
  m_solution = n
  P.Render()
end

-- How a coverage target is called: a participant by its label, another of
-- the player's cities ("C<id>") by its number and name.
local function TargetLabel(key, byKey)
  local city = byKey[key]
  if city ~= nil then return P.CityLabel(city) end
  local id = tonumber(key:match("^C(%d+)$") or "")
  local playerID = Game.GetLocalPlayer()
  local other = id and CityManager.GetCity(playerID, id)
  if other == nil then return key end
  return Locale.Lookup("LOC_SDP_CITY_N", SDP_City.CityNumbers(playerID)[id] or 0, Locale.Lookup(other:GetName()))
end

local function TargetLabels(keys, byKey)
  local names = {}
  for _, key in ipairs(keys) do names[#names + 1] = TargetLabel(key, byKey) end
  return table.concat(names, Locale.Lookup("LOC_SDP_LIST_SEPARATOR"))
end

local function AddRow(icon, name, detail, toolTip)
  local inst = m_resultIM:GetInstance()
  inst.Icon:SetIcon(icon, 32)
  inst.Name:SetText(name)
  inst.Detail:SetText(detail)
  inst.Root:SetToolTipString(toolTip or "")
  m_view.Results[#m_view.Results + 1] = { Icon = icon, Name = name, Detail = detail, ToolTip = toolTip }
end

function P.Render()
  m_solutionIM:ResetInstances()
  m_resultIM:ResetInstances()
  m_view.Solutions, m_view.Results = {}, {}
  Controls.MultiQuality:SetText("")
  local result = m_result
  if result == nil then
    Controls.MultiSummary:SetText(Locale.Lookup("LOC_SDP_MULTI_NONE"))
  elseif not result.Ok then
    local key = "LOC_SDP_RESULT_" .. tostring(result.Error)
    local text = Locale.Lookup(key)
    if text == key then text = Locale.Lookup("LOC_SDP_RESULT_ERROR", tostring(result.Error)) end
    Controls.MultiSummary:SetText(text)
  else
    local solution = result.Solutions[m_solution] or result.Solutions[1]
    local byKey = CityByKey(solution)
    local stats = result.Stats
    local statsText = Locale.Lookup("LOC_SDP_MULTI_STATS", Locale.Lookup("LOC_SDP_TIER_" .. stats.Tier),
      stats.Cities or 0, stats.Calls, stats.Tries, stats.Continues, SDP_UI.Signed(result.FirstGain or 0))
    if solution.Covered ~= nil then
      Controls.MultiSummary:SetText(Locale.Lookup("LOC_SDP_RESULT_SUMMARY_COVERAGE", SDP_UI.Signed(solution.Gain),
        SDP_UI.Signed(solution.Adjacency), SDP_UI.Signed(solution.LandDelta),
        SDP_UI.Signed(solution.CoverageDelta)))
      local lines = {}
      for _, entry in ipairs(solution.CoveredBy) do
        lines[#lines + 1] = Locale.Lookup("LOC_SDP_COVERAGE_GROUP", SDP_UI.TypeName(entry.Group), #entry.Keys,
          TargetLabels(entry.Keys, byKey))
      end
      if #lines == 0 then lines[1] = Locale.Lookup("LOC_SDP_COVERAGE_NOTHING") end
      statsText = table.concat(lines, "[NEWLINE]") .. "[NEWLINE][NEWLINE]" .. statsText
    else
      Controls.MultiSummary:SetText(Locale.Lookup("LOC_SDP_RESULT_SUMMARY_LAND", SDP_UI.Signed(solution.Gain),
        SDP_UI.Signed(solution.Adjacency), SDP_UI.Signed(solution.LandDelta)))
    end
    Controls.MultiSummary:SetToolTipString(statsText)
    Controls.MultiQuality:SetText(SDP_UI.QualityText(result))
    -- Solutions.
    for n, s in ipairs(result.Solutions) do
      local inst = m_solutionIM:GetInstance()
      local wonders = 0
      for _, p in ipairs(s.Plan) do
        if p.Kind == "WONDER" then wonders = wonders + 1 end
      end
      SDP_UI.SolutionRow(inst, Locale.Lookup("LOC_SDP_SOLUTION_N", n, SDP_UI.Signed(s.Gain)),
        Locale.Lookup("LOC_SDP_MULTI_SOLUTION_DETAIL", #s.Cities, #s.Plan - wonders, wonders), n == m_solution)
      inst.Root:RegisterCallback(Mouse.eLClick, function() P.SelectSolution(n) end)
      m_view.Solutions[n] = { Gain = s.Gain, Selected = n == m_solution }
    end
    -- The selected solution, city by city.
    for _, city in ipairs(solution.Cities) do
      AddRow("ICON_DISTRICT_CITY_CENTER", P.CityLabel(city) .. "  " .. SDP_UI.Where(city.X, city.Y),
        Locale.Lookup("LOC_SDP_MULTI_CITY_GAIN", SDP_UI.Signed(city.Gain)), "")
      for _, p in ipairs(solution.Plan) do
        if p.City == city.Key then
          local tip = (p.ToolTip ~= nil and p.ToolTip ~= "") and p.ToolTip or Locale.Lookup("LOC_SDP_NO_ADJACENCY")
          local detail = SDP_UI.YieldText(p.Yields)
          if p.Reach ~= nil then
            detail = detail .. "  " .. Locale.Lookup("LOC_SDP_COVERAGE_ROW", #p.Reach)
            tip = tip .. "[NEWLINE][NEWLINE]" .. Locale.Lookup("LOC_SDP_COVERAGE_TIP", TargetLabels(p.Reach, byKey))
          end
          AddRow("ICON_" .. p.Type, "  " .. SDP_UI.TypeName(p.Type) .. "  " .. SDP_UI.Where(p.X, p.Y), detail, tip)
        end
      end
    end
    for _, u in ipairs(solution.Unplaced) do
      local city = byKey[u.City]
      local where = city and P.CityLabel(city) or Locale.Lookup("LOC_SDP_MULTI_WONDERS")
      AddRow("ICON_" .. u.Type, Locale.Lookup("LOC_SDP_RESULT_UNPLACED", SDP_UI.TypeName(u.Type)) .. "  " .. where,
        Locale.Lookup("LOC_SDP_REASON_" .. u.Reason), "")
    end
    if not Controls.MultiPage:IsHidden() then P.Preview(m_solution) end
  end
  Controls.MultiSolutionStack:CalculateSize()
  Controls.MultiResultStack:CalculateSize()
  Controls.MultiResultScroll:CalculateSize()
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
  local running = SDP_Task.IsRunning()
  local ok = m_result ~= nil and m_result.Ok
  Controls.MultiSolveButton:SetDisabled(running)
  Controls.MultiContinueButton:SetDisabled(running or not ok or not m_result.Quality.CanContinue or m_result.Placed == true)
  Controls.MultiCancelButton:SetHide(not running)
  Controls.MultiPlaceButton:SetDisabled(running or not ok or m_result.Placed == true)
  Controls.MultiUndoButton:SetDisabled(running or not SDP_Pins.CanUndo())
end

-- ===========================================================================
-- Actions
-- ===========================================================================
function P.Solve()
  if SDP_Task.IsRunning() then return false end
  local request = P.Request()
  if request == nil then return false end
  local params = SDP_Tiers.Params(SDP_Tiers.Multi, m_tier)
  m_result, m_solution = nil, 1
  SDP_Preview.Clear()
  local participants = SDP_Multi.Participants(request.PlayerID, { Existing = request.Existing })
  local estimate = SDP_Multi.EstimateUnits(#participants, PlanSize(request, participants), #request.Wonders, params)
  return SDP_UI.StartTask(function() return SDP_Multi.SolveNow(request) end, estimate,
    function(result) m_result, m_solution = result, 1 end, P)
end

function P.Continue()
  if SDP_Task.IsRunning() or m_result == nil or not m_result.Ok or not m_result.Quality.CanContinue then return false end
  local session = m_result.Session
  local estimate = SDP_Multi.EstimateUnits(#session.Participants, PlanSize(session.Request, session.Participants),
    #(session.Request.Wonders or {}), session.Params)
  return SDP_UI.StartTask(function()
    session:Continue()
    return session:Result()
  end, estimate, function(result) m_result = result end, P)
end

function P.Place()
  if SDP_Task.IsRunning() or m_result == nil or not m_result.Ok or m_result.Placed then return 0 end
  local solution = m_result.Solutions[m_solution]
  local byKey = CityByKey(solution)
  local entries = {}
  for _, p in ipairs(solution.Plan) do
    local city = byKey[p.City]
    entries[#entries + 1] = { Type = p.Type, X = p.X, Y = p.Y, Name = city and tostring(city.Number or "") or "" }
  end
  -- The plan was made as if this mod's earlier pins were gone: remove them.
  local placed = SDP_Pins.Place(Game.GetLocalPlayer(), entries,
    { Replace = m_result.Session and m_result.Session.Request.IgnorePins })
  m_result.Placed = true
  SDP_Preview.Clear()
  UpdateReplaceLabel()
  SDP_UI.UpdateAllButtons()
  return placed
end

function P.Undo()
  local last = SDP_Pins.LastBatch()
  local removed = SDP_Pins.UndoLast()
  if last ~= nil and last.Replaced and #last.Replaced > 0 then
    ClearResult() -- the replaced pins are back: plan again
  elseif m_result ~= nil and m_result.Ok then
    m_result.Placed = false
  end
  UpdateReplaceLabel()
  SDP_UI.UpdateAllButtons()
  return removed
end

-- Tests drive the tab through these.
function P.State()
  return {
    Result = m_result, Solution = m_solution, Tier = m_tier, Land = m_land, Replace = m_replace, View = m_view,
    EstimateText = Controls.MultiEstimate:GetText(), QualityText = Controls.MultiQuality:GetText(),
    PlaceDisabled = Controls.MultiPlaceButton:IsDisabled(), ContinueDisabled = Controls.MultiContinueButton:IsDisabled(),
  }
end

Controls.MultiLandCheck:RegisterCheckHandler(function() P.SetLand(Controls.MultiLandCheck:IsChecked()) end)
Controls.MultiReplaceCheck:RegisterCheckHandler(function() P.SetReplace(Controls.MultiReplaceCheck:IsChecked()) end)
Controls.MultiSolveButton:RegisterCallback(Mouse.eLClick, function() P.Solve() end)
Controls.MultiContinueButton:RegisterCallback(Mouse.eLClick, function() P.Continue() end)
Controls.MultiCancelButton:RegisterCallback(Mouse.eLClick, function() SDP_Task.Cancel() end)
Controls.MultiPlaceButton:RegisterCallback(Mouse.eLClick, function() P.Place() end)
Controls.MultiUndoButton:RegisterCallback(Mouse.eLClick, function() P.Undo() end)
