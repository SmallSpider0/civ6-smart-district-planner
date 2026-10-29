-- Offline: the panel's settings kept in the save (issue 57, SDP_Settings).
-- A save is simulated by values in the player's configuration before the
-- panel's script runs, as when the game loads a save into a new context.
local test, T = ...

local UI_Mock = include("ui")

local MAP = {
  "~~~~~~~~~~~~~~",
  "~..f.M..h...f~",
  "~.fMj..p.d...~",
  "~h..f.j..M.h.~",
  "~.pM...f.h..p~",
  "~..j.p..q....~",
  "~f..h.M.j..f.~",
  "~~~~~~~~~~~~~~",
}

World.New({ rows = MAP, cities = { { id = 1, x = 5, y = 3, population = 6, capital = true, radius = 1 } } })
local broadcasts = 0
Network.BroadcastPlayerInfo = function() broadcasts = broadcasts + 1 end
local cfg = PlayerConfigurations[0]
cfg:SetValue("SDP_Settings_SINGLE", "v1;preset=BALANCED;LAND=0;YIELD_GOLD=3;TIER=FINE;HOUSING=9;BOGUS=1;SWAP=yes")
-- Several cities: a save written by v1.5.0 with a change from Science (issue 89).
cfg:SetValue("SDP_Settings_MULTI", "v1;preset=SCIENCE;YIELD_GOLD=2")
cfg:SetValue("SDP_Settings_SITES",
  "v1;preset=GROWTH;APPEAL=1;K=2;D=9;COUNT=4;DISTRICTS=DISTRICT_PRESERVE:P,DISTRICT_CAMPUS:M,bad entry,DISTRICT_NOPE:M")
UI_Mock.Install()
include("SDP_Panel")

local FIELDS = {
  { Key = "A", Kind = "number", Min = 0, Max = 3, Default = 1, Preset = true },
  { Key = "B", Kind = "flag", Default = true, Preset = true },
  { Key = "TIER", Kind = "choice", Choices = { FAST = true, STANDARD = true }, Default = "STANDARD" },
}
local PRESETS = { BALANCED = {}, HIGH = { A = 2 } }
local ORDER = { "BALANCED", "HIGH" }

test("encode: the preset's name and only what differs from it", function()
  T.eq(SDP_Settings.Encode("BALANCED", { A = 1, B = true, TIER = "STANDARD" }, FIELDS, PRESETS), "v1;preset=BALANCED",
    "nothing changed")
  T.eq(SDP_Settings.Encode("HIGH", { A = 2, B = false, TIER = "FAST" }, FIELDS, PRESETS), "v1;preset=HIGH;B=0;TIER=FAST",
    "the preset's own value is not written")
  T.eq(SDP_Settings.Encode("BALANCED", { A = 0.5, B = true, TIER = "STANDARD" }, FIELDS, PRESETS), "v1;preset=BALANCED;A=0.5",
    "a fraction")
end)

test("decode: back to the values; what is unknown or out of range keeps the default", function()
  local kept = SDP_Settings.Decode("v1;preset=HIGH;B=0;TIER=FAST", FIELDS, PRESETS, ORDER)
  T.eq(kept.Preset, "HIGH", "preset")
  T.same(kept.Values, { A = 2, B = false, TIER = "FAST" }, "values: the preset, then the changes")
  T.same(kept.Edited, { B = true, TIER = true }, "edited")
  local bad = SDP_Settings.Decode("v1;preset=NOPE;A=4;B=2;TIER=FINE;Z=1;A", FIELDS, PRESETS, ORDER)
  T.eq(bad.Preset, "BALANCED", "unknown preset: the default one")
  T.same(bad.Values, { A = 1, B = true, TIER = "STANDARD" }, "out of range, not a flag, not a choice: defaults")
  T.same(SDP_Settings.Decode("v2;A=0", FIELDS, PRESETS, ORDER).Values, { A = 1, B = true, TIER = "STANDARD" },
    "another version: defaults")
  T.same(SDP_Settings.Decode(nil, FIELDS, PRESETS, ORDER).Values, { A = 1, B = true, TIER = "STANDARD" }, "nothing kept")
  T.eq(SDP_Settings.Changed("HIGH", { A = 2, B = true, TIER = "FAST" }, FIELDS, PRESETS), false,
    "the tier does not change the preset")
  T.eq(SDP_Settings.Changed("HIGH", { A = 3, B = true, TIER = "STANDARD" }, FIELDS, PRESETS), true, "a weight does")
end)

