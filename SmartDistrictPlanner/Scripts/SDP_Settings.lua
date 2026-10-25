-- SDP_Settings: a tab's settings kept in the save (issue 57).
--
-- Each tab (single city, city sites, several cities) keeps its switches,
-- weights, tier and the like under a key of its own in the local player's
-- configuration (PlayerConfiguration:SetValue, where this mod's pins are
-- kept too). The value is the preset's name and only what differs from it:
--   "v1;preset=BALANCED;LAND=0;TIER=FINE;YIELD_GOLD=2"
-- so a later version that changes a preset moves what the player never
-- touched and keeps what they changed. Nothing is broadcast: no other player
-- needs a planner's settings (as Empire Planner does; the game keeps the
-- value in the save either way).
-- Reading checks every entry against the tab's fields: an unknown preset is
-- the default one, an unknown key or a value out of range is dropped (the
-- default stands), so a value written by another version, or a damaged
-- one, never breaks the panel.
--
-- fields: list of { Key, Kind = "number" (Min, Max), "flag" or "choice"
--   (Choices = { [value] = true }), Default, Preset (a preset may set it) },
--   in a fixed order.
-- presets: { [name] = { [key] = value } } for some of the keys; the first
--   name in `order` is the default.

SDP_Settings = {}

SDP_Settings.CONFIG_KEY = "SDP_Settings_"   -- + the tab's name
SDP_Settings.VERSION = "v1"

