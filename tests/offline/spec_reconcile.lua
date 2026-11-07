-- Offline: every setting a tab keeps reaches the solver it starts, or the
-- table below says why not (issue 327, item 4).
--
-- The settings come from each tab's own settings table (SDP_PageKit: the
-- weight columns, the switches, the tier and the tab's other kept values,
-- the same list that is written into the save), not from a list written
-- here. For each one the test changes it (a weight with its column's arrow,
-- a switch with its check box, the tier with its pulldown, the rest as a
-- save restores them), clicks the tab's Solve button and compares what the
-- solver was handed with the solve before the change:
--   the request  the argument of the solver the tab calls (SDP_Solver.Solve
--                or SolveScan, SDP_Multi.SolveNow, SDP_SiteSolver.SolveNow);
--   the search   what every SDP_Search.New of that solve got (the scoring:
--                weights, distance costs, land, coverage, housing, improvements,
--                swaps, the candidates), the three places named in #327.
-- A setting that changes neither is in NOT_USED for that path, one that
-- changes the request only is in NOT_SEARCHED; anything else fails, and so
-- does an entry of either table the setting no longer needs.
--
-- Paths: the single-city tab without a wonder (SDP_Solver), with one (the
-- same tab through SDP_Multi with this one city: the settings copied into
-- WonderRequest), the several-cities tab, the city-sites tab, and the
-- good-places map of the single-city tab (SDP_Solver.Heat: what it scores
-- with and the spots it finds). The single-city and several-cities tabs plan
-- the same thing, so a setting one has and the other lacks is in ABSENT.
local test, T = ...

local UI_Mock = include("ui")

-- ===========================================================================
-- The table: which settings a path does not use, and why.
-- ===========================================================================
local SHOWN = "only folds the settings away; the plan is the same"
local REMIND = "only decides whether placing the plan adds reminder pins; the plan is the same"

-- The setting changes nothing the solver gets.
local NOT_USED = {
  SINGLE = { FOLD = SHOWN },
  SINGLE_WONDER = { FOLD = SHOWN },
  MULTI = { FOLD = SHOWN },
  SITES = { FOLD = SHOWN },
  -- The good-places map ranks one district's plots by adjacency alone
  -- (decided in issue 324: the map does not charge distance either).
  HEAT = {
    FOLD = SHOWN, REMIND = REMIND,
    IMPROVE = "the map places no improvements",
    WORKED = "the map places no improvements",
    TIER = "the map evaluates every plot; there is no search to tune",
    WONDERS = "the map shows one district; wonders are for Solve",
  },
}

-- The setting is in the request but changes no search input: the solver
-- uses it after the search, or it only matters with something else on.
local NOT_SEARCHED = {
  -- The map gets the tab's weights but scores with the yields' alone.
  HEAT = {
    LAND = "the map shows adjacency only (issue 324)",
    DISTANCE = "the map shows adjacency only, it does not charge distance (issue 324)",
    HOUSING = "the map shows adjacency only (issue 324)",
    COVERAGE = "the map shows adjacency only (issue 324)",
  },
  SINGLE = { REMIND = REMIND },
  SINGLE_WONDER = { REMIND = REMIND },
  MULTI = { REMIND = REMIND },
  -- A site's score is its district placement (SDP_Search) plus parts the
  -- site solver adds itself, weighted outside the search (SDP_Sites).
  SITES = {
    HOUSING = "a site part (fresh water), weighted by the site solver",
    AMENITY = "a site part (luxuries), weighted by the site solver",
    STRATEGIC = "a site part (strategic resources), weighted by the site solver",
    APPEAL = "a site part (appeal), weighted by the site solver",
    K = "how many sites; each site's search is the same",
    D = "how far apart the sites are; each site's search is the same",
    DENSE = "dense packing: where the sites go; each site's search is the same",
    DD = "how far apart the sites are with dense packing; each site's search is the same",
  },
}

-- What the single-city or the several-cities tab has and the other lacks.
local ABSENT = {
  MULTI = { ALLOW_REMOVAL = "the several-cities tab has no such switch: it always allows removing woods (as the single-city default)" },
}

-- Settings that only matter with another one set: changed in that context.
local CONTEXT = {
  SITES = { DD = { DENSE = true } },
}

