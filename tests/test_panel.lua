-- @state SDP_Panel
-- Phase 1 skeleton: launch bar button and the panel's open/close behaviour.
-- A real mouse click on the button cannot be automated (the game window
-- refuses synthetic clicks); its callback is the same Toggle used here.
local test, T = ...

local function reset()
  SDP_Panel.Close()
  T.ok(not SDP_Panel.IsOpen(), "panel should start closed")
end

test("launch bar button is injected once", function()
  local button = SDP_Panel.LaunchButton()
  T.ok(button ~= nil, "button missing")
  T.ok(not button:IsHidden(), "button hidden")
  local stack = ContextPtr:LookUpControl("/InGame/LaunchBar/ButtonStack")
  T.ok(stack ~= nil and not ContextPtr:LookUpControl("/InGame/LaunchBar"):IsHidden(), "launch bar hidden")
end)

test("open and close through the popup queue", function()
  reset()
  T.ok(ContextPtr:IsHidden(), "closed panel should be hidden")
  SDP_Panel.Open()
  T.ok(SDP_Panel.IsOpen(), "not queued after Open")
  -- Not asserting visibility here: a higher-priority popup (e.g. a historic
  -- moment after founding a city) keeps a Low-priority popup hidden until it
  -- is dismissed.
  SDP_Panel.Open() -- second Open must not queue twice
  SDP_Panel.Close()
  T.ok(not SDP_Panel.IsOpen(), "still queued after one Close")
  T.ok(ContextPtr:IsHidden(), "dequeued but still visible")
end)

test("Esc closes an open panel and passes through otherwise", function()
  reset()
  T.eq(SDP_Panel.HandleInput(KeyEvents.KeyUp, Keys.VK_ESCAPE), false, "Esc consumed while closed")
  SDP_Panel.Open()
  T.eq(SDP_Panel.HandleInput(KeyEvents.KeyUp, Keys.VK_ESCAPE), true, "Esc not consumed while open")
  T.ok(not SDP_Panel.IsOpen(), "Esc did not close")
end)

test("LuaEvents.SDP_OpenPanel and SDP_ClosePanel work", function()
  reset()
  LuaEvents.SDP_OpenPanel()
  T.ok(SDP_Panel.IsOpen(), "SDP_OpenPanel")
  LuaEvents.SDP_ClosePanel()
  T.ok(not SDP_Panel.IsOpen(), "SDP_ClosePanel")
end)

test("panel text is localized", function()
  for _, key in ipairs({ "LOC_SDP_PANEL_TITLE", "LOC_SDP_PANEL_PLACEHOLDER", "LOC_SDP_LAUNCHBAR_TOOLTIP" }) do
    T.ok(Locale.Lookup(key) ~= key, key .. " has no text in game")
  end
  T.eq(Controls.Placeholder:GetText(), Locale.Lookup("LOC_SDP_PANEL_PLACEHOLDER"), "placeholder label")
end)
