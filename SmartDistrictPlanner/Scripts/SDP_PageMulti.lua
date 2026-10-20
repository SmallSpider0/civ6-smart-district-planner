-- SDP_PageMulti: the "several cities" tab of the planner panel
-- (docs/multicity-design.md section 4, step 2). Included by SDP_Panel.lua
-- into its context: uses its Controls and the SDP_UI helpers.
--   Cities    new cities (city-center pins) and the existing cities near them,
--             which can be switched; the plan and the wonders to place
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

local m_selected = {}  -- [DistrictType] = true: the plan
local m_wonders = {}   -- [BuildingType] = true
local m_existing = {}  -- [cityID] = true | false: switches over the default
local m_weights = {}
for _, column in ipairs(SDP_UI.WEIGHT_COLUMNS) do m_weights[column.Key] = 1 end
local m_weightViews = {}
local m_tier = SDP_Tiers.DEFAULT
local m_land = true
local m_result = nil
local m_solution = 1
local m_view = { Cities = {}, Districts = {}, Wonders = {}, Solutions = {}, Results = {} } -- for tests

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
local function PlannedTypes()
  local list = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(Game.GetLocalPlayer())) do
    if m_selected[d.Type] then list[#list + 1] = d.Type end
  end
  return list
end

local function WonderTypes()
  local list = {}
  for _, w in ipairs(SDP_Wonders.List(Game.GetLocalPlayer())) do
    if m_wonders[w.Type] and w.Status == nil then list[#list + 1] = w.Type end
  end
  return list
end

function P.Request()
  local districts = PlannedTypes()
  if #districts == 0 and #WonderTypes() == 0 then return nil end
  local weights, existing = {}, {}
  for key, value in pairs(m_weights) do weights[key] = value end
  for id, on in pairs(m_existing) do existing[id] = on end
  return {
    PlayerID = Game.GetLocalPlayer(), Tier = m_tier, Districts = districts, Wonders = WonderTypes(),
    Existing = existing, Weights = weights, Land = m_land,
  }
end

local function UpdateEstimate()
  local request = P.Request()
  if request == nil then
    Controls.MultiEstimate:SetText("")
    return
  end
  local participants = SDP_Multi.Participants(request.PlayerID, { Existing = request.Existing })
  local units = SDP_Multi.EstimateUnits(#participants, #request.Districts, #request.Wonders,
    SDP_Tiers.Params(SDP_Tiers.Multi, m_tier))
  Controls.MultiEstimate:SetText(SDP_UI.EstimateText(units))
end

function P.SetSelected(districtType, on)
  if (m_selected[districtType] == true) ~= (on == true) then
    m_selected[districtType] = on or nil
    ClearResult()
  end
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
  for _, part in ipairs(participants) do
    if part.Kind == "SITE" then
      local inst = m_cityIM:GetInstance()
      inst.Icon:SetIcon("ICON_DISTRICT_CITY_CENTER", 26)
      inst.Name:SetText(P.CityLabel(part))
      inst.Detail:SetText(Locale.Lookup("LOC_SDP_MULTI_SITE_PIN", SDP_UI.Where(part.X, part.Y)))
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
    inst.Detail:SetText(detail)
    inst.Check:SetDisabled(false)
    inst.Check:SetCheck(e.On == true)
    inst.Check:RegisterCheckHandler(function() P.SetExisting(cityID, inst.Check:IsChecked()) end)
    m_view.Cities[#m_view.Cities + 1] = { CityID = cityID, Kind = "CITY", On = e.On, Included = e.Included, Reason = e.Reason }
  end
  Controls.MultiCityStack:CalculateSize()
  Controls.MultiCityScroll:CalculateSize()

  -- Plan.
  m_districtIM:ResetInstances()
  m_view.Districts = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(playerID)) do
    local inst = m_districtIM:GetInstance()
    local districtType = d.Type
    inst.Icon:SetIcon(d.Icon, 26)
    inst.Name:SetText(Locale.Lookup(d.Name))
    inst.Status:SetText((d.MaxPerPlayer and d.MaxPerPlayer > 0) and Locale.Lookup("LOC_SDP_MULTI_EMPIRE_LIMIT", d.MaxPerPlayer) or "")
    inst.Check:SetDisabled(false)
    inst.Check:SetCheck(m_selected[districtType] == true)
    inst.Root:SetAlpha(1)
    inst.Check:RegisterCheckHandler(function() P.SetSelected(districtType, inst.Check:IsChecked()) end)
    m_view.Districts[#m_view.Districts + 1] = { Type = districtType, Check = inst.Check }
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
  UpdateEstimate()
end

function P.Refresh()
  P.RefreshLists()
  m_weightViews = SDP_UI.BuildWeights(m_weightIM, Controls.MultiWeightStack, SDP_UI.WEIGHT_COLUMNS, m_weights,
    function(column) return column.Land and not m_land end, P.SetWeight)
  SDP_UI.PopulateTierPull(Controls.MultiTierPull, m_tier, P.SetTier)
  Controls.MultiLandCheck:SetCheck(m_land)
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
    Controls.MultiSummary:SetText(Locale.Lookup("LOC_SDP_RESULT_SUMMARY_LAND", SDP_UI.Signed(solution.Gain),
      SDP_UI.Signed(solution.Adjacency), SDP_UI.Signed(solution.LandDelta)))
    local stats = result.Stats
    Controls.MultiSummary:SetToolTipString(Locale.Lookup("LOC_SDP_MULTI_STATS", Locale.Lookup("LOC_SDP_TIER_" .. stats.Tier),
      stats.Cities or 0, stats.Calls, stats.Tries, stats.Continues, SDP_UI.Signed(result.FirstGain or 0)))
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
    local byKey = CityByKey(solution)
    for _, city in ipairs(solution.Cities) do
      AddRow("ICON_DISTRICT_CITY_CENTER", P.CityLabel(city) .. "  " .. SDP_UI.Where(city.X, city.Y),
        Locale.Lookup("LOC_SDP_MULTI_CITY_GAIN", SDP_UI.Signed(city.Gain)), "")
      for _, p in ipairs(solution.Plan) do
        if p.City == city.Key then
          local tip = (p.ToolTip ~= nil and p.ToolTip ~= "") and p.ToolTip or Locale.Lookup("LOC_SDP_NO_ADJACENCY")
          AddRow("ICON_" .. p.Type, "  " .. SDP_UI.TypeName(p.Type) .. "  " .. SDP_UI.Where(p.X, p.Y), SDP_UI.YieldText(p.Yields), tip)
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
  local estimate = SDP_Multi.EstimateUnits(#participants, #request.Districts, #request.Wonders, params)
  return SDP_UI.StartTask(function() return SDP_Multi.SolveNow(request) end, estimate,
    function(result) m_result, m_solution = result, 1 end, P)
end

function P.Continue()
  if SDP_Task.IsRunning() or m_result == nil or not m_result.Ok or not m_result.Quality.CanContinue then return false end
  local session = m_result.Session
  local estimate = SDP_Multi.EstimateUnits(#session.Participants, #(session.Request.Districts or {}),
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
  local placed = SDP_Pins.Place(Game.GetLocalPlayer(), entries)
  m_result.Placed = true
  SDP_Preview.Clear()
  SDP_UI.UpdateAllButtons()
  return placed
end

function P.Undo()
  local removed = SDP_Pins.UndoLast()
  if m_result ~= nil and m_result.Ok then m_result.Placed = false end
  SDP_UI.UpdateAllButtons()
  return removed
end

-- Tests drive the tab through these.
function P.State()
  return {
    Result = m_result, Solution = m_solution, Tier = m_tier, Land = m_land, View = m_view,
    EstimateText = Controls.MultiEstimate:GetText(), QualityText = Controls.MultiQuality:GetText(),
    PlaceDisabled = Controls.MultiPlaceButton:IsDisabled(), ContinueDisabled = Controls.MultiContinueButton:IsDisabled(),
  }
end

Controls.MultiLandCheck:RegisterCheckHandler(function() P.SetLand(Controls.MultiLandCheck:IsChecked()) end)
Controls.MultiSolveButton:RegisterCallback(Mouse.eLClick, function() P.Solve() end)
Controls.MultiContinueButton:RegisterCallback(Mouse.eLClick, function() P.Continue() end)
Controls.MultiCancelButton:RegisterCallback(Mouse.eLClick, function() SDP_Task.Cancel() end)
Controls.MultiPlaceButton:RegisterCallback(Mouse.eLClick, function() P.Place() end)
Controls.MultiUndoButton:RegisterCallback(Mouse.eLClick, function() P.Undo() end)