test("match: the preset the values equal, the current one first, else none (issue 89)", function()
  local function Values(a, b, tier) return { A = a, B = b, TIER = tier or "STANDARD" } end
  T.eq(SDP_Settings.Match("BALANCED", Values(1, true, "FAST"), FIELDS, PRESETS, ORDER), "BALANCED",
    "equal to the current one; the tier does not count")
  T.eq(SDP_Settings.Match("BALANCED", Values(2, true), FIELDS, PRESETS, ORDER), "HIGH", "equal to another one")
  T.eq(SDP_Settings.Match("HIGH", Values(1, true), FIELDS, PRESETS, ORDER), "BALANCED", "back to the default one")
  T.eq(SDP_Settings.Match("HIGH", Values(3, true), FIELDS, PRESETS, ORDER), nil, "a weight equal to no preset: none")
  T.eq(SDP_Settings.Match("HIGH", Values(2, false), FIELDS, PRESETS, ORDER), nil, "a switch counts too")
  local twins, twinOrder = { BALANCED = {}, SAME = {} }, { "BALANCED", "SAME" }
  T.eq(SDP_Settings.Match("SAME", Values(1, true), FIELDS, twins, twinOrder), "SAME", "two equal: the current one")
  T.eq(SDP_Settings.Match("NOPE", Values(1, true), FIELDS, twins, twinOrder), "BALANCED",
    "an unknown current one: the first in order")
end)

test("a loaded save: each tab gets back what it kept", function()
  SDP_Panel.Open()
  SDP_Panel.SelectCity(1)
  local s = SDP_Panel.State()
  T.eq(s.Weights.LAND, 0, "a kept LAND=0: the land weight 0 (it was the switch)")
  T.eq(s.Land, false, "the land part off")
  T.eq(s.Weights.YIELD_GOLD, 3, "gold weight")
  T.eq(s.Tier, "FINE", "tier")
  T.eq(UI_Mock.Controls.TierPull:GetButton():GetText(), "LOC_SDP_TIER_FINE", "the tier shown")
  T.eq(s.Weights.HOUSING, 1, "a weight out of range: the default")
  T.eq(s.Swap, true, "a switch that is not 0 or 1: the default (on, issue 162)")
  T.eq(s.Remind, true, "what was not kept: the default")
  SDP_Panel.SelectTab("MULTI")
  local m = SDP_Panel.Multi.State()
  T.eq(m.Weights.YIELD_GOLD, 2, "several cities: its own gold weight")
  T.eq(m.Weights.YIELD_SCIENCE, SDP_Settings.FOCUS.SCIENCE, "and the preset's science")
  T.eq(m.Remind, true, "and its own reminder switch")
  T.eq(m.Land, true, "and its own land switch")
  T.eq(m.Preset, "SCIENCE", "the preset read stays the current one")
  T.eq(UI_Mock.Controls.MultiPresetPull:GetButton():GetText(), "LOC_SDP_PRESET_CUSTOM",
    "a v1.5.0 save with a change: Custom (issue 89)")
  T.ok(m.FoldText:find("LOC_SDP_PRESET_CUSTOM", 1, true) ~= nil, "on the fold line too")
  SDP_Panel.SelectTab("SITES")
  local sites = SDP_Panel.Sites.State()
  T.eq(sites.Preset, "GROWTH", "city sites: the preset")
  T.eq(UI_Mock.Controls.SitesPresetPull:GetButton():GetText(), "LOC_SDP_PRESET_CUSTOM", "a change: Custom")
  T.eq(sites.Weights.YIELD_FOOD, SDP_Sites.PRESETS.GROWTH.YIELD_FOOD, "its weights")
  T.eq(sites.Weights.APPEAL, 1, "and the change")
  T.eq(sites.Weights.DISTANCE, 0.5, "a save without the distance weight: the default 0.5 (issue 91)")
  T.eq(sites.K, 2, "the number of new cities (issue 84)")
  T.eq(sites.D, 9, "and the distance")
  T.eq(UI_Mock.Controls.SitesDistance:GetText(), "9", "the distance shown")
  -- Issue 90: the district states and the count.
  T.eq(sites.DistrictCount, 4, "the district count")
  T.eq(UI_Mock.Controls.SitesPlanValue:GetText(), "4", "shown")
  local states = {}
  for _, row in ipairs(sites.View.Districts) do states[row.Type] = row.State end
  T.eq(states.DISTRICT_CAMPUS, "MUST", "a required campus")
  T.eq(states.DISTRICT_PRESERVE, "POOL", "a preserve set to candidate")
  T.eq(states.DISTRICT_HOLY_SITE, "POOL", "the rest: their defaults")
  T.eq(states.DISTRICT_ENCAMPMENT, "OFF", "the rest: their defaults")
  SDP_Panel.SelectTab("SINGLE")
  for _, row in ipairs(SDP_Panel.State().DistrictRows) do
    if row.Type == "DISTRICT_CAMPUS" then T.eq(row.State, "POOL", "the single-city tab has its own states") end
  end
end)

