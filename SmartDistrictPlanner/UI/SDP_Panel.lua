-- SDP_Panel: launch bar entry and the planner panel.
-- The panel opens through the popup queue: an AddUserInterfaces context sits
-- at the bottom of the render stack, so SetHide(false) alone shows nothing
-- (requirements pitfall 11).

include("MapTacks")   -- game file: the player's district list
include("SDP_Rules")
include("SDP_City")

local LAUNCH_BAR_STACK = "/InGame/LaunchBar/ButtonStack"

local m_launchItem = {}     -- SDP_LaunchBarItem instance in the game's launch bar
local m_launchPin = {}      -- SDP_LaunchBarPin instance next to it

local function IsOpen()
  return UIManager:IsInPopupQueue(ContextPtr)
end

local function Open()
  if IsOpen() then return end
  UIManager:QueuePopup(ContextPtr, PopupPriority.Low)
  UI.PlaySound("UI_Screen_Open")
end

local function Close()
  if not IsOpen() then return end
  UIManager:DequeuePopup(ContextPtr)
  UI.PlaySound("UI_Screen_Close")
end

local function Toggle()
  if IsOpen() then Close() else Open() end
end

-- Mirrors RealizeBacking() in the game's LaunchBar.lua, which lives in
-- another context and cannot be called from here.
local function ResizeLaunchBar(stack)
  stack:CalculateSize()
  local width = stack:GetSizeX()
  local backing = ContextPtr:LookUpControl("/InGame/LaunchBar/LaunchBacking")
  local tile = ContextPtr:LookUpControl("/InGame/LaunchBar/LaunchBackingTile")
  local shadow = ContextPtr:LookUpControl("/InGame/LaunchBar/LaunchBarDropShadow")
  if backing ~= nil then backing:SetSizeX(width + 116) end
  if tile ~= nil then tile:SetSizeX(math.max(0, width - 20)) end
  if shadow ~= nil then shadow:SetSizeX(width) end
  LuaEvents.LaunchBar_Resize(width)
end

local function InjectLaunchButton()
  if m_launchItem.LaunchItemButton ~= nil then return true end
  local stack = ContextPtr:LookUpControl(LAUNCH_BAR_STACK)
  if stack == nil then return false end

  ContextPtr:BuildInstanceForControl("SDP_LaunchBarItem", m_launchItem, stack)
  ContextPtr:BuildInstanceForControl("SDP_LaunchBarPin", m_launchPin, stack)
  m_launchItem.LaunchItemIcon:SetIcon("ICON_MAP_PIN_DISTRICT")
  m_launchItem.LaunchItemButton:RegisterCallback(Mouse.eLClick, Toggle)
  m_launchItem.LaunchItemButton:RegisterCallback(Mouse.eMouseEnter, function()
    UI.PlaySound("Main_Menu_Mouse_Over")
  end)
  ResizeLaunchBar(stack)
  return true
end

-- Remove our controls from the launch bar so a reloaded context does not
-- leave a dead duplicate behind.
local function RemoveLaunchButton()
  local stack = ContextPtr:LookUpControl(LAUNCH_BAR_STACK)
  if stack == nil then return end
  if m_launchItem.LaunchItemButton ~= nil then stack:DestroyChild(m_launchItem.LaunchItemButton) end
  if m_launchPin.Pin ~= nil then stack:DestroyChild(m_launchPin.Pin) end
  m_launchItem, m_launchPin = {}, {}
  ResizeLaunchBar(stack)
end

local function OnLoadScreenClose()
  InjectLaunchButton()
end

local function OnInput(uiMsg, wParam)
  if uiMsg == KeyEvents.KeyUp and wParam == Keys.VK_ESCAPE and IsOpen() then
    Close()
    return true
  end
  return false
end

local function OnInit(isReload)
  -- After a hot reload the load screen is long gone; inject right away.
  if isReload then InjectLaunchButton() end
end

local function OnShutdown()
  Events.LoadScreenClose.Remove(OnLoadScreenClose)
  LuaEvents.SDP_OpenPanel.Remove(Open)
  LuaEvents.SDP_ClosePanel.Remove(Close)
  RemoveLaunchButton()
end

-- Test hooks: tools/run_tests.py runs tests inside this context's Lua state.
SDP_Panel = {
  Open = Open,
  Close = Close,
  IsOpen = IsOpen,
  HandleInput = OnInput,
  LaunchButton = function() return m_launchItem.LaunchItemButton end,
}

Controls.CloseButton:RegisterCallback(Mouse.eLClick, Close)
Controls.CloseButton:RegisterCallback(Mouse.eMouseEnter, function()
  UI.PlaySound("Main_Menu_Mouse_Over")
end)
ContextPtr:SetInputHandler(OnInput, true)
ContextPtr:SetInitHandler(OnInit)
ContextPtr:SetShutdown(OnShutdown)
Events.LoadScreenClose.Add(OnLoadScreenClose)
LuaEvents.SDP_OpenPanel.Add(Open)
LuaEvents.SDP_ClosePanel.Add(Close)
