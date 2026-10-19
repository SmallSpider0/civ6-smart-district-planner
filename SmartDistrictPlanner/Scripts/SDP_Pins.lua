-- SDP_Pins: turns a plan into map tacks with district icons and undoes the
-- last batch. Pins are made the way DMT's pin popup makes them on OK and
-- deleted the way DMT's right-click delete does (requirements pitfall 19), so
-- DMT shows their yields and fully forgets them again. Pins already on the
-- map are never touched (requirement constraint 7).

SDP_Pins = {}

local m_batches = {} -- undo stack: { PlayerID, Pins = { { ID, X, Y } } }

-- The player's pin at (x, y), or nil. PlayerConfiguration:GetMapPin(x, y)
-- would create one, so search GetMapPins() instead.
local function PinAt(cfg, x, y)
  for _, pin in pairs(cfg:GetMapPins()) do
    if pin:GetHexX() == x and pin:GetHexY() == y then return pin end
  end
  return nil
end

-- One pin per plan entry ({ Type, X, Y }), named after the district, with
-- the district's icon. Plots that already have a pin are skipped. Returns
-- the number of pins placed; a non-empty batch can be undone.
--
-- Only pin IDs are kept: creating a pin can invalidate the objects of pins
-- made before it, and calling a stale one crashed the game (2026-10-19).
-- Like DMT's popup (GetEditPinConfig), every use re-fetches by ID.
function SDP_Pins.Place(playerID, plan)
  local cfg = PlayerConfigurations[playerID]
  local batch = { PlayerID = playerID, Pins = {} }
  for _, entry in ipairs(plan) do
    if PinAt(cfg, entry.X, entry.Y) == nil then
      local pin = cfg:GetMapPin(entry.X, entry.Y)
      pin:SetName(Locale.Lookup(GameInfo.Districts[entry.Type].Name))
      pin:SetIconName("ICON_" .. entry.Type)
      batch.Pins[#batch.Pins + 1] = { ID = pin:GetID(), X = entry.X, Y = entry.Y }
    end
  end
  if #batch.Pins == 0 then return 0 end
  Network.BroadcastPlayerInfo()
  for _, record in ipairs(batch.Pins) do
    LuaEvents.DMT_MapPinAdded(cfg:GetMapPinID(record.ID))
  end
  UI.PlaySound("Map_Pin_Add")
  m_batches[#m_batches + 1] = batch
  return #batch.Pins
end

function SDP_Pins.CanUndo()
  return #m_batches > 0
end

-- The pins of the last batch that are still where they were placed.
function SDP_Pins.LastBatch()
  return m_batches[#m_batches]
end

-- Delete the last batch's pins. A pin the player has since deleted or that
-- is no longer at its plot is left alone. Returns the number deleted.
function SDP_Pins.UndoLast()
  local batch = table.remove(m_batches)
  if batch == nil then return 0 end
  local cfg = PlayerConfigurations[batch.PlayerID]
  local removed = 0
  for i = #batch.Pins, 1, -1 do
    local record = batch.Pins[i]
    local pin = cfg:GetMapPinID(record.ID)
    if pin ~= nil and pin:GetHexX() == record.X and pin:GetHexY() == record.Y then
      LuaEvents.DMT_MapPinRemoved(pin)
      cfg:DeleteMapPin(record.ID)
      removed = removed + 1
    end
  end
  Network.BroadcastPlayerInfo()
  UI.PlaySound("Map_Pin_Remove")
  return removed
end
