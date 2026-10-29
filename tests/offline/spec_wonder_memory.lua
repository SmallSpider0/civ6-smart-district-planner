-- Offline: the wonders chosen on a tab are kept in the save with its other
-- settings (issue 166). Before the fix the several-cities tab (and the
-- single-city tab) kept its switches, weights and tier, but the wonders were
-- gone after loading the save; with "replace" on, a wonder this mod had
-- pinned then showed up as not chosen, and placing the new plan removed its
-- pin without planning it again.
-- A save is simulated by values in the player's configuration before the
-- panel's script runs (as in spec_settings.lua). The wonders go through the
-- controls' own callbacks: the "add" pulldown's entries and the tags.
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
  rows = MAP, rivers = { "6,4", "7,4", "7,5", "12,7", "13,7" },
  cities = { { id = 1, x = 4, y = 5, population = 6, capital = true, radius = 1 } },
})

local GARDENS, PYRAMIDS, STONEHENGE = "BUILDING_HANGING_GARDENS", "BUILDING_PYRAMIDS", "BUILDING_STONEHENGE"
local cfg = PlayerConfigurations[0]
-- What an earlier session kept: a wonder on each tab, plus entries this
-- ruleset does not have or that are not building types (dropped).
cfg:SetValue("SDP_Settings_MULTI", "v1;preset=BALANCED;YIELD_GOLD=2;WONDERS=" .. GARDENS .. ",BUILDING_NOPE,bad entry")
cfg:SetValue("SDP_Settings_SINGLE", "v1;preset=BALANCED;WONDERS=" .. PYRAMIDS)

UI_Mock.Install()
-- The wonder tags of each tab, by their stack.
local chipIMs = {}
local NewIM = InstanceManager.new
InstanceManager.new = function(self, name, root, parent)
  local im = NewIM(self, name, root, parent)
  if name == "WonderChip" then chipIMs[parent] = im end
  return im
end
include("SDP_Panel")
local c = UI_Mock.Controls

local function PickWonder(pull, wonderType)
  for _, entry in ipairs(pull._entries) do
    if entry.Button:GetText() == "LOC_" .. wonderType .. "_NAME" then
      entry.Button:Click()
      return true
    end
  end
  return false
end

-- Take a wonder off through its tag.
local function DropWonder(stack, wonderType)
  for _, inst in ipairs(chipIMs[stack].Instances) do
    if inst.Name:GetText() == "LOC_SDP_WONDER_CHIP(LOC_" .. wonderType .. "_NAME)" then
      inst.Root:Click()
      return true
    end
  end
  return false
end

local function Kept(tab)
  return cfg:GetValue("SDP_Settings_" .. tab) or ""
end

