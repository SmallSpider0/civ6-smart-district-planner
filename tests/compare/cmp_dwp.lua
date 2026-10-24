-- cmp_dwp.lua: District & Wonder Planner (Steam workshop 3780936549, modinfo
-- version 36, "v7.10"; by 人机爱丽丝) as a comparison planner, run headlessly
-- the way a player uses it (issue 48).
--
-- Its own files are loaded unmodified (gp_planner.lua; it includes DMT's
-- dmt_yieldcalculator and initialises itself on load). The panel's controls are
-- recording fakes, so the adapter does what the player does:
--   1. open the panel (LuaEvents.GP_OpenPlanner, as its launch-bar button);
--   2. set the three priority pull-downs to the requested districts in request
--      order (it plans at most three; first, second, third weigh 1.0, 0.75,
--      0.5) and the rest to "none", by clicking their entries;
--   3. tick "all cities" for a multi-city scenario (it then plans every city
--      of the player; one city: the selected city, UI.GetHeadSelectedCity);
--   4. set "strict planning" (see the variants), press Find Best, then Place.
-- The plan read is what it pinned: its own registry of auto pins (player
-- configuration GP_AUTO_PINS_V1), which records each pin's district and city.
--
-- It always adds an Aqueduct for every city and one Government Plaza (weight
-- 0: only for what they give the others). Requested ones count as requested;
-- an Aqueduct or Government Plaza the scenario did not ask for is left out of
-- the plan judged and listed in stats.extra (it was placed to help the
-- others' adjacency, which the judged plan then lacks).
--
-- Variants:
--   ""        strict planning off: every legal plot, as the judge sees them
--   DEFAULT   strict planning on, the panel's default: the first three
--             campuses and commercial hubs avoid woods, rainforest, marsh,
--             stone, sheep and copper
-- Its objective adds every yield alike (no yield weights): profile scenarios
-- only make sense with DEFAULT, as what a player gets.

CmpAdapters = CmpAdapters or {}

local POOL_LOC = {
  DISTRICT_INDUSTRIAL_ZONE = "LOC_GP_DISTRICT_IZ", DISTRICT_CAMPUS = "LOC_GP_DISTRICT_CAMPUS",
  DISTRICT_COMMERCIAL_HUB = "LOC_GP_DISTRICT_COMMERCIAL", DISTRICT_HOLY_SITE = "LOC_GP_DISTRICT_HOLY",
  DISTRICT_THEATER = "LOC_GP_DISTRICT_THEATER", DISTRICT_ENCAMPMENT = "LOC_GP_DISTRICT_ENCAMPMENT",
  DISTRICT_ENTERTAINMENT_COMPLEX = "LOC_GP_DISTRICT_ENTERTAINMENT", DISTRICT_HARBOR = "LOC_GP_DISTRICT_HARBOR",
  DISTRICT_AERODROME = "LOC_GP_DISTRICT_AERODROME",
}
local AUTO = { DISTRICT_AQUEDUCT = true, DISTRICT_GOVERNMENT = true }

-- Controls, ContextPtr and UIManager as recording fakes; pull-downs keep the
-- entries the panel builds so the adapter can click one.
local function InstallUI()
  local Stub = CmpGame.Stub
  local ui = { callbacks = {}, input = nil, hidden = true, pulldowns = {}, serial = 0 }
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
      -- Pull-downs (PullDown controls): entries built by BuildEntry.
      ClearEntries = function(self) ui.pulldowns[name] = {} end,
      BuildEntry = function(self, _, entry)
        ui.serial = ui.serial + 1
        entry.Button = Control(name .. ".entry" .. ui.serial)
        local list = ui.pulldowns[name] or {}
        list[#list + 1] = entry.Button
        ui.pulldowns[name] = list
      end,
      GetButton = function(self)
        local button = rawget(self, "button") or Control(name .. ".button")
        rawset(self, "button", button)
        return button
      end,
    }
    return setmetatable(c, {
      __index = function(_, k)
        if methods[k] then return methods[k] end
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
      if k == "SetInputHandler" then return function(_, fn) ui.input = fn end end
      if k == "IsHidden" then return function() return ui.hidden end end
      if k == "SetHide" then return function(_, v) ui.hidden = v and true or false end end
      return function() return Stub end
    end,
  })
  UIManager = setmetatable({
    QueuePopup = function() ui.hidden = false end,
    DequeuePopup = function() ui.hidden = true end,
    IsInPopupQueue = function() return not ui.hidden end,
  }, { __index = function() return function() return Stub end end })
  if Mouse == nil then Mouse = setmetatable({}, { __index = function(_, k) return k end }) end
  if PopupPriority == nil then
    PopupPriority = setmetatable({ Low = 100, Medium = 200, High = 300 }, { __index = function() return 0 end })
  end
  UILens = setmetatable({}, { __index = function() return function() return 0 end end })
  Input = setmetatable({ GetActionId = function() return -1 end }, { __index = function() return function() return 0 end end })
  return ui
end

local function Click(ui, control)
  local fn = ui.callbacks[control .. "#" .. tostring(Mouse.eLClick)]
  if fn == nil then error("no click handler on " .. control) end
  fn()
end

-- Click the entry of pull-down `name` whose text is `text`.
local function Choose(ui, name, text)
  for _, button in ipairs(ui.pulldowns[name] or {}) do
    if button.text == text then
      Click(ui, button.name)
      return true
    end
  end
  return false
end

-- The base type of a district key (DISTRICT_HANSA -> DISTRICT_INDUSTRIAL_ZONE).
local function BaseType(key)
  for row in GameInfo.DistrictReplaces() do
    if row.CivUniqueDistrictType == key then return row.ReplacesDistrictType end
  end
  return key
end

function CmpAdapters.dwp(request, variant, w)
  local playerID = request.playerID
  local strict = variant:find("DEFAULT", 1, true) ~= nil
  local stats = { variant = variant ~= "" and variant or "STRICT_OFF", strict = strict }
  local out = { placements = {}, stats = stats, notes = {} }
  local function Note(s) out.notes[#out.notes + 1] = s end
  local scn = request.scenario
  if scn.kind == "sites" or #(request.wonders or {}) > 0 then
    error("District & Wonder Planner: only district scenarios are wired up")
  end

  -- What the player picks: the requested districts it plans itself, in
  -- request order, at most three; Aqueduct and Government Plaza it adds by
  -- itself.
  -- request.districts holds the civilization's own types (Bath for Rome's
  -- Aqueduct); compare by base type.
  local picks, requested, ownType = {}, {}, {}
  for _, own in ipairs(request.districts) do
    local t = BaseType(own)
    requested[t], ownType[t] = true, own
    if POOL_LOC[t] then
      picks[#picks + 1] = t
    elseif not AUTO[t] then
      Note("requested " .. t .. " is not in its district list")
    end
  end
  if #picks > 3 then
    Note(string.format("%d districts requested; it plans the first three", #picks))
    while #picks > 3 do picks[#picks] = nil end
  end
  stats.picks = table.concat(picks, ",")

  local ui = InstallUI()
  local cities = request.cities or { request.target }
  UI.GetHeadSelectedCity = function() return request.target or cities[1] end
  include("dmt_serialize")
  include("gp_planner")
  w.Events.LoadGameViewStateDone()
  CmpRun.CountDMT(stats)
  w.LuaEvents.GP_OpenPlanner()
  if ui.hidden then Note("panel did not open") end

  -- Pull-downs: all three to "none" first (an option taken by another slot
  -- is not offered), then the picks in order.
  local none = Locale.Lookup("LOC_GP_PRIORITY_NONE")
  for i = 1, 3 do
    if not Choose(ui, "Priority" .. i .. "PullDown", none) then error("no 'none' entry in pull-down " .. i) end
  end
  for i, t in ipairs(picks) do
    if not Choose(ui, "Priority" .. i .. "PullDown", Locale.Lookup(POOL_LOC[t])) then
      error("no entry for " .. t .. " in pull-down " .. i)
    end
  end
  Controls.StrictPlanCheck:SetCheck(strict)
  Controls.AllCitiesCheck:SetCheck(scn.kind == "multi")

  Click(ui, "FindBestButton")
  stats.resultText = Controls.ResultText.text
  Click(ui, "ConfirmButton")

  local raw = PlayerConfigurations[playerID]:GetValue("GP_AUTO_PINS_V1")
  local registry = type(raw) == "table" and raw or (type(raw) == "string" and deserialize(raw)) or nil
  if registry == nil then error("no pins placed: " .. tostring(stats.resultText)) end
  local keys = {}
  for k in pairs(registry) do keys[#keys + 1] = k end
  table.sort(keys)
  local extra = {}
  for _, k in ipairs(keys) do
    local r = registry[k]
    if r.subjectType == "DISTRICT" and r.district then
      local base = BaseType(r.district)
      if requested[base] then
        -- It pins the generic Aqueduct (and Government Plaza) whatever the
        -- civilization; a player builds the civilization's own district there
        -- (Rome: Bath, same placement rules).
        local t = r.district
        if t == base and ownType[base] ~= base then
          t = ownType[base]
          stats.mapped = (stats.mapped and stats.mapped .. " " or "") .. r.district .. "->" .. t
        end
        out.placements[#out.placements + 1] = { city = r.cityID, type = t, x = r.x, y = r.y }
      else
        extra[#extra + 1] = string.format("%s(%d,%d)", r.district, r.x, r.y)
      end
    end
  end
  stats.extra = #extra > 0 and table.concat(extra, " ") or nil
  return out
end