-- ===========================================================================
-- The world: two cities near each other, open land for the sites.
-- ===========================================================================
local MAP = {
  "~~~~~~~~~~~~~~~~~~~~~~",
  "~..f.M..h...f..M..h..~",
  "~.fMj..p.d...fMj..p..~",
  "~h..f.j..M.h..f.j..M.~",
  "~.pM...f.h..pM...f.h.~",
  "~..j.p..q....j.p..q..~",
  "~f..h.M.j..f..h.M.j..~",
  "~.s..f..p...s..f..p..~",
  "~..p...h...p...h.....~",
  "~.M..f..j..M..f..j...~",
  "~..h..p...h..p...h...~",
  "~.f..M..p..f..M..p...~",
  "~..j...h..j...h..j...~",
  "~~~~~~~~~~~~~~~~~~~~~~",
}
-- City 2 owns plots two rings out that city 1 can swap over (the swap
-- switch), and improvements give an Industrial Zone adjacency (the
-- improvement switches).
World.New({
  rows = MAP, rivers = { "6,4", "7,4", "7,5", "12,7", "13,7" }, improvementRules = true, improveAdjacency = true,
  cities = {
    { id = 1, x = 4, y = 5, population = 6, capital = true, radius = 1 },
    { id = 2, x = 8, y = 5, population = 4, radius = 2 },
  },
})
UI_Mock.Install()
include("SDP_Panel")
local c = UI_Mock.Controls
-- One of this mod's pins for city 1, placed as the panel places them: the
-- replace switch has something to plan over.
SDP_Pins.Place(0, { { Type = "DISTRICT_HOLY_SITE", X = 5, Y = 5, Name = "1" } }, {})
-- An Industrial Zone (adjacency from improvements) and a Neighborhood (its
-- housing follows appeal: the housing weight).
local PLAN = { "DISTRICT_INDUSTRIAL_ZONE", "DISTRICT_NEIGHBORHOOD" }
local function Plan(page, on)
  for _, d in ipairs(PLAN) do page.SetSelected(d, on) end
end