local function MultiChosen()
  local list = {}
  for _, v in ipairs(SDP_Panel.Multi.State().View.Wonders) do
    if v.Chosen and v.Status == nil then list[#list + 1] = v.Type end
  end
  return list
end

local function SetCheck(check, on)
  if (check:IsChecked() == true) ~= on then check:Toggle() end
  T.eq(check:IsChecked() == true, on, "the switch")
end

test("a loaded save: each tab gets back the wonders it kept", function()
  SDP_Panel.Open()
  SDP_Panel.SelectCity(1)
  SDP_Panel.SelectTab("MULTI")
  local multi = SDP_Panel.Multi
  T.same(MultiChosen(), { GARDENS }, "several cities: the kept wonder is chosen again")
  T.eq(multi.State().Weights.YIELD_GOLD, 2, "next to the other settings it kept")
  T.ok(multi.State().FoldText:find("LOC_SDP_FOLD_WONDERS(1)", 1, true) ~= nil, "on the fold line: " .. multi.State().FoldText)
  T.same(multi.Request().Wonders, { GARDENS }, "and planned")
  SDP_Panel.SelectTab("SINGLE")
  T.same(SDP_Panel.State().Wonders, { PYRAMIDS }, "single city: its own kept wonder")
end)

test("a wonder chosen or taken off through the controls is kept at once, per tab", function()
  SDP_Panel.SelectTab("MULTI")
  T.ok(PickWonder(c.MultiWonderPull, STONEHENGE), "a second wonder from the pulldown")
  T.same(MultiChosen(), { GARDENS, STONEHENGE }, "both chosen")
  local text = Kept("MULTI")
  T.ok(text:find(";WONDERS=" .. GARDENS .. "," .. STONEHENGE, 1, true) ~= nil, "both kept, sorted: " .. text)
  T.ok(text:find("BUILDING_NOPE", 1, true) == nil, "what this ruleset lacks is dropped: " .. text)
  T.ok(text:find(";YIELD_GOLD=2", 1, true) ~= nil, "the other settings stay")
  T.ok(DropWonder(c.MultiWonderChipStack, GARDENS), "the tag")
  T.same(MultiChosen(), { STONEHENGE }, "one left")
  text = Kept("MULTI")
  T.ok(text:find(";WONDERS=" .. STONEHENGE, 1, true) ~= nil, "kept without it: " .. text)
  T.ok(DropWonder(c.MultiWonderChipStack, STONEHENGE), "the other tag")
  T.ok(Kept("MULTI"):find("WONDERS", 1, true) == nil, "none chosen: nothing written")
  T.eq(Kept("SINGLE"), "v1;preset=BALANCED;WONDERS=" .. PYRAMIDS, "the single-city tab untouched")

  SDP_Panel.SelectTab("SINGLE")
  T.ok(DropWonder(c.WonderChipStack, PYRAMIDS), "single city: the tag")
  T.ok(Kept("SINGLE"):find("WONDERS", 1, true) == nil, "single city: none kept")
  T.ok(PickWonder(c.WonderPull, GARDENS), "single city: from the pulldown")
  T.ok(Kept("SINGLE"):find(";WONDERS=" .. GARDENS, 1, true) ~= nil, "single city: kept")
  T.ok(Kept("MULTI"):find("WONDERS", 1, true) == nil, "not on the several-cities tab")
  SDP_Panel.SetWonder(GARDENS, false)
end)

test("a preset keeps the chosen wonders", function()
  SDP_Panel.SelectTab("MULTI")
  local multi = SDP_Panel.Multi
  T.ok(PickWonder(c.MultiWonderPull, GARDENS), "a wonder")
  for _, entry in ipairs(c.MultiPresetPull._entries) do
    if entry.Button:GetText() == "LOC_SDP_PRESET_SCIENCE" then entry.Button:Click() end
  end
  T.eq(multi.State().Preset, "SCIENCE", "the preset")
  T.same(MultiChosen(), { GARDENS }, "the wonder still chosen")
  T.ok(Kept("MULTI"):find(";WONDERS=" .. GARDENS, 1, true) ~= nil, "and kept: " .. Kept("MULTI"))
  for _, entry in ipairs(c.MultiPresetPull._entries) do
    if entry.Button:GetText() == "LOC_SDP_PRESET_BALANCED" then entry.Button:Click() end
  end
end)

-- A wonder chosen and pinned stays chosen (only left out while pinned), so
-- with "replace" on it is planned again, also after a load: what is kept
-- still names it once its pin is on the map.
test("a pinned wonder stays kept, and with replace on it is planned again", function()
  SDP_Panel.SelectTab("MULTI")
  local multi = SDP_Panel.Multi
  multi.SetCount(0)
  multi.SetPlanFor("ALL")
  multi.ApplyPlan({ "DISTRICT_THEATER" })
  SetCheck(c.MultiReplaceCheck, false)
  SetCheck(c.MultiRemindCheck, false)
  multi.SetTier("FAST")
  c.MultiSolveButton:Click()
  SDP_Panel.RunTask(500)
  local first = multi.State().Result
  T.ok(first and first.Ok, "plan: " .. tostring(first and first.Error))
  c.MultiPlaceButton:Click()
  T.same(MultiChosen(), {}, "pinned: left out")
  T.ok(Kept("MULTI"):find(";WONDERS=" .. GARDENS, 1, true) ~= nil, "but still kept: " .. Kept("MULTI"))
  c.MultiReplaceCheck:Toggle()
  T.same(MultiChosen(), { GARDENS }, "replace on: chosen again")
  T.same(multi.Request().Wonders, { GARDENS }, "and planned again")
  c.MultiReplaceCheck:Toggle()
  while SDP_Pins.CanUndo() do c.MultiUndoButton:Click() end
  T.eq(#w:Pins(), 0, "clean")
  multi.SetWonder(GARDENS, false)
  SetCheck(c.MultiRemindCheck, true)
end)
