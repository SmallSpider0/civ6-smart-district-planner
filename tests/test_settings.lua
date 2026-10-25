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
  local key = SDP_Settings.CONFIG_KEY .. "SINGLE"
  local old = SDP_Panel.State().Weights.YIELD_CULTURE
  SDP_Panel.SetWeight("YIELD_CULTURE", old == 3 and 2 or 3)
  local text = cfg:GetValue(key)
  T.ok(type(text) == "string" and text:find("YIELD_CULTURE=" .. (old == 3 and "2" or "3"), 1, true) ~= nil,
    "kept: " .. tostring(text))
  SDP_Panel.SetWeight("YIELD_CULTURE", old)
  local kept = SDP_Settings.Load(pid, "SINGLE", SDP_UI.SettingFields(
    (function()
      local columns = {}
      for _, column in ipairs(SDP_UI.WEIGHT_COLUMNS) do columns[#columns + 1] = column end
      columns[#columns + 1] = SDP_UI.COVERAGE_COLUMN
      return columns
    end)(), {}, SDP_Tiers.Single), SDP_Settings.PRESETS, SDP_Settings.PRESET_ORDER)
  T.eq(kept.Values.YIELD_CULTURE, old, "back as it was")
end)
