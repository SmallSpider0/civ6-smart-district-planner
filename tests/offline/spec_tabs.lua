-- Offline: the settings and actions the three tabs share (SDP_PageKit,
-- issue 251), each through the tab's own controls: a weight arrow, the tier
-- and preset pulldowns, the fold line, a switch, and the solve, place and
-- undo buttons behave the same on every tab and are kept under the tab's key.
local test, T = ...

local UI_Mock = include("ui")

local MAP = {
  "~~~~~~~~~~~~~~~~~~~~~~",
  "~..f.M..h...f..M..h..~",
  "~.fMj..p.d...fMj..p..~",
  "~h..f.j..M.h..f.j..M.~",
  "~.pM...f.h..pM...f.h.~",
  "~..j.p..q....j.p..q..~",
  "~f..h.M.j..f..h.M.j..~",
  "~.s..f..p...s..f..p..~",
  "~..p...h...p...h.....~",
  "~.M..f..j..M..f..j...~",
  "~..h..p...h..p...h...~",
  "~.f..M..p..f..M..p...~",
  "~..j...h..j...h..j...~",
  "~~~~~~~~~~~~~~~~~~~~~~",
}

local w = World.New({
  rows = MAP, rivers = { "6,4", "7,4", "7,5" },
  cities = { { id = 1, x = 4, y = 5, population = 6, capital = true, radius = 1 } },
})
UI_Mock.Install()
include("SDP_Panel")
local c = UI_Mock.Controls
local cfg = PlayerConfigurations[0]

-- Each tab: its State(), its weight cells, its controls and the keys it keeps.
local TABS = {
  { Name = "SINGLE", State = function() return SDP_Panel.State() end,
    Cells = function() return SDP_Panel.State().WeightCells end,
    TierPull = c.TierPull, PresetPull = c.PresetPull, Order = SDP_Settings.PRESET_ORDER, Preset = "SCIENCE",
    Fold = c.FoldButton, FoldText = c.FoldText, Switch = c.RemindCheck, SwitchKey = "REMIND", SwitchField = "Remind" },
  { Name = "SITES", State = function() return SDP_Panel.Sites.State() end,
    Cells = function() return SDP_Panel.Sites.State().View.WeightCells end,
    TierPull = c.SitesTierPull, PresetPull = c.SitesPresetPull, Order = SDP_Sites.PRESET_ORDER,
    Preset = SDP_Sites.PRESET_ORDER[2], Fold = c.SitesFoldButton, FoldText = c.SitesFoldText },
  { Name = "MULTI", State = function() return SDP_Panel.Multi.State() end,
    Cells = function() return SDP_Panel.Multi.State().WeightCells end,
    TierPull = c.MultiTierPull, PresetPull = c.MultiPresetPull, Order = SDP_Settings.PRESET_ORDER, Preset = "CULTURE",
    Fold = c.MultiFoldButton, FoldText = c.MultiFoldText, Switch = c.MultiRemindCheck, SwitchKey = "REMIND",
    SwitchField = "Remind" },
}

local function Entry(pull, name, order)
  for i, other in ipairs(order) do
    if other == name then return pull._entries[i] end
  end
end

local function Kept(tab) return cfg:GetValue("SDP_Settings_" .. tab.Name) or "" end

for _, tab in ipairs(TABS) do
  test(tab.Name .. ": weight arrow, tier, preset, fold and switch through the tab's own controls", function()
    SDP_Panel.Open()
    SDP_Panel.SelectTab(tab.Name)
    -- A weight column's arrow: the weight up by its step, kept at once.
    local cell = tab.Cells()[2] -- culture: one step up matches no preset
    T.ok(cell ~= nil, "weight cells")
    local before = tab.State().Weights[cell.Key]
    cell.More:Click()
    T.eq(tab.State().Weights[cell.Key], before + 0.5, "the arrow")
    T.ok(Kept(tab):find(";" .. cell.Key .. "=", 1, true) ~= nil, "kept: " .. Kept(tab))
    cell.Less:Click()
    T.eq(tab.State().Weights[cell.Key], before, "back")
    T.ok(Kept(tab):find(";" .. cell.Key .. "=", 1, true) == nil, "back to the preset: not written")
    -- The tier pulldown.
    local fast = nil
    for i, tier in ipairs(SDP_Tiers.ORDER) do
      if tier == "FAST" then fast = tab.TierPull._entries[i] end
    end
    fast.Button:Click()
    T.eq(tab.State().Tier, "FAST", "tier")
    T.eq(tab.TierPull:GetButton():GetText(), "LOC_SDP_TIER_FAST", "shown")
    T.ok(Kept(tab):find(";TIER=FAST", 1, true) ~= nil, "tier kept")
    -- A preset: its weights, kept by name; the tier stays.
    Entry(tab.PresetPull, tab.Preset, tab.Order).Button:Click()
    T.eq(tab.State().Preset, tab.Preset, "preset")
    T.ok(Kept(tab):find("preset=" .. tab.Preset, 1, true) ~= nil, "preset kept")
    T.eq(tab.State().Tier, "FAST", "the tier stays")
    T.ok(tab.FoldText:GetText():find("LOC_SDP_PRESET_" .. tab.Preset, 1, true) ~= nil, "the fold line names it")
    -- The fold line folds and unfolds, kept.
    local fold = tab.State().Fold
    tab.Fold:Click()
    T.eq(tab.State().Fold, not fold, "folded")
    tab.Fold:Click()
    T.eq(tab.State().Fold, fold, "unfolded")
    -- A switch, where the tab has one.
    if tab.Switch ~= nil then
      local on = tab.State()[tab.SwitchField]
      tab.Switch:Toggle()
      T.eq(tab.State()[tab.SwitchField], not on, "switch")
      T.ok(Kept(tab):find(";" .. tab.SwitchKey .. "=", 1, true) ~= nil, "switch kept")
      tab.Switch:Toggle()
      T.eq(tab.State()[tab.SwitchField], on, "switch back")
    end
    -- Back to how it was for the next tab's test.
    Entry(tab.PresetPull, tab.Order[1], tab.Order).Button:Click()
    SDP_Panel.Close()
  end)
end

test("SINGLE: solve, place and undo through the buttons; a weight change clears the result", function()
  SDP_Panel.Open()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(1)
  SDP_Panel.SetTier("FAST")
  for _, d in ipairs({ "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE" }) do SDP_Panel.SetSelected(d, true) end
  c.SolveButton:Click()
  local result = SDP_Panel.RunTask(500) -- picking from the candidates runs as a task
  T.ok(result and result.Ok, "solved: " .. tostring(result and result.Error))
  T.eq(SDP_Panel.State().PlaceDisabled, false, "place on")
  local pins = #w:Pins()
  c.PlaceButton:Click()
  T.ok(#w:Pins() > pins, "tacks placed")
  T.eq(SDP_Panel.State().PlaceDisabled, true, "placed once")
  T.eq(SDP_Panel.State().UndoDisabled, false, "undo on")
  c.UndoButton:Click()
  T.eq(#w:Pins(), pins, "undone")
  T.eq(SDP_Panel.State().PlaceDisabled, false, "the plan can be placed again")
  SDP_Panel.State().WeightCells[2].More:Click()
  T.eq(SDP_Panel.State().Result, nil, "a weight change clears the result")
  SDP_Panel.State().WeightCells[2].Less:Click()
  for _, d in ipairs({ "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE" }) do SDP_Panel.SetSelected(d, false) end
  SDP_Panel.Close()
end)
