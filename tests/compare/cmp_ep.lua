-- cmp_ep.lua: Empire Planner (Steam workshop 3793348626; modinfo version 94,
-- EP_BUILD 93) as a
-- comparison planner, run headlessly the way a player gets it.
--
-- EP's own files are loaded unmodified, through its panel (ep_panel.lua
-- includes ep_rules, ep_meta, ep_planner; ep_rules includes DMT's
-- dmt_yieldcalculator and unhooks DMT's handlers, as in the game). The panel's
-- controls are replaced by recording fakes, so the adapter can do what the
-- player does:
--   1. the player's panel settings are in the player configuration
--      (EP_SETTINGS_V1, the blob EP's own LoadSettings reads in OnInit):
--      districts only (no new cities, wonders, improvements), every district
--      type that was not requested unticked, every requested one ticked,
--      "districts per city" = the requested districts that take a population
--      slot (EP counts only Districts.RequiresPopulation against it; Aqueduct,
--      Dam, Canal ... are free and planned on top), all eras, BALANCED focus;
--   2. the context initialises (OnInit), the game finishes loading
--      (LoadGameViewStateDone), the player opens the panel (LuaEvents.EP_Open)
--      and presses Plan; the panel's frame-budgeted coroutine is driven to the
--      end through its own SetUpdate handler;
--   3. the plan read is what the panel shows and pins first:
--      result.siteSets[1].layouts[1] (BuildLayouts sorts layouts best first),
--      its DISTRICT entries. Built districts come back in layout.existing and
--      are not new placements.
--
-- Variants (tokens, combinable):
--   ""        yield weights all 1 (the comparison's objective), passed through
--             EP_Planner.Run's options.weights -- the one input the panel does
--             not expose (it always passes EP_Meta.DefaultWeights()); DMT on.
--   DEFAULT   the panel's own BALANCED focus weights (science 1.6, culture 1.5,
--             gold 0.8, faith 1.1, production 2.6, food 1.0), i.e. exactly what
--             the Plan button sends.
--   NODMT     Detailed Map Tacks not loaded in EP's context, as EP's mod
--             description asks players to have it ("TURN DETAILED MAP TACKS OFF
--             BEFORE ENABLING THIS MOD"); EP then uses only its own legality.

CmpAdapters = CmpAdapters or {}

-- ---------------------------------------------------------------------------
-- UI layer: recording fakes for Controls, ContextPtr and UIManager.
-- ---------------------------------------------------------------------------
local function InstallUI()
  local Stub = CmpGame.Stub
  local ui = { callbacks = {}, init = nil, update = nil, input = nil, hidden = true, popups = 0 }

  local function Control(name)
    local c = { name = name, hidden = false, checked = false, text = "" }
    local methods = {
      RegisterCallback = function(self, event, fn) ui.callbacks[name .. "#" .. tostring(event)] = fn end,
      SetHide = function(self, v) self.hidden = v and true or false end,
      IsHidden = function(self) return self.hidden end,
      SetCheck = function(self, v) self.checked = v and true or false end,
      IsChecked = function(self) return self.checked end,
      SetText = function(self, s) self.text = tostring(s) end,
      GetText = function(self) return self.text end,
      LocalizeAndSetText = function(self, key, ...) self.text = Locale.Lookup(key, ...) end,
    }
    return setmetatable(c, {
      __index = function(_, k)
        if methods[k] then return methods[k] end
        -- Anything else (sizes, offsets, CalculateSize, SetToolTipString ...)
        -- behaves like the shared stub; FitToScreen leaves before using sizes
        -- because the screen size is unknown (GetScreenSizeVal returns nil).
        return function() return Stub end
      end,
    })
  end
  Controls = setmetatable({}, {
    __index = function(t, name)
      local c = Control(name)
      rawset(t, name, c)
      return c
    end,
  })
  ContextPtr = setmetatable({}, {
    __index = function(_, k)
      if k == "SetInitHandler" then return function(_, fn) ui.init = fn end end
      if k == "SetInputHandler" then return function(_, fn) ui.input = fn end end
      if k == "SetUpdate" then return function(_, fn) ui.update = fn end end
      if k == "ClearUpdate" then return function() ui.update = nil end end
      if k == "IsHidden" then return function() return ui.hidden end end
      if k == "SetHide" then return function(_, v) ui.hidden = v and true or false end end
      return function() return Stub end
    end,
  })
  UIManager = setmetatable({
    QueuePopup = function() ui.hidden = false ui.popups = ui.popups + 1 end,
    DequeuePopup = function() ui.hidden = true end,
    IsInPopupQueue = function() return not ui.hidden end,
    GetScreenSizeVal = function() return nil end,
  }, { __index = function() return function() return Stub end end })
  -- Engine enums the panel's OnInit reads.
  if Mouse == nil then
    Mouse = setmetatable({}, { __index = function(_, k) return k end })
  end
  if PopupPriority == nil then
    PopupPriority = setmetatable({ Low = 100, Medium = 200, High = 300 }, { __index = function() return 0 end })
  end
  return ui
end

local function Click(ui, control)
  local fn = ui.callbacks[control .. "#" .. tostring(Mouse.eLClick)]
  if fn == nil then error("no click handler on " .. control) end
  fn()
end

-- ---------------------------------------------------------------------------
-- Settings blob, in EP's own format (ep_panel.lua SettingsSig/LoadSettings).
-- ---------------------------------------------------------------------------
local function SettingsBlob(request, playerID)
  local wanted = {}
  for _, t in ipairs(request.districts) do wanted[t] = true end
  local off, slots = {}, 0
  for _, t in ipairs(EP_Rules.GetCivDistricts(playerID)) do
    if not wanted[t] then off[#off + 1] = t end
  end
  table.sort(off)
  for _, t in ipairs(request.districts) do
    local row = GameInfo.Districts[t]
    if row and row.RequiresPopulation and not row.CityCenter then slots = slots + 1 end
  end
  -- The stepper's range is 1..9; LoadSettings drops values outside it.
  local dpc = math.max(1, math.min(9, slots))
  local blob = string.format("v1|nc=%d,dpc=%d,wpe=%d,wpc=%d,d=%d,w=%d,i=%d,s=%d,era=%d|%s|%s",
    0, dpc, 3, 1, 1, 0, 0, 0, 0, table.concat(off, ";"), "BALANCED")
  return blob, dpc
end

function CmpAdapters.ep(request, variant, w)
  local playerID = request.playerID
  local useDefaultWeights = variant:find("DEFAULT", 1, true) ~= nil
  local noDMT = variant:find("NODMT", 1, true) ~= nil
  local stats = { variant = variant ~= "" and variant or "EQUAL" }
  local out = { placements = {}, stats = stats, notes = {} }
  local function Note(s) out.notes[#out.notes + 1] = s end

  local ui = InstallUI()

  -- The game's Lua runtime has table.count (number of keys; the base UI uses
  -- it too, e.g. DiplomacyDealView.lua); EP's rule builder calls it.
  if table.count == nil then
    table.count = function(t)
      local n = 0
      for _ in pairs(t) do n = n + 1 end
      return n
    end
  end
  -- fengari has no lua_gc ("lua_gc not implemented"); the game's collect is a
  -- memory housekeeping call with no effect on results (EP calls it once,
  -- after building its plot cache).
  local realCollect = collectgarbage
  collectgarbage = function(opt, ...)
    local ok, r = pcall(realCollect, opt, ...)
    if ok then return r end
    return 0
  end

  -- Detailed Map Tacks switched off in this context (NODMT): include() of its
  -- files finds nothing, as when the mod is not enabled.
  if noDMT then
    local realInclude = include
    include = function(name, ...)
      if tostring(name):match("^dmt_") then return end
      return realInclude(name, ...)
    end
  end

  -- PlayerResources methods EP's resource snapshot reads (for city-site and
  -- improvement scoring, both off here). The emulated player owns, trades
  -- and stockpiles no resources, so the engine would answer 0.
  local player = Players[playerID]
  local realGetResources = player.GetResources
  player.GetResources = function(self, ...)
    local res = realGetResources(self, ...)
    res.GetExportedResourceAmount = function() return 0 end
    res.GetImportedResourceAmount = function() return 0 end
    res.GetResourceStockpileAmount = function() return 0 end
    res.GetResourceStockpileCap = function() return 0 end
    res.GetResourceAccumulationPerTurn = function() return 0 end
    return res
  end

  -- The panel context loads (and, through it, EP's three logic files).
  include("ep_panel")
  if EP_Planner == nil or EP_Rules == nil or EP_Meta == nil then error("Empire Planner did not load") end
  if ui.init == nil then error("ep_panel registered no init handler") end
  stats.dmtBridge = (CanPlacePin ~= nil)
  stats.epApi = EP_Planner.API

  -- The player's saved panel settings, then the context's init handler.
  local blob, dpc = SettingsBlob(request, playerID)
  PlayerConfigurations[playerID]:SetValue("EP_SETTINGS_V1", blob)
  ui.init()
  -- Read back through EP's own signature: proves LoadSettings took every field.
  local sig = SettingsSig()
  if sig ~= blob then
    Note("settings not applied as written: " .. tostring(sig))
  end
  stats.districtsPerCity = dpc

  local civDistricts = {}
  for _, t in ipairs(EP_Rules.GetCivDistricts(playerID)) do civDistricts[t] = true end
  for _, t in ipairs(request.districts) do
    if not civDistricts[t] then Note("requested " .. t .. " is not in EP's district list for this civ") end
  end

  -- The game finishes loading; the player opens the panel and presses Plan.
  w.Events.LoadGameViewStateDone()
  CmpRun.CountDMT(stats)

  local captured = {}
  local realRun = EP_Planner.Run
  EP_Planner.Run = function(pid, options, yieldFn)
    captured.options = options
    if not useDefaultWeights then
      local equal = {}
      for k, v in pairs(request.weights) do equal[k] = v end
      options.weights = equal
    end
    captured.weights = options.weights
    local result = realRun(pid, options, yieldFn)
    captured.result = result
    return result
  end

  w.LuaEvents.EP_Open()
  if ui.hidden then Note("panel did not open") end
  Click(ui, "PlanButton")
  local frames = 0
  while ui.update ~= nil do
    frames = frames + 1
    if frames > 2000000 then error("planner coroutine did not finish") end
    ui.update(0.016)
  end
  EP_Planner.Run = realRun
  stats.frames = frames

  local result = captured.result
  if result == nil then
    error("Plan produced no result: " .. tostring(Controls.ResultText.text))
  end
  stats.resultText = Controls.ResultText.text

  local set = result.siteSets and result.siteSets[1]
  local layouts = set and set.layouts or {}
  local layout = layouts[1]
  local diag = result.diag or {}
  stats.siteSets = #(result.siteSets or {})
  stats.layouts = #layouts
  stats.placedTotal = diag.placedTotal
  stats.polishImproved = diag.polishImproved
  stats.polishRestarts = diag.polishRestarts
  stats.dmtFailures = EP_Rules.DmtFailures or 0
  if EP_Rules.LastDmtReason then Note("last DMT refusal: " .. EP_Rules.LastDmtReason) end
  for i = 2, #layouts do
    if layouts[i].score > layouts[i - 1].score + 1e-9 then Note("layouts not sorted best first") break end
  end
  if layout == nil then
    Note("no layout")
    return out
  end
  stats.epScore = layout.score
  stats.epWorstScore = layouts[#layouts].score

  -- City of each entry: entries carry the city's label, contexts its ID.
  local byLabel, dup = {}, false
  for _, ctx in ipairs(layout.cities or {}) do
    if byLabel[ctx.label] ~= nil then dup = true end
    byLabel[ctx.label] = ctx.cityID
  end
  if dup then Note("duplicate city labels; city of an entry may be wrong") end
  local wanted = {}
  if request.scenario.kind == "single" then
    wanted[request.target:GetID()] = true
  else
    for _, c in ipairs(request.cities) do wanted[c:GetID()] = true end
  end
  local requested = {}
  for _, t in ipairs(request.districts) do requested[t] = true end
  local counts = { district = 0, other = 0, unrequested = 0, skippedCity = 0 }
  for _, e in ipairs(layout.entries or {}) do
    if e.kind == "DISTRICT" then
      local cityID = byLabel[e.city]
      if cityID ~= nil and wanted[cityID] then
        out.placements[#out.placements + 1] = { city = cityID, type = e.type, x = e.x, y = e.y }
        counts.district = counts.district + 1
        if not requested[e.type] then counts.unrequested = counts.unrequested + 1 end
      else
        counts.skippedCity = counts.skippedCity + 1
        Note("skipped " .. e.type .. " at " .. e.x .. "," .. e.y .. " for city " .. tostring(e.city))
      end
    else
      counts.other = counts.other + 1
    end
  end
  stats.districts = counts.district
  stats.unrequested = counts.unrequested
  stats.otherEntries = counts.other
  stats.existingEchoed = #(layout.existing or {})

  -- What the panel put on the map (it pins layouts[1] at once): does it
  -- touch the pins the player placed by hand?
  local manual = {}
  for _, p in ipairs(w.Spec.pins or {}) do manual[#manual + 1] = p end
  local overwritten = 0
  for _, p in ipairs(manual) do
    local pin = nil
    for _, q in ipairs(PlayerConfigurations[playerID]:GetMapPins()) do
      if q:GetHexX() == p.x and q:GetHexY() == p.y then pin = q end
    end
    if pin == nil then
      Note("hand-placed pin " .. p.icon .. " at " .. p.x .. "," .. p.y .. " gone after Plan")
      overwritten = overwritten + 1
    elseif pin:GetIconName() ~= p.icon then
      Note("hand-placed pin " .. p.icon .. " at " .. p.x .. "," .. p.y .. " now " .. tostring(pin:GetIconName()))
      overwritten = overwritten + 1
    end
  end
  stats.manualPins = #manual
  stats.manualPinsOverwritten = overwritten
  stats.mapPins = #PlayerConfigurations[playerID]:GetMapPins()

  -- Requested districts EP left out, per target city.
  for _, c in ipairs(request.cities) do
    if wanted[c:GetID()] then
      local have = {}
      for _, d in c:GetDistricts():Members() do have[GameInfo.Districts[d:GetType()].DistrictType] = true end
      for _, p in ipairs(out.placements) do
        if p.city == c:GetID() then have[p.type] = true end
      end
      for _, t in ipairs(request.districts) do
        if not have[t] then
          local row = GameInfo.Districts[t]
          if (row.MaxPerPlayer or -1) < 0 or request.scenario.kind == "single" then
            Note("not planned: " .. t .. " in city " .. c:GetID())
          end
        end
      end
    end
  end
  return out
end
