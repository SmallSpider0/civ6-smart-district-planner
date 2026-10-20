-- cmp_amt.lua: Auto Map Tacks Planner r49 (AMT, Steam 3771382002) as a
-- comparison planner. AMT's files are loaded unmodified from reference/amt
-- (include("amt_autoplanner")) into this planner's own Lua state, the game
-- "finishes loading" (Events.LoadGameViewStateDone, which builds DMT's
-- modifier cache in AMT's state, as in the game), and AMT is driven the way
-- a player drives it: open the planner, pick a mode, set the specialty slot
-- count, click the district icons, click Plan (single city) or save every
-- city and confirm the scope (multi-city), and let the per-frame update run
-- the solve to its end.
--
-- The game's UI objects are emulated here so that AMT's UI logic behaves as
-- in the game (the shared auto-stub in cmp_game.lua answers every call with
-- a truthy stub, which would e.g. read every check box as ticked):
--   Controls     the ids of amt_autoplanner.xml (outside <Instance>), with
--                hidden/checked/disabled/text state and recorded callbacks;
--                ids not in the XML are nil, as in the game
--   InstanceManager  instances whose controls keep state and callbacks
--   ContextPtr, UIManager  popup queue, hidden state, the update handler
--   Mouse, Drag, PopupPriority, UILens, Input  constants and no-ops
-- plus pcall/coroutine.yield as in HavokScript (no yield across pcall) and
-- the City methods AMT probes (PatchEngine). AMT's chunk locals (selected
-- city plan, icon instances, queued job) are reached read-only through the
-- debug library's upvalue access; no AMT function is replaced except the
-- call counter on EvaluatePlan and the weight injection below.
--
--   variant ""         the comparison's weights, request.weights: every yield
--                      1.0, or the scenario's profile (one yield 3, "~SCI"),
--                      the judge's objective. AMT's focus buttons only give
--                      its default weights x1.75 or 0, so the weights are
--                      injected: single city, into the queued job after Plan
--                      is clicked; multi-city, by AMT_MC_M3_MergeWeights
--                      during the solve. The weights that reach the solve
--                      (BuildAutoPlanPreview's argument, the joint inputs'
--                      weights) are read back into stats.solveWeights.
--   variant DEFAULTW   AMT's own default weights for a player who leaves the
--                      yield focus buttons alone (sci 1.8, cul 1.5, faith 1.6,
--                      gold 1.15, prod 0.75, food 0.55)
--   variant CITY_BY_CITY  multi only: the single-city planner city by city,
--                      each preview confirmed (pinned) before the next city
--   variants DEBUG:/TRACE:  diagnostics, see Diagnose below
--
-- Wonders (request.wonders, W scenarios, single city, both variants): AMT's
-- planner page has a "Wonders" tab next to "Districts"; a player switches to
-- it and clicks the wonders' icons, then Plan. Every selected wonder becomes
-- one required request of the same solve as the districts (BuildPlanRequests
-- AddPoolRequests), placed with its support (e.g. a Campus next to the Great
-- Library) when the district is also selected or already there. AMT refuses
-- to plan a wonder whose adjacent district is neither (the Plan click shows
-- a warning); the adapter then unticks that wonder and clicks Plan again,
-- as a player who cannot or did not ask to build the district would. The
-- plan's wonders come back as placements with kind = "WONDER". The
-- multi-city path has a wonder tab per city as well; no multi-city scenario
-- asks for wonders, so it is not driven here.
--
-- CmpAmt exposes the loading and player actions to cmp_cross_amt.lua, which
-- reuses them to score other planners' plans with AMT's own objective.

CmpAdapters = CmpAdapters or {}
CmpAmt = {}

local Stub = CmpGame.Stub