test("a change through the controls is kept at once, with no broadcast", function()
  local cells = SDP_Panel.State().WeightCells
  local science = nil
  for _, cell in ipairs(cells) do
    if cell.Key == "YIELD_SCIENCE" then science = cell end
  end
  science.More:Click()
  local text = cfg:GetValue("SDP_Settings_SINGLE")
  T.ok(text:find(";YIELD_SCIENCE=1.5", 1, true) ~= nil, "science up by 0.5 (issue 53) and kept: " .. text)
  T.ok(text:find(";LAND=0", 1, true) ~= nil, "the land switch still kept")
  UI_Mock.Controls.FeatureCheck:Toggle()
  T.eq(SDP_Panel.State().AllowFeatureRemoval, false, "the switch")
  T.ok(cfg:GetValue("SDP_Settings_SINGLE"):find(";ALLOW_REMOVAL=0", 1, true) ~= nil, "kept")
  UI_Mock.Controls.FeatureCheck:Toggle()
  T.ok(cfg:GetValue("SDP_Settings_SINGLE"):find("ALLOW_REMOVAL", 1, true) == nil, "back to the default: not written")
  SDP_Panel.Multi.SetWeight("YIELD_FAITH", 0)
  T.ok(cfg:GetValue("SDP_Settings_MULTI"):find(";YIELD_FAITH=0", 1, true) ~= nil, "several cities: kept under its own key")
  T.ok(cfg:GetValue("SDP_Settings_SINGLE"):find("YIELD_FAITH", 1, true) == nil, "not on the single-city tab")
  T.eq(broadcasts, 0, "nothing broadcast")
end)

test("a list field: items that match, sorted; nothing kept is the empty default (issue 90)", function()
  local fields = { { Key = "L", Kind = "list", Pattern = "^[%w_]+:[MPO]$", Default = "" } }
  T.eq(SDP_Settings.Encode("BALANCED", { L = "" }, fields, PRESETS), "v1;preset=BALANCED", "empty: not written")
  T.eq(SDP_Settings.Encode("BALANCED", { L = "A:M,B:O" }, fields, PRESETS), "v1;preset=BALANCED;L=A:M,B:O", "written")
  T.eq(SDP_Settings.Decode("v1;preset=BALANCED;L=B:O,x y,A:M,C:Q", fields, PRESETS, ORDER).Values.L, "A:M,B:O",
    "bad items dropped, sorted")
end)

test("city sites: the district grid and count are kept under the tab's key (issue 90)", function()
  SDP_Panel.SelectTab("SITES")
  local function Row(districtType)
    for _, row in ipairs(SDP_Panel.Sites.State().View.Districts) do
      if row.Type == districtType then return row end
    end
  end
  Row("DISTRICT_THEATER").Cell:Click()
  local text = cfg:GetValue("SDP_Settings_SITES")
  T.ok(text:find("DISTRICT_THEATER:M", 1, true) ~= nil, "a required theater kept: " .. text)
  T.ok(text:find("DISTRICT_CAMPUS:M", 1, true) ~= nil, "the campus still")
  T.ok(text:find(";COUNT=4", 1, true) ~= nil, "the count")
  Row("DISTRICT_THEATER").Cell:Click()
  Row("DISTRICT_THEATER").Cell:Click()
  text = cfg:GetValue("SDP_Settings_SITES")
  T.ok(text:find("DISTRICT_THEATER", 1, true) == nil, "back to a candidate, its default: not written: " .. text)
  UI_Mock.Controls.SitesPlanLess:Click()
  T.ok(cfg:GetValue("SDP_Settings_SITES"):find("COUNT=", 1, true) == nil, "back to 3: not written")
  T.ok(cfg:GetValue("SDP_Settings_SINGLE"):find("DISTRICT", 1, true) == nil, "nothing on the single-city tab's key")
  SDP_Panel.SelectTab("SINGLE")
end)

