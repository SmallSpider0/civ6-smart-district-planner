-- SDP_PageSites: the "city sites" tab of the planner panel
-- (docs/multicity-design.md section 3, step 1). Included by SDP_Panel.lua
-- into its context: uses its Controls and the SDP_UI helpers.
--   Inputs    number of new cities K, relay distance D, a weight preset and
--             the ten weights, the districts each site is scored with
--   Solve     over several frames (SDP_Task); up to three distinct site
--             combinations; the selected one is previewed; "place" puts a
--             city-center map tack on each site, which step 2 then plans.

SDP_PageSites = {}
local P = SDP_PageSites
P.Name = "SITES"

local m_districtIM = InstanceManager:new("DistrictRow", "Root", Controls.SitesDistrictStack)
local m_weightIM = InstanceManager:new("WeightColumn", "Root", Controls.SitesWeightStack)
local m_weightIM2 = InstanceManager:new("WeightColumn", "Root", Controls.SitesWeightStack2)
local m_solutionIM = InstanceManager:new("SolutionRow", "Root", Controls.SitesSolutionStack)
local m_resultIM = InstanceManager:new("ResultRow", "Root", Controls.SitesResultStack)

-- The ten site weights in two rows (design 3.3).
local COLUMNS_A = {
  { Key = "YIELD_SCIENCE", Icon = "ICON_ENVOY_BONUS_SCIENCE" },
  { Key = "YIELD_CULTURE", Icon = "ICON_ENVOY_BONUS_CULTURE" },
  { Key = "YIELD_FAITH", Icon = "ICON_ENVOY_BONUS_FAITH" },
  { Key = "YIELD_GOLD", Icon = "ICON_ENVOY_BONUS_GOLD" },
  { Key = "YIELD_PRODUCTION", Icon = "ICON_ENVOY_BONUS_PRODUCTION" },
}
local COLUMNS_B = {
  { Key = "YIELD_FOOD", Glyph = "[ICON_Food]" },
  { Key = "AMENITY", Glyph = "[ICON_Amenities]", ToolTip = "LOC_SDP_WEIGHT_AMENITY" },
  { Key = "STRATEGIC", Glyph = "LOC_SDP_WEIGHT_STRATEGIC_SHORT", ToolTip = "LOC_SDP_WEIGHT_STRATEGIC" },
  { Key = "FEATURE", Glyph = "LOC_SDP_WEIGHT_FEATURE_SHORT", ToolTip = "LOC_SDP_WEIGHT_FEATURE" },
  { Key = "APPEAL", Glyph = "LOC_SDP_WEIGHT_APPEAL_SHORT", ToolTip = "LOC_SDP_WEIGHT_APPEAL" },
}

local m_k, m_d = 3, 8
local MIN_D, MAX_D = 4, 15
local m_preset = "BALANCED"
local m_weights = {}
for key, value in pairs(SDP_Sites.PRESETS.BALANCED) do m_weights[key] = value end
local m_views = {}
local m_selected = {}
local m_tier = SDP_Tiers.DEFAULT
local m_result = nil
local m_solution = 1
local m_view = { Districts = {}, Solutions = {}, Results = {} }

local function ClearResult()
  local job = SDP_Task.Current()
  if job ~= nil and job.Page == P.Name then SDP_Task.Cancel() end
  if m_result ~= nil then
    m_result = nil
    SDP_Preview.Clear()
    P.Render()
  end
end