-- ===========================================================================
-- What the solver was handed
-- ===========================================================================
-- A value as text: keys sorted, functions as "fn", a table seen before as
-- "@" (cycles, shared tables), deeper than `depth` as its size.
local function Text(value, depth, seen)
  local kind = type(value)
  if kind == "function" then return "fn" end
  if kind == "number" then return string.format("%.6g", value) end
  if kind ~= "table" then return tostring(value) end
  if seen[value] then return "@" end
  seen[value] = true
  if depth <= 0 then
    local n = 0
    for _ in pairs(value) do n = n + 1 end
    return "#" .. n
  end
  local keys = {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for _, key in ipairs(keys) do parts[#parts + 1] = tostring(key) .. "=" .. Text(value[key], depth - 1, seen) end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- The search's input without the board (the DMT state the solve builds).
local function SearchText(spec, proxy)
  local copy = {}
  for key, value in pairs(spec) do
    if key ~= "Board" then copy[key] = value end
  end
  local seen = {}
  if proxy ~= nil then seen[proxy] = true end
  return Text(copy, 5, seen)
end

-- The solve running: { Path, Request, Searches = { [key] = text } }; the key
-- is the search's number in the solve, or on the city-sites tab the site it
-- places districts around (a changed weight may move the sites: only the
-- searches of a site both solves scored are compared).
local m_capture = nil
local m_site = nil -- the site SDP_Sites.Fine scores now, "X,Y"
local PROBE = "the reconcile test stops the solve here"
-- The tab's weight table goes into the request whole, and some solvers hand
-- it on whole (SDP_Search's Appeal.Weights): a changed weight would then
-- change every search input though nothing reads it. So the request's
-- Weights become a proxy that notes the keys read while a search is made
-- and set up (SDP_Search.New and its Singles), and a search input shows the proxy as "@"; the keys read
-- and their values count as search input.
local m_inNew = false
local function Watch(request)
  local raw = request.Weights
  if type(raw) ~= "table" then return end
  local reads = {}
  request.Weights = setmetatable({}, {
    __index = function(_, key)
      if m_inNew then reads[key] = true end
      return raw[key]
    end,
    __newindex = function(_, key, value) raw[key] = value end,
    __pairs = function()
      if m_inNew then
        for key in pairs(raw) do reads[key] = true end
      end
      return next, raw, nil
    end,
  })
  m_capture.Proxy, m_capture.Raw, m_capture.Reads = request.Weights, raw, reads
end

local function Entry(tbl, name, path)
  local original = tbl[name]
  tbl[name] = function(request, ...)
    if m_capture ~= nil and m_capture.Request == nil then
      m_capture.Path, m_capture.Request = path, Text(request, 6, {})
      Watch(request)
    end
    return original(request, ...)
  end
end
Entry(SDP_Solver, "Solve", "SDP_Solver")
Entry(SDP_Solver, "SolveScan", "SDP_Solver")
Entry(SDP_Multi, "SolveNow", "SDP_Multi")
Entry(SDP_SiteSolver, "SolveNow", "SDP_SiteSolver")
do
  local original = SDP_Search.New
  SDP_Search.New = function(spec)
    if m_capture ~= nil then
      local searches = m_capture.Searches
      local key = m_site or #searches + 1
      if m_site ~= nil and searches[key] ~= nil then key = nil end -- scored once more: the first counts
      if key ~= nil then searches[key] = SearchText(spec, m_capture.Proxy) end
      m_inNew = true
      -- Only the input is compared: the search itself is not run, so the
      -- test stays quick. A city's solve stops after the search's Singles (an error
      -- the panel shows as a failed solve); a site gets no districts, which leaves the
      -- sites the solver scores as they were (chosen before their districts).
      if m_capture.Probe == "empty" then
        m_inNew = false
        return { Singles = function() return {} end, Run = function() end }
      end
    end
    local search = original(spec) -- no pcall, as above; Capture resets m_inNew
    if m_capture ~= nil and m_capture.Probe == "stop" then
      -- Every solver sets the search up with Singles right after New (the
      -- housing model reads its weight there): stopped after it.
      local singles = search.Singles
      search.Singles = function(self)
        singles(self) -- no pcall: it yields to the next frame (SDP_Task)
        m_inNew = false
        error(PROBE, 0)
      end
    else
      m_inNew = false
    end
    return search
  end
end
do
  local fine = SDP_Sites.Fine
  SDP_Sites.Fine = function(ctx, site, params)
    -- No pcall: the search inside yields to the next frame (SDP_Task).
    m_site = site.X .. "," .. site.Y
    local out = fine(ctx, site, params)
    m_site = nil
    return out
  end
end
-- The good-places map: what it scores with and the spots it finds.
do
  local heat, evaluate = SDP_Solver.Heat, SDP_Overlay.Evaluate
  SDP_Solver.Heat = function(request)
    local weights = nil
    SDP_Overlay.Evaluate = function(subjects, fixed, w)
      weights = weights or Text(w, 3, {})
      return evaluate(subjects, fixed, w)
    end
    local ok, spots = pcall(heat, request)
    SDP_Overlay.Evaluate = evaluate
    if not ok then error(spots, 0) end
    if m_capture ~= nil then
      local list = {}
      for _, s in ipairs(spots or {}) do list[#list + 1] = s.Index .. ":" .. string.format("%.6g", s.Gain) end
      m_capture.Path, m_capture.Request = "Heat", Text(request, 6, {})
      m_capture.Searches[1] = tostring(weights) .. " " .. table.concat(list, " ")
    end
    return spots
  end
end

-- ===========================================================================
-- The tabs and their paths
-- ===========================================================================
local function Run() SDP_Panel.RunTask(500) end

local single, multi, sites = SDP_PageSingle, SDP_PageMulti, SDP_PageSites
local PATHS = {
  { Name = "SINGLE", Solver = "SDP_Solver", Page = single, Tab = "SINGLE", TierPull = c.TierPull, Probe = "stop",
    Setup = function()
      single.SelectCity(1)
      Plan(single, true)
    end,
    Go = function() c.SolveButton:Click(); Run() end },
  { Name = "SINGLE_WONDER", Solver = "SDP_Multi", Page = single, Tab = "SINGLE", TierPull = c.TierPull, Probe = "stop",
    Setup = function()
      single.SelectCity(1)
      Plan(single, true)
      single.SetWonder("BUILDING_STONEHENGE", true)
    end,
    Go = function() c.SolveButton:Click(); Run() end },
  { Name = "MULTI", Solver = "SDP_Multi", Page = multi, Tab = "MULTI", TierPull = c.MultiTierPull, Probe = "stop",
    Setup = function()
      multi.AllCities()
      Plan(multi, true)
    end,
    Go = function() c.MultiSolveButton:Click(); Run() end },
  { Name = "SITES", Solver = "SDP_SiteSolver", Page = sites, Tab = "SITES", TierPull = c.SitesTierPull, Probe = "empty",
    -- One site, so that each solve is quick; the count is changed from it.
    Setup = function()
      for _ = 1, 20 do
        if sites.State().K > 1 then c.SitesCountLess:Click() end
      end
    end,
    Go = function() c.SitesSolveButton:Click(); Run() end },
  -- The good-places map: its pulldown's campus entry.
  { Name = "HEAT", Solver = "Heat", Page = single, Tab = "SINGLE", TierPull = c.TierPull,
    Setup = function()
      single.SelectCity(1)
    end,
    Go = function()
      for _, entry in ipairs(c.HeatPull._entries) do
        if entry.Button:GetText() == "LOC_DISTRICT_CAMPUS_NAME" then entry.Button:Click() end
      end
    end },
}

-- A setting changed through its own control where it has one.
local function Cell(page, key)
  for _, cell in ipairs(page.Kit.Cells) do
    if cell.Key == key then return cell end
  end
end
local function Switch(page, key)
  for _, switch in ipairs(page.Kit.Switches) do
    if switch.Key == key then return switch end
  end
end

local function Other(field, value)
  if field.Kind == "flag" then return not value end
  if field.Kind == "choice" then
    local list = {}
    for choice in pairs(field.Choices) do list[#list + 1] = choice end
    table.sort(list)
    for _, choice in ipairs(list) do
      if choice ~= value then return choice end
    end
  end
  if field.Kind == "number" then
    if value + 1 <= (field.Max or math.huge) then return value + 1 end
    return value - 1
  end
  if field.Key == "WONDERS" then
    return value == "" and "BUILDING_PYRAMIDS" or value .. ",BUILDING_PYRAMIDS"
  end
  if field.Key == "DISTRICTS" then
    -- The first district the sites tab lists, set to "not wanted" (or required when it was).
    local d = SDP_Rules.PlannableDistricts(0)[1]
    local state = sites.State().States[d.Type]
    return d.Type .. ":" .. (state == "OFF" and "M" or "O")
  end
  error("no other value for " .. field.Key)
end

-- Change a setting; returns how to put it back (the same way: a switch's
-- OnChange must run again, issue 144's counts follow the replace switch).
local function Change(path, field)
  local page = path.Page
  local values = page.Kit.Keeper.Values()
  local value = values[field.Key]
  local other = Other(field, value)
  local cell, switch = Cell(page, field.Key), Switch(page, field.Key)
  local function Tier(tier)
    for _, entry in ipairs(path.TierPull._entries) do
      if entry.Button:GetText() == "LOC_SDP_TIER_" .. tier then entry.Button:Click() end
    end
  end
  local undo
  if cell ~= nil and field.Kind == "number" then
    local there, back = cell.More, cell.Less
    if other < value then there, back = back, there end
    there:Click()
    undo = function() back:Click() end
  elseif switch ~= nil and switch.Check ~= nil then
    switch.Check:Toggle()
    undo = function() switch.Check:Toggle() end
  elseif field.Key == "TIER" then
    Tier(other)
    undo = function() Tier(value) end
  else
    values[field.Key] = other -- as a save restores it (SDP_Settings.Keeper)
    page.Kit.Keeper.Apply(values)
    undo = function()
      local now = page.Kit.Keeper.Values()
      now[field.Key] = value
      page.Kit.Keeper.Apply(now)
    end
  end
  T.ok(page.Kit.Keeper.Values()[field.Key] ~= value, path.Name .. " " .. field.Key .. ": changed")
  return undo
end

local function Capture(path)
  m_capture, m_inNew = { Searches = {}, Probe = path.Probe }, false
  path.Go()
  local got = m_capture
  m_capture, m_inNew = nil, false
  -- The weights a search read, with their values.
  local read = {}
  for key in pairs(got.Reads or {}) do read[key] = got.Raw[key] end
  got.Read = Text(read, 1, {})
  T.ok(got.Request ~= nil, path.Name .. ": the solver was called")
  return got
end

-- How each kept setting reaches the path: "search", "request" or "none".
local function Classify(path)
  SDP_Panel.Open()
  SDP_Panel.SelectTab(path.Tab)
  local page = path.Page
  local start = page.Kit.Keeper.Values()
  local out = {}
  local ok, err = pcall(function()
    path.Setup()
    -- The fast tier for the base (the tier itself is changed from it).
    for _, entry in ipairs(path.TierPull._entries) do
      if entry.Button:GetText() == "LOC_SDP_TIER_FAST" then entry.Button:Click() end
    end
    local plain = nil -- the solve before a change, without a context
    for _, field in ipairs(page.Kit.Keeper.Fields) do
      local base = page.Kit.Keeper.Values()
      local context = CONTEXT[path.Name] and CONTEXT[path.Name][field.Key]
      local before
      if context ~= nil then
        local values = page.Kit.Keeper.Values()
        for key, value in pairs(context) do values[key] = value end
        page.Kit.Keeper.Apply(values)
        before = Capture(path)
      else
        if plain == nil then
          plain = Capture(path)
          T.eq(plain.Path, path.Solver, path.Name .. ": the solver this path calls")
        end
        before = plain
      end
      local undo = Change(path, field)
      local after = Capture(path)
      undo()
      page.Kit.Keeper.Apply(base) -- the context, and the fold a solve sets
      local searched, common = before.Read ~= after.Read, 0
      for key, text in pairs(before.Searches) do
        if after.Searches[key] ~= nil then
          common = common + 1
          if after.Searches[key] ~= text then searched = true end
        end
      end
      for key in pairs(after.Searches) do
        if before.Searches[key] == nil and type(key) == "number" then searched = true end -- one more search
      end
      if type(next(before.Searches)) == "number" or next(before.Searches) == nil then
        if #before.Searches ~= #after.Searches then searched = true end
      else
        T.ok(common > 0, path.Name .. " " .. field.Key .. ": a site both solves scored")
      end
      local requested = before.Path ~= after.Path or before.Request ~= after.Request
      out[field.Key] = searched and "search" or requested and "request" or "none"
    end
    -- Every change was put back: the same solve as at the start.
    local last = Capture(path)
    T.ok(plain == nil or (last.Request == plain.Request and Text(last.Searches, 2, {}) == Text(plain.Searches, 2, {})),
      path.Name .. ": the settings are back as they were")
  end)
  page.Kit.Keeper.Apply(start)
  page.Kit.SetTier(start.TIER)
  if path.Name == "SINGLE_WONDER" then single.SetWonder("BUILDING_STONEHENGE", false) end
  if path.Name == "HEAT" then single.ShowHeat(nil) end
  Plan(single, false)
  Plan(multi, false)
  SDP_Panel.Close()
  if not ok then error(err, 0) end
  return out, page.Kit.Keeper.Fields
end

local m_fields = {} -- [path] = the kept keys, for ABSENT
local m_got = {}    -- [path] = Classify's result, for the good-places map's comparison

for _, path in ipairs(PATHS) do
  test(path.Name .. ": every kept setting reaches the solver, or the table says why not", function()
    local got, fields = Classify(path)
    local keys = {}
    for _, field in ipairs(fields) do keys[#keys + 1] = field.Key end
    m_fields[path.Name] = keys
    m_got[path.Name] = got
    local notUsed, notSearched = NOT_USED[path.Name] or {}, NOT_SEARCHED[path.Name] or {}
    local rows, wrong = {}, {}
    local function Check(ok, message)
      if not ok then wrong[#wrong + 1] = path.Name .. " " .. message end
    end
    for _, key in ipairs(keys) do
      local how = got[key]
      rows[#rows + 1] = key .. "=" .. how
      if how == "none" then
        Check(notUsed[key] ~= nil, key .. ": changes nothing the solver gets, and NOT_USED does not say why")
      elseif how == "request" then
        Check(notSearched[key] ~= nil, key .. ": in the request but in no search input, and NOT_SEARCHED does not say why")
      end
      Check(not (notUsed[key] ~= nil and how ~= "none"), key .. ": in NOT_USED but reaches the solver (" .. how .. ")")
      Check(not (notSearched[key] ~= nil and how ~= "request"), key .. ": in NOT_SEARCHED but " .. how)
    end
    -- An entry for a setting the tab does not keep is out of date.
    local kept = {}
    for _, key in ipairs(keys) do kept[key] = true end
    for _, list in ipairs({ notUsed, notSearched, CONTEXT[path.Name] or {} }) do
      for key in pairs(list) do Check(kept[key], key .. ": in the table but not a setting of the tab") end
    end
    T.ok(#wrong == 0, table.concat(wrong, "\n") .. "\n  seen: " .. table.concat(rows, " "))
  end)
end

test("the single-city and several-cities tabs keep the same settings, or ABSENT says why", function()
  local single, multi = m_fields.SINGLE, m_fields.MULTI
  T.ok(single ~= nil and multi ~= nil, "both tabs classified")
  local has = { SINGLE = {}, MULTI = {} }
  for _, key in ipairs(single) do has.SINGLE[key] = true end
  for _, key in ipairs(multi) do has.MULTI[key] = true end
  for name, other in pairs({ SINGLE = "MULTI", MULTI = "SINGLE" }) do
    for key in pairs(has[other]) do
      if not has[name][key] then
        T.ok(ABSENT[name] ~= nil and ABSENT[name][key] ~= nil, name .. " lacks " .. key .. " and ABSENT does not say why")
      end
    end
    for key in pairs(ABSENT[name] or {}) do
      T.ok(not has[name][key], name .. " " .. key .. ": in ABSENT but the tab has it")
    end
  end
end)




-- The good-places map and the solver (issue 319, 324): the map's best plot
-- for a district is the solver's plot for that district alone once every
-- setting the solver uses and the map does not is set so that it changes
-- nothing. Those settings are what the table above says (the HEAT rows,
-- against the single-city tab's search); each is here with its neutral
-- value, or in HEAT_ANY with why its value does not matter. The in-game test
-- (tests/test_features.lua, "the good-places map") sets the same ones.
local HEAT_NEUTRAL = { LAND = 0, DISTANCE = 0, HOUSING = 0, COVERAGE = 0, IMPROVE = false, WORKED = false }
local HEAT_ANY = {
  TIER = "one district alone: every tier finds its best plot",
  WONDERS = "none chosen: the comparison is one district",
}

test("the good-places map's best plot is the solver's with the settings the map does not use neutral", function()
  local heat, solver = m_got.HEAT, m_got.SINGLE
  T.ok(heat ~= nil and solver ~= nil, "both paths classified")
  for key, how in pairs(solver) do
    if how == "search" and heat[key] ~= "search" then
      T.ok(HEAT_NEUTRAL[key] ~= nil or HEAT_ANY[key] ~= nil,
        key .. ": the solver uses it, the map does not, and HEAT_NEUTRAL or HEAT_ANY does not have it")
    end
  end
  for _, list in ipairs({ HEAT_NEUTRAL, HEAT_ANY }) do
    for key in pairs(list) do
      T.ok(solver[key] == "search" and heat[key] ~= "search", key .. ": in the list but not a setting only the solver uses")
    end
  end
  SDP_Panel.Open()
  SDP_Panel.SelectTab("SINGLE")
  local start = single.Kit.Keeper.Values()
  local ok, err = pcall(function()
    single.SelectCity(1)
    local values = single.Kit.Keeper.Values()
    for key, value in pairs(HEAT_NEUTRAL) do values[key] = value end
    single.Kit.Keeper.Apply(values)
    single.SetTier("STANDARD")
    -- The Commercial Hub alone (no district added by itself, the aqueduct,
    -- either): its best plot on this map is one the city does not own yet,
    -- which the solver charges distance for (as in issue 319).
    local HUB = "DISTRICT_COMMERCIAL_HUB"
    for _, d in ipairs(SDP_Rules.PlannableDistricts(0)) do
      single.SetState(d.Type, d.Type == HUB and "MUST" or "OFF")
    end
    single.ShowHeat(HUB)
    local spots = single.Heat()
    T.ok(spots ~= nil and #spots > 0, "spots")
    for i = 2, #spots do T.ok(spots[i - 1].Gain >= spots[i].Gain, "best first") end
    local function Solve()
      c.SolveButton:Click()
      Run()
      local solo = single.State().Result
      T.ok(solo and solo.Ok, "solved: " .. tostring(solo and solo.Error))
      T.eq(#solo.Plan, 1, "the hub alone")
      return solo
    end
    T.near(Solve().Adjacency, spots[1].Gain, 1e-9, "the solver's hub is worth the map's best plot")
    -- The distance charged in full: the solver takes a nearer plot worth
    -- less, so the comparison depends on it (the map stays the same).
    for _ = 1, 10 do Cell(single, "DISTANCE").More:Click() end
    T.ok(single.State().Weights.DISTANCE > 0, "the distance on")
    T.ok(Solve().Adjacency < spots[1].Gain - 1e-9, "setup: with the distance charged the solver takes another plot")
    single.ShowHeat(HUB)
    T.near(single.Heat()[1].Gain, spots[1].Gain, 1e-9, "the map does not charge distance")
  end)
  single.Kit.Keeper.Apply(start)
  single.SetTier(start.TIER)
  for _, d in ipairs(SDP_Rules.PlannableDistricts(0)) do single.SetState(d.Type, SDP_UI.DefaultState(d)) end
  SDP_Panel.Close()
  if not ok then error(err, 0) end
end)