-- Issue 91 (decided 2026-10-27): the distance weight on the city sites tab
-- starts at 0.5; a changed value is kept, the default is not written, and a
-- preset puts it back to 0.5 and is still recognised.
test("city sites: the distance weight 0.5 by default, a change kept, a preset back to 0.5 (issue 91)", function()
  SDP_Panel.SelectTab("SITES")
  local sites = SDP_Panel.Sites
  local pull = UI_Mock.Controls.SitesPresetPull
  sites.SetPreset("DISTRICTS")
  T.eq(sites.State().Weights.DISTANCE, 0.5, "the preset: 0.5")
  T.eq(pull:GetButton():GetText(), "LOC_SDP_PRESET_DISTRICTS", "and the preset recognised, not Custom")
  local text = cfg:GetValue("SDP_Settings_SITES")
  T.ok(text:find("DISTANCE=", 1, true) == nil, "the default is not written: " .. text)
  local distance = nil
  for _, c in ipairs(sites.State().View.WeightCells) do
    if c.Key == "DISTANCE" then distance = c end
  end
  T.eq(distance.Value:GetText(), "0.5", "shown")
  distance.Less:Click()
  T.eq(sites.State().Weights.DISTANCE, 0, "down to 0 through the arrow")
  T.eq(pull:GetButton():GetText(), "LOC_SDP_PRESET_CUSTOM", "a change: Custom")
  text = cfg:GetValue("SDP_Settings_SITES")
  T.ok(text:find(";DISTANCE=0", 1, true) ~= nil, "0 kept: " .. text)
  -- What a later load reads from that text: the 0 kept; a text without the
  -- key (a save from before) gives 0.5.
  local fields = SDP_UI.SettingFields({ { Key = "DISTANCE", Default = SDP_Sites.DEFAULT_DISTANCE } }, {}, SDP_Tiers.Sites)
  T.eq(SDP_Settings.Decode(text, fields, SDP_Sites.PRESETS, SDP_Sites.PRESET_ORDER).Values.DISTANCE, 0, "loaded: 0")
  T.eq(SDP_Settings.Decode("v1;preset=BALANCED", fields, SDP_Sites.PRESETS, SDP_Sites.PRESET_ORDER).Values.DISTANCE, 0.5,
    "never changed: 0.5")
  sites.SetPreset("BALANCED")
  T.eq(sites.State().Weights.DISTANCE, 0.5, "Balanced: 0.5 again")
  T.eq(pull:GetButton():GetText(), "LOC_SDP_PRESET_BALANCED", "recognised")
  T.ok(cfg:GetValue("SDP_Settings_SITES"):find("DISTANCE=", 1, true) == nil, "not written")
  SDP_Panel.SelectTab("SINGLE")
end)

test("city sites: the number of new cities and the distance are kept, the default 5 is not written (issue 84)", function()
  SDP_Panel.SelectTab("SITES")
  for _ = 1, 4 do UI_Mock.Controls.SitesDistanceLess:Click() end
  T.eq(SDP_Panel.Sites.State().D, 5, "9 down to 5")
  local text = cfg:GetValue("SDP_Settings_SITES")
  T.ok(text:find("D=", 1, true) == nil, "the default distance is not written: " .. text)
  T.ok(text:find(";K=2", 1, true) ~= nil, "the number of new cities still kept")
  UI_Mock.Controls.SitesDistanceLess:Click()
  UI_Mock.Controls.SitesCountMore:Click()
  text = cfg:GetValue("SDP_Settings_SITES")
  T.ok(text:find(";D=4", 1, true) ~= nil, "4 kept: " .. text)
  T.ok(text:find("K=", 1, true) == nil, "back to 3 new cities: not written")
  local fields = SDP_UI.SettingFields({}, {}, SDP_Tiers.Sites,
    { { Key = "K", Kind = "number", Min = 1, Max = 6, Default = 3 }, { Key = "D", Kind = "number", Min = 4, Max = 15, Default = 5 } })
  T.same(SDP_Settings.Decode("v1;preset=BALANCED;D=20;K=0", fields, SDP_Sites.PRESETS, SDP_Sites.PRESET_ORDER).Edited, {},
    "a number field from Extra keeps its range: out of range, the defaults")
  SDP_Panel.SelectTab("SINGLE")
end)
