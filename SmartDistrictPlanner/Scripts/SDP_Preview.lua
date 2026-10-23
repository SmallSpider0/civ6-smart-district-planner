-- SDP_Preview: shows a plan on the map without placing map tacks
-- (docs/multicity-design.md section 5). Placing real tacks would broadcast
-- over the network and make DMT recompute; a preview only draws.
--   Areas  colored hexes, one color per city or per shade, on the government
--          lens's layer (MinimapPanel.lua: m_HexColoringGovernment), which
--          draws each area in its own color. The placement layer the game
--          uses for districts (WorldInput.lua: g_HexColoringPlacement) draws
--          every area in its one green whatever color is passed (seen in the
--          game); the appeal lens's layer, used until v1.1.1, makes the game
--          show every plot's appeal number on top (issue 33). Turning the
--          layer on makes the minimap fill in its own colors
--          (MinimapPanel.lua: OnLensLayerOn -> SetGovernmentHexes, an event
--          that comes after the call), so the preview redraws its own hexes
--          when that event arrives (OnLensLayerOn below).
--   Icons  WorldAnchor instances at plots (as MapPinManager and AMT do):
--          the district, wonder or city center icon and a short text
-- The preview must be cleared when the panel closes, the tab or the
-- selected solution changes, or the game enters a placement mode, whose
-- own highlights would mix with ours (Clear, called by the panel).

SDP_Preview = {}

-- Fixed colors per city, in order (names from the game's color database,
-- used by MinimapPanel.lua for the appeal lens).
SDP_Preview.COLORS = {
  "COLOR_BREATHTAKING_APPEAL", "COLOR_CHARMING_APPEAL", "COLOR_AVERAGE_APPEAL", "COLOR_DISGUSTING_APPEAL",
}

SDP_Preview.LAYER = "Hex_Coloring_Government"

local m_layer = nil
local m_icons = nil       -- InstanceManager of world icons
local m_layerOn = false   -- we switched the layer on
local m_shown = false
local m_drawn = nil       -- { PlayerID, Areas } last shown, for redrawing

local function Draw()
  UILens.ClearLayerHexes(m_layer)
  for _, area in ipairs(m_drawn.Areas) do
    if #area.Plots > 0 then
      local name = SDP_Preview.COLORS[(area.Color - 1) % #SDP_Preview.COLORS + 1]
      UILens.SetLayerHexesColoredArea(m_layer, m_drawn.PlayerID, area.Plots, UI.GetColorValue(name))
    end
  end
end

-- The minimap filled the layer with appeal colors: put ours back.
local function OnLensLayerOn(layerNum)
  if m_shown and m_layer ~= nil and layerNum == m_layer then Draw() end
end

-- `container`: a control of the panel's context to hold the world icons;
-- `instanceName`: the WorldAnchor instance (root ID "Anchor").
function SDP_Preview.Init(container, instanceName)
  m_icons = InstanceManager:new(instanceName, "Anchor", container)
  Events.LensLayerOn.Add(OnLensLayerOn)
end

function SDP_Preview.Shutdown()
  Events.LensLayerOn.Remove(OnLensLayerOn)
end

local function Layer()
  if m_layer == nil then m_layer = UILens.CreateLensLayerHash(SDP_Preview.LAYER) end
  return m_layer
end

function SDP_Preview.IsShown()
  return m_shown
end

function SDP_Preview.Clear()
  if m_icons ~= nil then m_icons:ResetInstances() end
  if m_layer ~= nil and m_shown then
    UILens.ClearLayerHexes(m_layer)
    if m_layerOn then
      UILens.ToggleLayerOff(m_layer)
      m_layerOn = false
    end
  end
  m_shown = false
  m_drawn = nil
end

-- Show areas = { { Plots = { plot index }, Color = n } } (Color: index into
-- COLORS) and icons = { { X, Y, Icon, Text } }. Replaces what was shown.
function SDP_Preview.Show(playerID, areas, icons)
  SDP_Preview.Clear()
  local layer = Layer()
  m_drawn = { PlayerID = playerID, Areas = areas }
  m_shown = true
  if not UILens.IsLayerOn(layer) then
    UILens.ToggleLayerOn(layer)
    m_layerOn = true
  end
  Draw()
  if m_icons ~= nil then
    for _, icon in ipairs(icons) do
      local inst = m_icons:GetInstance()
      inst.Icon:SetIcon(icon.Icon)
      inst.Text:SetText(icon.Text or "")
      inst.TextBacking:SetHide(icon.Text == nil or icon.Text == "")
      local x, y, z = UI.GridToWorld(icon.X, icon.Y)
      inst.Anchor:SetWorldPositionVal(x, y, (z or 0) + 12)
    end
  end
  m_shown = true
end

-- Move the camera to a plot.
function SDP_Preview.Focus(x, y)
  UI.LookAtPlot(x, y)
end
