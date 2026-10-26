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
