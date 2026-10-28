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
include("SDP_Appeal")
include("SDP_Coverage")
include("SDP_Search")
include("SDP_Remind")
include("SDP_Solver")
include("SDP_Wonders")
include("SDP_Multi")
include("SDP_Sites")
include("SDP_SiteSolver")
include("SDP_Pins")
include("SDP_Preview")
include("SDP_Settings")

local LAUNCH_BAR_STACK = "/InGame/LaunchBar/ButtonStack"
local MAX_WEIGHT = 3
-- The release, in the launch bar button's tooltip, so that a report says
-- which copy the game loaded (issue 27). tools/validate.py checks it against
-- the newest version in CHANGELOG.md.
local VERSION = "v1.6.0"

-- The weight row (feedback item 3): the six yields with the game's font
-- icons, one family (the texture icons cover only some yields: requirements
-- pitfalls 13 and 14); the other weights with a short word, since the font
-- icons that would fit them (terrain, movement, range) are drawn in another
-- style, dark squares. The land part weighs plots with fixed numbers
-- (SDP_Land.PLOT_WEIGHTS, issue 53), so food and the one-time yields of
-- clearing and harvesting have no column here; LAND weighs the whole land
-- part (0: off, in place of the switch it had). DISTANCE is the distance
-- cost weight (feedback item 9), 0.5 by default (issue 91, decided
-- 2026-10-26: with the same adjacency, closer to the City Center is better,
-- since outer tiles join the city later or cost Gold); 0 is off. Settings
-- kept in a save hold only what differs from the default (SDP_Settings), so
-- a player who never changed it gets 0.5 and one who set it keeps theirs.
-- Every weight steps by 0.5 (issue 53).
local WEIGHT_COLUMNS = {
  { Key = "YIELD_SCIENCE", Glyph = "[ICON_Science]" },
  { Key = "YIELD_CULTURE", Glyph = "[ICON_Culture]" },
  { Key = "YIELD_FAITH", Glyph = "[ICON_Faith]" },
  { Key = "YIELD_GOLD", Glyph = "[ICON_Gold]" },
  { Key = "YIELD_PRODUCTION", Glyph = "[ICON_Production]" },
  { Key = "LAND", Glyph = "LOC_SDP_WEIGHT_LAND_SHORT", ToolTip = "LOC_SDP_LAND" },
  { Key = "DISTANCE", Glyph = "LOC_SDP_WEIGHT_DISTANCE_SHORT", ToolTip = "LOC_SDP_WEIGHT_DISTANCE", Step = 0.5, Default = 0.5 },
  -- Housing of districts that depend on appeal (neighborhood, preserve; SDP_Appeal).
  -- Short text like the other non-yield columns: [ICON_Housing] is a
  -- black square in the game (seen 2026-10-21), as 20.5 found for others.
  { Key = "HOUSING", Glyph = "LOC_SDP_WEIGHT_HOUSING_SHORT", ToolTip = "LOC_SDP_WEIGHT_HOUSING" },
}
-- The coverage part (SDP_Coverage, design 19), the last column of the
-- single-city and multi-city tabs: 0 (off) by default.
local COVERAGE_COLUMN = { Key = "COVERAGE", Glyph = "LOC_SDP_WEIGHT_COVERAGE_SHORT", ToolTip = "LOC_SDP_WEIGHT_COVERAGE", Default = 0 }
-- This tab's columns: the shared ones, then coverage.
local SINGLE_COLUMNS = {}
for _, column in ipairs(WEIGHT_COLUMNS) do SINGLE_COLUMNS[#SINGLE_COLUMNS + 1] = column end
SINGLE_COLUMNS[#SINGLE_COLUMNS + 1] = COVERAGE_COLUMN
local WEIGHT_WIDTH = 50 -- nine columns: a little narrower than the 520 page

local m_launchItem = {}     -- SDP_LaunchBarItem instance in the game's launch bar
local m_launchPin = {}      -- SDP_LaunchBarPin instance next to it

local m_cellIM = InstanceManager:new("DistrictCell", "Root", Controls.DistrictStack)
local m_utilityIM = InstanceManager:new("DistrictCell", "Root", Controls.UtilityStack)
local m_chipIM = InstanceManager:new("WonderChip", "Root", Controls.WonderChipStack)
local m_weightIM = InstanceManager:new("WeightColumn", "Root", Controls.WeightStack)
local m_solutionIM = InstanceManager:new("SolutionRow", "Root", Controls.SolutionStack)
local m_resultIM = InstanceManager:new("ResultRow", "Root", Controls.ResultStack)

-- Panel state, kept while the game runs.
local m_cityID = nil
local m_states = {}           -- [DistrictType] = "MUST" | "POOL" | "OFF" | "AUTO" (chosen; else SDP_UI.DefaultState)
local m_count = nil           -- districts that take population to plan (nil: SDP_UI.DEFAULT_COUNT)
local m_weights = {}          -- [YieldType, DISTANCE, HOUSING or COVERAGE] = 0..MAX_WEIGHT
for _, column in ipairs(SINGLE_COLUMNS) do m_weights[column.Key] = column.Default or 1 end
local m_allowFeatureRemoval = true
local m_swap = false          -- plots swapped from another of our cities are candidates (issue 54)
local m_replace = false       -- plan over this mod's earlier pins for the city and replace them
local m_remind = true         -- reminder pins on the woods and rainforest the plan relies on (feedback item 5)
local m_apart = true          -- keep partner districts (harbor, commercial hub) out of one city's picks (SDP_Rules.Apart)
local m_wonders = {}          -- [BuildingType] = true: wonders to place too (then solved by SDP_Multi, one city)
local m_heat = nil            -- the district whose good places the map shows
local m_heatSpots = nil       -- SDP_Solver.Heat of m_heat (tests)
local m_tier = SDP_Tiers.DEFAULT
local m_launchDone = false    -- a background solve finished while the panel was closed
local m_scan = nil            -- the selected city (district status, specialty slots)
local m_districts = {}        -- SDP_Rules.PlannableDistricts, sorted by type
local m_status = {}           -- SDP_City.DistrictStatus for the selected city
local m_result = nil          -- last solve; cleared whenever an input changes
local m_solution = 1          -- the solution shown (and previewed)
local m_districtRows = {}     -- what the district grid shows, for tests
local m_resultRows = {}       -- what the result list shows, for tests
local m_solutionCells = {}    -- the solution rows' buttons, for real-click tests
local m_weightViews = {}      -- [key] = function that redraws that weight
local m_weightCells = {}      -- the weight columns' controls, for tests (SDP_UI.BuildWeights)
local m_tab = "SINGLE"        -- the open tab: SINGLE, SITES or MULTI
local m_lookNext = false      -- move the camera to the city when the next result shows (a solve, a continue)
local m_preset = SDP_Settings.PRESET_ORDER[1] -- the weights and switches started from (issue 49)
local m_fold = false          -- the settings folded into one line (issue 71)
local m_peek = false          -- the window hidden to look at the map (issue 71)

-- The switches kept in the save with the weights and the tier (issue 57).
local SINGLE_SWITCHES = {
  { Key = "ALLOW_REMOVAL", Default = true, Get = function() return m_allowFeatureRemoval end,
    Put = function(v) m_allowFeatureRemoval = v end },
  { Key = "SWAP", Default = false, Get = function() return m_swap end, Put = function(v) m_swap = v end },
  { Key = "REPLACE", Default = false, Get = function() return m_replace end, Put = function(v) m_replace = v end },
  { Key = "REMIND", Default = true, Get = function() return m_remind end, Put = function(v) m_remind = v end },
  { Key = "APART", Default = true, Get = function() return m_apart end, Put = function(v) m_apart = v end },
}

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

-- The text under a preview icon: the plan entry's adjacency yields as the
-- game shows them (DMT's numbers, not weighted; issue 34), nothing when
-- there are none.
local function PinText(yields)
  if yields == nil then return "" end
  local parts = {}
  for _, yieldType in ipairs(SDP_Rules.YIELDS) do
    local amount = yields[yieldType]
    if amount ~= nil and amount ~= 0 then
      parts[#parts + 1] = Locale.Lookup("LOC_SDP_YIELD_SHORT_" .. yieldType) .. Signed(amount)
    end
  end
  return table.concat(parts, " ")
end

-- Localized name of a district, improvement, building or feature type.
-- Texts joined with the language's separator ("a; b; c"). The separator sits
-- inside a format string (LOC_SDP_LIST_JOIN = "{1_A}; {2_B}"): the game trims
-- the spaces at both ends of a text, so a separator text "; " would lose its space.
local function Join(list, key)
  local out = nil
  for _, item in ipairs(list) do
    out = (out == nil) and item or Locale.Lookup(key or "LOC_SDP_LIST_JOIN", out, item)
  end
  return out or ""
end

local function TypeName(typeName)
  local row = GameInfo.Districts[typeName] or GameInfo.Improvements[typeName] or GameInfo.Buildings[typeName]
    or GameInfo.Features[typeName] or GameInfo.Resources[typeName]
  return row and Locale.Lookup(row.Name) or typeName
end

-- A result row grows with its detail line: English notes ("clear or harvest
-- the tile first") run past the row's width and wrap.
local function FitResultRow(inst)
  inst.Root:SetSizeY(math.max(40, 23 + inst.Detail:GetSizeY()))
end

-- Hover text of an "is left out" row (issue 60): with no legal plot in
-- range, the game's own description of the district or wonder, which says
-- where it may stand (an aqueduct: next to the City Center and to a river,
-- lake, oasis or mountain).
local function UnplacedTip(u)
  if u.Reason ~= "NO_LEGAL_PLOT" and u.Reason ~= "NEEDS_IMPROVEMENT" then return "" end
  local row = GameInfo.Districts[u.Type] or GameInfo.Buildings[u.Type]
  return (row ~= nil and row.Description ~= nil) and Locale.Lookup(row.Description) or ""
end

-- Move the camera so that a plot sits right of the panel (issue 67), as the
-- game's TradeOverview puts a unit beside its own panel.
local LOOK_X = 0.65
local function LookAt(x, y)
  if x == nil or y == nil then return end
  UI.LookAtPlotScreenPosition(x, y, LOOK_X, 0.5)
  SDP_UI.LastLook = x .. "," .. y -- for tests: the game's UI table cannot be wrapped
end

-- Helpers shared with the other tabs (SDP_PageSites, SDP_PageMulti).
SDP_UI = {
  LookAt = LookAt,
  FitResultRow = FitResultRow, UnplacedTip = UnplacedTip,
  MAX_WEIGHT = MAX_WEIGHT, WEIGHT_COLUMNS = WEIGHT_COLUMNS, COVERAGE_COLUMN = COVERAGE_COLUMN,
  Number = Number, Signed = Signed, Where = Where, YieldText = YieldText, PinText = PinText, TypeName = TypeName, Join = Join,
}

-- An "is left out" row: what (a district added by itself, or for a wonder,
-- says so: issue 66), and why.
function SDP_UI.UnplacedName(u)
  if u.ForWonder ~= nil then return Locale.Lookup("LOC_SDP_RESULT_UNPLACED_FOR_WONDER", TypeName(u.Type), TypeName(u.ForWonder)) end
  return Locale.Lookup(u.Auto and "LOC_SDP_RESULT_UNPLACED_AUTO" or "LOC_SDP_RESULT_UNPLACED", TypeName(u.Type))
end

function SDP_UI.ReasonText(u)
  local other = u.Other and TypeName(u.Other) or ""
  if u.Where ~= nil then return Locale.Lookup("LOC_SDP_REASON_" .. u.Reason, other, Locale.Lookup(u.Where)) end
  return Locale.Lookup("LOC_SDP_REASON_" .. u.Reason, other)
end

-- What a tab keeps in the save (issue 57, SDP_Settings): its weight columns,
-- its switches ({ Key, Default }), its tier (one of `tiers`) and `extra`
-- flags no preset sets ({ Key, Default }: the fold, issue 71).
function SDP_UI.SettingFields(columns, switches, tiers, extra)
  local fields = {}
  for _, column in ipairs(columns) do
    fields[#fields + 1] = { Key = column.Key, Kind = "number", Min = 0, Max = MAX_WEIGHT, Default = column.Default or 1,
      Preset = true }
  end
  for _, switch in ipairs(switches) do
    fields[#fields + 1] = { Key = switch.Key, Kind = "flag", Default = switch.Default, Preset = true }
  end
  local choices = {}
  for _, tier in ipairs(SDP_Tiers.ORDER) do
    if tiers[tier] ~= nil then choices[tier] = true end
  end
  fields[#fields + 1] = { Key = "TIER", Kind = "choice", Choices = choices, Default = SDP_Tiers.DEFAULT }
  for _, flag in ipairs(extra or {}) do
    fields[#fields + 1] = { Key = flag.Key, Kind = flag.Kind or "flag", Min = flag.Min, Max = flag.Max, Pattern = flag.Pattern,
      Default = flag.Default }
  end
  return fields
end

-- A keeper (SDP_Settings.Keeper) for a tab: spec = { Tab, Columns, Weights
-- (the tab's table), Switches and Extra ({ Key, Default, Get, Put; Kind "number"
-- with Min, Max, "list" with Pattern, else a flag }), Tiers,
-- GetTier, PutTier, Presets and Order (default the planner's, SDP_Settings) }.
function SDP_UI.Keeper(spec)
  local columns, weights = spec.Columns, spec.Weights
  local switches = {}
  for _, switch in ipairs(spec.Switches or {}) do switches[#switches + 1] = switch end
  for _, flag in ipairs(spec.Extra or {}) do switches[#switches + 1] = flag end
  local getTier, putTier = spec.GetTier, spec.PutTier
  local fields = SDP_UI.SettingFields(columns, spec.Switches or {}, spec.Tiers, spec.Extra)
  return SDP_Settings.Keeper({
    Tab = spec.Tab, Fields = fields, Presets = spec.Presets or SDP_Settings.PRESETS,
    Order = spec.Order or SDP_Settings.PRESET_ORDER,
    Values = function()
      local values = {}
      for _, column in ipairs(columns) do values[column.Key] = weights[column.Key] end
      for _, switch in ipairs(switches) do values[switch.Key] = switch.Get() end
      values.TIER = getTier()
      return values
    end,
    Apply = function(values)
      for _, column in ipairs(columns) do weights[column.Key] = values[column.Key] end
      for _, switch in ipairs(switches) do switch.Put(values[switch.Key]) end
      putTier(values.TIER)
    end,
  })
end

-- ===========================================================================
-- Fold, fit, peek (issue 71)
-- ===========================================================================
-- A tab's fold line: the summary `text`; `folded` hides the settings stack.
function SDP_UI.ShowFold(button, label, action, stack, folded, text)
  label:SetText(text)
  action:SetText(Locale.Lookup(folded and "LOC_SDP_FOLD_SHOW" or "LOC_SDP_FOLD_HIDE"))
  button:SetToolTipString(Locale.Lookup("LOC_SDP_FOLD_TOOLTIP"))
  stack:SetHide(folded)
end

-- A preset's name on the pulldown and the fold line: `shown` (SDP_Settings.Match),
-- "Custom" when nil (issue 89).
function SDP_UI.PresetName(shown)
  if shown == nil then return Locale.Lookup("LOC_SDP_PRESET_CUSTOM") end
  return Locale.Lookup("LOC_SDP_PRESET_" .. shown)
end

-- The preset pulldown (issue 49): an entry a preset, the button shows the
-- preset the values equal (`shown`, nil for "Custom", issue 89).
-- spec = { Order (default the planner's presets), Tips (each preset's
-- LOC_SDP_PRESET_<name>_TOOLTIP, with SDP_Settings.FOCUS), CustomTip }.
-- onSelect(name).
function SDP_UI.ShowPreset(pull, shown, onSelect, spec)
  spec = spec or {}
  local function Tip(name)
    if not spec.Tips then return "" end
    return Locale.Lookup("LOC_SDP_PRESET_" .. name .. "_TOOLTIP", Number(SDP_Settings.FOCUS[name] or 1))
  end
  pull:ClearEntries()
  for _, name in ipairs(spec.Order or SDP_Settings.PRESET_ORDER) do
    local entry = {}
    pull:BuildEntry("InstanceOne", entry)
    entry.Button:SetText(Locale.Lookup("LOC_SDP_PRESET_" .. name))
    entry.Button:SetToolTipString(Tip(name))
    entry.Button:RegisterCallback(Mouse.eLClick, function() onSelect(name) end)
  end
  pull:CalculateInternals()
  pull:GetButton():SetText(SDP_UI.PresetName(shown))
  if shown == nil then
    pull:GetButton():SetToolTipString(Locale.Lookup(spec.CustomTip or "LOC_SDP_PRESET_CUSTOM_TOOLTIP"))
  else
    pull:GetButton():SetToolTipString(Tip(shown))
  end
end

-- The summary: the preset's name (`shown`, nil for "Custom"), then `parts`,
-- the settings that are not as usual.
function SDP_UI.FoldSummary(shown, parts)
  local list = { SDP_UI.PresetName(shown) }
  for _, part in ipairs(parts) do list[#list + 1] = part end
  return Locale.Lookup("LOC_SDP_FOLD_SUMMARY", Join(list, "LOC_SDP_FOLD_JOIN"))
end

-- The window's height for the screen (M1): from WINDOW_TOP down to
-- WINDOW_BELOW above the bottom, at least WINDOW_MIN. A page has the
-- window's height less PAGE_INSET (the title and the tabs above, 12 below).
SDP_UI.WINDOW_TOP = 85   -- the shadow's offset 60 and its padding 25
SDP_UI.WINDOW_BELOW = 35 -- the shadow's padding 25 and 10 more
SDP_UI.WINDOW_MIN = 640
SDP_UI.PAGE_INSET = 100
function SDP_UI.WindowHeight(screenHeight)
  return math.max(SDP_UI.WINDOW_MIN, screenHeight - SDP_UI.WINDOW_TOP - SDP_UI.WINDOW_BELOW)
end

-- The result list takes what the page has left (M1): the window's height
-- above or below the drawn 920 goes there, never below RESULT_MIN (a row).
SDP_UI.RESULT_MIN = 40
function SDP_UI.FitResults(body, page, scroll)
  scroll:SetSizeY(SDP_UI.RESULT_MIN)
  scroll:CalculateSize()
  body:CalculateSize()
  local height = SDP_UI.RESULT_MIN + math.max(0, page:GetSizeY() - body:GetSizeY())
  scroll:SetSizeY(height)
  scroll:CalculateSize()
  body:CalculateSize()
  return height
end

local m_keeper = SDP_UI.Keeper({ Tab = "SINGLE", Columns = SINGLE_COLUMNS, Weights = m_weights, Switches = SINGLE_SWITCHES,
  Extra = { { Key = "FOLD", Default = false, Get = function() return m_fold end, Put = function(v) m_fold = v end } },
  Tiers = SDP_Tiers.Single, GetTier = function() return m_tier end, PutTier = function(tier) m_tier = tier end })
local UpdateFold, SetPreset -- defined below (inputs)
-- Keep the tab's settings in the save after a change (issue 57), and show
-- them on the fold line.
-- Values equal to another preset make it the current one (issue 89).
local function Remember()
  m_preset = m_keeper.Match(m_preset) or m_preset
  m_keeper.Remember(m_preset)
  UpdateFold()
end
local function FitPage() SDP_UI.FitResults(Controls.Body, Controls.SinglePage, Controls.ResultScroll) end
-- Read them from the save the first time the panel shows for this player.
local function Restore()
  local kept = m_keeper.Restore()
  if kept ~= nil then m_preset = m_keeper.Match(kept.Preset) or kept.Preset end
end

-- How a coverage target (SDP_Coverage key) is called: one of the player's
-- cities ("C<id>") by its number and name, a city-center pin ("S<plot
-- index>") as "Site n" with the number SDP_City.SiteNumbers gives it.
function SDP_UI.TargetLabel(key)
  local playerID = Game.GetLocalPlayer()
  local id = tonumber(key:match("^C(%d+)$") or "")
  if id ~= nil then
    local city = CityManager.GetCity(playerID, id)
    if city == nil then return key end
    return Locale.Lookup("LOC_SDP_CITY_N", SDP_City.CityNumbers(playerID)[id] or 0, Locale.Lookup(city:GetName()))
  end
  local index = tonumber(key:match("^S(%d+)$") or "")
  if index ~= nil then
    local sites, names = SDP_City.Sites(playerID), {}
    for s, site in ipairs(sites) do names[s] = site.Name end
    local numbers = SDP_City.SiteNumbers(playerID, names)
    for s, site in ipairs(sites) do
      if site.Index == index then return Locale.Lookup("LOC_SDP_SITE_N", numbers[s]) end
    end
  end
  return key
end

-- Coverage on a result: label(key) names a target (default SDP_UI.TargetLabel).
-- The summary's tooltip lines: the newly covered cities by group.
function SDP_UI.CoverageLines(solution, label)
  label = label or SDP_UI.TargetLabel
  local lines = {}
  for _, entry in ipairs(solution.CoveredBy or {}) do
    local names = {}
    for _, key in ipairs(entry.Keys) do names[#names + 1] = label(key) end
    lines[#lines + 1] = Locale.Lookup("LOC_SDP_COVERAGE_GROUP", TypeName(entry.Group), #entry.Keys, Join(names))
  end
  if #lines == 0 then lines[1] = Locale.Lookup("LOC_SDP_COVERAGE_NOTHING") end
  return lines
end

-- A plan entry with a reach: "covers N" after `detail` and the cities under
-- `tip`, counting only the cities it newly covers (none: unchanged).
function SDP_UI.CoverageRow(p, detail, tip, label)
  if p.Reach == nil or #p.Reach == 0 then return detail, tip end
  label = label or SDP_UI.TargetLabel
  local names = {}
  for _, key in ipairs(p.Reach) do names[#names + 1] = label(key) end
  return detail .. "  " .. Locale.Lookup("LOC_SDP_COVERAGE_ROW", #p.Reach),
    tip .. "[NEWLINE][NEWLINE]" .. Locale.Lookup("LOC_SDP_COVERAGE_TIP", Join(names))
end

-- ===========================================================================
-- District states (feedback items 1, 4, 7): every plannable district is
--   MUST  placed for sure
--   POOL  a candidate: picked when the count asks for more than the MUST ones
--   OFF   left out
--   AUTO  added when the city needs it (aqueduct, dam: SDP_Rules.AutoKind)
-- Districts that take population default to POOL (OFF when the empire may
-- have only one: those are never picked), the others to AUTO when they can
-- be automatic, else OFF. A click goes POOL -> MUST -> OFF -> POOL, or
-- AUTO -> MUST -> OFF -> AUTO. A district whose buildings give yields to
-- the plots around it (Adjacent_AppealYieldChanges: the preserve) starts
-- OFF and cycles as the POOL ones (issue 91, decided 2026-10-26: few
-- civilizations build it; a player who wants it sets it to Must).
-- ===========================================================================
local function Limited(d) return d.MaxPerPlayer ~= nil and d.MaxPerPlayer > 0 end

-- The state a click cycles back to.
local function CycleState(d)
  if d.Specialty then return Limited(d) and "OFF" or "POOL" end
  return SDP_Rules.AutoKind(d.Type) ~= nil and "AUTO" or "OFF"
end

function SDP_UI.DefaultState(d)
  if d.Specialty and SDP_Appeal.Rules().Tiles[d.Type] ~= nil then return "OFF" end
  return CycleState(d)
end

function SDP_UI.NextState(d, state)
  local first = CycleState(d)
  if state == "MUST" then return "OFF" end
  if state == "OFF" then return first == "OFF" and "MUST" or first end
  return "MUST"
end

function SDP_UI.StateOf(states, d)
  return states[d.Type] or SDP_UI.DefaultState(d)
end

-- What a district list asks for, in type order: Must (types), Pool (types,
-- candidates that take population), Auto (set), MustSpecialty (count), and
-- Count, the districts that take population to plan (at least MustSpecialty,
-- at most MustSpecialty + #Pool; `count` nil: DEFAULT_COUNT, issue 71).
-- `status` (optional): [type] = reason the district cannot be planned (left out).
SDP_UI.DEFAULT_COUNT = 3
function SDP_UI.ListRequest(districts, states, count, status)
  if count == nil then count = SDP_UI.DEFAULT_COUNT end
  local out = { Must = {}, Pool = {}, Auto = {}, MustSpecialty = 0 }
  for _, d in ipairs(districts) do
    if status == nil or status[d.Type] == nil then
      local state = SDP_UI.StateOf(states, d)
      if state == "MUST" then
        out.Must[#out.Must + 1] = d.Type
        if d.Specialty then out.MustSpecialty = out.MustSpecialty + 1 end
      elseif state == "POOL" and d.Specialty and not Limited(d) then
        out.Pool[#out.Pool + 1] = d.Type
      elseif state == "AUTO" then
        out.Auto[d.Type] = true
      end
    end
  end
  out.Count = math.max(out.MustSpecialty, math.min(count, out.MustSpecialty + #out.Pool))
  out.Pick = out.Count - out.MustSpecialty
  return out
end

-- The districts the player set to "not wanted" themselves (a default OFF
-- state is no choice): a wonder's district is never supplied there (issue 66).
function SDP_UI.OffSet(states)
  local off = {}
  for districtType, state in pairs(states) do
    if state == "OFF" then off[districtType] = true end
  end
  return off
end

-- The districts the chosen wonders (types) need next to them that a city
-- does not have, built, pinned for it, required or added by itself (issue
-- 66): [district type] = the wonder. `scan` the city (SDP_City.Scan),
-- `states` its list. The player's own "not wanted" and a district the
-- required ones exclude are left out, as the solver does (SDP_Multi).
function SDP_UI.WonderNeeds(playerID, wonders, districts, states, scan, status)
  local needs = {}
  if scan == nil or #wonders == 0 then return needs end
  local must, has = {}, {}
  for _, d in ipairs(districts) do
    local state = SDP_UI.StateOf(states, d)
    if (status == nil or status[d.Type] == nil) and (state == "MUST" or state == "AUTO" and SDP_City.NeedsAuto(scan, d.Type)) then
      must[d.Type] = true
      has[SDP_Rules.BaseDistrict(d.Type)] = true
    end
  end
  for districtType in pairs(SDP_City.PresentDistricts(scan)) do has[SDP_Rules.BaseDistrict(districtType)] = true end
  local rows = {}
  for _, w in ipairs(SDP_Wonders.List(playerID)) do rows[w.Type] = w end
  for _, wonderType in ipairs(wonders) do
    local w = rows[wonderType]
    local base = w ~= nil and w.Status == nil and w.AdjacentDistrict or nil
    if base ~= nil and not has[base] then
      for _, d in ipairs(districts) do
        if SDP_Rules.BaseDistrict(d.Type) == base and (status == nil or status[d.Type] == nil) and states[d.Type] ~= "OFF"
            and SDP_Rules.ExcludedBy(d.Type, must) == nil then
          needs[d.Type] = wonderType
        end
      end
      has[base] = true
    end
  end
  return needs
end

-- A name in a fixed-width cell (TruncateWidth in the XML): one line in the
-- normal 14 point font; when that would cut it off (English names are
-- longer), two lines at 11 points. Cut off, with the full name as tooltip,
-- only when even that does not fit. `width`: the room for the name (80, a
-- district cell's, by default).
local function FitName(label, text, width)
  width = width or 80
  label:SetFontSize(14)
  label:SetWrapWidth(0)
  label:SetTruncateWidth(width)
  label:SetText(text)
  if label.IsTextTruncated ~= nil and label:IsTextTruncated() then
    label:SetFontSize(11)
    label:SetTruncateWidth(0)
    label:SetWrapWidth(width)
    label:SetText(text)
  end
end
SDP_UI.FitName = FitName

-- Show one district cell: its icon, name and state; the selected look for
-- MUST and AUTO; dimmed when OFF or when it cannot be planned (`status`).
function SDP_UI.ShowCell(inst, d, state, status)
  -- WONDER: shown for a district a chosen wonder needs (issue 66), not stored.
  local selected = status == nil and (state == "MUST" or state == "AUTO" or state == "WONDER")
  local name = Locale.Lookup(d.Name)
  local label = status and Locale.Lookup("LOC_SDP_STATUS_" .. status) or Locale.Lookup("LOC_SDP_STATE_" .. state)
  inst.Icon:SetIcon(d.Icon, 26)
  FitName(inst.Name, name)
  FitName(inst.NameDark, name)
  inst.State:SetText(label)
  inst.StateDark:SetText(label)
  inst.Selected:SetHide(not selected)
  inst.Name:SetHide(selected)
  inst.State:SetHide(selected)
  inst.NameDark:SetHide(not selected)
  inst.StateDark:SetHide(not selected)
  inst.Root:SetDisabled(status ~= nil)
  inst.Root:SetAlpha((status ~= nil or state == "OFF") and 0.55 or 1)
  -- No tooltip (issue 67): it repeated the name and state the cell shows and
  -- covered the cells below.
  inst.Root:SetToolTipString("")
end

-- Fill the two district grids (districts that take population, the others)
-- in name order. stateOf(d), statusOf(d) (or nil), onClick(d). Returns the
-- rows { Type, Name, State, Status, Group, Cell, Click } (tests).
function SDP_UI.BuildCells(im, otherIM, stack, otherStack, districts, stateOf, statusOf, onClick)
  im:ResetInstances()
  otherIM:ResetInstances()
  local display = {}
  for i, d in ipairs(districts) do display[i] = { District = d, Name = Locale.Lookup(d.Name) } end
  table.sort(display, function(a, b)
    if a.Name ~= b.Name then return Locale.Compare(a.Name, b.Name) == -1 end
    return a.District.Type < b.District.Type
  end)
  local rows = {}
  for _, entry in ipairs(display) do
    local d = entry.District
    local inst = (d.Specialty and im or otherIM):GetInstance()
    local state, status = stateOf(d), statusOf and statusOf(d) or nil
    SDP_UI.ShowCell(inst, d, state, status)
    local click = function() onClick(d) end
    inst.Root:RegisterCallback(Mouse.eLClick, click)
    -- Click: the function the cell calls on a click (in-game tests; the
    -- game's controls cannot be clicked from Lua).
    rows[#rows + 1] = { Type = d.Type, Name = entry.Name, State = state, Status = status,
      Group = d.Specialty and "SPECIALTY" or "OTHER", Cell = inst.Root, Click = click }
  end
  stack:CalculateSize()
  otherStack:CalculateSize()
  return rows
end

-- A pulldown entry whose text is wider than the entry (long English wonder
-- names such as Mausoleum at Halicarnassus): a smaller font.
local function FitEntry(button)
  local text = button.GetTextControl and button:GetTextControl()
  if text == nil then return end
  local room = button:GetSizeX() - 16
  for _, size in ipairs({ 12, 10 }) do
    if (text:GetSizeX() or 0) <= room then return end
    text:SetFontSize(size)
  end
end

-- Wonder tags (feedback item 2): one per chosen wonder, a click removes it;
-- the pulldown lists the others, a click adds one. onSet(type, on).
function SDP_UI.BuildWonders(pull, chipIM, chipStack, wonders, chosen, onSet)
  pull:ClearEntries()
  chipIM:ResetInstances()
  local count = 0
  for _, w in ipairs(wonders) do
    if w.Status == nil then
      local wonderType = w.Type
      local name = Locale.Lookup(w.Name)
      if chosen[wonderType] then
        count = count + 1
        local inst = chipIM:GetInstance()
        inst.Name:SetText(Locale.Lookup("LOC_SDP_WONDER_CHIP", name))
        inst.Root:SetSizeX(math.max(60, inst.Name:GetSizeX() + 20))
        inst.Root:SetToolTipString(Locale.Lookup("LOC_SDP_WONDER_CHIP_TOOLTIP"))
        inst.Root:RegisterCallback(Mouse.eLClick, function() onSet(wonderType, false) end)
      else
        local entry = {}
        pull:BuildEntry("InstanceOne", entry)
        entry.Button:SetText(name)
        local era = w.EraType and GameInfo.Eras[w.EraType]
        entry.Button:SetToolTipString(era and Locale.Lookup(era.Name) or "")
        entry.Button:RegisterCallback(Mouse.eLClick, function() onSet(wonderType, true) end)
        FitEntry(entry.Button)
      end
    end
  end
  pull:CalculateInternals()
  pull:GetButton():SetText(count == 0 and Locale.Lookup("LOC_SDP_WONDER_ADD")
    or Locale.Lookup("LOC_SDP_WONDER_ADD_MORE", count))
  chipStack:CalculateSize()
  return count
end

-- The summary line (issue 91, decided 2026-10-26): the weighted adjacency
-- first, then the other parts that are on, each on its own (tiles, distance,
-- housing, reach, in the weight row's order). The sum the solutions are
-- ranked by is not shown: late in the game the tiles the districts take can
-- outweigh their adjacency, and a negative total read as a bad plan.
function SDP_UI.SummaryText(s, parts)
  local list = SDP_UI.PartsList({ Land = s.LandDelta, Distance = s.CostDelta, Appeal = s.AppealDelta,
    Coverage = s.CoverageDelta }, parts)
  local adjacency = Signed(s.Adjacency or 0)
  if #list == 0 then return Locale.Lookup("LOC_SDP_RESULT_SUMMARY_ADJACENCY", adjacency) end
  return Locale.Lookup("LOC_SDP_RESULT_SUMMARY_OTHERS", adjacency, Join(list))
end

-- The parts other than the adjacency, in the summary's order, as texts:
-- tiles and distance when on, housing when there is a value, reach when on.
-- `skipZero`: leave out housing and reach that are 0 (a district's share).
local function Shown(value) return value ~= nil and math.abs(value) >= 0.05 end
function SDP_UI.PartsList(values, parts, skipZero)
  local list = {}
  if parts.Land then list[#list + 1] = Locale.Lookup("LOC_SDP_PART_LAND", Signed(values.Land or 0)) end
  if parts.Distance then list[#list + 1] = Locale.Lookup("LOC_SDP_PART_DISTANCE", Signed(values.Distance or 0)) end
  if values.Appeal ~= nil and (not skipZero or Shown(values.Appeal)) then
    list[#list + 1] = Locale.Lookup("LOC_SDP_PART_APPEAL", Signed(values.Appeal))
  end
  if parts.Coverage and (not skipZero or Shown(values.Coverage)) then
    list[#list + 1] = Locale.Lookup("LOC_SDP_PART_COVERAGE", Signed(values.Coverage or 0))
  end
  return list
end

-- A district's own parts (issue 126), the first line of its row's tooltip:
-- its weighted adjacency, then its share of the other parts (SDP_Search
-- SlotParts). `key` names the line (the district's or a city's).
function SDP_UI.PartsText(partValues, parts, key)
  if partValues == nil then return nil end
  local list = SDP_UI.PartsList(partValues, parts, true)
  local adjacency = Signed(partValues.Adjacency or 0)
  if #list == 0 then return Locale.Lookup(key, adjacency) end
  return Locale.Lookup(key .. "_OTHERS", adjacency, Join(list))
end

-- A district row's tooltip with its parts first.
function SDP_UI.PartsTip(p, parts, tip)
  local line = SDP_UI.PartsText(p.Parts, parts, "LOC_SDP_PARTS_DISTRICT")
  if line == nil then return tip end
  return line .. "[NEWLINE][NEWLINE]" .. tip
end

-- The summary tooltip's lines on the plan's parts (issue 126): the
-- adjacency by yield before and after the weights, and what the districts'
-- shares leave of each part (the change of the districts already there; the
-- tiles, housing and reach several districts share).
function SDP_UI.BreakdownLines(s, parts)
  local lines = {}
  if s.YieldAdjacency ~= nil then
    lines[#lines + 1] = Locale.Lookup("LOC_SDP_RESULT_BY_YIELD", YieldText(s.YieldAdjacency), YieldText(s.YieldWeighted))
  end
  local rest = s.Rest
  if rest ~= nil then
    local list = {}
    if Shown(rest.Adjacency) then list[#list + 1] = Locale.Lookup("LOC_SDP_PART_EXISTING", Signed(rest.Adjacency)) end
    if parts.Land and Shown(rest.Land) then list[#list + 1] = Locale.Lookup("LOC_SDP_PART_LAND", Signed(rest.Land)) end
    if Shown(rest.Appeal) then list[#list + 1] = Locale.Lookup("LOC_SDP_PART_APPEAL", Signed(rest.Appeal)) end
    if parts.Coverage and Shown(rest.Coverage) then
      list[#list + 1] = Locale.Lookup("LOC_SDP_PART_COVERAGE", Signed(rest.Coverage))
    end
    if #list > 0 then lines[#lines + 1] = Locale.Lookup("LOC_SDP_RESULT_REST", Join(list)) end
  end
  return lines
end

-- A solution button's label: its number and weighted adjacency, the
-- summary's first figure (issue 91); its tooltip: the summary, then `detail`.
function SDP_UI.SolutionLabel(n, s)
  return Locale.Lookup("LOC_SDP_SOLUTION_N", n, Signed(s.Adjacency or 0))
end

-- A reminder's text: the districts and what each would lose.
function SDP_UI.RemindText(remind)
  local parts = {}
  for _, loss in ipairs(remind.Losses) do
    local lost = {}
    for _, yieldType in ipairs(SDP_Rules.YIELDS) do
      if loss.Yields[yieldType] then
        lost[#lost + 1] = Locale.Lookup("LOC_SDP_YIELD_SHORT_" .. yieldType) .. "-" .. Number(loss.Yields[yieldType])
      end
    end
    parts[#parts + 1] = Locale.Lookup("LOC_SDP_REMIND_LOSS", TypeName(loss.Type), table.concat(lost, " "))
  end
  return Join(parts, "LOC_SDP_REMIND_JOIN")
end

-- Pin entries for a solution's reminders, named with the city number first
-- (SDP_Pins.Own then knows them as this mod's pins of that city).
function SDP_UI.RemindEntries(reminds, numberOf)
  local entries = {}
  for _, r in ipairs(reminds or {}) do
    local number = numberOf(r)
    entries[#entries + 1] = { Icon = SDP_Pins.REMIND_ICON, X = r.X, Y = r.Y,
      Name = (number and (tostring(number) .. " ") or "") .. Locale.Lookup("LOC_SDP_REMIND_PIN", SDP_UI.RemindText(r)) }
  end
  return entries
end

-- ===========================================================================
-- Open / close
-- ===========================================================================
local Refresh -- defined below
local UpdateReplaceLabel -- defined below
local SetWonder, ShowHeat, PopulateHeat -- defined below
local UpdateEstimate -- defined below

-- The launch bar button's tooltip (progress of a background computation)
-- and the mark that a result is ready.
-- The key that opens the panel as the game shows it, following the
-- player's binding (Options.lua does the same); nil when there is none.
local function OpenKey()
  if Input == nil or Input.GetActionId == nil or Input.GetGestureDisplayString == nil then return nil end
  local key = Input.GetGestureDisplayString(Input.GetActionId("SDP_OpenPlanner"), 0)
  if key == nil or key == false or key == "" then return nil end
  return key
end

local function LaunchToolTip(text)
  if m_launchItem.LaunchItemButton ~= nil then
    if text == nil then
      text = Locale.Lookup("LOC_SDP_LAUNCHBAR_TOOLTIP", VERSION)
      local key = OpenKey()
      if key ~= nil then text = text .. "[NEWLINE]" .. Locale.Lookup("LOC_SDP_LAUNCHBAR_KEY", key) end
    end
    m_launchItem.LaunchItemButton:SetToolTipString(text)
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
SDP_UI.IsOpen = IsOpen

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

-- Follow the city selected on the map (issue 63): a city selected since the
-- panel last opened becomes the single-city tab's city and the centre of
-- the Several cities tab's default group, and the panel opens on the
-- single-city tab (issue 76; true then). Not while a computation runs (its
-- result would go); that selection is then passed over, not kept for later.
local m_followed = nil -- the selected city (ID) when the panel last opened
local FollowSelection -- defined below (after SelectCity)

-- Peek (M3): the window hidden, the panel still open, so the map preview
-- stays; a button where the window was, and Esc, bring it back. The context
-- stays shown (pitfall 23: a hidden one gets no updates).
local function SetPeek(on)
  on = on == true and IsOpen()
  m_peek = on
  Controls.DropShadow:SetHide(on)
  Controls.PeekReturn:SetHide(not on)
  -- The city sites tab: its sites one after another on the map (issue 75).
  Controls.PeekNextSite:SetHide(not (on and m_tab == "SITES" and SDP_PageSites.CanStep()))
end

-- The window's height for the screen (M1), then the open tab's page.
local m_fitPages = {} -- [tab] = function that fits its page (FitPage, the tabs' P.FitPage)
local function FitWindow()
  local screenHeight = nil
  if UIManager.GetScreenSizeVal ~= nil then
    local _, h = UIManager:GetScreenSizeVal()
    screenHeight = h
  end
  if screenHeight == nil or screenHeight <= 0 then return end
  local height = SDP_UI.WindowHeight(screenHeight)
  Controls.Window:SetSizeY(height)
  for _, page in ipairs({ Controls.SinglePage, Controls.SitesPage, Controls.MultiPage }) do
    page:SetSizeY(height - SDP_UI.PAGE_INSET)
  end
  SDP_UI.WindowFitted = height -- tests
  if m_fitPages[m_tab] ~= nil then m_fitPages[m_tab]() end
end

local function Open()
  if IsOpen() then return end
  if m_launchDone then SetLaunchMark(false) end
  if FollowSelection() then m_tab = "SINGLE" end
  SelectTab(m_tab)
  Controls.DropShadow:SetHide(false)
  UIManager:QueuePopup(ContextPtr, PopupPriority.Low)
  UI.PlaySound("UI_Screen_Open")
end

local function Close()
  if not IsOpen() then return end
  SetPeek(false)
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

local Request -- defined below

local function UpdateButtons()
  local plan = m_result and m_result.Ok and m_result.Plan or {}
  local running = SDP_Task.IsRunning()
  -- Nothing to plan (no required district, the count 0, no wonder): greyed
  -- out, and the summary says what to do (issue 67).
  Controls.SolveButton:SetDisabled(m_cityID == nil or running or Request() == nil)
  Controls.ContinueButton:SetDisabled(running or not CanContinue())
  Controls.ContinueButton:SetHide(running)
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
  -- The English parts start in lower case, whichever comes first; the line
  -- starts with a capital (Chinese text has no case and is left as it is).
  -- Not gsub("^%l", ...): the game's Lua replaces twice there (pitfall 39).
  local text = Join(parts)
  return text:sub(1, 1):upper() .. text:sub(2)
end
SDP_UI.QualityText = QualityText

-- A result row (ResultRow instance); with x, y a click moves the camera to
-- that plot (issue 67), and the row lights up under the mouse and says so
-- first in its tooltip (issue 75). Shared with the other tabs, which keep
-- their rows.
function SDP_UI.ResultRow(inst, icon, name, detail, toolTip, x, y)
  inst.Icon:SetIcon(icon, 32)
  inst.Name:SetText(name)
  inst.Detail:SetText(detail)
  FitResultRow(inst)
  inst.HoverArea:SetHide(x == nil)
  local tip = toolTip or ""
  if x ~= nil then
    tip = Locale.Lookup("LOC_SDP_RESULT_LOOK") .. (tip ~= "" and ("[NEWLINE]" .. tip) or "")
  end
  inst.Root:SetToolTipString(tip)
  inst.Root:RegisterCallback(Mouse.eLClick, function()
    if x ~= nil then
      LookAt(x, y)
      UI.PlaySound("Play_UI_Click")
    end
  end)
  return { Icon = icon, Name = name, Detail = detail, ToolTip = toolTip, X = x, Y = y, Row = inst.Root }
end

local function AddResultRow(icon, name, detail, toolTip, x, y)
  m_resultRows[#m_resultRows + 1] = SDP_UI.ResultRow(m_resultIM:GetInstance(), icon, name, detail, toolTip, x, y)
end

-- What a plan entry is beyond its yields: added by itself, picked from the
-- pool; what the city has to do first: own the plot (grow into it, buy it,
-- or swap it from another city), research the technology that clears its
-- feature or harvests its resource, clear or harvest it.
function SDP_UI.PlanNote(p)
  local notes = {}
  if p.Auto then notes[#notes + 1] = Locale.Lookup("LOC_SDP_RESULT_AUTO") end
  if p.ForWonder then notes[#notes + 1] = Locale.Lookup("LOC_SDP_RESULT_FOR_WONDER", TypeName(p.ForWonder)) end
  if p.Picked then notes[#notes + 1] = Locale.Lookup("LOC_SDP_RESULT_PICKED") end
  if p.Unowned then notes[#notes + 1] = Locale.Lookup("LOC_SDP_RESULT_UNOWNED") end
  if p.Swap ~= nil then
    local city = CityManager.GetCity(Game.GetLocalPlayer(), p.Swap)
    notes[#notes + 1] = Locale.Lookup("LOC_SDP_RESULT_SWAP", city ~= nil and Locale.Lookup(city:GetName()) or "")
  end
  if p.RemoveTech ~= nil then
    local tech = GameInfo.Technologies[p.RemoveTech]
    notes[#notes + 1] = Locale.Lookup("LOC_SDP_RESULT_NEEDS_TECH", tech and Locale.Lookup(tech.Name) or p.RemoveTech)
  end
  if p.ClearFirst then notes[#notes + 1] = Locale.Lookup("LOC_SDP_RESULT_CLEAR_FIRST") end
  if #notes == 0 then return "" end
  return "  " .. table.concat(notes, " ")
end

-- The improvement a planned wonder needs next to it (issue 51, a Camp for
-- the Temple of Artemis): a result row after the wonder's (`indent` before
-- its name), a preview icon, a tack named like the wonder's.
function SDP_UI.SupportRow(p, add, indent)
  local s = p.Support
  if s == nil then return end
  add("ICON_" .. s.Type, (indent or "") .. TypeName(s.Type) .. "  " .. Where(s.X, s.Y),
    Locale.Lookup("LOC_SDP_RESULT_SUPPORT", TypeName(p.Type)) .. SDP_UI.PlanNote({ Unowned = s.Unowned }),
    Locale.Lookup("LOC_SDP_RESULT_SUPPORT_TOOLTIP", TypeName(p.Type), TypeName(s.Type)), s.X, s.Y)
end

function SDP_UI.SupportIcons(plan, icons)
  for _, p in ipairs(plan) do
    local s = p.Support
    if s ~= nil then icons[#icons + 1] = { X = s.X, Y = s.Y, Icon = "ICON_" .. s.Type, Text = "" } end
  end
end

function SDP_UI.SupportEntry(p, name)
  local s = p.Support
  if s == nil then return nil end
  return { Type = s.Type, X = s.X, Y = s.Y, Name = name }
end

-- The switch for partner districts (SDP_Rules.Apart, 2026-10-21 feedback):
-- the label names the pair (several pairs: a general label), the tooltip
-- gives the rule as the game's data states it; hidden when the rules have
-- no such pair for the player's districts (SDP_Rules.ApartFor).
function SDP_UI.ShowApart(box, check, label, on)
  local pairs = SDP_Rules.ApartFor(Game.GetLocalPlayer())
  box:SetHide(#pairs == 0)
  check:SetCheck(on)
  if #pairs == 0 then return end
  if #pairs == 1 then
    label:SetText(Locale.Lookup("LOC_SDP_APART_SHORT", TypeName(pairs[1].A), TypeName(pairs[1].B)))
  else
    label:SetText(Locale.Lookup("LOC_SDP_APART_SHORT_ANY"))
  end
  local rules = {}
  for _, pair in ipairs(pairs) do
    rules[#rules + 1] = Locale.Lookup("LOC_SDP_APART_RULE", TypeName(pair.Building), TypeName(pair.Other), TypeName(pair.A),
      TypeName(pair.B))
  end
  box:SetToolTipString(Locale.Lookup("LOC_SDP_APART_TOOLTIP", table.concat(rules, "[NEWLINE]")))
end

-- Result rows for partner districts a plan leaves in one city
-- (Together); `city` names the city (several cities) or is nil.
-- Housing the plan takes from improvements (SDP_Appeal), as one row.
function SDP_UI.ImprovementHousingRow(lost, add)
  if lost ~= nil and lost < 0 then
    add("ICON_IMPROVEMENT_FARM", Locale.Lookup("LOC_SDP_RESULT_IMPROVEMENT_HOUSING"),
      Locale.Lookup("LOC_SDP_RESULT_IMPROVEMENT_HOUSING_DETAIL", lost), Locale.Lookup("LOC_SDP_RESULT_IMPROVEMENT_HOUSING_TOOLTIP"))
  end
end

function SDP_UI.TogetherRows(together, city, add)
  for _, t in ipairs(together or {}) do
    local name = city and Locale.Lookup("LOC_SDP_RESULT_TOGETHER_CITY", city, TypeName(t.A), TypeName(t.B))
      or Locale.Lookup("LOC_SDP_RESULT_TOGETHER", TypeName(t.A), TypeName(t.B))
    add("ICON_" .. t.A, name, Locale.Lookup("LOC_SDP_RESULT_TOGETHER_DETAIL", TypeName(t.Building)),
      Locale.Lookup("LOC_SDP_APART_RULE", TypeName(t.Building), TypeName(t.Other), TypeName(t.A), TypeName(t.B)))
  end
end

-- A plan entry's detail: its adjacency yields, then for a district that
-- depends on appeal its housing (and its plot's appeal) and a preserve's
-- yields on the plots around it.
function SDP_UI.PlanDetail(p)
  local parts = {}
  local yields = YieldText(p.Yields)
  if p.Housing == nil or yields ~= Locale.Lookup("LOC_SDP_NO_YIELDS") then parts[#parts + 1] = yields end
  if p.Housing ~= nil then parts[#parts + 1] = Locale.Lookup("LOC_SDP_RESULT_HOUSING", Signed(p.Housing), Signed(p.Appeal or 0)) end
  if p.Tiles ~= nil then
    local tiles = {}
    for _, yieldType in ipairs(SDP_Land.TILE_YIELDS) do
      local amount = p.Tiles[yieldType]
      if amount ~= nil and amount ~= 0 then
        tiles[#tiles + 1] = Locale.Lookup("LOC_SDP_YIELD_SHORT_" .. yieldType) .. Signed(amount)
      end
    end
    if #tiles > 0 then
      -- Shown, not scored: a preserve picked from the pool (SDP_Appeal
      -- Optional), or the Tiles weight at 0 (they belong to the tiles, issue 91).
      local key = "LOC_SDP_RESULT_TILES"
      if p.TilesCounted == false then
        key = p.TilesReason == "LAND" and "LOC_SDP_RESULT_TILES_LAND_OFF" or "LOC_SDP_RESULT_TILES_UNCOUNTED"
      end
      parts[#parts + 1] = Locale.Lookup(key, table.concat(tiles, " "))
    end
  end
  return table.concat(parts, "  ") .. SDP_UI.PlanNote(p)
end

-- A solution row's detail: the districts picked from the pool, or how many.
function SDP_UI.SolutionDetail(solution)
  local picked = solution.Picked or {}
  if #picked > 0 then
    local names = {}
    for _, t in ipairs(picked) do names[#names + 1] = TypeName(t) end
    return Locale.Lookup("LOC_SDP_SOLUTION_PICKED", Join(names))
  end
  return Locale.Lookup("LOC_SDP_SOLUTION_DISTRICTS", #solution.Plan)
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
  local icons = {}
  for _, p in ipairs(solution.Plan) do
    icons[#icons + 1] = { X = p.X, Y = p.Y, Icon = "ICON_" .. p.Type, Text = PinText(p.Yields) }
  end
  SDP_UI.SupportIcons(solution.Plan, icons)
  for _, r in ipairs(solution.Remind or {}) do
    icons[#icons + 1] = { X = r.X, Y = r.Y, Icon = SDP_Pins.REMIND_ICON, Text = "" }
  end
  SDP_Preview.Show(Game.GetLocalPlayer(), { { Plots = plots, Color = 1 } }, icons)
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
    local shown = solutions[m_solution] or result
    local request = result.Session and result.Session.Request or {}
    local summaryParts = { Land = request.Land, Distance = (request.Distance or 0) > 0, Coverage = shown.Covered ~= nil }
    Controls.Summary:SetText(SDP_UI.SummaryText(shown, summaryParts))
    -- How the solutions are ranked, and the cities the plan covers; the
    -- search's counts (result.Stats) are for tests, not the player (issue 67).
    local tip = Locale.Lookup("LOC_SDP_RESULT_RANKED")
    if shown.Covered ~= nil then tip = tip .. "[NEWLINE][NEWLINE]" .. table.concat(SDP_UI.CoverageLines(shown), "[NEWLINE]") end
    local breakdown = SDP_UI.BreakdownLines(shown, summaryParts)
    if #breakdown > 0 then tip = table.concat(breakdown, "[NEWLINE]") .. "[NEWLINE][NEWLINE]" .. tip end
    Controls.Summary:SetToolTipString(tip)
    Controls.Quality:SetText(QualityText(result))
    -- The solutions (feedback item 1): a click shows one and previews it.
    if #solutions > 1 then
      for n, sol in ipairs(solutions) do
        local inst = m_solutionIM:GetInstance()
        m_solutionCells[n] = inst.Root
        SDP_UI.SolutionRow(inst, SDP_UI.SolutionLabel(n, sol),
          SDP_UI.SummaryText(sol, summaryParts) .. "[NEWLINE]" .. SDP_UI.SolutionDetail(sol), n == m_solution)
        inst.Root:RegisterCallback(Mouse.eLClick, function()
          m_solution = n
          m_lookNext = true
          ShowResult()
        end)
      end
    end
    -- What the plan leaves out comes first, so a long list does not hide it
    -- (issue 60).
    for _, u in ipairs(shown.Unplaced or result.Unplaced or {}) do
      AddResultRow("ICON_" .. u.Type, SDP_UI.UnplacedName(u), SDP_UI.ReasonText(u), UnplacedTip(u))
    end
    -- Each planned district: where, its yields, and DMT's own breakdown on hover.
    for _, p in ipairs(shown.Plan) do
      local toolTip = (p.ToolTip ~= nil and p.ToolTip ~= "") and p.ToolTip or Locale.Lookup("LOC_SDP_NO_ADJACENCY")
      local detail
      detail, toolTip = SDP_UI.CoverageRow(p, SDP_UI.PlanDetail(p), toolTip)
      toolTip = SDP_UI.PartsTip(p, summaryParts, toolTip)
      AddResultRow("ICON_" .. p.Type, TypeName(p.Type) .. "  " .. Where(p.X, p.Y), detail, toolTip, p.X, p.Y)
      SDP_UI.SupportRow(p, AddResultRow, "  ")
    end
    -- Woods and rainforest the plan relies on (feedback item 5).
    for _, r in ipairs(shown.Remind or {}) do
      AddResultRow(SDP_Pins.REMIND_ICON, Locale.Lookup("LOC_SDP_RESULT_REMIND", TypeName(r.Feature), Where(r.X, r.Y)),
        SDP_UI.RemindText(r), Locale.Lookup("LOC_SDP_REMIND_TOOLTIP"), r.X, r.Y)
    end
    -- Districts and locked pins whose adjacency the plan changes.
    for _, n in ipairs(shown.Neighbours or {}) do
      local s = n.Subject
      AddResultRow("ICON_" .. s.Key, Locale.Lookup("LOC_SDP_RESULT_NEIGHBOUR", TypeName(s.Key), Where(s.X, s.Y)),
        Locale.Lookup("LOC_SDP_RESULT_NEIGHBOUR_DETAIL", Number(n.Before), Number(n.After)),
        (n.ToolTip ~= nil and n.ToolTip ~= "") and n.ToolTip or Locale.Lookup("LOC_SDP_NO_ADJACENCY"), s.X, s.Y)
    end
    -- Partner districts left together (required ones, or the count needed them).
    local together = shown.Together
    if together == nil and shown.Cities ~= nil and shown.Cities[1] ~= nil then together = shown.Cities[1].Together end
    SDP_UI.TogetherRows(together, nil, AddResultRow)
    SDP_UI.ImprovementHousingRow(shown.ImprovementHousing, AddResultRow)
    Preview(m_solution)
    -- A new result or another solution: the city beside the panel (issue
    -- 67); not on reopening the panel or changing a setting.
    if m_lookNext and IsOpen() and m_scan ~= nil then
      m_lookNext = false
      LookAt(m_scan.X, m_scan.Y)
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
  local job = SDP_Task.Current()
  if job ~= nil and job.Page == "SINGLE" then SDP_Task.Cancel() end
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
  return SDP_UI.ListRequest(m_districts, m_states, m_count, m_status)
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
  Controls.CountValue:SetText(tostring(list.Count))
  Controls.CountLess:SetDisabled(list.Count <= list.MustSpecialty)
  Controls.CountMore:SetDisabled(list.Count >= list.MustSpecialty + #list.Pool)
end

local SetState -- defined below

local SelectedWonders -- defined below

local function ShowCells()
  -- A district a chosen wonder needs shows "for wonder" (issue 66); a click
  -- goes on from its own state.
  local needs = SDP_UI.WonderNeeds(Game.GetLocalPlayer(), SelectedWonders(), m_districts, m_states, m_scan, m_status)
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

-- How many districts that take population to plan (clamped to what the
-- states allow; at the required number nothing is picked).
local function SetCount(count)
  local list = SDP_UI.ListRequest(m_districts, m_states, count, m_status)
  if list.Count ~= List().Count then
    m_count = list.Count
    ClearResult()
  else
    m_count = list.Count
  end
  ShowCount()
  UpdateSpecialtyNote()
  UpdateEstimate()
end

local function RefreshDistricts()
  local playerID = Game.GetLocalPlayer()
  m_districts = SDP_Rules.PlannableDistricts(playerID)
  m_scan = m_cityID and SDP_City.Scan(playerID, m_cityID) or nil
  m_status = m_scan and SDP_City.DistrictStatus(m_scan, m_districts) or {}
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
  if cityID == m_followed then return false end
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

local function SetWeight(key, value)
  value = math.max(0, math.min(MAX_WEIGHT, value))
  if m_weights[key] ~= value then
    m_weights[key] = value
    ClearResult()
    Remember()
  end
  if m_weightViews[key] then m_weightViews[key]() end
end

-- Weight columns for a tab: `columns` like WEIGHT_COLUMNS, `weights` the
-- tab's table, isOff(column) greys a column out, onChange(key, value),
-- width (optional) the column width when more columns must fit. A column's
-- Step (default 1) is how much an arrow changes it.
-- Returns { [key] = redraw function } and the columns' controls in order
-- ({ Key, Less, More, Value, Root }, for tests).
function SDP_UI.BuildWeights(im, stack, columns, weights, isOff, onChange, width)
  im:ResetInstances()
  local views, cells = {}, {}
  for _, column in ipairs(columns) do
    local key = column.Key
    local step = column.Step or 0.5
    local inst = im:GetInstance()
    if width ~= nil then inst.Root:SetSizeX(width) end
    local function Show()
      local off = isOff and isOff(column) or false
      inst.Value:SetText(Number(weights[key]))
      inst.Less:SetDisabled(off or weights[key] <= 0)
      inst.More:SetDisabled(off or weights[key] >= MAX_WEIGHT)
      inst.Root:SetAlpha(off and 0.5 or 1)
    end
    inst.Glyph:SetText(Locale.Lookup(column.Glyph))
    local row = GameInfo.Yields[key]
    inst.Root:SetToolTipString(Locale.Lookup(column.ToolTip or (row and row.Name) or key))
    inst.Less:RegisterCallback(Mouse.eLClick, function() onChange(key, math.max(0, weights[key] - step)) end)
    inst.More:RegisterCallback(Mouse.eLClick, function() onChange(key, math.min(MAX_WEIGHT, weights[key] + step)) end)
    views[key] = Show
    cells[#cells + 1] = { Key = key, Less = inst.Less, More = inst.More, Value = inst.Value, Root = inst.Root }
    Show()
  end
  stack:CalculateSize()
  return views, cells
end

local function BuildWeights()
  m_weightViews, m_weightCells = SDP_UI.BuildWeights(m_weightIM, Controls.WeightStack, SINGLE_COLUMNS, m_weights, nil,
    SetWeight, WEIGHT_WIDTH)
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

-- A SolutionRow instance, one button of a row of three (issue 71): its
-- name and the selected look (light text on the dark button, dark text on
-- the light selected look); the detail (the districts picked) is the tooltip.
function SDP_UI.SolutionRow(inst, name, detail, selected)
  inst.Name:SetText(name)
  inst.NameDark:SetText(name)
  inst.Root:SetToolTipString(detail or "")
  inst.Selected:SetHide(not selected)
  inst.Name:SetHide(selected)
  inst.NameDark:SetHide(not selected)
end

-- "About X s" for `units` of work.
function SDP_UI.EstimateText(units, atOnce)
  if units <= 0 then return "" end
  local seconds = SDP_Task.EstimateSeconds(units, atOnce)
  if seconds < 1 then return Locale.Lookup("LOC_SDP_ESTIMATE_UNDER_ONE") end
  return Locale.Lookup("LOC_SDP_ESTIMATE", Number(math.floor(seconds + 0.5)))
end

local function SetSwap(on)
  Controls.SwapCheck:SetCheck(on)
  if m_swap ~= on then
    m_swap = on
    ClearResult()
    Remember()
  end
end

local function SetAllowFeatureRemoval(allow)
  Controls.FeatureCheck:SetCheck(allow)
  if m_allowFeatureRemoval ~= allow then
    m_allowFeatureRemoval = allow
    ClearResult()
    Remember()
  end
end

-- This mod's earlier pins for the selected city (the ones "replace" removes).
local function OwnPins()
  if m_cityID == nil then return {} end
  local playerID = Game.GetLocalPlayer()
  return SDP_Pins.Own(playerID, { SDP_City.CityNumbers(playerID)[m_cityID] })
end

UpdateReplaceLabel = function()
  Controls.ReplaceLabel:SetText(Locale.Lookup("LOC_SDP_REPLACE_OWN_SHORT", #OwnPins()))
end

local function SetReplace(on)
  Controls.ReplaceCheck:SetCheck(on)
  if m_replace ~= on then
    m_replace = on
    ClearResult()
    Remember()
  end
end

local function SetApart(on)
  Controls.ApartCheck:SetCheck(on)
  if m_apart ~= on then
    m_apart = on
    ClearResult()
    Remember()
  end
end

-- Reminder pins only change what "place" puts on the map.
local function SetRemind(on)
  Controls.RemindCheck:SetCheck(on)
  if m_remind ~= on then
    m_remind = on
    ClearResult()
    Remember()
  end
end

-- Wonders to place with the districts (design 18, item 5): selectable ones,
-- in type order (the solver's slot order, independent of the list's order).
SelectedWonders = function()
  local list = {}
  for _, w in ipairs(SDP_Wonders.List(Game.GetLocalPlayer())) do
    if m_wonders[w.Type] and w.Status == nil then list[#list + 1] = w.Type end
  end
  table.sort(list)
  return list
end

local function PopulateWonders()
  SDP_UI.BuildWonders(Controls.WonderPull, m_chipIM, Controls.WonderChipStack, SDP_Wonders.List(Game.GetLocalPlayer()),
    m_wonders, function(wonderType, on) SetWonder(wonderType, on) end)
end

SetWonder = function(wonderType, on)
  if (m_wonders[wonderType] == true) ~= (on == true) then
    m_wonders[wonderType] = on or nil
    ClearResult()
  end
  PopulateWonders()
  ShowCells()
  UpdateEstimate()
  UpdateFold()
end

-- The fold line: the preset, then what is not as usual (land part off,
-- clearing off, swaps, replacing, wonders, the good places shown).
UpdateFold = function()
  local parts = {}
  if m_weights.LAND == 0 then parts[#parts + 1] = Locale.Lookup("LOC_SDP_FOLD_LAND_OFF") end
  if not m_allowFeatureRemoval then parts[#parts + 1] = Locale.Lookup("LOC_SDP_FOLD_NO_REMOVAL") end
  if m_swap then parts[#parts + 1] = Locale.Lookup("LOC_SDP_FOLD_SWAP") end
  if m_replace then parts[#parts + 1] = Locale.Lookup("LOC_SDP_FOLD_REPLACE") end
  local wonders = #SelectedWonders()
  if wonders > 0 then parts[#parts + 1] = Locale.Lookup("LOC_SDP_FOLD_WONDERS", wonders) end
  if m_heat ~= nil then parts[#parts + 1] = Locale.Lookup("LOC_SDP_FOLD_HEAT", TypeName(m_heat)) end
  local shown = m_keeper.Match(m_preset)
  SDP_UI.ShowFold(Controls.FoldButton, Controls.FoldText, Controls.FoldAction, Controls.SettingsStack, m_fold,
    SDP_UI.FoldSummary(shown, parts))
  SDP_UI.ShowPreset(Controls.PresetPull, shown, function(name) SetPreset(name) end, { Tips = true })
end

-- A preset (issue 49): its weights and switches; the tier and the fold stay.
-- The same preset again puts back what was changed (issue 89: no Reset).
SetPreset = function(name)
  if not m_keeper.Use(name) then return end
  m_preset = name
  ClearResult()
  for _, view in pairs(m_weightViews) do view() end
  Controls.FeatureCheck:SetCheck(m_allowFeatureRemoval)
  Controls.SwapCheck:SetCheck(m_swap)
  Controls.ReplaceCheck:SetCheck(m_replace)
  Controls.RemindCheck:SetCheck(m_remind)
  Controls.ApartCheck:SetCheck(m_apart)
  Remember()
  UpdateEstimate()
end

-- Fold or unfold the settings (M2): after a solve, or a click on the line.
local function SetFold(on)
  if m_fold ~= on then
    m_fold = on
    Remember()
  end
  UpdateFold()
  FitPage()
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
      icons[#icons + 1] = { X = spot.X, Y = spot.Y, Icon = "ICON_" .. districtType, Text = PinText(spot.Yields) }
    end
    SDP_Preview.Show(playerID, areas, icons)
    m_heatSpots = spots
    label = TypeName(districtType)
  else
    m_heatSpots = nil
  end
  Controls.HeatPull:GetButton():SetText(label)
  UpdateFold()
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

-- Tests and older callers: the land part on (weight 1 unless it is set) or off (0).
local function SetLand(on)
  if on then
    if m_weights.LAND == 0 then SetWeight("LAND", 1) end
  else
    SetWeight("LAND", 0)
  end
end

local function SetTier(tier)
  if SDP_Tiers.Single[tier] == nil then return end
  if m_tier ~= tier then
    m_tier = tier
    ClearResult()
    Remember()
  end
  Controls.TierPull:GetButton():SetText(Locale.Lookup("LOC_SDP_TIER_" .. tier))
  UpdateEstimate()
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
  Restore()
  PopulateCities()
  RefreshDistricts()
  BuildWeights()
  SDP_UI.PopulateTierPull(Controls.TierPull, m_tier, SetTier)
  Controls.FeatureCheck:SetCheck(m_allowFeatureRemoval)
  Controls.SwapCheck:SetCheck(m_swap)
  Controls.ReplaceCheck:SetCheck(m_replace)
  Controls.RemindCheck:SetCheck(m_remind)
  SDP_UI.ShowApart(Controls.ApartBox, Controls.ApartCheck, Controls.ApartLabel, m_apart)
  UpdateReplaceLabel()
  PopulateWonders()
  m_heat = nil
  PopulateHeat()
  UpdateEstimate()
  UpdateFold()
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

Request = function()
  local list = List()
  local wonders = SelectedWonders()
  if m_cityID == nil or (#list.Must == 0 and list.Pick == 0 and #wonders == 0) then return nil end
  local weights = {}
  for key, value in pairs(m_weights) do weights[key] = value end
  return {
    PlayerID = Game.GetLocalPlayer(), CityID = m_cityID, Districts = list.Must, Weights = weights,
    Pool = list.Pool, Count = list.Count, MustSpecialty = list.MustSpecialty, Auto = list.Auto,
    Distance = m_weights.DISTANCE, Coverage = m_weights.COVERAGE, Remind = m_remind, Apart = m_apart,
    AllowFeatureRemoval = m_allowFeatureRemoval, Land = m_weights.LAND > 0, Tier = m_tier, Swap = m_swap,
    IgnorePins = m_replace and OwnPins() or nil, Wonders = wonders, Off = SDP_UI.OffSet(m_states),
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
  }
end

-- Solve now (fast and standard tiers without picking: returns the result) or
-- start a sliced computation (returns nil, the result shows when it is done).
local function Solve()
  if SDP_Task.IsRunning() then return nil end
  local request = Request()
  if m_heat ~= nil then ShowHeat(nil) end
  m_solution = 1
  m_lookNext = true
  -- The settings fold away after a solve (M2): the results get the room.
  if request ~= nil then SetFold(true) end
  if request ~= nil and #request.Wonders > 0 then
    local multi = WonderRequest(request)
    m_result = nil
    StartTask(function() return SDP_Multi.SolveNow(multi) end, EstimateFor(request), function(result) m_result = result end)
    return nil
  end
  if request ~= nil and Sliced(request) then
    local scan = SDP_City.Scan(request.PlayerID, request.CityID, SDP_City.ScanOptions(request))
    if scan ~= nil then
      m_result = nil
      StartTask(function() return SDP_Solver.SolveScan(request, scan) end, EstimateFor(request),
        function(result) m_result = result end)
      return nil
    end
  end
  m_result = request and SDP_Solver.Solve(request) or nil
  ShowResult()
  return m_result
end

-- One more batch on the shown result (design 7.3).
local function Continue()
  if SDP_Task.IsRunning() or not CanContinue() then return nil end
  m_lookNext = true
  local session = m_result.Session
  if session.Params.Sliced or session.Pick ~= nil and session.Pick > 0 or session.Participants ~= nil then
    -- A continue runs SINGLE_CONTINUE_STARTS local searches; the first run
    -- had Starts + Kicks of them.
    local params = session.Params
    local estimate = EstimateFor(session.Request) * SDP_Tiers.SINGLE_CONTINUE_STARTS / math.max(1, params.Starts + (params.Kicks or 0))
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

-- Map tacks for the shown solution, with its reminder pins when asked for.
local function PlacePins()
  if SDP_Task.IsRunning() or m_result == nil or not m_result.Ok or m_result.Placed then return 0 end
  local playerID = Game.GetLocalPlayer()
  local solution = (m_result.Solutions and m_result.Solutions[m_solution]) or m_result
  local number = SDP_City.CityNumbers(playerID)[m_cityID]
  local entries = {}
  for _, p in ipairs(solution.Plan) do
    entries[#entries + 1] = { Type = p.Type, X = p.X, Y = p.Y, Name = tostring(number or "") }
    entries[#entries + 1] = SDP_UI.SupportEntry(p, tostring(number or ""))
  end
  if m_remind then
    for _, e in ipairs(SDP_UI.RemindEntries(solution.Remind, function() return number end)) do entries[#entries + 1] = e end
  end
  -- The plan was made as if this mod's earlier pins were gone: remove them.
  local session = m_result.Session
  local placed = SDP_Pins.Place(playerID, entries, { Replace = session and session.Request.IgnorePins })
  m_result.Placed = true
  SDP_Preview.Clear()
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
m_fitPages.SINGLE, m_fitPages.SITES, m_fitPages.MULTI = FitPage, SDP_PageSites.FitPage, SDP_PageMulti.FitPage

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
  LaunchToolTip()
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
  FitWindow()
  Restore()
  SDP_PageSites.Restore()
  SDP_PageMulti.Restore()
end

local function OnInput(uiMsg, wParam)
  if uiMsg == KeyEvents.KeyUp and wParam == Keys.VK_ESCAPE and IsOpen() then
    -- Esc from a peek brings the window back (M3); else it closes the panel.
    if m_peek then SetPeek(false) else Close() end
    return true
  end
  return false
end

local function OnUpdateUI(type)
  if type == SystemUpdateUI.ScreenResize then FitWindow() end
end

local function OnInit(isReload)
  FitWindow()
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
  SDP_Preview.Shutdown()
  Events.LoadScreenClose.Remove(OnLoadScreenClose)
  Events.InterfaceModeChanged.Remove(OnInterfaceModeChanged)
  Events.SystemUpdateUI.Remove(OnUpdateUI)
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
  SetState = function(districtType, state) SetState(districtType, state) end,
  SetCount = SetCount,
  SetRemind = SetRemind,
  SetApart = SetApart,
  SelectSolution = function(n)
    if m_result ~= nil and m_result.Ok and m_result.Solutions and m_result.Solutions[n] then
      m_solution = n
      m_lookNext = true
      ShowResult()
    end
  end,
  SetWeight = SetWeight,
  SetAllowFeatureRemoval = SetAllowFeatureRemoval,
  SetReplace = SetReplace,
  SetWonder = SetWonder,
  ShowHeat = function(districtType) ShowHeat(districtType) end,
  Heat = function() return m_heatSpots end,
  SetLand = SetLand,
  SetSwap = SetSwap,
  SetFold = function(on) SetFold(on) end,
  SetPreset = function(name) SetPreset(name) end,
  SetPeek = SetPeek,
  FitWindow = FitWindow,
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
      SolutionCells = m_solutionCells, WeightCells = m_weightCells,
      Count = List().Count, Solution = m_solution, Remind = m_remind, Apart = m_apart,
      Weights = m_weights, AllowFeatureRemoval = m_allowFeatureRemoval, Land = m_weights.LAND > 0, Tier = m_tier, Replace = m_replace,
      Swap = m_swap,
      Wonders = SelectedWonders(), HeatDistrict = m_heat,
      Running = SDP_Task.IsRunning(), QualityText = Controls.Quality:GetText(), EstimateText = Controls.Estimate:GetText(),
      PlaceDisabled = Controls.PlaceButton:IsDisabled(), UndoDisabled = Controls.UndoButton:IsDisabled(),
      ContinueDisabled = Controls.ContinueButton:IsDisabled(), LaunchMark = m_launchDone,
      SolveDisabled = Controls.SolveButton:IsDisabled(), SummaryText = Controls.Summary:GetText(),
      SummaryToolTip = Controls.Summary:GetToolTipString(),
      Fold = m_fold, FoldText = Controls.FoldText:GetText(), Peek = m_peek, Preset = m_preset,
      ResultHeight = Controls.ResultScroll:GetSizeY(), WindowHeight = SDP_UI.WindowFitted,
      LaunchToolTip = m_launchItem.LaunchItemButton and m_launchItem.LaunchItemButton:GetToolTipString() or nil,
    }
  end,
}

Controls.CloseButton:RegisterCallback(Mouse.eLClick, Close)
Controls.PeekButton:RegisterCallback(Mouse.eLClick, function() SetPeek(true) end)
Controls.PeekReturn:RegisterCallback(Mouse.eLClick, function() SetPeek(false) end)
Controls.PeekNextSite:RegisterCallback(Mouse.eLClick, function() SDP_PageSites.NextSite() end)
Controls.FoldButton:RegisterCallback(Mouse.eLClick, function() SetFold(not m_fold) end)
Controls.CloseButton:RegisterCallback(Mouse.eMouseEnter, function()
  UI.PlaySound("Main_Menu_Mouse_Over")
end)
Controls.ReplaceCheck:RegisterCheckHandler(function()
  SetReplace(Controls.ReplaceCheck:IsChecked())
end)
Controls.FeatureCheck:RegisterCheckHandler(function()
  SetAllowFeatureRemoval(Controls.FeatureCheck:IsChecked())
end)
Controls.SwapCheck:RegisterCheckHandler(function()
  SetSwap(Controls.SwapCheck:IsChecked())
end)
Controls.RemindCheck:RegisterCheckHandler(function()
  SetRemind(Controls.RemindCheck:IsChecked())
end)
Controls.ApartCheck:RegisterCheckHandler(function()
  SetApart(Controls.ApartCheck:IsChecked())
end)
Controls.CountLess:RegisterCallback(Mouse.eLClick, function() SetCount(List().Count - 1) end)
Controls.CountMore:RegisterCallback(Mouse.eLClick, function() SetCount(List().Count + 1) end)
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
Events.SystemUpdateUI.Add(OnUpdateUI)
LuaEvents.SDP_OpenPanel.Add(Open)
LuaEvents.SDP_ClosePanel.Add(Close)
FitWindow()
