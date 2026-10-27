-- SDP_PageSites: the "city sites" tab of the planner panel
-- (docs/multicity-design.md section 3, step 1). Included by SDP_Panel.lua
-- into its context: uses its Controls and the SDP_UI helpers.
--   Inputs    number of new cities K, relay distance D, a weight preset and
--             the thirteen weights plus the distance cost, the districts each site
--             is scored with: the single-city tab's grid (required, candidates,
--             not wanted) and count, the tab's own (issue 90; SDP_Sites.DefaultState)
--   Solve     over several frames (SDP_Task); up to three distinct site
--             combinations; the selected one is previewed; "place" puts a
--             city-center map tack on each site, which step 2 then plans.

SDP_PageSites = {}
local P = SDP_PageSites
P.Name = "SITES"

local m_cellIM = InstanceManager:new("DistrictCell", "Root", Controls.SitesDistrictStack)
local m_utilityIM = InstanceManager:new("DistrictCell", "Root", Controls.SitesUtilityStack)
local m_weightIM = InstanceManager:new("WeightColumn", "Root", Controls.SitesWeightStack)
local m_weightIM2 = InstanceManager:new("WeightColumn", "Root", Controls.SitesWeightStack2)
local m_solutionIM = InstanceManager:new("SolutionRow", "Root", Controls.SitesSolutionStack)
local m_resultIM = InstanceManager:new("ResultRow", "Root", Controls.SitesResultStack)

