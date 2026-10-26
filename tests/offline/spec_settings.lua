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
cfg:SetValue("SDP_Settings_MULTI", "v1;preset=NOT_A_PRESET;REMIND=0;COVERAGE=2")
cfg:SetValue("SDP_Settings_SITES", "v1;preset=GROWTH;APPEAL=1;K=2;D=9")
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
  T.eq(s.Swap, false, "a switch that is not 0 or 1: the default")
  T.eq(s.Remind, true, "what was not kept: the default")
  SDP_Panel.SelectTab("MULTI")
  local m = SDP_Panel.Multi.State()
  T.eq(m.Remind, false, "several cities: its own reminder switch")
  T.eq(m.Land, true, "and its own land switch")
  T.eq(m.Weights.COVERAGE, 2, "and coverage")
  SDP_Panel.SelectTab("SITES")
  local sites = SDP_Panel.Sites.State()
  T.eq(sites.Preset, "GROWTH", "city sites: the preset")
  T.eq(sites.Weights.YIELD_FOOD, SDP_Sites.PRESETS.GROWTH.YIELD_FOOD, "its weights")
  T.eq(sites.Weights.APPEAL, 1, "and the change")
  T.eq(sites.K, 2, "the number of new cities (issue 84)")
  T.eq(sites.D, 9, "and the distance")
  T.eq(UI_Mock.Controls.SitesDistance:GetText(), "9", "the distance shown")
  SDP_Panel.SelectTab("SINGLE")
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