-- The single-city and several-cities tabs' presets (issue 49, decided
-- 2026-10-25): what each changes from the defaults (the weight columns' and
-- switches' Default); the first is the default. A victory focus raises one
-- yield's weight by FOCUS; FOCUS comes from the experiment on the proven
-- optima (docs/notes/issue-49-presets.md), the smallest of 1.5, 2, 3 that
-- does not merge the preset into Balanced.
SDP_Settings.FOCUS = { SCIENCE = 1.5, CULTURE = 3, RELIGION = 3 }
SDP_Settings.PRESETS = {
  BALANCED = {},
  SCIENCE = { YIELD_SCIENCE = SDP_Settings.FOCUS.SCIENCE },
  CULTURE = { YIELD_CULTURE = SDP_Settings.FOCUS.CULTURE },
  RELIGION = { YIELD_FAITH = SDP_Settings.FOCUS.RELIGION },
  -- Gold and faith at half (purchase prices: 1 production = 4 gold = 2 faith).
  HALF_GOLD_FAITH = { YIELD_GOLD = 0.5, YIELD_FAITH = 0.5 },
}
SDP_Settings.PRESET_ORDER = { "BALANCED", "SCIENCE", "CULTURE", "RELIGION", "HALF_GOLD_FAITH" }

local function Text(value)
  if type(value) == "boolean" then return value and "1" or "0" end
  if type(value) == "number" then
    if value == math.floor(value) then return string.format("%d", value) end
    return string.format("%.4g", value)
  end
  return tostring(value)
end

-- What a key is worth before the player changes it: the preset's value,
-- else the field's default.
function SDP_Settings.Base(field, preset)
  local value = preset ~= nil and preset[field.Key] or nil
  if value == nil then value = field.Default end
  return value
end

-- The text kept for `values` ({ [key] = value }) under preset `name`.
function SDP_Settings.Encode(name, values, fields, presets)
  local preset = presets and presets[name] or nil
  local parts = { SDP_Settings.VERSION, "preset=" .. tostring(name) }
  for _, field in ipairs(fields) do
    local value = values[field.Key]
    if value ~= nil and value ~= SDP_Settings.Base(field, preset) then
      parts[#parts + 1] = field.Key .. "=" .. Text(value)
    end
  end
  return table.concat(parts, ";")
end

local function Parse(field, text)
  if field.Kind == "flag" then
    if text == "1" then return true end
    if text == "0" then return false end
    return nil
  end
  if field.Kind == "number" then
    local value = tonumber(text)
    if value == nil or value ~= value or value < (field.Min or 0) or value > (field.Max or math.huge) then return nil end
    return value
  end
  if field.Kind == "choice" then
    if field.Choices[text] then return text end
    return nil
  end
  return nil
end

-- Read a kept text back: { Preset = name, Values = { [key] = value } for
-- every field, Edited = { [key] = true } for the keys the text changes }.
-- nil text, or another version: the default preset with nothing edited.
function SDP_Settings.Decode(text, fields, presets, order)
  local name = order[1]
  local entries = {}
  if type(text) == "string" then
    local version = text:match("^([^;]*)")
    if version == SDP_Settings.VERSION then
      for key, value in text:gmatch(";([^;=]+)=([^;]*)") do
        if key == "preset" then
          if presets[value] ~= nil then name = value end
        else
          entries[key] = value
        end
      end
    end
  end
  local preset = presets[name]
  local out = { Preset = name, Values = {}, Edited = {} }
  for _, field in ipairs(fields) do
    -- Not `x and Parse(...) or nil`: a flag parses to false.
    local value = nil
    if entries[field.Key] ~= nil then value = Parse(field, entries[field.Key]) end
    if value ~= nil and value ~= SDP_Settings.Base(field, preset) then
      out.Values[field.Key] = value
      out.Edited[field.Key] = true
    else
      out.Values[field.Key] = SDP_Settings.Base(field, preset)
    end
  end
  return out
end

-- Whether `values` differ from preset `name` in a field a preset sets
-- (Preset = true: weights and switches; not the tier or the fold).
function SDP_Settings.Changed(name, values, fields, presets)
  local preset = presets[name]
  for _, field in ipairs(fields) do
    if field.Preset and values[field.Key] ~= SDP_Settings.Base(field, preset) then return true end
  end
  return false
end

local function Config(playerID)
  if playerID == nil or playerID < 0 or PlayerConfigurations == nil then return nil end
  return PlayerConfigurations[playerID]
end

-- What the save keeps for `tab`, decoded (see Decode).
function SDP_Settings.Load(playerID, tab, fields, presets, order)
  local cfg = Config(playerID)
  local text = nil
  if cfg ~= nil and cfg.GetValue ~= nil then
    local ok, value = pcall(cfg.GetValue, cfg, SDP_Settings.CONFIG_KEY .. tab)
    if ok then text = value end
  end
  return SDP_Settings.Decode(text, fields, presets, order)
end

-- Keep `values` under preset `name` for `tab`; not rewritten when unchanged.
local m_written = {} -- [playerID .. tab] = the text last written
function SDP_Settings.Save(playerID, tab, name, values, fields, presets)
  local cfg = Config(playerID)
  if cfg == nil or cfg.SetValue == nil then return false end
  local text = SDP_Settings.Encode(name, values, fields, presets)
  local id = tostring(playerID) .. tab
  if m_written[id] == text then return true end
  local ok = pcall(cfg.SetValue, cfg, SDP_Settings.CONFIG_KEY .. tab, text)
  if ok then m_written[id] = text end
  return ok
end

-- Forget what was written (a new game, tests).
function SDP_Settings.Reset()
  m_written = {}
end

-- A tab's keeper. spec = { Tab, Fields, Presets, Order, Values() -> the
-- tab's values, Apply(values) sets them without side effects }. Restore()
-- reads the save once per local player (hot seat: each player their own)
-- and returns { Preset, Values, Edited } then, nil when already read;
-- Remember(name) keeps the values, only after Restore (so a change made
-- before the save was read never overwrites it); Changed(name) whether the
-- values differ from preset `name` (SDP_Settings.Changed).
function SDP_Settings.Keeper(spec)
  local keeper = { For = nil }
  function keeper.Restore()
    local playerID = Game.GetLocalPlayer()
    if keeper.For == playerID then return nil end
    keeper.For = playerID
    local kept = SDP_Settings.Load(playerID, spec.Tab, spec.Fields, spec.Presets, spec.Order)
    spec.Apply(kept.Values)
    return kept
  end
  function keeper.Changed(name)
    return SDP_Settings.Changed(name, spec.Values(), spec.Fields, spec.Presets)
  end
  -- Set every field a preset may set to preset `name`'s value (the tier and
  -- the fold stay); false for an unknown preset.
  function keeper.Use(name)
    local preset = spec.Presets[name]
    if preset == nil then return false end
    local values = spec.Values()
    for _, field in ipairs(spec.Fields) do
      if field.Preset then values[field.Key] = SDP_Settings.Base(field, preset) end
    end
    spec.Apply(values)
    return true
  end
  function keeper.Remember(name)
    local playerID = Game.GetLocalPlayer()
    if keeper.For ~= playerID then return false end
    return SDP_Settings.Save(playerID, spec.Tab, name, spec.Values(), spec.Fields, spec.Presets)
  end
  return keeper
end