-- The site weights (design 3.3, issue 88) and the distance cost, in two
-- rows: the six yields with the game's font icons and the distance cost,
-- then one weight per part of a site's score, with a short word (feedback
-- item 3, as on the single-city tab). Seven columns a row, narrower than the
-- default so they fit beside the row's title.
local COLUMNS_A = {
  { Key = "YIELD_SCIENCE", Glyph = "[ICON_Science]" },
  { Key = "YIELD_CULTURE", Glyph = "[ICON_Culture]" },
  { Key = "YIELD_FAITH", Glyph = "[ICON_Faith]" },
  { Key = "YIELD_GOLD", Glyph = "[ICON_Gold]" },
  { Key = "YIELD_PRODUCTION", Glyph = "[ICON_Production]" },
  { Key = "YIELD_FOOD", Glyph = "[ICON_Food]" },
  { Key = "DISTANCE", Glyph = "LOC_SDP_WEIGHT_DISTANCE_SHORT", ToolTip = "LOC_SDP_WEIGHT_DISTANCE", Step = 0.5,
    Default = SDP_Sites.DEFAULT_DISTANCE },
}
-- The parts of a site's score (issue 88): their weight, the part in
-- site.Parts, the short word of the column and the result row, the
-- tooltip line with its per-turn value.
local ITEMS = {
  { Key = "DISTRICT", Part = "District", Short = "LOC_SDP_SITES_W_DISTRICT_SHORT" },
  { Key = "LAND", Part = "Farm", Short = "LOC_SDP_WEIGHT_LAND_SHORT" },
  { Key = "FEATURE", Part = "Feature", Short = "LOC_SDP_SITES_W_FEATURE_SHORT" },
  { Key = "HOUSING", Part = "Water", Short = "LOC_SDP_WEIGHT_HOUSING_SHORT" },
  { Key = "AMENITY", Part = "Luxury", Short = "LOC_SDP_SITES_W_AMENITY_SHORT" },
  { Key = "STRATEGIC", Part = "Strategic", Short = "LOC_SDP_WEIGHT_STRATEGIC_SHORT" },
  { Key = "APPEAL", Part = "Appeal", Short = "LOC_SDP_WEIGHT_APPEAL_SHORT" },
}
local COLUMNS_B = {}
for _, item in ipairs(ITEMS) do
  COLUMNS_B[#COLUMNS_B + 1] = { Key = item.Key, Glyph = item.Short, ToolTip = "LOC_SDP_SITES_W_" .. item.Key }
end
local WEIGHT_WIDTH = 50

-- Default distance 5 (issue 84, the maintainer's choice): sites land at the
-- full distance (nothing in the score pulls them closer), and players space
-- cities 4-6 apart.
local DEFAULT_K, DEFAULT_D = 3, 5
local m_k, m_d = DEFAULT_K, DEFAULT_D
local MIN_D, MAX_D = 4, 15
-- The districts each site is scored with (issue 90): states as on the
-- single-city tab, MUST / POOL / OFF, only the ones the player chose (the
-- rest at SDP_Sites.DefaultState), and how many that take population.
local m_states = {}
local m_count = SDP_Sites.DEFAULT_COUNT
local m_preset = "BALANCED"
local m_weights = { DISTANCE = SDP_Sites.DEFAULT_DISTANCE }
for key, value in pairs(SDP_Sites.PRESETS.BALANCED) do m_weights[key] = value end
local m_views = {}
local m_tier = SDP_Tiers.DEFAULT
local m_result = nil
local m_solution = 1
local m_view = { Districts = {}, Solutions = {}, Results = {} }
local m_lookNext = false -- move the camera to the first site when the next result shows (issue 67)
local m_site = 1 -- the site of the solution the camera was last moved to (issue 75)

-- The preset, the weights and the tier, kept in the save (issue 57); the
-- number of new cities and the distance too (issue 84); the district states
-- ("DISTRICT_CAMPUS:M,DISTRICT_PRESERVE:P", only the chosen ones) and the
-- district count (issue 90).
local STATE_CODE = { MUST = "M", POOL = "P", OFF = "O" }
local CODE_STATE = { M = "MUST", P = "POOL", O = "OFF" }
local function KeptStates()
  local items = {}
  for districtType, state in pairs(m_states) do items[#items + 1] = districtType .. ":" .. STATE_CODE[state] end
  return SDP_Settings.List(table.concat(items, ","), "^[%w_]+:[MPO]$")
end
local function PutStates(text)
  m_states = {}
  local known = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(Game.GetLocalPlayer())) do known[d.Type] = true end
  for districtType, code in tostring(text):gmatch("([%w_]+):([MPO])") do
    if known[districtType] then m_states[districtType] = CODE_STATE[code] end
  end
end
local ALL_COLUMNS = {}
for _, column in ipairs(COLUMNS_A) do ALL_COLUMNS[#ALL_COLUMNS + 1] = column end
for _, column in ipairs(COLUMNS_B) do ALL_COLUMNS[#ALL_COLUMNS + 1] = column end
local m_fold = false -- the preset and weights folded into one line (issue 71)
local m_keeper = SDP_UI.Keeper({ Tab = "SITES", Columns = ALL_COLUMNS, Weights = m_weights, Tiers = SDP_Tiers.Sites,
  Extra = { { Key = "FOLD", Default = false, Get = function() return m_fold end, Put = function(v) m_fold = v end },
    { Key = "K", Kind = "number", Min = 1, Max = SDP_SiteSolver.MAX_K, Default = DEFAULT_K,
      Get = function() return m_k end, Put = function(v) m_k = math.floor(v) end },
    { Key = "D", Kind = "number", Min = MIN_D, Max = MAX_D, Default = DEFAULT_D,
      Get = function() return m_d end, Put = function(v) m_d = math.floor(v) end },
    { Key = "COUNT", Kind = "number", Min = 0, Max = SDP_Sites.MAX_COUNT, Default = SDP_Sites.DEFAULT_COUNT,
      Get = function() return m_count end, Put = function(v) m_count = math.floor(v) end },
    { Key = "DISTRICTS", Kind = "list", Pattern = "^[%w_]+:[MPO]$", Default = "", Get = KeptStates, Put = PutStates } },
  GetTier = function() return m_tier end, PutTier = function(tier) m_tier = tier end,
  Presets = SDP_Sites.PRESETS, Order = SDP_Sites.PRESET_ORDER })

-- The fold line (issue 71) and the pulldown: the preset the weights equal,
-- "Custom" when none (issue 89).
local function UpdateFold()
  local shown = m_keeper.Match(m_preset)
  SDP_UI.ShowFold(Controls.SitesFoldButton, Controls.SitesFoldText, Controls.SitesFoldAction, Controls.SitesSettingsStack,
    m_fold, SDP_UI.FoldSummary(shown, {}))
  SDP_UI.ShowPreset(Controls.SitesPresetPull, shown, function(name) P.SetPreset(name) end,
    { Order = SDP_Sites.PRESET_ORDER, CustomTip = "LOC_SDP_SITES_PRESET_CUSTOM_TOOLTIP" })
end

function P.FitPage() SDP_UI.FitResults(Controls.SitesBody, Controls.SitesPage, Controls.SitesResultScroll) end

-- Weights equal to another preset make it the current one (issue 89).
local function Remember()
  m_preset = m_keeper.Match(m_preset) or m_preset
  m_keeper.Remember(m_preset)
  UpdateFold()
end

function P.SetFold(on)
  if m_fold ~= on then
    m_fold = on
    Remember()
  end
  UpdateFold()
  P.FitPage()
end
function P.Restore()
  local kept = m_keeper.Restore()
  if kept ~= nil then m_preset = m_keeper.Match(kept.Preset) or kept.Preset end
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

local function Districts() return SDP_Rules.PlannableDistricts(Game.GetLocalPlayer()) end

-- The state a district starts in on this tab (SDP_Sites.DefaultState).
function P.DefaultState(d)
  return SDP_Sites.DefaultState(d, SDP_Rules.Functional(Game.GetLocalPlayer()))
end

-- Why a district cannot be chosen here: one per empire would count once per site.
local function StatusOf(d)
  if d.MaxPerPlayer and d.MaxPerPlayer > 0 then return "NOT_PER_SITE" end
  return nil
end

-- Every district's state: the chosen one, else the default.
local function States()
  local functional, states = SDP_Rules.Functional(Game.GetLocalPlayer()), {}
  for _, d in ipairs(Districts()) do states[d.Type] = m_states[d.Type] or SDP_Sites.DefaultState(d, functional) end
  return states
end

-- What the grid asks for (SDP_UI.ListRequest): Must, Pool, Count, Pick.
local function List(count)
  local districts, status = Districts(), {}
  for _, d in ipairs(districts) do status[d.Type] = StatusOf(d) end
  return SDP_UI.ListRequest(districts, States(), math.min(count or m_count, SDP_Sites.MAX_COUNT), status)
end

-- A click: as on the single-city tab, except that the districts without
-- population have no automatic state here (a site is not a city yet): Must or Off.
local function NextState(d, state)
  if not d.Specialty then return state == "MUST" and "OFF" or "MUST" end
  return SDP_UI.NextState(d, state)
end

function P.Request()
  local weights = {}
  for key, value in pairs(m_weights) do weights[key] = value end
  local list = List()
  return { PlayerID = Game.GetLocalPlayer(), Tier = m_tier, K = m_k, D = m_d, Districts = list.Must, Pool = list.Pool,
    Pick = list.Pick, Weights = weights, Distance = m_weights.DISTANCE }
end

-- The time estimate: each site places the required districts and, with a
-- pool, solves a few combinations of the count (SDP_SiteSolver.EstimateUnits).
local function Estimate(request, params, continue)
  local districts = #request.Districts + #request.Pool
  local picking = request.Pick > 0 and request.Pick < #request.Pool
  return SDP_SiteSolver.EstimateUnits(picking and districts or #request.Districts + request.Pick, request.K, params, continue,
    picking and (#request.Districts + request.Pick) or nil)
end

local function UpdateEstimate()
  local params = SDP_Tiers.Params(SDP_Tiers.Sites, m_tier)
  Controls.SitesEstimate:SetText(SDP_UI.EstimateText(Estimate(P.Request(), params, false)))
end

local function ShowSteppers()
  Controls.SitesCount:SetText(tostring(m_k))
  Controls.SitesDistance:SetText(tostring(m_d))
  local list = List()
  Controls.SitesPlanValue:SetText(tostring(list.Count))
  Controls.SitesPlanLess:SetDisabled(list.Count <= list.MustSpecialty)
  Controls.SitesPlanMore:SetDisabled(list.Count >= math.min(SDP_Sites.MAX_COUNT, list.MustSpecialty + #list.Pool))
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
    Remember()
  end
  ShowSteppers()
  UpdateEstimate()
end

-- How many districts that take population each site is scored with,
-- required ones included (clamped as on the single-city tab, at most
-- SDP_Sites.MAX_COUNT).
function P.SetDistrictCount(n)
  local before = List().Count
  local count = List(math.max(0, n)).Count
  m_count = count
  if count ~= before then ClearResult() end
  Remember()
  ShowSteppers()
  UpdateEstimate()
end

function P.SetDistance(d)
  d = math.max(MIN_D, math.min(MAX_D, d))
  if d ~= m_d then
    m_d = d
    ClearResult()
    Remember()
  end
  ShowSteppers()
end

function P.SetWeight(key, value)
  value = math.max(0, math.min(SDP_UI.MAX_WEIGHT, value))
  if m_weights[key] ~= value then
    m_weights[key] = value
    ClearResult()
    Remember()
  end
  if m_views[key] then m_views[key]() end
end

-- A preset: every weight, the distance too (issue 89), as on the other tabs;
-- the number of new cities, the distance between them and the tier stay.
function P.SetPreset(name)
  if not m_keeper.Use(name) then return end
  m_preset = name
  ClearResult()
  for _, view in pairs(m_views) do view() end
  Remember()
end

local ShowCells -- defined below

-- Set a district's state (MUST, POOL, OFF); its default is not kept.
function P.SetState(districtType, state)
  for _, d in ipairs(Districts()) do
    if d.Type == districtType and StatusOf(d) == nil then
      local before = States()[districtType]
      if state == P.DefaultState(d) then m_states[districtType] = nil else m_states[districtType] = state end
      if state ~= before then ClearResult() end
      Remember()
    end
  end
  ShowCells()
  ShowSteppers()
  UpdateEstimate()
end

-- Tests and older callers: selected = MUST, unselected = the default state.
function P.SetSelected(districtType, on)
  for _, d in ipairs(Districts()) do
    if d.Type == districtType then P.SetState(districtType, on and "MUST" or P.DefaultState(d)) end
  end
end

function P.SetTier(tier)
  if SDP_Tiers.Sites[tier] == nil then return end
  if m_tier ~= tier then
    m_tier = tier
    ClearResult()
    Remember()
  end
  Controls.SitesTierPull:GetButton():SetText(Locale.Lookup("LOC_SDP_TIER_" .. tier))
  UpdateEstimate()
end

-- The two district grids (SDP_UI.BuildCells, as on the other tabs).
ShowCells = function()
  local states = States()
  local rows = SDP_UI.BuildCells(m_cellIM, m_utilityIM, Controls.SitesDistrictStack, Controls.SitesUtilityStack, Districts(),
    function(d) return states[d.Type] end, StatusOf,
    function(d) P.SetState(d.Type, NextState(d, States()[d.Type])) end)
  m_view.Districts = {}
  for _, row in ipairs(rows) do
    -- The only tooltip of a district cell (issue 67): why it is not counted.
    if row.Status ~= nil then row.Cell:SetToolTipString(Locale.Lookup("LOC_SDP_SITES_NOT_PER_SITE")) end
    m_view.Districts[#m_view.Districts + 1] = { Type = row.Type, State = row.State, Status = row.Status, Group = row.Group,
      Cell = row.Cell, Click = row.Click }
  end
end

function P.Refresh()
  P.Restore()
  ShowSteppers()
  local a, cellsA = SDP_UI.BuildWeights(m_weightIM, Controls.SitesWeightStack, COLUMNS_A, m_weights, nil, P.SetWeight,
    WEIGHT_WIDTH)
  local b, cellsB = SDP_UI.BuildWeights(m_weightIM2, Controls.SitesWeightStack2, COLUMNS_B, m_weights, nil, P.SetWeight,
    WEIGHT_WIDTH)
  m_views = {}
  for key, view in pairs(a) do m_views[key] = view end
  for key, view in pairs(b) do m_views[key] = view end
  m_view.WeightCells = {} -- the weight columns' controls, for tests
  for _, cell in ipairs(cellsA) do m_view.WeightCells[#m_view.WeightCells + 1] = cell end
  for _, cell in ipairs(cellsB) do m_view.WeightCells[#m_view.WeightCells + 1] = cell end
  ShowCells()
  SDP_UI.PopulateTierPull(Controls.SitesTierPull, m_tier, P.SetTier)
  UpdateEstimate()
  UpdateFold()
  P.Render()
end

-- ===========================================================================
-- Results
-- ===========================================================================
local function Round(value) return SDP_UI.Number(math.floor(value * 10 + 0.5) / 10) end

-- The parts of a site's score in points (issue 88), those with a weight:
-- "Distr. 8.3  Tiles 10.1 ...", and what too few usable tiles cost.
local function SiteDetail(site, result)
  local weights = result.Weights or {}
  local items = {}
  for _, item in ipairs(ITEMS) do
    if (weights[item.Key] or 0) > 0 then
      items[#items + 1] = Locale.Lookup("LOC_SDP_SITES_ITEM_SHORT", Locale.Lookup(item.Short), Round(site.Parts[item.Part] or 0))
    end
  end
  if (site.Parts.Penalty or 0) > 0 then items[#items + 1] = Locale.Lookup("LOC_SDP_SITES_ITEM_PENALTY", Round(site.Parts.Penalty)) end
  return table.concat(items, "  ")
end

-- A line a part for the tooltip (issue 88): its points, the per-turn value
-- behind them and the value 10 points take; its weight when not 1.
local function ItemLines(site, result)
  local lines = {}
  local weights, items, points = result.Weights or {}, result.Items or {}, result.Points or {}
  for _, item in ipairs(ITEMS) do
    local w, scale, unit = weights[item.Key] or 0, items[item.Key] or 0, points[item.Key] or 1
    if w > 0 and scale > 0 then
      local part = site.Parts[item.Part] or 0
      local line = Locale.Lookup("LOC_SDP_SITES_ITEM_" .. item.Key, Round(part), Round(part / scale),
        Round(SDP_Sites.ITEM_POINTS / unit))
      if w ~= 1 then line = Locale.Lookup("LOC_SDP_SITES_WEIGHTED", line, SDP_UI.Number(w)) end
      lines[#lines + 1] = line
    end
  end
  if (site.Parts.Penalty or 0) > 0 then
    lines[#lines + 1] = Locale.Lookup("LOC_SDP_SITES_ITEM_PENALTY_LONG", Round(site.Parts.Penalty), SDP_Sites.MISSING_PLOT)
  end
  return lines
end

-- "Silk 2 (new), Spices 1": resource copies by name; "new" for a kind the
-- player lacks that counts as new at this site.
local function ResourceList(copies, newKinds)
  local list = {}
  for kind, count in pairs(copies or {}) do
    local name = SDP_UI.TypeName(kind)
    list[#list + 1] = (newKinds or {})[kind] and Locale.Lookup("LOC_SDP_SITES_NEW_KIND", name, count)
      or (name .. " " .. count)
  end
  table.sort(list)
  return table.concat(list, ", ")
end

-- Risk notes, the resources it works and the planned districts, for a
-- site's tooltip (design 3.3; issues 8, 9).
local function SiteToolTip(site, result)
  local lines = ItemLines(site, result)
  local info = site.Info
  lines[#lines + 1] = Locale.Lookup("LOC_SDP_SITES_WATER_" .. info.WaterKind)
  if info.Housing ~= nil then lines[#lines + 1] = Locale.Lookup("LOC_SDP_SITES_HOUSING", SDP_UI.Number(info.Housing)) end
  local own = site.OwnDistance or info.OwnDistance
  if own ~= nil and own < math.huge then lines[#lines + 1] = Locale.Lookup("LOC_SDP_SITES_OWN_DISTANCE", own) end
  if site.SiteDistance ~= nil then lines[#lines + 1] = Locale.Lookup("LOC_SDP_SITES_SITE_DISTANCE", site.SiteDistance) end
  if next(site.Luxury or {}) ~= nil then
    lines[#lines + 1] = Locale.Lookup("LOC_SDP_SITES_LUXURY", ResourceList(site.Luxury, site.NewKinds))
  end
  if next(site.Strategic or {}) ~= nil then
    lines[#lines + 1] = Locale.Lookup("LOC_SDP_SITES_STRATEGIC", ResourceList(site.Strategic, site.NewKinds))
  end
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

-- The numbers the sites of a solution get (their pins' names): the next free
-- numbers after the player's cities and planned cities (SDP_City.SiteNumbers).
local function SiteNumbers(solution)
  local playerID = Game.GetLocalPlayer()
  local names = {}
  for _, site in ipairs(SDP_Multi.Sites(playerID)) do names[#names + 1] = site.Name end
  for _ = 1, #solution.Sites do names[#names + 1] = "" end
  local numbers = SDP_City.SiteNumbers(playerID, names)
  local out = {}
  for s = 1, #solution.Sites do out[s] = numbers[#numbers - #solution.Sites + s] end
  return out
end

function P.Preview(n)
  local solution = m_result and m_result.Ok and m_result.Solutions[n]
  if solution == nil then
    SDP_Preview.Clear()
    return
  end
  local areas, icons = {}, {}
  local numbers = SiteNumbers(solution)
  for s, site in ipairs(solution.Sites) do
    local plots = {}
    for _, entry in ipairs(SDP_City.PlotsInRange(site.X, site.Y, SDP_City.RADIUS)) do plots[#plots + 1] = entry.Index end
    areas[#areas + 1] = { Plots = plots, Color = s }
    icons[#icons + 1] = { X = site.X, Y = site.Y, Icon = "ICON_DISTRICT_CITY_CENTER",
      Text = Locale.Lookup("LOC_SDP_SITE_N", numbers[s]) .. " " .. SDP_UI.Number(math.floor(site.Value * 10 + 0.5) / 10) }
    for _, d in ipairs(site.Districts or {}) do icons[#icons + 1] = { X = d.X, Y = d.Y, Icon = "ICON_" .. d.Type } end
  end
  SDP_Preview.Show(Game.GetLocalPlayer(), areas, icons)
  -- Only for a new result or another solution, not on reopening the tab (issue 67).
  if m_lookNext and SDP_UI.IsOpen() then
    m_lookNext = false
    m_site = 1
    SDP_UI.LookAt(solution.Sites[1].X, solution.Sites[1].Y)
  end
end

-- Move the camera to site s of the selected solution (issue 75).
function P.LookAtSite(s)
  local solution = m_result and m_result.Ok and m_result.Solutions[m_solution]
  local site = solution and solution.Sites[s]
  if site == nil then return end
  m_site = s
  m_view.Site = s
  SDP_UI.LookAt(site.X, site.Y)
  UI.PlaySound("Play_UI_Click")
end

-- Whether the selected solution has more than one site to go through.
function P.CanStep()
  local solution = m_result and m_result.Ok and m_result.Solutions[m_solution]
  return solution ~= nil and #solution.Sites > 1
end

-- The camera to the selected solution's next site, after the last the first.
function P.NextSite()
  if not P.CanStep() then return end
  P.LookAtSite(m_site % #m_result.Solutions[m_solution].Sites + 1)
end

-- Another solution: shown, the camera to its first site. The selected one
-- again: the camera to its next site (issue 75).
function P.SelectSolution(n)
  if m_result == nil or not m_result.Ok or m_result.Solutions[n] == nil then return end
  if n == m_solution and SDP_UI.IsOpen() then
    if P.CanStep() then P.NextSite() else P.LookAtSite(1) end
    return
  end
  m_solution = n
  m_lookNext = true
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
    Controls.SitesQuality:SetText(SDP_UI.Join({ SDP_UI.QualityText(result), Locale.Lookup("LOC_SDP_SITES_MODEL_NOTE") }))
    for n, s in ipairs(result.Solutions) do
      local inst = m_solutionIM:GetInstance()
      local where = {}
      for _, site in ipairs(s.Sites) do where[#where + 1] = SDP_UI.Where(site.X, site.Y) end
      local tip = table.concat(where, " ")
      if #s.Sites > 1 then tip = tip .. "[NEWLINE]" .. Locale.Lookup("LOC_SDP_SITES_SOLUTION_NEXT") end
      SDP_UI.SolutionRow(inst, Locale.Lookup("LOC_SDP_SOLUTION_N", n, SDP_UI.Number(math.floor(s.Value * 10 + 0.5) / 10)),
        tip, n == m_solution)
      inst.Root:RegisterCallback(Mouse.eLClick, function() P.SelectSolution(n) end)
      m_view.Solutions[n] = { Value = s.Value, Selected = n == m_solution, Cell = inst.Root }
    end
    local numbers = SiteNumbers(solution)
    for s, site in ipairs(solution.Sites) do
      local name = Locale.Lookup("LOC_SDP_SITE_N", numbers[s]) .. "  " .. SDP_UI.Where(site.X, site.Y) .. "  "
        .. SDP_UI.Number(math.floor(site.Value * 10 + 0.5) / 10)
      local inst = m_resultIM:GetInstance()
      m_view.Results[#m_view.Results + 1] = SDP_UI.ResultRow(inst, "ICON_DISTRICT_CITY_CENTER", name,
        SiteDetail(site, result), SiteToolTip(site, result), site.X, site.Y)
      -- A click on a site also sets where "next site" goes on from.
      inst.Root:RegisterCallback(Mouse.eLClick, function() P.LookAtSite(s) end)
    end
    if not Controls.SitesPage:IsHidden() then P.Preview(m_solution) end
  end
  Controls.SitesSolutionStack:CalculateSize()
  Controls.SitesResultStack:CalculateSize()
  Controls.SitesResultScroll:CalculateSize()
  P.FitPage()
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
  Controls.SitesContinueButton:SetHide(running)
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
  m_lookNext = true
  P.SetFold(true) -- the results get the room (issue 71)
  SDP_Preview.Clear()
  return SDP_UI.StartTask(function() return SDP_SiteSolver.SolveNow(request) end, Estimate(request, params, false),
    function(result) m_result, m_solution = result, 1 end, P)
end

function P.Continue()
  if SDP_Task.IsRunning() or m_result == nil or not m_result.Ok or not m_result.Quality.CanContinue then return false end
  m_lookNext = true
  local session = m_result.Session
  return SDP_UI.StartTask(function()
    session:Continue()
    return session:Result()
  end, SDP_SiteSolver.EstimateUnits(#session.Ctx.Plan + #session.Ctx.Pool, session.K, session.Params, true,
    session.Ctx.Pick > 0 and (#session.Ctx.Plan + session.Ctx.Pick) or nil),
    function(result) m_result = result end, P)
end

-- A city-center map tack on every site of the selected solution, named with
-- the site's number: step 2 (the several-cities tab) plans them, and the
-- district pins it places around a site carry the same number.
function P.Place()
  if SDP_Task.IsRunning() or m_result == nil or not m_result.Ok or m_result.Placed then return 0 end
  local solution = m_result.Solutions[m_solution]
  local numbers = SiteNumbers(solution)
  local entries = {}
  for s, site in ipairs(solution.Sites) do
    entries[s] = { Type = "DISTRICT_CITY_CENTER", X = site.X, Y = site.Y, Name = tostring(numbers[s]) }
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
    Result = m_result, Solution = m_solution, Site = m_site, K = m_k, D = m_d, Tier = m_tier, Weights = m_weights, View = m_view,
    DistrictCount = List().Count, States = States(), Preset = m_preset, Fold = m_fold, FoldText = Controls.SitesFoldText:GetText(),
    EstimateText = Controls.SitesEstimate:GetText(), PlaceDisabled = Controls.SitesPlaceButton:IsDisabled(),
  }
end

Controls.SitesCountLess:RegisterCallback(Mouse.eLClick, function() P.SetCount(m_k - 1) end)
Controls.SitesCountMore:RegisterCallback(Mouse.eLClick, function() P.SetCount(m_k + 1) end)
Controls.SitesDistanceLess:RegisterCallback(Mouse.eLClick, function() P.SetDistance(m_d - 1) end)
Controls.SitesDistanceMore:RegisterCallback(Mouse.eLClick, function() P.SetDistance(m_d + 1) end)
Controls.SitesPlanLess:RegisterCallback(Mouse.eLClick, function() P.SetDistrictCount(List().Count - 1) end)
Controls.SitesPlanMore:RegisterCallback(Mouse.eLClick, function() P.SetDistrictCount(List().Count + 1) end)
Controls.SitesSolveButton:RegisterCallback(Mouse.eLClick, function() P.Solve() end)
Controls.SitesContinueButton:RegisterCallback(Mouse.eLClick, function() P.Continue() end)
Controls.SitesCancelButton:RegisterCallback(Mouse.eLClick, function() SDP_Task.Cancel() end)
Controls.SitesPlaceButton:RegisterCallback(Mouse.eLClick, function() P.Place() end)
Controls.SitesUndoButton:RegisterCallback(Mouse.eLClick, function() P.Undo() end)
Controls.SitesFoldButton:RegisterCallback(Mouse.eLClick, function() P.SetFold(not m_fold) end)