local function Plan()
  local list = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(Game.GetLocalPlayer())) do
    if m_selected[d.Type] then list[#list + 1] = d.Type end
  end
  return list
end

function P.Request()
  local weights = {}
  for key, value in pairs(m_weights) do weights[key] = value end
  return { PlayerID = Game.GetLocalPlayer(), Tier = m_tier, K = m_k, D = m_d, Districts = Plan(), Weights = weights }
end

local function UpdateEstimate()
  local params = SDP_Tiers.Params(SDP_Tiers.Sites, m_tier)
  Controls.SitesEstimate:SetText(SDP_UI.EstimateText(SDP_SiteSolver.EstimateUnits(#Plan(), m_k, params)))
end

local function ShowSteppers()
  Controls.SitesCount:SetText(tostring(m_k))
  Controls.SitesDistance:SetText(tostring(m_d))
  Controls.SitesCountLess:SetDisabled(m_k <= 1)
  Controls.SitesCountMore:SetDisabled(m_k >= SDP_SiteSolver.MAX_K)
  Controls.SitesDistanceLess:SetDisabled(m_d <= MIN_D)
  Controls.SitesDistanceMore:SetDisabled(m_d >= MAX_D)
end

function P.SetCount(k)
  k = math.max(1, math.min(SDP_SiteSolver.MAX_K, k))
  if k ~= m_k then
    m_k = k
    ClearResult()
  end
  ShowSteppers()
  UpdateEstimate()
end

function P.SetDistance(d)
  d = math.max(MIN_D, math.min(MAX_D, d))
  if d ~= m_d then
    m_d = d
    ClearResult()
  end
  ShowSteppers()
end

function P.SetWeight(key, value)
  value = math.max(0, math.min(SDP_UI.MAX_WEIGHT, value))
  if m_weights[key] ~= value then
    m_weights[key] = value
    ClearResult()
  end
  if m_views[key] then m_views[key]() end
end

function P.SetPreset(name)
  local preset = SDP_Sites.PRESETS[name]
  if preset == nil then return end
  m_preset = name
  for _, key in ipairs(SDP_Sites.WEIGHT_KEYS) do P.SetWeight(key, preset[key]) end
  Controls.SitesPresetPull:GetButton():SetText(Locale.Lookup("LOC_SDP_PRESET_" .. name))
end

function P.SetSelected(districtType, on)
  if (m_selected[districtType] == true) ~= (on == true) then
    m_selected[districtType] = on or nil
    ClearResult()
  end
  for _, row in ipairs(m_view.Districts) do
    if row.Type == districtType and row.Check:IsChecked() ~= (on == true) then row.Check:SetCheck(on == true) end
  end
  UpdateEstimate()
end

function P.SetTier(tier)
  if SDP_Tiers.Sites[tier] == nil then return end
  if m_tier ~= tier then
    m_tier = tier
    ClearResult()
  end
  Controls.SitesTierPull:GetButton():SetText(Locale.Lookup("LOC_SDP_TIER_" .. tier))
  UpdateEstimate()
end

function P.Refresh()
  ShowSteppers()
  local pull = Controls.SitesPresetPull
  pull:ClearEntries()
  for _, name in ipairs(SDP_Sites.PRESET_ORDER) do
    local entry = {}
    pull:BuildEntry("InstanceOne", entry)
    entry.Button:SetText(Locale.Lookup("LOC_SDP_PRESET_" .. name))
    entry.Button:RegisterCallback(Mouse.eLClick, function() P.SetPreset(name) end)
  end
  pull:CalculateInternals()
  pull:GetButton():SetText(Locale.Lookup("LOC_SDP_PRESET_" .. m_preset))
  local a = SDP_UI.BuildWeights(m_weightIM, Controls.SitesWeightStack, COLUMNS_A, m_weights, nil, P.SetWeight)
  local b = SDP_UI.BuildWeights(m_weightIM2, Controls.SitesWeightStack2, COLUMNS_B, m_weights, nil, P.SetWeight)
  m_views = {}
  for key, view in pairs(a) do m_views[key] = view end
  for key, view in pairs(b) do m_views[key] = view end
  -- Districts the sites are scored with (an empire-limited one would count once per site).
  m_districtIM:ResetInstances()
  m_view.Districts = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(Game.GetLocalPlayer())) do
    local inst = m_districtIM:GetInstance()
    local districtType = d.Type
    local limited = d.MaxPerPlayer and d.MaxPerPlayer > 0
    inst.Icon:SetIcon(d.Icon, 32)
    inst.Name:SetText(Locale.Lookup(d.Name))
    inst.Status:SetText(limited and Locale.Lookup("LOC_SDP_SITES_NOT_PER_SITE") or "")
    inst.Check:SetDisabled(limited)
    inst.Check:SetCheck(not limited and m_selected[districtType] == true)
    inst.Root:SetAlpha(limited and 0.5 or 1)
    inst.Check:RegisterCheckHandler(function() P.SetSelected(districtType, inst.Check:IsChecked()) end)
    m_view.Districts[#m_view.Districts + 1] = { Type = districtType, Check = inst.Check }
  end
  Controls.SitesDistrictStack:CalculateSize()
  Controls.SitesDistrictScroll:CalculateSize()
  SDP_UI.PopulateTierPull(Controls.SitesTierPull, m_tier, P.SetTier)
  UpdateEstimate()
  P.Render()
end

-- ===========================================================================
-- Results
-- ===========================================================================
local function SiteDetail(site)
  local parts = site.Parts
  return Locale.Lookup("LOC_SDP_SITES_PARTS", SDP_UI.Number(parts.District or 0), SDP_UI.Number(site.Land or 0),
    SDP_UI.Number(parts.Water), SDP_UI.Number(parts.Luxury), SDP_UI.Number(parts.Strategic))
end

-- Risk notes and the planned districts, for a site's tooltip (design 3.3).
local function SiteToolTip(site)
  local lines = {}
  local info = site.Info
  lines[#lines + 1] = Locale.Lookup("LOC_SDP_SITES_WATER_" .. info.WaterKind)
  lines[#lines + 1] = Locale.Lookup("LOC_SDP_SITES_OWN_DISTANCE", info.OwnDistance)
  if info.Unrevealed > 0 then lines[#lines + 1] = Locale.Lookup("LOC_SDP_SITES_UNREVEALED", info.Unrevealed) end
  if info.Loyalty ~= nil and info.Loyalty ~= "LOW" then lines[#lines + 1] = Locale.Lookup("LOC_SDP_SITES_LOYALTY_" .. info.Loyalty) end
  if info.Disaster then lines[#lines + 1] = Locale.Lookup("LOC_SDP_SITES_DISASTER") end
  if info.UnknownStrategic then lines[#lines + 1] = Locale.Lookup("LOC_SDP_SITES_UNKNOWN_STRATEGIC") end
  local features = {}
  for featureType, count in pairs(info.Features or {}) do
    features[#features + 1] = SDP_UI.TypeName(featureType) .. " " .. count
  end
  table.sort(features)
  if #features > 0 then lines[#lines + 1] = Locale.Lookup("LOC_SDP_SITES_FEATURES", table.concat(features, ", ")) end
  local districts = {}
  for _, d in ipairs(site.Districts or {}) do districts[#districts + 1] = SDP_UI.TypeName(d.Type) .. " " .. SDP_UI.Where(d.X, d.Y) end
  if #districts > 0 then lines[#lines + 1] = Locale.Lookup("LOC_SDP_SITES_DISTRICTS", table.concat(districts, ", ")) end
  return table.concat(lines, "[NEWLINE]")
end

function P.Preview(n)
  local solution = m_result and m_result.Ok and m_result.Solutions[n]
  if solution == nil then
    SDP_Preview.Clear()
    return
  end
  local areas, icons = {}, {}
  for s, site in ipairs(solution.Sites) do
    local plots = {}
    for _, entry in ipairs(SDP_City.PlotsInRange(site.X, site.Y, SDP_City.RADIUS)) do plots[#plots + 1] = entry.Index end
    areas[#areas + 1] = { Plots = plots, Color = s }
    icons[#icons + 1] = { X = site.X, Y = site.Y, Icon = "ICON_DISTRICT_CITY_CENTER",
      Text = Locale.Lookup("LOC_SDP_SITE_N", s) .. " " .. SDP_UI.Number(math.floor(site.Value * 10 + 0.5) / 10) }
    for _, d in ipairs(site.Districts or {}) do icons[#icons + 1] = { X = d.X, Y = d.Y, Icon = "ICON_" .. d.Type } end
  end
  SDP_Preview.Show(Game.GetLocalPlayer(), areas, icons)
  SDP_Preview.Focus(solution.Sites[1].X, solution.Sites[1].Y)
end

function P.SelectSolution(n)
  if m_result == nil or not m_result.Ok or m_result.Solutions[n] == nil then return end
  m_solution = n
  P.Render()
end

function P.Render()
  m_solutionIM:ResetInstances()
  m_resultIM:ResetInstances()
  m_view.Solutions, m_view.Results = {}, {}
  Controls.SitesQuality:SetText("")
  local result = m_result
  if result == nil then
    Controls.SitesSummary:SetText(Locale.Lookup("LOC_SDP_SITES_NONE"))
  elseif not result.Ok then
    local key = "LOC_SDP_RESULT_" .. tostring(result.Error)
    local text = Locale.Lookup(key)
    if text == key then text = Locale.Lookup("LOC_SDP_RESULT_ERROR", tostring(result.Error)) end
    Controls.SitesSummary:SetText(text)
  else
    local solution = result.Solutions[m_solution] or result.Solutions[1]
    Controls.SitesSummary:SetText(Locale.Lookup("LOC_SDP_SITES_SUMMARY", SDP_UI.Number(math.floor(solution.Value * 10 + 0.5) / 10),
      result.Stats.Candidates, result.Stats.Refined))
    Controls.SitesQuality:SetText(SDP_UI.QualityText(result) .. Locale.Lookup("LOC_SDP_LIST_SEPARATOR")
      .. Locale.Lookup("LOC_SDP_SITES_MODEL_NOTE"))
    for n, s in ipairs(result.Solutions) do
      local inst = m_solutionIM:GetInstance()
      local where = {}
      for _, site in ipairs(s.Sites) do where[#where + 1] = SDP_UI.Where(site.X, site.Y) end
      SDP_UI.SolutionRow(inst, Locale.Lookup("LOC_SDP_SOLUTION_N", n, SDP_UI.Number(math.floor(s.Value * 10 + 0.5) / 10)),
        table.concat(where, " "), n == m_solution)
      inst.Root:RegisterCallback(Mouse.eLClick, function() P.SelectSolution(n) end)
      m_view.Solutions[n] = { Value = s.Value, Selected = n == m_solution }
    end
    for s, site in ipairs(solution.Sites) do
      local inst = m_resultIM:GetInstance()
      local name = Locale.Lookup("LOC_SDP_SITE_N", s) .. "  " .. SDP_UI.Where(site.X, site.Y) .. "  "
        .. SDP_UI.Number(math.floor(site.Value * 10 + 0.5) / 10)
      local detail = SiteDetail(site)
      local tip = SiteToolTip(site)
      inst.Icon:SetIcon("ICON_DISTRICT_CITY_CENTER", 32)
      inst.Name:SetText(name)
      inst.Detail:SetText(detail)
      inst.Root:SetToolTipString(tip)
      m_view.Results[#m_view.Results + 1] = { Name = name, Detail = detail, ToolTip = tip }
    end
    if not Controls.SitesPage:IsHidden() then P.Preview(m_solution) end
  end
  Controls.SitesSolutionStack:CalculateSize()
  Controls.SitesResultStack:CalculateSize()
  Controls.SitesResultScroll:CalculateSize()
  P.UpdateButtons()
end

function P.ShowProgress(text)
  Controls.SitesSummary:SetText(text)
  Controls.SitesQuality:SetText("")
end

function P.OnError(message)
  m_result = { Ok = false, Error = message }
end

function P.UpdateButtons()
  local running = SDP_Task.IsRunning()
  local ok = m_result ~= nil and m_result.Ok
  Controls.SitesSolveButton:SetDisabled(running)
  Controls.SitesContinueButton:SetDisabled(running or not ok or not m_result.Quality.CanContinue or m_result.Placed == true)
  Controls.SitesCancelButton:SetHide(not running)
  Controls.SitesPlaceButton:SetDisabled(running or not ok or m_result.Placed == true)
  Controls.SitesUndoButton:SetDisabled(running or not SDP_Pins.CanUndo())
end

-- ===========================================================================
-- Actions
-- ===========================================================================
function P.Solve()
  if SDP_Task.IsRunning() then return false end
  local request = P.Request()
  local params = SDP_Tiers.Params(SDP_Tiers.Sites, m_tier)
  m_result, m_solution = nil, 1
  SDP_Preview.Clear()
  return SDP_UI.StartTask(function() return SDP_SiteSolver.SolveNow(request) end,
    SDP_SiteSolver.EstimateUnits(#request.Districts, request.K, params),
    function(result) m_result, m_solution = result, 1 end, P)
end

function P.Continue()
  if SDP_Task.IsRunning() or m_result == nil or not m_result.Ok or not m_result.Quality.CanContinue then return false end
  local session = m_result.Session
  return SDP_UI.StartTask(function()
    session:Continue()
    return session:Result()
  end, SDP_SiteSolver.EstimateUnits(#session.Ctx.Plan, session.K, session.Params, true),
    function(result) m_result = result end, P)
end

-- A city-center map tack on every site of the selected solution, named
-- "Site n": step 2 (the several-cities tab) plans them.
function P.Place()
  if SDP_Task.IsRunning() or m_result == nil or not m_result.Ok or m_result.Placed then return 0 end
  local solution = m_result.Solutions[m_solution]
  local entries = {}
  for s, site in ipairs(solution.Sites) do
    entries[s] = { Type = "DISTRICT_CITY_CENTER", X = site.X, Y = site.Y, Name = Locale.Lookup("LOC_SDP_SITE_N", s) }
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

function P.State()
  return {
    Result = m_result, Solution = m_solution, K = m_k, D = m_d, Tier = m_tier, Weights = m_weights, View = m_view,
    EstimateText = Controls.SitesEstimate:GetText(), PlaceDisabled = Controls.SitesPlaceButton:IsDisabled(),
  }
end

Controls.SitesCountLess:RegisterCallback(Mouse.eLClick, function() P.SetCount(m_k - 1) end)
Controls.SitesCountMore:RegisterCallback(Mouse.eLClick, function() P.SetCount(m_k + 1) end)
Controls.SitesDistanceLess:RegisterCallback(Mouse.eLClick, function() P.SetDistance(m_d - 1) end)
Controls.SitesDistanceMore:RegisterCallback(Mouse.eLClick, function() P.SetDistance(m_d + 1) end)
Controls.SitesSolveButton:RegisterCallback(Mouse.eLClick, function() P.Solve() end)
Controls.SitesContinueButton:RegisterCallback(Mouse.eLClick, function() P.Continue() end)
Controls.SitesCancelButton:RegisterCallback(Mouse.eLClick, function() SDP_Task.Cancel() end)
Controls.SitesPlaceButton:RegisterCallback(Mouse.eLClick, function() P.Place() end)
Controls.SitesUndoButton:RegisterCallback(Mouse.eLClick, function() P.Undo() end)
