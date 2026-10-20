-- ui.lua: stand-ins for the game's UI objects (Controls, ContextPtr,
-- UIManager, InstanceManager, lenses) so the panel scripts can run in the
-- offline tests. Every control is a stub that remembers what was set on it
-- (text, check state, hidden, disabled, callbacks) and does nothing else;
-- tests read the panel through its SDP_Panel hooks. Layout is never checked
-- here: that needs the game.
-- Call UI_Mock.Install() after World.New and before include("SDP_Panel").

local UI_Mock = {}

local Control = {}
Control.__index = function(self, key)
  local method = rawget(Control, key)
  if method ~= nil then return method end
  if type(key) == "string" and key:sub(1, 1) == "_" then return nil end -- the stub's own fields
  -- Unknown methods: accept anything, return nothing.
  return function() return nil end
end

local function NewControl(name)
  return setmetatable({ _name = name, _text = "", _hidden = false, _disabled = false, _checked = false,
    _callbacks = {}, _entries = {}, _tooltip = "" }, Control)
end
UI_Mock.NewControl = NewControl

function Control:SetText(text) self._text = text end
function Control:GetText() return self._text end
function Control:SetHide(hidden) self._hidden = hidden == true end
function Control:IsHidden() return self._hidden end
function Control:SetDisabled(disabled) self._disabled = disabled == true end
function Control:IsDisabled() return self._disabled end
function Control:SetCheck(checked) self._checked = checked == true end
function Control:IsChecked() return self._checked end
function Control:SetSelected(selected) self._selected = selected end
function Control:SetToolTipString(text) self._tooltip = text end
function Control:GetToolTipString() return self._tooltip end
function Control:RegisterCallback(event, fn) self._callbacks[event] = fn end
function Control:RegisterCheckHandler(fn) self._check = fn end
function Control:GetSizeX() return 100 end
function Control:GetSizeY() return 30 end
function Control:SetIcon(icon) self._icon = icon return true end
-- Pulldowns.
function Control:ClearEntries() self._entries = {} end
function Control:BuildEntry(_, entry)
  entry.Button = NewControl("entry")
  self._entries[#self._entries + 1] = entry
end
function Control:GetButton()
  if self._button == nil then self._button = NewControl(self._name .. ".Button") end
  return self._button
end
-- Simulated input.
function Control:Click()
  local fn = self._callbacks[1] -- Mouse.eLClick
  if fn then fn() end
end
function Control:Toggle()
  self._checked = not self._checked
  if self._check then self._check() end
end

local function Instance()
  return setmetatable({}, {
    __index = function(t, key)
      local c = NewControl(key)
      rawset(t, key, c)
      return c
    end,
  })
end

local InstanceManager = {}
InstanceManager.__index = InstanceManager
function InstanceManager:new(name, root, parent)
  return setmetatable({ Name = name, Root = root, Parent = parent, Instances = {} }, InstanceManager)
end
function InstanceManager:GetInstance()
  local inst = Instance()
  self.Instances[#self.Instances + 1] = inst
  return inst
end
function InstanceManager:ResetInstances() self.Instances = {} end

function UI_Mock.Install()
  local controls = setmetatable({}, {
    __index = function(t, key)
      local c = NewControl(key)
      rawset(t, key, c)
      return c
    end,
  })
  local queue = {}
  local context = NewControl("ContextPtr")
  context._hidden = true
  function context:LookUpControl(path) return NewControl(path) end
  function context:BuildInstanceForControl(_, instance)
    setmetatable(instance, getmetatable(Instance()))
  end
  function context:SetUpdate(fn) UI_Mock.Update = fn end
  function context:ClearUpdate() UI_Mock.Update = nil end
  function context:SetInputHandler(fn) UI_Mock.Input = fn end
  function context:SetInitHandler(fn) UI_Mock.Init = fn end
  function context:SetShutdown(fn) UI_Mock.Shutdown = fn end
  UI_Mock.Controls, UI_Mock.Queue = controls, queue
  local ui = UI
  local lenses = { on = {}, hexes = {} }
  UI_Mock.Lenses = lenses
  sdp_install_globals({
    Controls = controls,
    ContextPtr = context,
    InstanceManager = InstanceManager,
    UIManager = {
      IsInPopupQueue = function(_, ctx) return queue[ctx] == true end,
      -- As in the game: a queued popup is shown, a dequeued one hidden.
      QueuePopup = function(_, ctx) queue[ctx] = true; ctx:SetHide(false) end,
      DequeuePopup = function(_, ctx) queue[ctx] = nil; ctx:SetHide(true) end,
    },
    PopupPriority = { Low = 1 },
    -- Input actions (key bindings from the configuration database): ids are names here.
    Input = { GetActionId = function(name) return "action:" .. name end },
    Mouse = { eLClick = 1, eMouseEnter = 2 },
    KeyEvents = { KeyUp = 1 },
    Keys = { VK_ESCAPE = 27 },
    UILens = {
      CreateLensLayerHash = function(name) return name end,
      IsLayerOn = function(layer) return lenses.on[layer] == true end,
      ToggleLayerOn = function(layer) lenses.on[layer] = true end,
      ToggleLayerOff = function(layer) lenses.on[layer] = nil end,
      SetLayerHexesColoredArea = function(layer, _, plots)
        lenses.hexes[layer] = (lenses.hexes[layer] or 0) + #plots
      end,
      ClearLayerHexes = function(layer) lenses.hexes[layer] = 0 end,
    },
  })
  ui.GetHeadSelectedCity = function() return nil end
  ui.GridToWorld = function(x, y) return x * 10, y * 10, 0 end
  ui.GetColorValue = function() return 0 end
  ui.LookAtPlot = function() end
end

return UI_Mock
