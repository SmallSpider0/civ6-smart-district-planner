-- @state SDP_Panel
-- @timeout 30
-- Settings kept in the save (issue 57): the game's player configuration
-- takes the text and gives it back, and a change on the panel writes it.
local test, T = ...

local pid = Game.GetLocalPlayer()
local cfg = PlayerConfigurations[pid]

test("the player configuration keeps a tab's settings text", function()
  local key = SDP_Settings.CONFIG_KEY .. "SINGLE"
  local before = cfg:GetValue(key)
  local text = "v1;preset=BALANCED;LAND=0;YIELD_GOLD=0.5"
  cfg:SetValue(key, text)
  T.eq(cfg:GetValue(key), text, "read back as written")
  if before ~= nil then cfg:SetValue(key, before) end
end)

test("a weight changed on the panel is written at once", function()
  SDP_Panel.Refresh()
  local function Kept()
    local columns = {}
    for _, column in ipairs(SDP_UI.WEIGHT_COLUMNS) do columns[#columns + 1] = column end
    columns[#columns + 1] = SDP_UI.COVERAGE_COLUMN
    return SDP_Settings.Load(pid, "SINGLE", SDP_UI.SettingFields(columns, {}, SDP_Tiers.Single),
      SDP_Settings.PRESETS, SDP_Settings.PRESET_ORDER)
  end
  local old = SDP_Panel.State().Weights.YIELD_CULTURE
  local new = old == 3 and 2 or 3
  SDP_Panel.SetWeight("YIELD_CULTURE", new)
  -- Read back, not searched in the text: values equal to a preset are kept
  -- as that preset's name (issue 89; Balanced with culture 3 is Culture).
  local text = cfg:GetValue(SDP_Settings.CONFIG_KEY .. "SINGLE")
  local written = Kept()
  SDP_Panel.SetWeight("YIELD_CULTURE", old)
  local back = Kept()
  T.eq(written and written.Values.YIELD_CULTURE, new, "kept: " .. tostring(text))
  T.eq(back and back.Values.YIELD_CULTURE, old, "back as it was")
end)

-- Issue 91: the city sites tab's distance weight is 0.5 unless the save
-- says otherwise; a preset puts it back to 0.5, still recognised.
test("city sites: a preset sets the distance weight to 0.5, recognised", function()
  SDP_Panel.Refresh()
  local sites = SDP_Panel.Sites
  local before = sites.State()
  local preset, distance = before.Preset, before.Weights.DISTANCE
  sites.SetPreset("BALANCED")
  T.eq(sites.State().Weights.DISTANCE, 0.5, "Balanced: distance 0.5")
  T.eq(sites.State().Preset, "BALANCED", "and the preset recognised")
  local text = cfg:GetValue(SDP_Settings.CONFIG_KEY .. "SITES") or ""
  T.ok(text:find("DISTANCE=", 1, true) == nil, "the default is not written: " .. text)
  sites.SetPreset(preset)
  sites.SetWeight("DISTANCE", distance)
end)

-- Issue 162: the swap switch is on in a game that kept nothing for it; off,
-- the fold line names it with the game's loaded text.
test("the swap switch: on by default, off named on the fold line", function()
  SDP_Panel.Refresh()
  SDP_Panel.SelectTab("SINGLE")
  local kept = cfg:GetValue(SDP_Settings.CONFIG_KEY .. "SINGLE") or ""
  if kept:find("SWAP=", 1, true) == nil then T.eq(SDP_Panel.State().Swap, true, "on: " .. kept) end
  local word = Locale.Lookup("LOC_SDP_FOLD_NO_SWAP")
  T.ok(word ~= "" and word ~= "LOC_SDP_FOLD_NO_SWAP", "the text loads: " .. word)
  local was = SDP_Panel.State().Swap
  SDP_Panel.SetSwap(false)
  local off = SDP_Panel.State().FoldText
  SDP_Panel.SetSwap(true)
  local on = SDP_Panel.State().FoldText
  SDP_Panel.SetSwap(was)
  T.ok(off:find(word, 1, true) ~= nil, "off: named: " .. off)
  T.ok(on:find(word, 1, true) == nil, "on: not named: " .. on)
end)

-- Issue 166: the wonders chosen on the several-cities tab are kept with its
-- other settings, and read back only as wonders of this ruleset.
test("several cities: a chosen wonder is written at once and read back", function()
  SDP_Panel.Refresh()
  SDP_Panel.SelectTab("MULTI")
  local multi = SDP_Panel.Multi
  local wonderType = nil
  for _, w in ipairs(SDP_Wonders.List(pid)) do
    if wonderType == nil and w.Status == nil then wonderType = w.Type end
  end
  T.ok(wonderType ~= nil, "a wonder to choose")
  local was = false
  for _, v in ipairs(multi.State().View.Wonders) do
    if v.Type == wonderType then was = v.Chosen end
  end
  multi.SetWonder(wonderType, true)
  local text = cfg:GetValue(SDP_Settings.CONFIG_KEY .. "MULTI") or ""
  local list = text:match(";WONDERS=([^;]*)") or ""
  local chosen = {}
  SDP_UI.WonderSetting(chosen).Put(list .. ",BUILDING_MONUMENT,BUILDING_NOPE")
  multi.SetWonder(wonderType, was)
  SDP_Panel.SelectTab("SINGLE")
  T.ok(chosen[wonderType] == true, "kept and read back: " .. text)
  T.ok(chosen.BUILDING_MONUMENT == nil, "a building that is not a wonder is dropped")
  T.ok(chosen.BUILDING_NOPE == nil, "a type this ruleset lacks is dropped")
end)
