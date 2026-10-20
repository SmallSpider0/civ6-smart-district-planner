-- SDP_Pins: turns a plan into map tacks with district icons and undoes the
-- last batch. Pins are made the way DMT's pin popup makes them on OK and
-- deleted the way DMT's right-click delete does (requirements pitfall 19), so
-- DMT shows their yields and fully forgets them again. Pins already on the
-- map are never touched (requirement constraint 7), except this mod's own
-- pins when the player asks to replace them (Own, Place with Replace).
--
-- The batches are kept in the player's configuration (saved with the game),
-- so undo still works after loading a save and "replace" knows which pins
-- this mod made (design 18, item 4). A recorded pin counts as ours only while
-- it is unchanged: same plot, icon and name. A pin the player edited or
-- deleted is dropped from the record and never touched again.

SDP_Pins = {}

-- Player configuration key of the record (saved with the game).
SDP_Pins.CONFIG_KEY = "SDP_PinBatches"

local m_batches = {} -- [playerID] = undo stack: { { Pins = { { ID, X, Y, Icon, Name } }, Replaced = {...} } }

-- The player's pin at (x, y), or nil. PlayerConfiguration:GetMapPin(x, y)
-- would create one, so search GetMapPins() instead.
local function PinAt(cfg, x, y)
  for _, pin in pairs(cfg:GetMapPins()) do
    if pin:GetHexX() == x and pin:GetHexY() == y then return pin end
  end
  return nil
end

-- ===========================================================================
-- The record
-- ===========================================================================
-- "id:x:y:icon:name" per pin, "," between pins, ";" between batches; a
-- batch's replaced pins follow a "|" (same fields, id 0). Icons are type
-- names and names city numbers, neither holds a separator.
local function EncodePin(p)
  return table.concat({ p.ID or 0, p.X, p.Y, p.Icon or "", p.Name or "" }, ":")
end

local function DecodePin(text)
  local id, x, y, icon, name = text:match("^(%-?%d+):(%-?%d+):(%-?%d+):([^:]*):(.*)$")
  if id == nil then return nil end
  return { ID = tonumber(id), X = tonumber(x), Y = tonumber(y), Icon = icon, Name = name }
end

