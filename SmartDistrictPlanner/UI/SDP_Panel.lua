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
include("SDP_Improve")
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
local VERSION = "v1.7.6"

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

local m_launchItem = {}     -- SDP_LaunchBarItem instance in the game's launch bar
local m_launchPin = {}      -- SDP_LaunchBarPin instance next to it
local m_launchDone = false    -- a background solve finished while the panel was closed
local m_tab = "SINGLE"        -- the open tab: SINGLE, SITES or MULTI
local m_peek = false          -- the window hidden to look at the map (issue 71)

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

-- A tab's chosen wonders (`chosen`, { [BuildingType] = true }) as a kept
-- setting (issue 166): the types, sorted, comma-separated; read back, only
-- the wonders this ruleset has. A wonder stays chosen while it is pinned
-- (it is only left out then), so a load keeps that too: with "replace" on
-- it is planned again (issue 154).
function SDP_UI.WonderSetting(chosen)
  return { Key = "WONDERS", Kind = "list", Pattern = "^[%w_]+$", Default = "",
    Get = function()
      local list = {}
      for wonderType in pairs(chosen) do list[#list + 1] = wonderType end
      table.sort(list)
      return table.concat(list, ",")
    end,
    Put = function(text)
      for wonderType in pairs(chosen) do chosen[wonderType] = nil end
      for wonderType in tostring(text or ""):gmatch("[^,]+") do
        local row = GameInfo.Buildings[wonderType]
        if row ~= nil and row.IsWonder then chosen[wonderType] = true end
      end
    end }
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
-- A tab's fold line: the summary `text`; `folded` hides the settings (their
-- scroll panel, issue 199).
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
-- spec = { Order (default the planner's presets), Tips (true: each preset's
-- LOC_SDP_PRESET_<name>_TOOLTIP, with SDP_Settings.FOCUS; a string: that
-- prefix instead of LOC_SDP_PRESET_, issue 153), TipArgs (a function of the
-- preset's name giving the numbers its tooltip shows, instead of the focus
-- weight), CustomTip }.
-- onSelect(name).
function SDP_UI.ShowPreset(pull, shown, onSelect, spec)
  spec = spec or {}
  local prefix = (type(spec.Tips) == "string") and spec.Tips or "LOC_SDP_PRESET_"
  local function Tip(name)
    if not spec.Tips then return "" end
    if spec.TipArgs then
      local args = {}
      for i, value in ipairs(spec.TipArgs(name)) do args[i] = Number(value) end
      return Locale.Lookup(prefix .. name .. "_TOOLTIP", unpack(args))
    end
    return Locale.Lookup(prefix .. name .. "_TOOLTIP", Number(SDP_Settings.FOCUS[name] or 1))
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
-- The settings (`settings`, a scroll panel around `settingsStack`) and the
-- district grid (`districts` around `districtStack`) are as high as they are
-- drawn; when the page is too short for them with the result list at one
-- row, they scroll so the solve button and the tacks' buttons below stay on
-- the page: the settings first, down to SETTINGS_MIN (issue 199: many
-- wonders ticked, or a low screen), then the district grid, down to
-- DISTRICT_MIN, however many districts the rules give (issue 314: the
-- Diplomatic Quarter and the Preserve add a row).
SDP_UI.RESULT_MIN = 40
SDP_UI.SETTINGS_MIN = 56
SDP_UI.DISTRICT_MIN = 60
function SDP_UI.FitResults(body, page, scroll, settings, settingsStack, districts, districtStack)
  local parts = {}
  local function Add(panel, stack, least)
    if panel == nil or panel:IsHidden() then return end
    stack:CalculateSize()
    local full = stack:GetSizeY()
    panel:SetSizeY(full)
    panel:CalculateSize()
    parts[#parts + 1] = { Panel = panel, Full = full, Least = least }
  end
  Add(settings, settingsStack, SDP_UI.SETTINGS_MIN)
  Add(districts, districtStack, SDP_UI.DISTRICT_MIN)
  scroll:SetSizeY(SDP_UI.RESULT_MIN)
  scroll:CalculateSize()
  body:CalculateSize()
  local spare = page:GetSizeY() - body:GetSizeY()
  for _, part in ipairs(parts) do
    if spare >= 0 then break end
    part.Panel:SetSizeY(math.max(math.min(part.Full, part.Least), part.Full + spare))
    part.Panel:CalculateSize()
    body:CalculateSize()
    spare = page:GetSizeY() - body:GetSizeY()
  end
  local height = SDP_UI.RESULT_MIN + math.max(0, spare)
  scroll:SetSizeY(height)
  scroll:CalculateSize()
  body:CalculateSize()
  return height
end

-- A self-check after a tab fitted its page (issue 327): the body (the
-- solve and the tacks' buttons at its foot) must end on the page. When it
-- does not, one line starting with SDP_UI.OVERFLOW goes to the log; the
-- in-game tests (tools/run_tests.py) fail the test it shows up in. Nothing
-- on the panel changes. A hidden page is fitted again when its tab opens.
SDP_UI.OVERFLOW = "SDP_LAYOUT_OVERFLOW"
function SDP_UI.Log(text) print(text) end -- the offline tests read it
function SDP_UI.CheckFit(name, page, body)
  if page:IsHidden() then return true end
  local pageHeight, bodyHeight = page:GetSizeY(), body:GetSizeY()
  if bodyHeight <= pageHeight then return true end
  SDP_UI.Log(string.format("%s %s: the body %d does not fit the page %d", SDP_UI.OVERFLOW, name, bodyHeight, pageHeight))
  return false
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
-- The summary's tooltip lines: the newly covered cities by group, with the
-- group's range when the player's bonuses make it longer (issue 197).
function SDP_UI.CoverageLines(solution, label)
  label = label or SDP_UI.TargetLabel
  local lines = {}
  for _, entry in ipairs(solution.CoveredBy or {}) do
    local names = {}
    for _, key in ipairs(entry.Keys) do names[#names + 1] = label(key) end
    if (entry.Extra or 0) > 0 then
      lines[#lines + 1] = Locale.Lookup("LOC_SDP_COVERAGE_GROUP_EXTRA", TypeName(entry.Group), #entry.Keys, Join(names),
        entry.Range, entry.Extra)
    else
      lines[#lines + 1] = Locale.Lookup("LOC_SDP_COVERAGE_GROUP", TypeName(entry.Group), #entry.Keys, Join(names))
    end
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
-- the count of districts that take population (issues 71, 144). `count` is
-- a target: how many the city ends with, counting what it has. `have`
-- (SDP_City.SpecialtyHave, nil: nothing) is what it has; a tacked type it
-- must build is planned again and counted once. Out: Have (that number),
-- Target (`count` within Have + MustSpecialty .. Top; nil: DefaultTarget),
-- Top (Have + MustSpecialty + #Pool, or `ceiling` when higher: a list for
-- several cities, each with its own Have), Count (the districts to plan:
-- Target - Have, at least MustSpecialty, at most MustSpecialty + #Pool) and
-- Pick (Count - MustSpecialty).
-- `status` (optional): [type] = reason the district cannot be planned (left out).
SDP_UI.DEFAULT_COUNT = 3

-- The default target of a city that has `have` districts that take
-- population: three, or one more than it has (issue 144).
function SDP_UI.DefaultTarget(have)
  if have < SDP_UI.DEFAULT_COUNT then return SDP_UI.DEFAULT_COUNT end
  return have + 1
end

function SDP_UI.ListRequest(districts, states, count, status, have, ceiling)
  local out = { Must = {}, Pool = {}, Auto = {}, MustSpecialty = 0 }
  local must = {}
  for _, d in ipairs(districts) do
    if status == nil or status[d.Type] == nil then
      local state = SDP_UI.StateOf(states, d)
      if state == "MUST" then
        out.Must[#out.Must + 1] = d.Type
        must[d.Type] = true
        if d.Specialty then out.MustSpecialty = out.MustSpecialty + 1 end
      elseif state == "POOL" and d.Specialty and not Limited(d) then
        out.Pool[#out.Pool + 1] = d.Type
      elseif state == "AUTO" then
        out.Auto[d.Type] = true
      end
    end
  end
  out.Have = SDP_City.HaveCount(have, must)
  if count == nil then count = SDP_UI.DefaultTarget(out.Have) end
  local most = out.MustSpecialty + #out.Pool
  out.Top = math.max(out.Have + most, ceiling or 0)
  out.Target = math.max(out.Have + out.MustSpecialty, math.min(count, out.Top))
  out.Count = math.min(out.Target - out.Have, most)
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
-- `ignore` the pins being replaced (as for SDP_Wonders.Pinned). `room`
-- (optional): how many more districts that take population the city's
-- count leaves beside the required ones; a district that takes population
-- needs one (issue 177; wonders in SDP_Multi's order).
function SDP_UI.WonderNeeds(playerID, wonders, districts, states, scan, status, ignore, room)
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
  for _, w in ipairs(SDP_Wonders.List(playerID, ignore)) do rows[w.Type] = w end
  local sorted = {}
  for _, wonderType in ipairs(wonders) do sorted[#sorted + 1] = wonderType end
  table.sort(sorted)
  for _, wonderType in ipairs(sorted) do
    local w = rows[wonderType]
    local base = w ~= nil and w.Status == nil and w.AdjacentDistrict or nil
    if base ~= nil and not has[base] then
      local found = nil
      for _, d in ipairs(districts) do
        if SDP_Rules.BaseDistrict(d.Type) == base and (status == nil or status[d.Type] == nil) and states[d.Type] ~= "OFF"
            and SDP_Rules.ExcludedBy(d.Type, must) == nil then
          found = found or d
          if not d.Specialty or room == nil or room > 0 then needs[d.Type] = wonderType end
        end
      end
      if found ~= nil and found.Specialty and room ~= nil and room > 0 then room = room - 1 end
      has[base] = true
    end
  end
  return needs
end

-- A wrap width no text reaches: "do not wrap" for a label without a
-- truncate width. A wrap width of 0 wraps after every character there
-- (2026-11-03, issue 216: the state showed one letter a line); the game's
-- NotificationPanel.lua passes the screen width the same way.
local NO_WRAP = 4096

-- Whether `text` has a multi-byte (non-ASCII) character. A byte loop: in the
-- game's Lua a pattern such as "[\128-\255]" matches no byte (2026-11-03).
local function HasMultiByte(text)
  for i = 1, #text do
    if text:byte(i) >= 128 then return true end
  end
  return false
end

-- The widest word of `text` at the label's font size, measured on the label
-- itself (it is set again after). Words are runs without spaces and without
-- multi-byte characters: a Chinese name may wrap anywhere.
local function WidestWord(label, text)
  local widest = 0
  label:SetTruncateWidth(0)
  label:SetWrapWidth(NO_WRAP)
  for word in text:gmatch("%S+") do
    if not HasMultiByte(word) then
      label:SetText(word)
      widest = math.max(widest, label:GetSizeX() or 0)
    end
  end
  return widest
end

-- A name in a fixed-width cell (TruncateWidth in the XML): one line in the
-- normal 14 point font; when that would cut it off (English names are
-- longer), two lines at 11 points, broken only at spaces. Cut off at 11
-- points, with the full name as tooltip, when a word is wider than the room:
-- the game breaks such a word in two ("Encampme / nt", issue 216). Returns
-- false when the name was cut off. `width`: the room for the name (80 by
-- default).
local function FitName(label, text, width)
  width = width or 80
  label:SetFontSize(14)
  label:SetWrapWidth(0)
  label:SetTruncateWidth(width)
  label:SetText(text)
  if label.IsTextTruncated == nil or not label:IsTextTruncated() then return true end
  label:SetFontSize(11)
  if WidestWord(label, text) <= width then
    label:SetTruncateWidth(0)
    label:SetWrapWidth(width)
    label:SetText(text)
    return true
  end
  label:SetWrapWidth(0)
  label:SetTruncateWidth(width)
  label:SetText(text)
  return false
end
SDP_UI.FitName = FitName

-- A district cell's layout (DistrictCell in the XML): the name starts at
-- CELL_NAME_X, the state ends CELL_STATE_RIGHT from the right edge, and
-- CELL_GAP keeps them apart. A state wider than CELL_STATE_MAX (English
-- "Empire limit reached") goes to two lines at 11 points.
local CELL_NAME_X, CELL_STATE_RIGHT, CELL_GAP, CELL_STATE_MAX = 30, 12, 6, 60

-- Set a cell's state label and return its width; at 11 points when `small`.
local function FitState(label, text, small)
  label:SetFontSize(14)
  label:SetWrapWidth(NO_WRAP)
  label:SetText(text)
  if small or (label:GetSizeX() or 0) > CELL_STATE_MAX then
    label:SetFontSize(11)
    label:SetWrapWidth(CELL_STATE_MAX)
    label:SetText(text)
  end
  return math.min(label:GetSizeX() or 0, CELL_STATE_MAX)
end

-- The room a cell leaves for the name next to a state `stateWidth` wide.
function SDP_UI.CellNameRoom(cellWidth, stateWidth)
  return math.max(24, cellWidth - CELL_NAME_X - CELL_STATE_RIGHT - CELL_GAP - stateWidth)
end

-- A cell's name next to its state. When a word of the name does not fit
-- beside the state (English "Encampment" beside "Wonder"), the state goes to
-- 11 points to leave the name more room.
local function FitCell(nameLabel, stateLabel, name, state, cellWidth)
  if not FitName(nameLabel, name, SDP_UI.CellNameRoom(cellWidth, FitState(stateLabel, state))) then
    FitName(nameLabel, name, SDP_UI.CellNameRoom(cellWidth, FitState(stateLabel, state, true)))
  end
end

-- Show one district cell: its icon, name and state; the selected look for
-- MUST and AUTO; dimmed when OFF or when it cannot be planned (`status`).
-- The name gets the room the state leaves (issue 216: in English, long
-- names such as Encampment ran into "Wonder").
function SDP_UI.ShowCell(inst, d, state, status)
  -- WONDER: shown for a district a chosen wonder needs (issue 66), not stored.
  local selected = status == nil and (state == "MUST" or state == "AUTO" or state == "WONDER")
  local name = Locale.Lookup(d.Name)
  local label = status and Locale.Lookup("LOC_SDP_STATUS_" .. status) or Locale.Lookup("LOC_SDP_STATE_" .. state)
  inst.Icon:SetIcon(d.Icon, 26)
  local cellWidth = inst.Root:GetSizeX()
  FitCell(inst.Name, inst.State, name, label, cellWidth)
  FitCell(inst.NameDark, inst.StateDark, name, label, cellWidth)
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
-- rows { Type, Name, State, Status, Group, Cell, Click, Inst } (tests).
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
      Group = d.Specialty and "SPECIALTY" or "OTHER", Cell = inst.Root, Click = click, Inst = inst }
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
-- decorate(inst, type), optional: the tag is the instance's Chip inside its
-- Root, and decorate fills in the rest (the several cities tab's city
-- choice, issue 234).
function SDP_UI.BuildWonders(pull, chipIM, chipStack, wonders, chosen, onSet, decorate)
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
        local chip = decorate ~= nil and inst.Chip or inst.Root
        inst.Name:SetText(Locale.Lookup("LOC_SDP_WONDER_CHIP", name))
        chip:SetSizeX(math.max(60, inst.Name:GetSizeX() + 20))
        chip:SetToolTipString(Locale.Lookup("LOC_SDP_WONDER_CHIP_TOOLTIP"))
        chip:RegisterCallback(Mouse.eLClick, function() onSet(wonderType, false) end)
        if decorate ~= nil then
          decorate(inst, wonderType)
          inst.Root:CalculateSize()
        end
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

-- Why plan n comes after plan n - 1 (issue 189): the button shows the
-- weighted adjacency, but plans are ranked by how many districts and
-- wonders they place, then by the adjacency plus the items in brackets
-- (Gain). `parts`: the summary's items (SummaryText); with none the two
-- values are the same. "" for the first plan.
function SDP_UI.RankText(solutions, n, parts)
  local s, before = solutions[n], solutions[n - 1]
  if s == nil or before == nil then return "" end
  local fewer = #(before.Plan or {}) - #(s.Plan or {})
  if fewer > 0 then return Locale.Lookup("LOC_SDP_RANK_FEWER", n - 1, fewer) end
  local lower = math.floor(((before.Gain or 0) - (s.Gain or 0)) * 10 + 0.5) / 10
  local others = #SDP_UI.PartsList({ Appeal = s.AppealDelta }, parts or {}) > 0
  if lower <= 0 then return Locale.Lookup(others and "LOC_SDP_RANK_SAME" or "LOC_SDP_RANK_SAME_ADJACENCY", n - 1) end
  return Locale.Lookup(others and "LOC_SDP_RANK_LOWER" or "LOC_SDP_RANK_LOWER_ADJACENCY", n - 1, Number(lower))
end

-- `text`, then `rank` (RankText) on a line of its own when there is one.
function SDP_UI.WithRank(text, rank)
  if rank == nil or rank == "" then return text end
  if text == nil or text == "" then return rank end
  return text .. "[NEWLINE]" .. rank
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
-- Selecting a city on the map again is a new selection even when it is the
-- same city as before (issue 178): the game tells of each one
-- (Events.CitySelectionChanged), not only of a change of city.
-- SDP_PageSingle.FollowSelection does it.

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
  if SDP_PageSingle.FollowSelection() then m_tab = "SINGLE" end
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

-- The improvements planned with the districts (issue 227) ------------------
-- Plain-text tile yields, food included.
local function TileYieldText(yields)
  local parts = {}
  for _, yieldType in ipairs(SDP_Land.TILE_YIELDS) do
    local amount = yields and yields[yieldType]
    if amount ~= nil and amount ~= 0 then
      parts[#parts + 1] = Locale.Lookup("LOC_SDP_YIELD_SHORT_" .. yieldType) .. Signed(amount)
    end
  end
  if #parts == 0 then return Locale.Lookup("LOC_SDP_NO_YIELDS") end
  return table.concat(parts, " ")
end

-- One improvement tack in a tooltip: what, where, its yields once built,
-- and whether the feature goes first or the tile is not owned yet.
function SDP_UI.ImprovementLine(e)
  local text = Locale.Lookup("LOC_SDP_RESULT_IMPROVEMENT_LINE", TypeName(e.Type), Where(e.X, e.Y), TileYieldText(e.Yields))
  local notes = {}
  if e.Clear then notes[#notes + 1] = Locale.Lookup("LOC_SDP_RESULT_IMPROVEMENT_CLEAR") end
  if e.Unowned then notes[#notes + 1] = Locale.Lookup("LOC_SDP_RESULT_UNOWNED") end
  if #notes == 0 then return text end
  return text .. " " .. table.concat(notes, " ")
end

local function ImprovementsTip(list)
  local lines = {}
  for _, e in ipairs(list) do lines[#lines + 1] = SDP_UI.ImprovementLine(e) end
  return Locale.Lookup("LOC_SDP_RESULT_IMPROVEMENTS_TOOLTIP", table.concat(lines, "[NEWLINE]"))
end

-- The improvements planned next to a district: a result row after the
-- district's (`indent` before its name), with what they add to its adjacency.
function SDP_UI.ImprovementRow(p, add, indent)
  local list = p.Improvements
  if list == nil or #list == 0 then return end
  local names = {}
  for _, e in ipairs(list) do names[#names + 1] = TypeName(e.Type) .. " " .. Where(e.X, e.Y) end
  local detail
  if p.ImprovementYields ~= nil then
    detail = Locale.Lookup("LOC_SDP_RESULT_IMPROVEMENTS_FOR", TypeName(p.Type), YieldText(p.ImprovementYields))
  else
    detail = Locale.Lookup("LOC_SDP_RESULT_IMPROVEMENTS_TILES", TypeName(p.Type))
  end
  add("ICON_" .. list[1].Type, (indent or "") .. Locale.Lookup("LOC_SDP_RESULT_IMPROVEMENTS", Join(names)), detail,
    ImprovementsTip(list), list[1].X, list[1].Y)
end

-- The improvements of one city's worked tiles (issue 227 question 11): one
-- row with how many of each, every tile on hover. `city`: the city's label
-- (several cities) or nil.
function SDP_UI.WorkedRow(list, add, city)
  if list == nil or #list == 0 then return end
  local counts, order = {}, {}
  for _, e in ipairs(list) do
    if counts[e.Type] == nil then
      counts[e.Type] = 0
      order[#order + 1] = e.Type
    end
    counts[e.Type] = counts[e.Type] + 1
  end
  table.sort(order)
  local parts = {}
  for _, t in ipairs(order) do parts[#parts + 1] = Locale.Lookup("LOC_SDP_RESULT_WORKED_COUNT", TypeName(t), counts[t]) end
  local detail = city ~= nil and Locale.Lookup("LOC_SDP_RESULT_WORKED_CITY", city) or Locale.Lookup("LOC_SDP_RESULT_WORKED_DETAIL")
  add("ICON_" .. order[1], Locale.Lookup("LOC_SDP_RESULT_WORKED", Join(parts)), detail, ImprovementsTip(list))
end

-- Preview icons of both kinds of improvement tacks.
function SDP_UI.ImprovementIcons(plan, worked, icons)
  for _, p in ipairs(plan or {}) do
    for _, e in ipairs(p.Improvements or {}) do icons[#icons + 1] = { X = e.X, Y = e.Y, Icon = "ICON_" .. e.Type, Text = "" } end
  end
  for _, e in ipairs(worked or {}) do icons[#icons + 1] = { X = e.X, Y = e.Y, Icon = "ICON_" .. e.Type, Text = "" } end
end

-- Tack entries of a list of improvements, named `name` (the city's number).
function SDP_UI.ImprovementEntries(list, name, entries)
  for _, e in ipairs(list or {}) do entries[#entries + 1] = { Type = e.Type, X = e.X, Y = e.Y, Name = name } end
end

-- Result rows for partner districts a plan leaves in one city
-- (Together; partner districts are always kept apart otherwise, issue 152):
-- `city` names the city (several cities) or is nil.
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
      Locale.Lookup("LOC_SDP_RESULT_TOGETHER_TOOLTIP",
        Locale.Lookup("LOC_SDP_APART_RULE", TypeName(t.Building), TypeName(t.Other), TypeName(t.A), TypeName(t.B))))
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

-- ---------------------------------------------------------------------------
-- One path after the solve (issue 250). Without wonders the city is solved
-- by SDP_Solver, with wonders by SDP_Multi with this city alone (Solve
-- below); both results go through CityResult once, when they arrive, which
-- gives every solution the same fields:
--   Plan, Unplaced (this solution's own, a pool that falls short as one
--   POOL_SHORT entry), Picked (the types picked from the pool), Together,
--   Remind, Neighbours, ImprovementHousing and the summary's values.
-- The result rows (CityRows), the preview (CityIcons) and the tacks
-- (CityTacks) read only these, whichever solver made the plan.
-- ---------------------------------------------------------------------------
function SDP_UI.CityResult(result, cityID)
  if result == nil or not result.Ok or result.CityShaped then return result end
  result.CityShaped = true
  local session = result.Session
  -- SDP_Multi reports a pool that falls short itself; SDP_Solver picks
  -- fewer without a word: as many as it set out to pick (Session.Pick,
  -- capped by what can stand together), less what the plan picked.
  local pick = (session ~= nil and session.Participants == nil) and session.Pick or nil
  local function Shape(s)
    local city = nil
    for _, c in ipairs(s.Cities or {}) do
      if c.CityID == cityID then city = c end
    end
    s.Picked = s.Picked or (city and city.Picked) or {}
    if s.Together == nil and city ~= nil then s.Together = city.Together end
    if s.Worked == nil and city ~= nil then s.Worked = city.Worked end
    local unplaced = {}
    for _, u in ipairs(s.Unplaced or result.Unplaced or {}) do unplaced[#unplaced + 1] = u end
    if pick ~= nil and pick > #s.Picked then
      unplaced[#unplaced + 1] = { Type = "POOL", Reason = "POOL_SHORT", Count = pick - #s.Picked }
    end
    s.Unplaced = unplaced
  end
  local best = result.Solutions and result.Solutions[1]
  if best == nil then
    Shape(result)
  else
    for _, s in ipairs(result.Solutions) do Shape(s) end
    -- The best solution's fields at the top level, as both solvers keep them.
    result.Unplaced, result.Picked, result.Together = best.Unplaced, best.Picked, best.Together
  end
  return result
end

-- Solution n of a result (CityResult), or the result itself when it has none.
function SDP_UI.CitySolution(result, n)
  return (result.Solutions and result.Solutions[n]) or result
end

-- The result rows of a solution (CityResult): what it leaves out first, so
-- a long list does not hide it (issue 60), then each planned item, the
-- woods and rainforest it relies on, the neighbours whose adjacency it
-- changes, partner districts left together, the housing it takes.
-- add(icon, name, detail, toolTip, x, y); `parts` the summary's (SummaryText);
-- `cityID` the planned city.
function SDP_UI.CityRows(s, parts, add, cityID)
  for _, u in ipairs(s.Unplaced) do
    if u.Reason == "POOL_SHORT" then
      add("ICON_DISTRICT_CITY_CENTER", Locale.Lookup("LOC_SDP_RESULT_POOL_SHORT", SDP_UI.TargetLabel("C" .. tostring(cityID))),
        Locale.Lookup("LOC_SDP_REASON_POOL_SHORT", u.Count or 1), "")
    else
      add("ICON_" .. u.Type, SDP_UI.UnplacedName(u), SDP_UI.ReasonText(u), UnplacedTip(u))
    end
  end
  -- Each planned district: where, its yields, and DMT's own breakdown on hover.
  for _, p in ipairs(s.Plan) do
    local toolTip = (p.ToolTip ~= nil and p.ToolTip ~= "") and p.ToolTip or Locale.Lookup("LOC_SDP_NO_ADJACENCY")
    local detail
    detail, toolTip = SDP_UI.CoverageRow(p, SDP_UI.PlanDetail(p), toolTip)
    toolTip = SDP_UI.PartsTip(p, parts, toolTip)
    add("ICON_" .. p.Type, TypeName(p.Type) .. "  " .. Where(p.X, p.Y), detail, toolTip, p.X, p.Y)
    SDP_UI.SupportRow(p, add, "  ")
    SDP_UI.ImprovementRow(p, add, "  ")
  end
  -- The improvements of the worked tiles (issue 227).
  SDP_UI.WorkedRow(s.Worked, add)
  -- Woods and rainforest the plan relies on (feedback item 5).
  for _, r in ipairs(s.Remind or {}) do
    add(SDP_Pins.REMIND_ICON, Locale.Lookup("LOC_SDP_RESULT_REMIND", TypeName(r.Feature), Where(r.X, r.Y)),
      SDP_UI.RemindText(r), Locale.Lookup("LOC_SDP_REMIND_TOOLTIP"), r.X, r.Y)
  end
  -- Districts and locked pins whose adjacency the plan changes.
  for _, n in ipairs(s.Neighbours or {}) do
    local subject = n.Subject
    add("ICON_" .. subject.Key, Locale.Lookup("LOC_SDP_RESULT_NEIGHBOUR", TypeName(subject.Key), Where(subject.X, subject.Y)),
      Locale.Lookup("LOC_SDP_RESULT_NEIGHBOUR_DETAIL", Number(n.Before), Number(n.After)),
      (n.ToolTip ~= nil and n.ToolTip ~= "") and n.ToolTip or Locale.Lookup("LOC_SDP_NO_ADJACENCY"), subject.X, subject.Y)
  end
  -- Partner districts left together (required ones, or the count needed them).
  SDP_UI.TogetherRows(s.Together, nil, add)
  SDP_UI.ImprovementHousingRow(s.ImprovementHousing, add)
end

-- The preview's icons of a solution (CityResult): each planned item with
-- its adjacency, the improvements wonders need, the reminders.
function SDP_UI.CityIcons(s)
  local icons = {}
  for _, p in ipairs(s.Plan) do
    icons[#icons + 1] = { X = p.X, Y = p.Y, Icon = "ICON_" .. p.Type, Text = PinText(p.Yields) }
  end
  SDP_UI.SupportIcons(s.Plan, icons)
  SDP_UI.ImprovementIcons(s.Plan, s.Worked, icons)
  for _, r in ipairs(s.Remind or {}) do
    icons[#icons + 1] = { X = r.X, Y = r.Y, Icon = SDP_Pins.REMIND_ICON, Text = "" }
  end
  return icons
end

-- The tacks of a solution (CityResult): each planned item and the
-- improvement a wonder needs, named with the city's number, and with
-- `remind` its reminders.
function SDP_UI.CityTacks(s, number, remind)
  local name = tostring(number or "")
  local entries = {}
  for _, p in ipairs(s.Plan) do
    entries[#entries + 1] = { Type = p.Type, X = p.X, Y = p.Y, Name = name }
    entries[#entries + 1] = SDP_UI.SupportEntry(p, name)
    SDP_UI.ImprovementEntries(p.Improvements, name, entries)
  end
  SDP_UI.ImprovementEntries(s.Worked, name, entries)
  if remind then
    for _, e in ipairs(SDP_UI.RemindEntries(s.Remind, function() return number end)) do entries[#entries + 1] = e end
  end
  return entries
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

-- The tabs (filled in below): each { Name, Refresh, Render, ShowProgress(text), UpdateButtons, OnError(message),
-- FitPage, Restore }.
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

-- ===========================================================================
-- Tabs
-- ===========================================================================
SDP_Preview.Init(Controls.PreviewWorldIcons, "SDP_PreviewIcon")
include("SDP_PageKit")
include("SDP_PageSingle")
include("SDP_PageSites")
include("SDP_PageMulti")
for _, page in ipairs({ SDP_PageSingle, SDP_PageSites, SDP_PageMulti }) do
  m_pages[page.Name] = page
  m_fitPages[page.Name] = page.FitPage
end

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
  m_pages[name].Refresh()
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
  SDP_PageSingle.Restore()
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
  Events.CitySelectionChanged.Remove(SDP_PageSingle.OnCitySelectionChanged)
  Events.SystemUpdateUI.Remove(OnUpdateUI)
  LuaEvents.SDP_OpenPanel.Remove(Open)
  LuaEvents.SDP_ClosePanel.Remove(Close)
  RemoveLaunchButton()
end

-- Test hooks: tools/run_tests.py runs tests inside this context's Lua state.
-- The single-city tab's are SDP_PageSingle's, by their old names.
local S = SDP_PageSingle
SDP_Panel = {
  Open = Open,
  Close = Close,
  IsOpen = IsOpen,
  HandleInput = OnInput,
  LaunchButton = function() return m_launchItem.LaunchItemButton end,
  Refresh = S.Refresh,
  SelectCity = S.SelectCity,
  SetSelected = S.SetSelected,
  SetState = S.SetState,
  SetCount = S.SetCount,
  Request = S.Request,
  ForgetCounts = S.ForgetCounts,
  SetRemind = S.SetRemind,
  SetImprove = S.SetImprove,
  SetWorked = S.SetWorked,
  SelectSolution = S.SelectSolution,
  SetWeight = S.SetWeight,
  SetAllowFeatureRemoval = S.SetAllowFeatureRemoval,
  SetReplace = S.SetReplace,
  SetWonder = S.SetWonder,
  ShowHeat = S.ShowHeat,
  Heat = S.Heat,
  SetLand = S.SetLand,
  SetSwap = S.SetSwap,
  SetFold = S.SetFold,
  SetPreset = S.SetPreset,
  SetPeek = SetPeek,
  FitWindow = FitWindow,
  SetTier = S.SetTier,
  Solve = S.Solve,
  Continue = S.Continue,
  Cancel = function() return SDP_Task.Cancel() end,
  -- The panel as a new game shows it (issue 327): no computation, no peek,
  -- no result waiting, every tab at its defaults (SDP_PageSingle.Defaults
  -- and the others), the single-city tab. Open or closed as it was; this
  -- mod's tacks stay. tools/run_tests.py calls it before each test file,
  -- tools/shots.py before each stage.
  Defaults = function()
    if SDP_Task.IsRunning() then SDP_Task.Cancel() end
    SetPeek(false)
    if m_launchDone then SetLaunchMark(false) end
    SDP_Preview.Clear()
    SDP_PageSingle.Defaults()
    SDP_PageSites.Defaults()
    SDP_PageMulti.Defaults()
    SelectTab("SINGLE")
    FitWindow()
  end,
  -- Drive a sliced computation to its end now (tests cannot wait for frames).
  RunTask = function(quota)
    while SDP_Task.IsRunning() do SDP_Task.Step(quota) end
    return S.State().Result
  end,
  PlacePins = S.Place,
  UndoPins = S.Undo,
  SelectTab = function(name) SelectTab(name) end,
  Tab = function() return m_tab end,
  -- The context shown with the window hidden: a task runs on after Close.
  RunsHidden = function() return not ContextPtr:IsHidden() and Controls.DropShadow:IsHidden() end,
  Single = SDP_PageSingle,
  Sites = SDP_PageSites,
  Multi = SDP_PageMulti,
  State = function()
    local state = S.State()
    state.LaunchMark = m_launchDone
    state.Peek = m_peek
    state.WindowHeight = SDP_UI.WindowFitted
    state.LaunchToolTip = m_launchItem.LaunchItemButton and m_launchItem.LaunchItemButton:GetToolTipString() or nil
    return state
  end,
}

Controls.CloseButton:RegisterCallback(Mouse.eLClick, Close)
Controls.PeekButton:RegisterCallback(Mouse.eLClick, function() SetPeek(true) end)
Controls.PeekReturn:RegisterCallback(Mouse.eLClick, function() SetPeek(false) end)
Controls.PeekNextSite:RegisterCallback(Mouse.eLClick, function() SDP_PageSites.NextSite() end)
Controls.CloseButton:RegisterCallback(Mouse.eMouseEnter, function()
  UI.PlaySound("Main_Menu_Mouse_Over")
end)
ContextPtr:SetInputHandler(OnInput, true)
ContextPtr:SetInitHandler(OnInit)
ContextPtr:SetShutdown(OnShutdown)
Events.LoadScreenClose.Add(OnLoadScreenClose)
Events.InputActionTriggered.Add(OnInputActionTriggered)
Events.InterfaceModeChanged.Add(OnInterfaceModeChanged)
Events.CitySelectionChanged.Add(SDP_PageSingle.OnCitySelectionChanged)
Events.SystemUpdateUI.Add(OnUpdateUI)
LuaEvents.SDP_OpenPanel.Add(Open)
LuaEvents.SDP_ClosePanel.Add(Close)
FitWindow()