local function Note(notes, s) notes[#notes + 1] = s end

-- "YIELD_CULTURE=1 YIELD_FAITH=1 ..." in a fixed order (sorted keys).
local function WeightsText(weights)
  local keys = {}
  for k in pairs(weights or {}) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tostring(weights[k]) end
  return table.concat(parts, " ")
end
CmpAmt.WeightsText = WeightsText

-- ===========================================================================
-- Paths
-- ===========================================================================
local function RootDir()
  return (CMP_GAMEINFO:gsub("tests/compare/%.cache/gameinfo%.lua$", ""))
end

-- ===========================================================================
-- UI emulation
-- ===========================================================================
local Ui = { unknown = {}, clicks = 0 }

-- Control ids and their XML defaults: top-level ids (Controls) and the ids
-- of each <Instance> template.
local function ParseXml(path)
  local src = cmp_read_file(path) or error("cannot read " .. path)
  local top, templates = {}, {}
  local current = nil
  for close, tag, attrs in src:gmatch("<(/?)([%w_]+)([^>]*)>") do
    if tag == "Instance" then
      if close == "/" then
        current = nil
      else
        current = attrs:match('Name="([^"]+)"')
        templates[current] = templates[current] or {}
      end
    elseif close == "" then
      local id = attrs:match('%sID="([^"]+)"')
      if id then
        local hidden = attrs:match('%sHidden="([^"]+)"')
        local disabled = attrs:match('%sDisabled="([^"]+)"')
        local def = { hidden = hidden == "1" or hidden == "true", disabled = disabled == "1" or disabled == "true",
          tag = tag }
        if current then templates[current][id] = def else top[id] = def end
      end
    end
  end
  return top, templates
end

local ControlMethods = {}
local ControlMeta = {
  __index = function(self, k)
    local m = ControlMethods[k]
    if m ~= nil then return m end
    if type(k) == "string" and k:match("^%u") then
      if not Ui.unknown[k] then Ui.unknown[k] = true end
      -- Unknown setters and layout calls: no-op, chainable.
      return function(c) return c end
    end
    return nil
  end,
  __tostring = function(self) return "Control:" .. tostring(rawget(self, "_name")) end,
}

local function NewControl(name, def)
  return setmetatable({ _name = name, _hidden = def and def.hidden or false, _disabled = def and def.disabled or false,
    _checked = false, _selected = false, _text = "", _callbacks = {}, _entries = {} }, ControlMeta)
end

-- A table of controls created on first use (instances, pull-down entries).
local function AutoControls(template, prefix)
  return setmetatable({}, {
    __index = function(t, k)
      if type(k) ~= "string" or not k:match("^%u") then return nil end
      local c = NewControl((prefix or "") .. "." .. k, template and template[k])
      rawset(t, k, c)
      return c
    end,
  })
end

function ControlMethods.SetHide(c, v) c._hidden = v == true return c end
function ControlMethods.IsHidden(c) return c._hidden end
function ControlMethods.IsVisible(c) return not c._hidden end
function ControlMethods.SetCheck(c, v) c._checked = v == true return c end
function ControlMethods.IsChecked(c) return c._checked end
function ControlMethods.SetSelected(c, v) c._selected = v == true return c end
function ControlMethods.IsSelected(c) return c._selected end
function ControlMethods.SetDisabled(c, v) c._disabled = v == true return c end
function ControlMethods.IsDisabled(c) return c._disabled end
function ControlMethods.SetEnabled(c, v) c._disabled = v ~= true return c end
function ControlMethods.IsEnabled(c) return not c._disabled end
function ControlMethods.SetText(c, s) c._text = s == nil and "" or tostring(s) return c end
function ControlMethods.GetText(c) return c._text end
function ControlMethods.SetString(c, s) c._text = s == nil and "" or tostring(s) return c end
function ControlMethods.RegisterCallback(c, event, fn) c._callbacks[event] = fn return c end
function ControlMethods.ClearCallback(c, event) c._callbacks[event] = nil return c end
function ControlMethods.RegisterCheckHandler(c, fn) c._callbacks.check = fn return c end
function ControlMethods.RegisterSelectionCallback(c, fn) c._callbacks.selection = fn return c end
function ControlMethods.SetIcon(c, name) c._icon = name return true end
function ControlMethods.GetSizeX() return 0 end
function ControlMethods.GetSizeY() return 0 end
function ControlMethods.GetOffsetX() return 0 end
function ControlMethods.GetOffsetY() return 0 end
function ControlMethods.GetSizeVal() return 0, 0 end
function ControlMethods.GetOffsetVal() return 0, 0 end
function ControlMethods.GetScrollValue() return 0 end
function ControlMethods.GetRatio() return 0 end
function ControlMethods.GetID(c) return c._name end
function ControlMethods.GetBestOverlappingControl() return nil end
function ControlMethods.GetButton(c)
  c._button = c._button or NewControl(c._name .. ".Button")
  return c._button
end
-- Pull-downs: entries built into the caller's table.
function ControlMethods.ClearEntries(c) c._entries = {} return c end
function ControlMethods.BuildEntry(c, instanceName, tbl)
  setmetatable(tbl, getmetatable(AutoControls(nil, c._name .. "." .. tostring(instanceName))))
  c._entries[#c._entries + 1] = tbl
  return c
end

-- Fire a recorded callback the way a click does.
local function Click(control, event)
  if control == nil then return false end
  local fn = control._callbacks[event or "eLClick"]
  if fn == nil or control._disabled then return false end
  Ui.clicks = Ui.clicks + 1
  fn()
  return true
end

local function InstallUi(w)
  local root = RootDir()
  local top, templates = ParseXml(root .. "reference/amt/amt_autoplanner.xml")
  local controls = {}
  Controls = setmetatable({}, {
    __index = function(_, k)
      local c = controls[k]
      if c == nil and top[k] ~= nil then
        c = NewControl(k, top[k])
        controls[k] = c
      end
      return c
    end,
    __newindex = function() end,
  })
  Ui.controls = controls

  -- The planner's own context: hidden until queued as a popup.
  local ctx = { hidden = true, queued = false, update = nil }
  Ui.ctx = ctx
  ContextPtr = setmetatable({
    IsHidden = function() return ctx.hidden end,
    IsVisible = function() return not ctx.hidden end,
    SetHide = function(_, v) ctx.hidden = v == true end,
    SetUpdate = function(_, fn) ctx.update = fn end,
    ClearUpdate = function() ctx.update = nil end,
    SetInitHandler = function(_, fn) ctx.init = fn end,
    SetShutdown = function(_, fn) ctx.shutdown = fn end,
    SetShowHandler = function(_, fn) ctx.show = fn end,
    SetHideHandler = function(_, fn) ctx.hide = fn end,
    SetInputHandler = function(_, fn) ctx.input = fn end,
    LookUpControl = function() return Stub end,
    BuildInstanceForControl = function(_, name, tbl)
      if type(tbl) == "table" then setmetatable(tbl, getmetatable(AutoControls(templates[name], name))) end
    end,
  }, { __index = function(_, k)
    Ui.unknown["ContextPtr:" .. tostring(k)] = true
    return function() return Stub end
  end })
  UIManager = setmetatable({
    QueuePopup = function(_, c)
      if c == ContextPtr then ctx.queued, ctx.hidden = true, false end
    end,
    DequeuePopup = function(_, c)
      if c == ContextPtr then ctx.queued, ctx.hidden = false, true end
    end,
    IsInPopupQueue = function(_, c) return c == ContextPtr and ctx.queued end,
  }, { __index = function(_, k)
    Ui.unknown["UIManager:" .. tostring(k)] = true
    return function() return Stub end
  end })

  local IM = {}
  IM.__index = IM
  function IM:GetInstance()
    local inst = AutoControls(templates[self.m_InstanceName], self.m_InstanceName)
    local _ = inst[self.m_RootControlName]
    self.m_AllocatedInstances[#self.m_AllocatedInstances + 1] = inst
    return inst
  end
  function IM:ResetInstances() self.m_AllocatedInstances = {} end
  function IM:ReleaseInstance(inst)
    for i, x in ipairs(self.m_AllocatedInstances) do
      if x == inst then table.remove(self.m_AllocatedInstances, i) break end
    end
  end
  function IM:DestroyInstances() self.m_AllocatedInstances = {} end
  function IM:GetAllocatedInstance(i) return self.m_AllocatedInstances[i] end
  InstanceManager = {
    new = function(_, instanceName, rootName, parent)
      return setmetatable({ m_InstanceName = instanceName, m_RootControlName = rootName, m_ParentControl = parent,
        m_AllocatedInstances = {} }, IM)
    end,
  }

  local Names = { __index = function(_, k) return k end }
  Mouse = setmetatable({}, Names)
  Drag = setmetatable({}, Names)
  PopupPriority = setmetatable({}, Names)
  UILens = setmetatable({}, { __index = function() return function() return 0 end end })
  Input = setmetatable({ GetActionId = function() return 0 end }, { __index = function() return function() return 0 end end })
end

-- Run the context's per-frame update until it clears itself.
local function Pump(limit)
  local ctx = Ui.ctx
  local frames = 0
  while ctx.update ~= nil do
    frames = frames + 1
    if frames > (limit or 5000000) then error("AMT update did not finish after " .. frames .. " frames") end
    ctx.update(1 / 60)
  end
  return frames
end

-- ===========================================================================
-- Access to AMT's chunk locals (read-only harness access via the debug
-- library; AMT's code is not changed). The planner keeps its state in
-- chunk-level locals, which are upvalues of its global functions.
-- ===========================================================================
local function FindUpvalue(roots, name)
  local seen, queue = {}, {}
  for _, f in ipairs(roots) do queue[#queue + 1] = f end
  local head = 1
  while head <= #queue do
    local f = queue[head]
    head = head + 1
    if type(f) == "function" and not seen[f] then
      seen[f] = true
      local i = 1
      while true do
        local n, v = debug.getupvalue(f, i)
        if n == nil then break end
        if n == name then return v, f, i end
        if type(v) == "function" then queue[#queue + 1] = v end
        i = i + 1
      end
    end
  end
  return nil
end

local function Roots()
  return { OnPlan, ExecuteQueuedPlan, AMT_MC_SaveCurrent, AMT_MC_SelectCityCard, BuildAutoPlanPreview,
    SearchBestPlan, AMT_MC_M3_RunJointSolve }
end

local function Local(name)
  local v = FindUpvalue(Roots(), name)
  return v
end

local function RequireLocal(name)
  local v = Local(name)
  if v == nil then error("AMT local not found: " .. name) end
  return v
end

-- Wrap a chunk local (all closures share the upvalue cell) to count calls.
local function CountLocal(name, counter, key)
  local v, f, i = FindUpvalue(Roots(), name)
  if type(v) ~= "function" then return false end
  counter[key] = 0
  debug.setupvalue(f, i, function(...)
    counter[key] = counter[key] + 1
    return v(...)
  end)
  return true
end

-- ===========================================================================
-- Engine objects: match the game's City methods where AMT probes them.
-- AMT's solver tells engine plots from other objects by probing
-- GetX/GetY/GetYield/GetResourceType (Solver Copy, AMT_MC_M3_PrepareLegacyItem).
-- The game's City has GetYield but no GetResourceType; cmp_game.lua answers
-- every unknown method with a function, which would make a city pass as a
-- plot there. GetYield is used otherwise only by AMT's wonder scoring (city
-- yield modifiers, not exercised here): the city center tile's yield.
-- ===========================================================================
local function PatchEngine(w, notes)
  w.Classes.City.GetResourceType = false
  w.Classes.City.GetYield = function(self, index)
    local plot = Map.GetPlot(self.x, self.y)
    return plot and plot:GetYield(index) or 0
  end
  Note(notes, "emulation: City:GetYield (city-center tile yield), City:GetResourceType absent as in the game")
end

-- ===========================================================================
-- Coroutines as in the game: HavokScript (Lua 5.1) cannot yield across a
-- pcall ("attempt to yield across a C-call boundary"); Lua 5.3 can. AMT is
-- written for the game (it yields only outside its protected calls), so a
-- yield inside pcall raises here as it would there, and is counted.
-- ===========================================================================
local Runtime = { yieldsInPcall = 0 }
local function InstallRuntime()
  local depth = setmetatable({}, { __mode = "k" })
  local realPcall, realYield = pcall, coroutine.yield
  local pack, unpack_ = table.pack, table.unpack
  pcall = function(f, ...)
    local co = coroutine.running()
    depth[co] = (depth[co] or 0) + 1
    local r = pack(realPcall(f, ...))
    depth[co] = depth[co] - 1
    return unpack_(r, 1, r.n)
  end
  coroutine.yield = function(...)
    local co = coroutine.running()
    if (depth[co] or 0) > 0 then
      Runtime.yieldsInPcall = Runtime.yieldsInPcall + 1
      error("attempt to yield across a C-call boundary")
    end
    return realYield(...)
  end
end

-- ===========================================================================
-- Loading
-- ===========================================================================
local function LoadAMT(w, request, notes)
  InstallUi(w)
  InstallRuntime()
  PatchEngine(w, notes)
  local target = request.target
  UI.GetHeadSelectedCity = function() return target end
  include("amt_autoplanner")
  if AMT_MC_ModulesReady ~= true then
    notes[#notes + 1] = "AMT multi-city modules not ready: " .. tostring(AMT_MC_ModuleLoadError)
  end
  if AMT_MC_FutureLoadOK ~= true then
    notes[#notes + 1] = "AMT future-city modules not loaded: " .. tostring(AMT_MC_FutureLoadError)
  end
  -- DMT's handlers stay subscribed in AMT's state: this builds DMT's
  -- modifier cache (m_GroupedModifiers) there, as in the game.
  w.Events.LoadGameViewStateDone()
  w.Events.LoadScreenClose()
  local groups = 0
  local grouped = FindUpvalue({ CacheEffectiveModifiers }, "m_GroupedModifiers")
  for _, byId in pairs(grouped or {}) do
    for _ in pairs(byId) do groups = groups + 1 end
  end
  local required = FindUpvalue({ CacheEffectiveModifiers }, "m_SpecialtyDistrictRequiredFeatures")
  return groups + #(required or {})
end

-- ===========================================================================
-- Player actions
-- ===========================================================================
-- The launch-bar button (amt_entry.lua, another context) raises
-- LuaEvents.AMT_OpenPlanner; the planner shows its mode chooser.
local function OpenPlanner(multi)
  LuaEvents.AMT_OpenPlanner()
  if not AMT_MC_ModeSelector.open then error("AMT mode chooser did not open") end
  if not Click(Controls[multi and "ModeMultiButton" or "ModeSingleButton"]) then
    error("AMT mode button not clickable (multi=" .. tostring(multi) .. ")")
  end
  local isOpen = RequireLocal("m_IsOpen")
  if not isOpen then error("AMT planner did not open (multi=" .. tostring(multi) .. ")") end
end

local function GetSelectedCityLocal()
  return RequireLocal("GetSelectedCity")()
end

local function IsSpecialty(districtType)
  local row = GameInfo.Districts[districtType]
  return row ~= nil and (row.RequiresPopulation == true or row.RequiresPopulation == 1)
end

-- The specialty slot count a player sets with the +/- buttons: enough slots
-- for the founded specialty districts plus the ones to plan, at most 6. The
-- default (3) is left alone when it is already enough.
local function SetSlotCount(city, districts, notes)
  local GetCitySpecialtyPlan = RequireLocal("GetCitySpecialtyPlan")
  local GetLockedSpecialtyDistricts = RequireLocal("GetLockedSpecialtyDistricts")
  local plan = GetCitySpecialtyPlan(city)
  local locked = GetLockedSpecialtyDistricts(city)
  local want = #locked
  for _, t in ipairs(districts) do
    if IsSpecialty(t) then want = want + 1 end
  end
  local maxSlots = RequireLocal("MAX_SPECIALTY_SLOT_COUNT")
  if want > maxSlots then
    Note(notes, string.format("city %d: %d specialty slots needed (%d founded + requested), AMT allows at most %d",
      city:GetID(), want, #locked, maxSlots))
  end
  local guard = 0
  while plan.slotCount < math.min(want, maxSlots) and guard < 10 do
    Click(Controls.AddSlotButton)
    guard = guard + 1
  end
  return plan
end

-- Click each district's icon in the planner's district page, in the
-- request's order (specialty districts fill the next free slot).
local function ClickDistricts(city, districts, notes)
  for _, t in ipairs(districts) do
    local icons = Local("m_IconInstances") or {}
    local inst = icons[t]
    if inst == nil then
      Note(notes, "city " .. city:GetID() .. ": AMT offers no icon for " .. t)
    elseif not Click(inst.IconButton) then
      Note(notes, "city " .. city:GetID() .. ": icon for " .. t .. " is disabled")
    end
  end
end

-- Switch to the planner's "Wonders" tab and click each wonder's icon (the
-- tab lists every wonder of the ruleset; a click toggles the selection).
local function ClickWonders(city, wonders, notes)
  if #(wonders or {}) == 0 then return end
  if not Click(Controls.WonderTabButton) then
    Note(notes, "city " .. city:GetID() .. ": wonder tab not clickable")
    return
  end
  for _, t in ipairs(wonders) do
    local icons = Local("m_IconInstances") or {}
    local inst = icons[t]
    if inst == nil then
      Note(notes, "city " .. city:GetID() .. ": AMT offers no wonder icon for " .. t)
    elseif not Click(inst.IconButton) then
      Note(notes, "city " .. city:GetID() .. ": wonder icon for " .. t .. " is disabled")
    end
  end
  -- Back to the district page, where a player normally clicks Plan.
  Click(Controls.DistrictTabButton)
end

local function SelectionSummary(selection)
  local parts = {}
  for _, t in ipairs(selection.districts or {}) do parts[#parts + 1] = t end
  for _, t in ipairs(selection.wonders or {}) do parts[#parts + 1] = t end
  local slots = {}
  for cityID, list in pairs(selection.specialtySlotsByCity or {}) do
    local s = {}
    for i = 1, (selection.specialtySlotCountByCity or {})[cityID] or 0 do s[#s + 1] = tostring(list[i] or "-") end
    slots[#slots + 1] = cityID .. ":" .. table.concat(s, "/")
  end
  table.sort(slots)
  return table.concat(parts, ",") .. " slots " .. table.concat(slots, " ")
end

local function NeutralWeights(request)
  local weights = {}
  for k, v in pairs(request.weights) do weights[k] = v end
  return weights
end

local function TakeItems(out, items, fallbackCity)
  for _, item in ipairs(items or {}) do
    if item.subjectType == "DISTRICT" then
      out.placements[#out.placements + 1] = { city = item.cityID or fallbackCity, type = item.subjectKey,
        x = item.x, y = item.y }
    elseif item.subjectType == "WONDER" then
      out.placements[#out.placements + 1] = { city = item.cityID or fallbackCity, type = item.subjectKey,
        x = item.x, y = item.y, kind = "WONDER" }
    else
      out.stats.otherItems = (out.stats.otherItems or 0) + 1
    end
  end
end

local function SkipNotes(out, skipped)
  out.stats.skippedRequests = (out.stats.skippedRequests or 0) + #(skipped or {})
  for _, r in ipairs(skipped or {}) do
    Note(out.notes, string.format("skipped %s city %s: %s", tostring(r.subjectKey or r.district),
      tostring(r.cityID), tostring(r.skipReason)))
  end
end

-- Record the weights that reach the solve (once per run).
local function SeenWeights(out, where, weights)
  if out.stats.solveWeights ~= nil then return end
  out.stats.solveWeights = WeightsText(weights)
  Note(out.notes, "weights reaching " .. where .. ": " .. out.stats.solveWeights)
end

-- The player's selection for one city in the single-city planner: open it,
-- set the slot count, click the districts, then the wonders.
local function SelectSingleCity(city, request, notes)
  UI.GetHeadSelectedCity = function() return city end
  OpenPlanner(false)
  SetSlotCount(city, request.districts, notes)
  ClickDistricts(city, request.districts, notes)
  ClickWonders(city, request.wonders, notes)
  local ReadSelectedSubjects = RequireLocal("ReadSelectedSubjects")
  Note(notes, "city " .. city:GetID() .. " selection: " .. SelectionSummary(ReadSelectedSubjects()))
end

-- Click Plan and put the comparison's weights into the queued job (variant
-- ""), as PlanSingleCity does; the caller pumps the update. AMT refuses to
-- plan a wonder whose adjacent district is neither selected nor in the city
-- (its warning asks the player to tick that district); a player who cannot
-- (e.g. Kongo has no Holy Site for Mahabodhi) or did not ask for it unticks
-- the wonder and clicks Plan again.
local function ClickPlan(request, variant, notes)
  for _ = 0, #(request.wonders or {}) do
    if not Click(Controls.OkButton) then error("AMT plan button not clickable") end
    local job = Local("m_QueuedPlan")
    if job ~= nil then
      if variant ~= "DEFAULTW" then job.weights = NeutralWeights(request) end
      return job
    end
    local city = GetSelectedCityLocal()
    local wonder, district = RequireLocal("GetMissingSelectedWonderDistrict")(RequireLocal("ReadSelectedSubjects")(), city)
    if wonder == nil then break end
    Note(notes, "city " .. city:GetID() .. ": AMT will not plan " .. wonder .. " without " .. tostring(district)
      .. " selected (not requested or not available to this civilization); wonder unticked")
    ClickWonders(city, { wonder }, notes)
  end
  local warning = Controls.WarningText and Controls.WarningText:GetText() or ""
  error("AMT did not queue a plan: " .. tostring(Controls.ResultText:GetText()) .. " " .. tostring(warning))
end

-- One city with the public single-city planner: open, tick, Plan, wait.
local function PlanSingleCity(city, request, variant, out)
  SelectSingleCity(city, request, out.notes)

  local captured = nil
  local real = BuildAutoPlanPreview
  BuildAutoPlanPreview = function(...)
    SeenWeights(out, "BuildAutoPlanPreview", (select(3, ...)))
    local preview = real(...)
    captured = preview or {}
    return preview
  end
  ClickPlan(request, variant, out.notes)
  local frames = Pump()
  BuildAutoPlanPreview = real
  out.stats.frames = (out.stats.frames or 0) + frames
  if captured == nil then
    error("AMT returned no preview: " .. tostring(Controls.ResultText:GetText()))
  end
  out.stats.status = captured.status
  local items = captured.bestState and captured.bestState.items or {}
  TakeItems(out, items, city:GetID())
  SkipNotes(out, captured.skippedRequests)
  if captured.bestState then out.stats.amtScore = captured.bestState.score end
  -- Close the planner as the Cancel button does (the preview is discarded;
  -- the caller pins it itself when it needs the plan on the map).
  Click(Controls.CancelButton)
  return captured, items
end

-- Put a single-city preview on the map with AMT's own confirm button (the
-- player's next step before planning the next city).
local function ConfirmSinglePreview(out)
  if Local("m_PendingPreview") == nil then return false end
  if not Click(Controls.PreviewConfirmButton) then
    Note(out.notes, "preview confirm button not clickable")
    return false
  end
  return true
end

-- Multi-city, the player's steps up to the scope page: AMT's joint planner
-- (mode chooser -> multi-city), every city of the request in a slot with its
-- district list (the same for all, or the city's own in V scenarios),
-- one-per-empire districts (Government Plaza) set to AUTO, save all (the
-- joint solve starts when the scope is confirmed).
local function OpenJointScope(request, notes)
  local cities = request.cities
  UI.GetHeadSelectedCity = function() return cities[1] end
  local caps = AMT_MultiCity and AMT_MultiCity.GetCapabilities and AMT_MultiCity.GetCapabilities() or {}
  local capList = {}
  for k, v in pairs(caps) do capList[#capList + 1] = k .. "=" .. tostring(v) end
  table.sort(capList)
  Note(notes, "AMT multi-city capabilities: " .. table.concat(capList, " "))
  OpenPlanner(true)
  local UIState = AMT_MultiCity.UIState
  local session = m_MCSession or error("AMT multi-city session did not start")
  if #cities > UIState.MAX_REAL_CITIES then error("AMT plans at most 4 cities jointly") end
  for slot, city in ipairs(cities) do
    local id = UIState.RealCityParticipantID(0, city:GetID())
    if session.slotParticipantIDs[slot] ~= id then
      AMT_MC_SelectCityCard(slot)
      if not AMT_MC_AssignSlotParticipant(slot, id) then error("cannot put city " .. city:GetID() .. " in slot " .. slot) end
    end
  end
  for slot = #cities + 1, 4 do
    if session.slotParticipantIDs[slot] then
      AMT_MC_SelectCityCard(slot)
      AMT_MC_AssignSlotParticipant(slot, nil)
    end
  end
  -- Each city's list: the scenario's own per city (V scenarios), else the
  -- shared one. One-per-empire districts go in the shared pull-down row.
  local unique, uniqueSeen = {}, {}
  for slot, city in ipairs(cities) do
    local list = (request.plans and request.plans[city:GetID()]) or request.districts
    local grid = {}
    for _, t in ipairs(list) do
      if AMT_MC_M6U_IsSupported(t) then
        if not uniqueSeen[t] then
          uniqueSeen[t] = true
          unique[#unique + 1] = t
        end
      else
        grid[#grid + 1] = t
      end
    end
    if not Click(Controls["MCCityCard" .. slot]) then AMT_MC_SelectCityCard(slot) end
    if GetSelectedCityLocal() ~= city then error("slot " .. slot .. " is not city " .. city:GetID()) end
    SetSlotCount(city, list, notes)
    ClickDistricts(city, grid, notes)
  end
  -- The unique-district row's pull-down entry "AUTO" (one shared choice).
  for _, t in ipairs(unique) do AMT_MC_M6U_ApplyDropdownValue(t, "AUTO") end
  if not Click(Controls.MCPrimaryActionButton) then error("primary action not clickable") end
  if m_MCPendingScope == nil then
    error("AMT scope not opened: " .. tostring(Controls.ResultText:GetText()))
  end
end

-- Multi-city: open the scope as above, confirm it, wait for the joint solve
-- and take the recommended plan (plan 1).
local function PlanJoint(request, variant, out)
  local notes = out.notes
  OpenJointScope(request, notes)

  local captured, failure = nil, nil
  local realShow, realFail, realMerge = AMT_MC_M3_ShowJointPreview, AMT_MC_M3_ShowJointFailure, AMT_MC_M3_MergeWeights
  local realInputs = AMT_MC_M3_BuildJointInputs
  AMT_MC_M3_BuildJointInputs = function(...)
    local inputs, reason = realInputs(...)
    if type(inputs) == "table" then SeenWeights(out, "the joint solve's inputs", inputs.weights) end
    return inputs, reason
  end
  AMT_MC_M3_ShowJointPreview = function(snapshot, result)
    captured = { snapshot = snapshot, result = result }
    return realShow(snapshot, result)
  end
  AMT_MC_M3_ShowJointFailure = function(status, result)
    failure = { status = status, result = result }
    return realFail(status, result)
  end
  if variant ~= "DEFAULTW" then
    AMT_MC_M3_MergeWeights = function() return NeutralWeights(request) end
  end
  if not Click(Controls.MCScopeConfirmButton) then error("scope confirm not clickable") end
  if AMT_MC_M3State.job == nil and captured == nil and failure == nil then
    error("AMT joint solve did not start: " .. tostring(Controls.MCScopeNotice:GetText()))
  end
  out.stats.frames = Pump()
  AMT_MC_M3_ShowJointPreview, AMT_MC_M3_ShowJointFailure, AMT_MC_M3_MergeWeights = realShow, realFail, realMerge
  AMT_MC_M3_BuildJointInputs = realInputs

  local result = (captured and captured.result) or (failure and failure.result) or {}
  out.stats.status = result.status or (failure and failure.status)
  out.stats.amtFullEvaluations = AMT_MC_M3State.fullEvaluationCount
  out.stats.amtEvaluations = result.evaluations or (result.stats and result.stats.evaluations)
  for _, n in ipairs(result.inputs and result.inputs.skippedNotes or {}) do Note(notes, "skipped: " .. tostring(n)) end
  local unfulfilled = result.diagnostics and result.diagnostics.unfulfilledRequired or {}
  for _, u in ipairs(unfulfilled) do
    Note(notes, "unfulfilled: " .. tostring(type(u) == "table" and (u.requestID or u.subjectKey) or u))
  end
  if failure then Note(notes, "AMT joint failure: " .. tostring(failure.status) .. " " .. tostring(result.note)) end
  local pending = AMT_MC_M3State.pending
  if pending then
    local list = pending.result.pool and pending.result.pool.list or {}
    local entry = list[pending.planIndex or 1] or { state = pending.result.best }
    out.stats.plans = #list
    out.stats.amtScore = entry.state and entry.state.score
    out.stats.partial = pending.result.partial == true
    TakeItems(out, AMT_MC_M3_CollectLegacyItems(entry.state, pending.result.inputs), nil)
  end
end

-- Multi-city baseline: the single-city planner city by city, each plan
-- confirmed (pinned) before the next city.
local function PlanCityByCity(request, variant, out)
  for _, city in ipairs(request.cities) do
    local districts = {}
    for _, t in ipairs(request.districts) do
      local row = GameInfo.Districts[t]
      local placed = false
      if (row.MaxPerPlayer or -1) >= 0 then
        for _, p in ipairs(out.placements) do if p.type == t then placed = true end end
      end
      if not placed then districts[#districts + 1] = t end
    end
    local r = { districts = districts, weights = request.weights }
    UI.GetHeadSelectedCity = function() return city end
    OpenPlanner(false)
    SetSlotCount(city, districts, out.notes)
    ClickDistricts(city, districts, out.notes)
    local captured = nil
    local real = BuildAutoPlanPreview
    BuildAutoPlanPreview = function(...)
      SeenWeights(out, "BuildAutoPlanPreview", (select(3, ...)))
      captured = real(...) or {}
      return captured
    end
    if not Click(Controls.OkButton) then error("AMT plan button not clickable") end
    local job = Local("m_QueuedPlan")
    if job and variant ~= "DEFAULTW" then job.weights = NeutralWeights(r) end
    out.stats.frames = (out.stats.frames or 0) + Pump()
    BuildAutoPlanPreview = real
    captured = captured or {}
    TakeItems(out, captured.bestState and captured.bestState.items or {}, city:GetID())
    SkipNotes(out, captured.skippedRequests)
    local before = #PlayerConfigurations[0]:GetMapPins()
    if not ConfirmSinglePreview(out) then Click(Controls.CancelButton) end
    local isOpen = Local("m_IsOpen")
    if isOpen then Click(Controls.CancelButton) end
    out.stats.pinsPlaced = (out.stats.pinsPlaced or 0) + #PlayerConfigurations[0]:GetMapPins() - before
  end
end

-- Diagnostics, not part of the comparison runs:
--   variant "DEBUG:TYPE@x,y;..."  AMT's candidate checks for single tiles of
--       the target city, before planning (CanPlan, DMT CanPlacePin,
--       EvaluatePlan of the tile alone)
--   variant "TRACE:TYPE@x,y;... [CLEAR|CLEARALL]"  plan normally (neutral
--       weights) and log AMT's raw candidate count per request and every DMT
--       verdict for the tiles; CLEAR clears DMT's realized-feature cache
--       (UpdatePinYields) before each request's candidate scan, CLEARALL
--       before every CanPlacePin (what-if runs that change AMT's behaviour)
local function Diagnose(spec, request, out)
  local city = request.target
  for t, x, y in spec:gmatch("([%w_]+)@(%d+),(%d+)") do
    x, y = tonumber(x), tonumber(y)
    local plot = Map.GetPlot(x, y)
    local res = plot:GetResourceType() >= 0 and GameInfo.Resources[plot:GetResourceType()] or nil
    local item = { subjectType = "DISTRICT", subjectKey = t, x = x, y = y, plot = plot, cityID = city:GetID(),
      district = t, isSpecialty = IsSpecialty(t) }
    local canPlan = RequireLocal("ImprovementPlacement").CanPlan(item, 0, nil)
    local _, canPin, why = pcall(CanPlacePin, 0, { Key = t, Type = "DISTRICT", X = x, Y = y })
    local runCache = RequireLocal("BuildPlanningRunCache")(0)
    local _, _, fixed = RequireLocal("GetExistingPlannedDistricts")({ city }, {})
    item.placementLegal = true
    local ok, score = pcall(RequireLocal("EvaluatePlan"), 0, { item }, NeutralWeights(request), {}, fixed, runCache)
    Note(out.notes, string.format("DEBUG %s@%d,%d owner=%d resource=%s(%s) CanPlan=%s CanPlacePin=%s %s EvaluatePlan=%s %s",
      t, x, y, plot:GetOwner(), tostring(res and res.ResourceType), tostring(res and res.ResourceClassType),
      tostring(canPlan), tostring(canPin), tostring(why), tostring(ok), tostring(score)))
  end
end

local function InstallTrace(spec, notes)
  local want = {}
  for t, x, y in spec:gmatch("([%w_]+)@(%d+),(%d+)") do want[t .. "@" .. x .. "," .. y] = true end
  local clearAll = spec:match("CLEARALL") ~= nil
  local clear = spec:match("CLEAR") ~= nil
  local realPin = CanPlacePin
  CanPlacePin = function(pid, subject)
    if clearAll then pcall(UpdatePinYields, 0, {}) end
    local a, b = realPin(pid, subject)
    local key = subject and (tostring(subject.Key) .. "@" .. tostring(subject.X) .. "," .. tostring(subject.Y))
    if key and want[key] then Note(notes, "TRACE CanPlacePin " .. key .. " -> " .. tostring(a) .. " " .. tostring(b)) end
    return a, b
  end
  local rb, fb, ib = FindUpvalue(Roots(), "BuildRawCandidates")
  debug.setupvalue(fb, ib, function(req, ...)
    if clear then pcall(UpdatePinYields, 0, {}) end
    local list = rb(req, ...)
    Note(notes, "TRACE raw candidates " .. tostring(req.subjectKey) .. " " .. #list)
    return list
  end)
end

-- ===========================================================================
-- Shared with cmp_cross_amt.lua
-- ===========================================================================
CmpAmt.Load = LoadAMT
CmpAmt.Click = Click
CmpAmt.Pump = Pump
CmpAmt.FindUpvalue = FindUpvalue
CmpAmt.Roots = Roots
CmpAmt.Local = Local
CmpAmt.RequireLocal = RequireLocal
CmpAmt.NeutralWeights = NeutralWeights
CmpAmt.SelectSingleCity = SelectSingleCity
CmpAmt.ClickPlan = ClickPlan
CmpAmt.OpenJointScope = OpenJointScope
CmpAmt.Ui = Ui
CmpAmt.Runtime = Runtime

-- ===========================================================================
-- Adapter
-- ===========================================================================
function CmpAdapters.amt(request, variant, w)
  local notes = {}
  local stats = {}
  stats.dmtModifierGroups = LoadAMT(w, request, notes)
  CmpRun.CountDMT(stats)
  CountLocal("EvaluatePlan", stats, "amtEvaluatePlan")
  local out = { placements = {}, stats = stats, notes = notes }
  local scn = request.scenario
  if variant:match("^DEBUG:") then
    Diagnose(variant:sub(7), request, out)
    return out
  end
  if variant:match("^TRACE:") then
    InstallTrace(variant:sub(7), notes)
    variant = ""
  end
  if scn.kind == "single" then
    stats.mode = "single"
    PlanSingleCity(request.target, request, variant, out)
  elseif variant == "CITY_BY_CITY" then
    stats.mode = "city-by-city"
    PlanCityByCity(request, variant, out)
  else
    stats.mode = "joint"
    PlanJoint(request, variant, out)
  end
  stats.weights = variant == "DEFAULTW" and "AMT defaults" or WeightsText(request.weights)
  stats.yieldsInPcall = Runtime.yieldsInPcall
  local unknown = {}
  for k in pairs(Ui.unknown) do unknown[#unknown + 1] = k end
  table.sort(unknown)
  Note(notes, "ui methods emulated as no-ops: " .. table.concat(unknown, ","))
  return out
end