local function EncodeList(list)
  local parts = {}
  for _, p in ipairs(list) do parts[#parts + 1] = EncodePin(p) end
  return table.concat(parts, ",")
end

local function DecodeList(text)
  local list = {}
  for part in (text or ""):gmatch("[^,]+") do
    local p = DecodePin(part)
    if p ~= nil then list[#list + 1] = p end
  end
  return list
end

local function Save(playerID)
  local parts = {}
  for _, batch in ipairs(m_batches[playerID] or {}) do
    local text = EncodeList(batch.Pins)
    if batch.Replaced and #batch.Replaced > 0 then text = text .. "|" .. EncodeList(batch.Replaced) end
    parts[#parts + 1] = text
  end
  PlayerConfigurations[playerID]:SetValue(SDP_Pins.CONFIG_KEY, table.concat(parts, ";"))
end

-- Whether a recorded pin is still on the map as we left it.
local function Unchanged(cfg, record)
  local pin = cfg:GetMapPinID(record.ID)
  return pin ~= nil and pin:GetHexX() == record.X and pin:GetHexY() == record.Y
    and (pin:GetIconName() or "") == record.Icon and (pin:GetName() or "") == record.Name
end

-- The player's batches, read from the configuration once, pruned of pins
-- that are no longer ours.
local function Batches(playerID)
  local batches = m_batches[playerID]
  if batches ~= nil then return batches end
  batches = {}
  local cfg = PlayerConfigurations[playerID]
  local text = cfg:GetValue(SDP_Pins.CONFIG_KEY)
  for chunk in (type(text) == "string" and text or ""):gmatch("[^;]+") do
    local pinsText, replacedText = chunk:match("^([^|]*)|?(.*)$")
    local pins = {}
    for _, record in ipairs(DecodeList(pinsText)) do
      if Unchanged(cfg, record) then pins[#pins + 1] = record end
    end
    local replaced = DecodeList(replacedText)
    if #pins > 0 or #replaced > 0 then batches[#batches + 1] = { Pins = pins, Replaced = replaced } end
  end
  m_batches[playerID] = batches
  return batches
end

-- Forget what was read (a new game, tests).
function SDP_Pins.Reset()
  m_batches = {}
end

-- This mod's pins still on the map unchanged, for cities numbered `numbers`
-- (a list of city numbers: the pins' names): { { ID, X, Y, Icon, Name } }
-- sorted by plot. These are what "replace my earlier pins" removes.
function SDP_Pins.Own(playerID, numbers)
  local wanted = {}
  for _, n in ipairs(numbers or {}) do wanted[tostring(n)] = true end
  local cfg, out = PlayerConfigurations[playerID], {}
  for _, batch in ipairs(Batches(playerID)) do
    for _, record in ipairs(batch.Pins) do
      if wanted[record.Name] and Unchanged(cfg, record) then out[#out + 1] = record end
    end
  end
  table.sort(out, function(a, b) return Map.GetPlotIndex(a.X, a.Y) < Map.GetPlotIndex(b.X, b.Y) end)
  return out
end

-- ===========================================================================
-- Place and undo
-- ===========================================================================
local function Delete(cfg, id)
  LuaEvents.DMT_MapPinRemoved(cfg:GetMapPinID(id))
  cfg:DeleteMapPin(id)
end

-- Make pins for entries { Type, X, Y, Name } where there is none. Returns the
-- records { ID, X, Y, Icon, Name }; the caller broadcasts and tells DMT.
local function Make(cfg, entries)
  local made = {}
  for _, entry in ipairs(entries) do
    if PinAt(cfg, entry.X, entry.Y) == nil then
      local pin = cfg:GetMapPin(entry.X, entry.Y)
      local icon = entry.Icon or ("ICON_" .. entry.Type)
      pin:SetName(entry.Name or "")
      pin:SetIconName(icon)
      made[#made + 1] = { ID = pin:GetID(), X = entry.X, Y = entry.Y, Icon = icon, Name = entry.Name or "" }
    end
  end
  return made
end

local function Announce(cfg, records)
  Network.BroadcastPlayerInfo()
  for _, record in ipairs(records) do
    LuaEvents.DMT_MapPinAdded(cfg:GetMapPinID(record.ID))
  end
end

-- One pin per plan entry ({ Type, X, Y, Name }): Type is a district or a
-- wonder (building) type and gives the icon; the pin is named Name (callers
-- pass the city number) or left unnamed. Plots that already have a pin are
-- skipped. options.Replace: this mod's pins to delete first (from Own; only
-- those still unchanged are deleted, and undo puts them back). Returns the
-- number of pins placed; a batch that placed or replaced pins can be undone.
--
-- Only pin IDs are kept: creating a pin can invalidate the objects of pins
-- made before it, and calling a stale one crashed the game (2026-10-19).
-- Like DMT's popup (GetEditPinConfig), every use re-fetches by ID.
function SDP_Pins.Place(playerID, plan, options)
  local cfg = PlayerConfigurations[playerID]
  local batches = Batches(playerID)
  local replaced = {}
  for _, record in ipairs((options and options.Replace) or {}) do
    if Unchanged(cfg, record) then
      Delete(cfg, record.ID)
      replaced[#replaced + 1] = { ID = 0, X = record.X, Y = record.Y, Icon = record.Icon, Name = record.Name }
    end
  end
  if #replaced > 0 then
    -- Out of their batches: they are gone, this batch remembers them.
    for _, batch in ipairs(batches) do
      local keep = {}
      for _, record in ipairs(batch.Pins) do
        if cfg:GetMapPinID(record.ID) ~= nil then keep[#keep + 1] = record end
      end
      batch.Pins = keep
    end
  end
  local made = Make(cfg, plan)
  if #made == 0 and #replaced == 0 then return 0 end
  Announce(cfg, made)
  if #made > 0 then UI.PlaySound("Map_Pin_Add") end
  batches[#batches + 1] = { Pins = made, Replaced = replaced }
  Save(playerID)
  Network.BroadcastPlayerInfo()
  return #made
end

function SDP_Pins.CanUndo(playerID)
  return #Batches(playerID or Game.GetLocalPlayer()) > 0
end

-- The last batch: { Pins = { { ID, X, Y, Icon, Name } }, Replaced }.
function SDP_Pins.LastBatch(playerID)
  local batches = Batches(playerID or Game.GetLocalPlayer())
  return batches[#batches]
end

-- Delete the last batch's pins and put back the pins it replaced. A pin the
-- player has since deleted or changed is left alone. Returns the number
-- deleted.
function SDP_Pins.UndoLast(playerID)
  playerID = playerID or Game.GetLocalPlayer()
  local batches = Batches(playerID)
  local batch = table.remove(batches)
  if batch == nil then return 0 end
  local cfg = PlayerConfigurations[playerID]
  local removed = 0
  for i = #batch.Pins, 1, -1 do
    local record = batch.Pins[i]
    if Unchanged(cfg, record) then
      Delete(cfg, record.ID)
      removed = removed + 1
    end
  end
  if batch.Replaced and #batch.Replaced > 0 then
    -- The replaced pins come back as a batch of their own.
    local restored = Make(cfg, batch.Replaced)
    Announce(cfg, restored)
    if #restored > 0 then batches[#batches + 1] = { Pins = restored, Replaced = {} } end
  end
  Save(playerID)
  Network.BroadcastPlayerInfo()
  UI.PlaySound("Map_Pin_Remove")
  return removed
end
