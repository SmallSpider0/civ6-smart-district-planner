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
local m_siteRowIM = InstanceManager:new("SiteRow", "Root", Controls.SitesResultStack)

-- The site weights (design 3.3, issue 88) and the distance cost, in two
-- rows: the six yields with the game's font icons and the distance cost,
-- then one weight per part of a site's score, with a short word (feedback
-- item 3, as on the single-city tab). Seven columns a row over the full
-- 480 width: 68 leaves room for "0.5" between the 19-wide arrows and keeps
-- the English words apart (issue 88; 50 hid the value behind the arrows).
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
local WEIGHT_WIDTH = 68

-- Default distance 5 (issue 84, the maintainer's choice): sites land at the
-- full distance (nothing in the score pulls them closer), and players space
-- cities 4-6 apart.
local DEFAULT_K, DEFAULT_D = 3, 5
local m_k, m_d = DEFAULT_K, DEFAULT_D
local MIN_D, MAX_D = 4, 15
-- Dense packing (issue 87, decided 2026-10-26): its own distance, kept in
-- the save; switching it off brings the usual one back.
-- The number of new cities is one for both modes (issue 191): switching
-- dense packing on keeps it (it had its own, 12 by default, and a plan that
-- far ahead was mostly out of date before the settlers got there). Dense
-- packing allows up to DENSE_MAX_K; with it off the count shows and runs as
-- at most MAX_K, and comes back when it is switched on again.
local m_dense = false
local m_dd = DEFAULT_D
-- Every site of a result has a tick box and only the ticked ones get a tack:
-- none ticked by default with dense packing on (issue 87), all with it off
-- (issue 241). m_flipped holds the sites the player set the other way.
local m_flipped = {} -- [site number in the solution] = true
local function MaxK() return m_dense and SDP_SiteSolver.DENSE_MAX_K or SDP_SiteSolver.MAX_K end
local function K() return math.min(m_k, MaxK()) end
local function D() return m_dense and m_dd or m_d end
-- The districts each site is scored with (issue 90): states as on the
-- single-city tab, MUST / POOL / OFF, only the ones the player chose (the
-- rest at SDP_Sites.DefaultState), and how many that take population.
local m_states = {}
local m_count = SDP_Sites.DEFAULT_COUNT
local m_weights = { DISTANCE = SDP_Sites.DEFAULT_DISTANCE }
for key, value in pairs(SDP_Sites.PRESETS.BALANCED) do m_weights[key] = value end
local m_kit -- SDP_PageKit: weights, tier, preset, fold (made at the end)
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

function P.FitPage()
  SDP_UI.FitResults(Controls.SitesBody, Controls.SitesPage, Controls.SitesResultScroll,
    Controls.SitesSettingsScroll, Controls.SitesSettingsStack, Controls.SitesDistrictScroll, Controls.SitesDistrictArea)
end

local function Remember() m_kit.Remember() end
function P.Restore() m_kit.Restore() end

local function Ticked(s)
  local flipped = m_flipped[s] == true
  if m_result ~= nil and m_result.Dense then return flipped end
  return not flipped
end
-- The ticked sites of the selected solution, [site number] = true.
local function TickedSet()
  local set = {}
  local solution = m_result and m_result.Ok and (m_result.Solutions[m_solution] or m_result.Solutions[1])
  if solution then
    for s = 1, #solution.Sites do
      if Ticked(s) then set[s] = true end
    end
  end
  return set
end

local function ClearResult()
  m_kit.CancelTask()
  m_flipped = {}
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
  return { PlayerID = Game.GetLocalPlayer(), Tier = m_kit.Tier, K = K(), D = D(), Districts = list.Must, Pool = list.Pool,
    Pick = list.Pick, Weights = weights, Distance = m_weights.DISTANCE, Dense = m_dense }
end

-- The time estimate: each site places the required districts and, with a
-- pool, solves a few combinations of the count (SDP_SiteSolver.EstimateUnits).
local function Estimate(request, params, continue)
  local districts = #request.Districts + #request.Pool
  local picking = request.Pick > 0 and request.Pick < #request.Pool
  return SDP_SiteSolver.EstimateUnits(picking and districts or #request.Districts + request.Pick, request.K, params, continue,
    picking and (#request.Districts + request.Pick) or nil, request.Dense)
end

local function UpdateEstimate()
  local params = SDP_Tiers.Params(SDP_Tiers.Sites, m_kit.Tier)
  Controls.SitesEstimate:SetText(SDP_UI.EstimateText(Estimate(P.Request(), params, false)))
end

local function ShowSteppers()
  Controls.SitesCount:SetText(tostring(K()))
  Controls.SitesDistance:SetText(tostring(D()))
  Controls.SitesDenseCheck:SetCheck(m_dense)
  local list = List()
  Controls.SitesPlanValue:SetText(tostring(list.Count))
  Controls.SitesPlanLess:SetDisabled(list.Count <= list.MustSpecialty)
  Controls.SitesPlanMore:SetDisabled(list.Count >= math.min(SDP_Sites.MAX_COUNT, list.MustSpecialty + #list.Pool))
  Controls.SitesCountLess:SetDisabled(K() <= 1)
  Controls.SitesCountMore:SetDisabled(K() >= MaxK())
  Controls.SitesDistanceLess:SetDisabled(D() <= MIN_D)
  Controls.SitesDistanceMore:SetDisabled(D() >= MAX_D)
end

function P.SetCount(k)
  k = math.max(1, math.min(MaxK(), k))
  if k ~= K() then
    m_k = k
    ClearResult()
    Remember()
  end
  ShowSteppers()
  UpdateEstimate()
end

-- Dense packing on or off (issue 87): the distance is each mode's own, the
-- number of new cities stays (issue 191).
function P.SetDense(on)
  on = on == true
  if on ~= m_dense then
    m_dense = on
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
  if d ~= D() then
    if m_dense then m_dd = d else m_d = d end
    ClearResult()
    Remember()
  end
  ShowSteppers()
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
  P.FitPage() -- the grid's rows take room (issue 314)
end

function P.Refresh()
  P.Restore()
  ShowSteppers()
  m_kit.BuildWeights()
  m_view.WeightCells = m_kit.Cells -- the weight columns' controls, for tests
  ShowCells()
  m_kit.ShowTiers()
  UpdateEstimate()
  m_kit.UpdateFold()
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
  -- Housing: the water's and each building's apart (issue 188), so the
  -- total does not read as what the new city has at once; buildings the
  -- player has not researched yet are named apart and not in the total.
  local function List(parts)
    local list = {}
    for _, part in ipairs(parts or {}) do
      list[#list + 1] = Locale.Lookup("LOC_SDP_SITES_HOUSING_PART", SDP_UI.TypeName(part.Building), SDP_UI.Number(part.Housing))
    end
    return list
  end
  local built, later = List(info.HousingParts), List(info.HousingLater)
  if info.Housing ~= nil and #built > 0 and #later > 0 then
    lines[#lines + 1] = Locale.Lookup("LOC_SDP_SITES_HOUSING_BUILT_LATER", SDP_UI.Number(info.Housing),
      SDP_UI.Number(info.HousingWater), table.concat(built, ", "), table.concat(later, ", "))
  elseif info.Housing ~= nil and #built > 0 then
    lines[#lines + 1] = Locale.Lookup("LOC_SDP_SITES_HOUSING_BUILT", SDP_UI.Number(info.Housing),
      SDP_UI.Number(info.HousingWater), table.concat(built, ", "))
  elseif info.Housing ~= nil and #later > 0 then
    lines[#lines + 1] = Locale.Lookup("LOC_SDP_SITES_HOUSING_LATER", SDP_UI.Number(info.Housing), SDP_UI.Number(info.HousingWater),
      table.concat(later, ", "))
  elseif info.Housing ~= nil then
    lines[#lines + 1] = Locale.Lookup("LOC_SDP_SITES_HOUSING", SDP_UI.Number(info.Housing))
  end
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
  m_flipped = {}
  m_lookNext = true
  P.Render()
end

function P.Render()
  m_solutionIM:ResetInstances()
  m_siteRowIM:ResetInstances()
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
    local ticked = 0
    for _ in pairs(TickedSet()) do ticked = ticked + 1 end
    if result.Dense then
      Controls.SitesSummary:SetText(Locale.Lookup("LOC_SDP_SITES_SUMMARY_DENSE", #solution.Sites,
        SDP_UI.Number(math.floor(solution.Value * 10 + 0.5) / 10), ticked))
    end
    Controls.SitesAllButton:SetText(Locale.Lookup(ticked == #solution.Sites and "LOC_SDP_SITES_TICK_NONE"
      or "LOC_SDP_SITES_TICK_ALL"))
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
      local inst = m_siteRowIM:GetInstance()
      local row = SDP_UI.ResultRow(inst, "ICON_DISTRICT_CITY_CENTER", name,
        SiteDetail(site, result), SiteToolTip(site, result), site.X, site.Y)
      m_view.Results[#m_view.Results + 1] = row
      -- Ticked for its tack (issues 87, 241).
      inst.Check:SetCheck(Ticked(s))
      inst.Check:RegisterCheckHandler(function() P.SetTicked(s, inst.Check:IsChecked()) end)
      row.Check = inst.Check
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
  local none = ok and next(TickedSet()) == nil
  m_kit.ShowButtons({ Solve = true, Continue = ok and m_result.Quality.CanContinue and m_result.Placed ~= true,
    Place = ok and m_result.Placed ~= true and not none })
  Controls.SitesAllButton:SetHide(not ok)
  Controls.SitesAllButton:SetDisabled(running or not ok or m_result.Placed == true)
end

-- ===========================================================================
-- Actions
-- ===========================================================================
function P.Solve()
  if SDP_Task.IsRunning() then return false end
  local request = P.Request()
  local params = SDP_Tiers.Params(SDP_Tiers.Sites, m_kit.Tier)
  m_result, m_solution, m_flipped = nil, 1, {}
  m_lookNext = true
  m_kit.SetFold(true) -- the results get the room (issue 71)
  SDP_Preview.Clear()
  return SDP_UI.StartTask(function() return SDP_SiteSolver.SolveNow(request) end, Estimate(request, params, false),
    function(result)
      m_result, m_solution = result, 1
      if result.Ok then result.Dense = request.Dense end
    end, P)
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
    function(result)
      -- Its solutions may differ: the tick boxes start over (issue 241).
      m_result, m_flipped = result, {}
    end, P)
end

-- A city-center map tack on every site of the selected solution, named with
-- the site's number: step 2 (the several-cities tab) plans them, and the
-- district pins it places around a site carry the same number.
function P.Place()
  if not SDP_PageKit.CanPlace(m_result) then return 0 end
  local solution = m_result.Solutions[m_solution]
  local numbers = SiteNumbers(solution)
  local entries = {}
  for s, site in ipairs(solution.Sites) do
    if Ticked(s) then
      entries[#entries + 1] = { Type = "DISTRICT_CITY_CENTER", X = site.X, Y = site.Y, Name = tostring(numbers[s]) }
    end
  end
  if #entries == 0 then return 0 end
  local placed = SDP_PageKit.Place(m_result, entries, nil)
  SDP_UI.UpdateAllButtons()
  return placed
end

-- Tick a site for its tack, or every site (issues 87, 241).
function P.SetTicked(s, on)
  if m_result == nil or not m_result.Ok then return end
  if (on == true) == Ticked(s) then return end
  m_flipped[s] = not m_flipped[s] or nil
  P.Render()
end

function P.TickAll()
  local solution = m_result and m_result.Ok and m_result.Solutions[m_solution]
  if solution == nil then return end
  local all = true
  for s = 1, #solution.Sites do
    if not Ticked(s) then all = false end
  end
  m_flipped = {}
  for s = 1, #solution.Sites do
    if Ticked(s) == all then m_flipped[s] = true end
  end
  P.Render()
end

function P.Undo()
  local removed = SDP_PageKit.Undo(m_result, nil)
  SDP_UI.UpdateAllButtons()
  return removed
end

function P.State()
  return {
    Result = m_result, Solution = m_solution, Site = m_site, K = K(), D = D(), Tier = m_kit.Tier, Weights = m_weights, View = m_view,
    Dense = m_dense, Ticked = TickedSet(), AllText = Controls.SitesAllButton:GetText(),
    DistrictCount = List().Count, States = States(), Preset = m_kit.Preset, Fold = m_kit.Fold, FoldText = Controls.SitesFoldText:GetText(),
    EstimateText = Controls.SitesEstimate:GetText(), PlaceDisabled = Controls.SitesPlaceButton:IsDisabled(),
  }
end

Controls.SitesCountLess:RegisterCallback(Mouse.eLClick, function() P.SetCount(K() - 1) end)
Controls.SitesCountMore:RegisterCallback(Mouse.eLClick, function() P.SetCount(K() + 1) end)
Controls.SitesDistanceLess:RegisterCallback(Mouse.eLClick, function() P.SetDistance(D() - 1) end)
Controls.SitesDistanceMore:RegisterCallback(Mouse.eLClick, function() P.SetDistance(D() + 1) end)
Controls.SitesDenseCheck:RegisterCheckHandler(function() P.SetDense(Controls.SitesDenseCheck:IsChecked()) end)
Controls.SitesAllButton:RegisterCallback(Mouse.eLClick, function() P.TickAll() end)
Controls.SitesPlanLess:RegisterCallback(Mouse.eLClick, function() P.SetDistrictCount(List().Count - 1) end)
Controls.SitesPlanMore:RegisterCallback(Mouse.eLClick, function() P.SetDistrictCount(List().Count + 1) end)

-- ===========================================================================
-- The settings every tab has (SDP_PageKit)
-- ===========================================================================
-- The preset, the weights and the tier, kept in the save (issue 57); the
-- number of new cities and the distance too (issue 84); the district states
-- and the district count (issue 90); dense packing and its distance (issue 87).
m_kit = SDP_PageKit.New({
  Page = P, Tab = "SITES", Columns = ALL_COLUMNS, Weights = m_weights, Tiers = SDP_Tiers.Sites,
  Presets = SDP_Sites.PRESETS, Order = SDP_Sites.PRESET_ORDER, Preset = "BALANCED",
  Extra = {
    { Key = "K", Kind = "number", Min = 1, Max = SDP_SiteSolver.DENSE_MAX_K, Default = DEFAULT_K,
      Get = function() return m_k end, Put = function(v) m_k = math.floor(v) end },
    { Key = "D", Kind = "number", Min = MIN_D, Max = MAX_D, Default = DEFAULT_D,
      Get = function() return m_d end, Put = function(v) m_d = math.floor(v) end },
    { Key = "COUNT", Kind = "number", Min = 0, Max = SDP_Sites.MAX_COUNT, Default = SDP_Sites.DEFAULT_COUNT,
      Get = function() return m_count end, Put = function(v) m_count = math.floor(v) end },
    { Key = "DISTRICTS", Kind = "list", Pattern = "^[%w_]+:[MPO]$", Default = "", Get = KeptStates, Put = PutStates },
    { Key = "DENSE", Default = false, Get = function() return m_dense end, Put = function(v) m_dense = v end },
    { Key = "DD", Kind = "number", Min = MIN_D, Max = MAX_D, Default = DEFAULT_D,
      Get = function() return m_dd end, Put = function(v) m_dd = math.floor(v) end } },
  WeightRows = { { IM = m_weightIM, Stack = Controls.SitesWeightStack, Columns = COLUMNS_A },
    { IM = m_weightIM2, Stack = Controls.SitesWeightStack2, Columns = COLUMNS_B } }, WeightWidth = WEIGHT_WIDTH,
  TierPull = Controls.SitesTierPull, PresetPull = Controls.SitesPresetPull,
  PresetTips = { Order = SDP_Sites.PRESET_ORDER, Tips = "LOC_SDP_SITES_PRESET_", CustomTip = "LOC_SDP_SITES_PRESET_CUSTOM_TOOLTIP",
    TipArgs = SDP_Sites.PresetTipArgs },
  Fold = { Button = Controls.SitesFoldButton, Text = Controls.SitesFoldText, Action = Controls.SitesFoldAction,
    Scroll = Controls.SitesSettingsScroll },
  Buttons = { Solve = Controls.SitesSolveButton, Continue = Controls.SitesContinueButton, Cancel = Controls.SitesCancelButton,
    Place = Controls.SitesPlaceButton, Undo = Controls.SitesUndoButton },
  ClearResult = function() ClearResult() end, FitPage = function() P.FitPage() end,
  Changed = function() UpdateEstimate() end,
})
-- A preset sets every weight, the distance cost too (issue 89), as on the
-- other tabs; the number of new cities, the distance between them and the
-- tier stay.
P.SetWeight = m_kit.SetWeight
P.SetTier = m_kit.SetTier
P.SetPreset = m_kit.SetPreset
P.SetFold = m_kit.SetFold
