-- Plan invariants (issue 242): rules every plan of SDP_Solver and SDP_Multi
-- must keep, whatever the request. tools/offline_tests.mjs loads this file
-- into every state as SDP_Invariants and checks each solve's result as it is
-- made (Session:Result of both solvers); a test with a violation fails.
--
-- The rules come from the world the test built (GameInfo, Map, cities,
-- pins) and from the request, not from the solver's own bookkeeping; the
-- scans (SDP_City) say which plots a city can take, as in the game.
--
--   count      a city's districts that take population stay within the
--              count asked (Count/Counts; with Target, less what it has),
--              unless the districts the player required are more
--   unique     a district with an empire limit (MaxPerPlayer): planned,
--              built and tacked together within the limit; a wonder once
--   onecity    one district of a kind per city (OnePerCity), none it has
--              built already, no two a city cannot have together
--   plot       one plan entry per plot, never on a city, a district or a
--              wonder already there
--   reach      every district and wonder on a plot its recorded city can
--              take (its scan's candidates), joined to that city's
--              territory with the other cities' plan in the way (issue 35)
--   wonder     a wonder that must touch a district touches one of its
--              recorded city's (pitfall 42, issue 238); a district supplied
--              for a wonder touches it (issue 180); an improvement it needs
--              is next to it
--   parts      each district's parts and each city's subtotal add up to
--              the plan's values (issue 126)
--   unplaced   every district and wonder asked is placed or listed as not
--              placed, never both
--
-- A test that builds an invalid state on purpose opts out with a reason:
--   SDP_Invariants.OptOut("reason")              -- every check
--   SDP_Invariants.OptOut("issue N", { "reach" }) -- only these checks
-- Called while a test runs, for the rest of that test; at the top of a spec
-- file, for the whole file.

local Inv = { Found = {}, FileOff = {}, TestOff = {}, Running = false, Results = 0 }
local EPS = 1e-6
local ALL = "*"

function Inv.OptOut(reason, checks)
  assert(type(reason) == "string" and reason ~= "", "SDP_Invariants.OptOut needs a reason")
  local into = Inv.Running and Inv.TestOff or Inv.FileOff
  for _, check in ipairs(checks or { ALL }) do into[check] = reason end
end

local function Off(check)
  return Inv.FileOff[ALL] or Inv.TestOff[ALL] or Inv.FileOff[check] or Inv.TestOff[check]
end

-- The runner calls these around every test.
function Inv.BeginTest()
  Inv.Found, Inv.TestOff, Inv.Running = {}, {}, true
  Inv.Install()
end
function Inv.EndTest()
  Inv.Running = false
  local found = Inv.Found
  Inv.Found = {}
  if #found == 0 then return nil end
  local lines = { "plan invariants (tests/offline/invariants.lua):" }
  for n, line in ipairs(found) do
    if n > 8 then
      lines[#lines + 1] = "  ... " .. tostring(#found - 8) .. " more"
      break
    end
    lines[#lines + 1] = "  " .. line
  end
  return table.concat(lines, "\n")
end

local function Report(label, check, message)
  if Off(check) then return end
  local line = "[" .. check .. "] " .. label .. ": " .. message
  if #Inv.Found < 200 and Inv.Found[#Inv.Found] ~= line then Inv.Found[#Inv.Found + 1] = line end
end

local function Row(districtType) return GameInfo.Districts[districtType] end
local function Base(districtType) return SDP_Rules.BaseDistrict(districtType) end
local function Specialty(districtType)
  local row = Row(districtType)
  return row ~= nil and row.RequiresPopulation == true
end
local function Where(item) return tostring(item.Type) .. "@" .. tostring(item.X) .. "," .. tostring(item.Y) end
local function Touch(a, b)
  local pa, pb = Map.GetPlotByIndex(a), Map.GetPlotByIndex(b)
  return Map.GetPlotDistance(pa:GetX(), pa:GetY(), pb:GetX(), pb:GetY()) == 1
end
local function Set(list, key)
  local out = {}
  for _, item in ipairs(list or {}) do out[key and item[key] or item] = true end
  return out
end

-- Live pins of the player (those being replaced left out), by icon.
local function PinCounts(playerID, ignore)
  local counts, pins = {}, {}
  for _, pin in pairs(PlayerConfigurations[playerID]:GetMapPins()) do
    if not (ignore and ignore[pin:GetID()]) then
      local key = (pin:GetIconName() or ""):gsub("^ICON_", "")
      counts[key] = (counts[key] or 0) + 1
      pins[#pins + 1] = { Key = key, Index = Map.GetPlotIndex(pin:GetHexX(), pin:GetHexY()) }
    end
  end
  return counts, pins
end

local function BuiltCounts(playerID)
  local counts = {}
  for _, district in Players[playerID]:GetDistricts():Members() do
    local districtType = GameInfo.Districts[district:GetType()].DistrictType
    counts[districtType] = (counts[districtType] or 0) + 1
  end
  return counts
end

-- ---------------------------------------------------------------------------
-- Checks shared by both solvers. `cities`: { Key = { Scan, Key, Kind } };
-- `cityOf(item)`: the city key of a plan entry.
-- ---------------------------------------------------------------------------
local function CheckPlots(label, plan, playerID, ignore)
  local at = {}
  local _, pins = PinCounts(playerID, ignore)
  local pinned = {}
  for _, pin in ipairs(pins) do
    if GameInfo.Districts[pin.Key] ~= nil or (GameInfo.Buildings[pin.Key] ~= nil and GameInfo.Buildings[pin.Key].IsWonder) then
      pinned[pin.Index] = pin.Key
    end
  end
  for _, item in ipairs(plan) do
    if at[item.Index] ~= nil then
      Report(label, "plot", Where(item) .. " shares its plot with " .. Where(at[item.Index]))
    end
    at[item.Index] = item
    local plot = Map.GetPlotByIndex(item.Index)
    if plot:IsCity() or plot:GetDistrictType() ~= -1 or plot:GetWonderType() ~= -1 then
      Report(label, "plot", Where(item) .. " is on a city, district or wonder already there")
    elseif pinned[item.Index] ~= nil then
      Report(label, "plot", Where(item) .. " is on a live tack of " .. pinned[item.Index])
    end
    if item.Support ~= nil then
      if not Touch(item.Support.Index, item.Index) then
        Report(label, "wonder", Where(item) .. "'s " .. tostring(item.Support.Type) .. " is not next to it")
      end
    end
  end
  for _, item in ipairs(plan) do
    if item.Support ~= nil and at[item.Support.Index] ~= nil then
      Report(label, "plot", Where(item) .. "'s " .. tostring(item.Support.Type) .. " is on " .. Where(at[item.Support.Index]))
    end
  end
end

local function CheckUnique(label, plan, playerID, ignore)
  local pins = PinCounts(playerID, ignore)
  local built = BuiltCounts(playerID)
  local planned, wonders = {}, {}
  for _, item in ipairs(plan) do
    if item.Kind == "WONDER" then
      wonders[item.Type] = (wonders[item.Type] or 0) + 1
    else
      planned[item.Type] = (planned[item.Type] or 0) + 1
    end
  end
  local types = {}
  for districtType in pairs(planned) do types[#types + 1] = districtType end
  table.sort(types)
  for _, districtType in ipairs(types) do
    local row = Row(districtType)
    local limit = row and row.MaxPerPlayer or 0
    if limit > 0 then
      local total = planned[districtType] + (built[districtType] or 0) + (pins[districtType] or 0)
      if total > limit then
        Report(label, "unique", districtType .. ": " .. planned[districtType] .. " planned, "
          .. tostring(built[districtType] or 0) .. " built, " .. tostring(pins[districtType] or 0)
          .. " tacked; the empire may have " .. limit)
      end
    end
  end
  local list = {}
  for wonderType in pairs(wonders) do list[#list + 1] = wonderType end
  table.sort(list)
  for _, wonderType in ipairs(list) do
    if wonders[wonderType] > 1 then Report(label, "unique", wonderType .. " planned " .. wonders[wonderType] .. " times") end
    if (pins[wonderType] or 0) > 0 then Report(label, "unique", wonderType .. " planned and tacked") end
  end
end

-- One district of a kind per city, none it has built, no exclusive pair.
local function CheckOneCity(label, items, scan)
  local seen, types = {}, {}
  for _, b in ipairs(scan.Built or {}) do
    if b.Type ~= nil then
      seen[Base(b.Type)] = "built"
      types[b.Type] = true
    end
  end
  for _, item in ipairs(items) do
    if item.Kind ~= "WONDER" then
      local row, base = Row(item.Type), Base(item.Type)
      if row ~= nil and row.OnePerCity ~= false and seen[base] ~= nil then
        Report(label, "onecity", Where(item) .. ": the city has " .. base .. " " .. seen[base] .. " already")
      end
      seen[base] = seen[base] or "planned"
      local other = SDP_Rules.ExcludedBy(item.Type, types)
      if other ~= nil then Report(label, "onecity", Where(item) .. " and " .. other .. " cannot share a city") end
      types[item.Type] = true
    end
  end
end

local function CheckCandidates(label, items, scan, blocked)
  local allowed = Set(scan.Candidates, "Index")
  local reached = SDP_City.Reach(scan.Reach.Start, scan.Reach.Through, blocked)
  for _, item in ipairs(items) do
    if Map.GetPlotDistance(scan.X, scan.Y, item.X, item.Y) > SDP_City.RADIUS then
      Report(label, "reach", Where(item) .. " is beyond the city's " .. SDP_City.RADIUS .. " rings")
    elseif not allowed[item.Index] then
      Report(label, "reach", Where(item) .. " is not a plot the city can take")
    elseif not reached[item.Index] then
      Report(label, "reach", Where(item) .. " is cut off from the city's territory by the other cities' plan")
    end
  end
end

-- The parts of every district, and of every city, add up (World.CheckParts,
-- without asserting).
local function CheckParts(label, s)
  if s.Rest == nil then return end
  local function Near(a, b, what)
    if type(a) ~= "number" or type(b) ~= "number" or math.abs(a - b) > EPS then
      Report(label, "parts", what .. ": " .. tostring(a) .. " ~= " .. tostring(b))
    end
  end
  local sum = { Adjacency = 0, Land = 0, Distance = 0, Appeal = 0, Coverage = 0 }
  for _, p in ipairs(s.Plan) do
    if p.Parts == nil then
      Report(label, "parts", Where(p) .. " has no parts")
      return
    end
    for key in pairs(sum) do sum[key] = sum[key] + (p.Parts[key] or 0) end
    Near(p.Parts.Adjacency, p.Score, Where(p) .. " adjacency part vs its weighted score")
  end
  local rest = s.Rest
  Near(sum.Adjacency + (rest.Adjacency or 0), s.Adjacency, "adjacency")
  Near(sum.Land + (rest.Land or 0), s.LandDelta, "tiles")
  Near(sum.Distance, s.CostDelta, "distance")
  Near(sum.Appeal + (rest.Appeal or 0), s.AppealDelta or 0, "housing")
  Near(sum.Coverage + (rest.Coverage or 0), s.CoverageDelta, "reach")
  Near(s.Adjacency + s.LandDelta + s.CostDelta + s.CoverageDelta + (s.AppealDelta or 0), s.Gain, "the parts give the gain")
  if s.YieldWeighted ~= nil then
    local weighted = 0
    for _, yieldType in ipairs(SDP_Rules.YIELDS) do weighted = weighted + (s.YieldWeighted[yieldType] or 0) end
    Near(weighted, s.Adjacency, "the weighted adjacency by yield")
  end
  local cityTotal = { Adjacency = 0, Land = 0, Distance = 0 }
  for _, city in ipairs(s.Cities or {}) do
    local own = { Adjacency = 0, Land = 0, Distance = 0 }
    for _, p in ipairs(s.Plan) do
      if p.City == city.Key then
        for key in pairs(own) do own[key] = own[key] + (p.Parts[key] or 0) end
      end
    end
    local parts = city.Parts or {}
    for _, key in ipairs({ "Adjacency", "Land", "Distance" }) do
      Near(parts[key] or 0, own[key], tostring(city.Key) .. " subtotal " .. key)
      cityTotal[key] = cityTotal[key] + (parts[key] or 0)
    end
    Near(parts.Adjacency or 0, city.Gain or 0, tostring(city.Key) .. " adjacency vs its gain")
  end
  if s.Cities ~= nil then
    Near(cityTotal.Adjacency + (rest.Adjacency or 0), s.Adjacency, "the cities' adjacency subtotals")
    Near(cityTotal.Land + (rest.Land or 0), s.LandDelta, "the cities' tile subtotals")
    Near(cityTotal.Distance, s.CostDelta, "the cities' distance subtotals")
  end
end

-- ---------------------------------------------------------------------------
-- Single city (SDP_Solver)
-- ---------------------------------------------------------------------------
local function CheckSingle(session, result)
  if not result.Ok then return end
  local request, scan, playerID = session.Request, session.Scan, session.PlayerID
  local ignore = SDP_City.ScanOptions(request).ignorePins
  for n, s in ipairs(result.Solutions or {}) do
    local label = "single city " .. tostring(scan.CityID) .. " solution " .. n
    CheckPlots(label, s.Plan, playerID, ignore)
    CheckUnique(label, s.Plan, playerID, ignore)
    CheckOneCity(label, s.Plan, scan)
    CheckCandidates(label, s.Plan, scan, nil)
    CheckParts(label, s)
    if request.Count ~= nil then
      local placed, required = 0, 0
      for _, item in ipairs(s.Plan) do
        if Specialty(item.Type) then
          placed = placed + 1
          if not item.Picked then required = required + 1 end
        end
      end
      if placed > math.max(request.Count, required) then
        Report(label, "count", placed .. " districts that take population, " .. request.Count .. " asked, "
          .. required .. " required")
      end
    end
  end
  -- What was asked is placed or not placed, never both (the best plan).
  local label = "single city " .. tostring(scan.CityID)
  local placed, unplaced = Set(result.Plan, "Type"), {}
  for _, u in ipairs(result.Unplaced or {}) do
    if placed[u.Type] then Report(label, "unplaced", u.Type .. " placed and listed as " .. tostring(u.Reason)) end
    unplaced[u.Type] = true
  end
  for _, districtType in ipairs(request.Districts or {}) do
    if not placed[districtType] and not unplaced[districtType] then
      Report(label, "unplaced", districtType .. " asked, neither placed nor listed as not placed")
    end
  end
end

-- ---------------------------------------------------------------------------
-- Several cities (SDP_Multi)
-- ---------------------------------------------------------------------------

-- The districts of participant `part` next to plot `index` (built, its own
-- tacks, and the plan's entries recorded for it).
local function OwnNeighbours(part, index, plan)
  local out = {}
  for _, b in ipairs(part.Scan.Built or {}) do
    if b.Index ~= nil and Touch(b.Index, index) then out[#out + 1] = b.Type end
  end
  for _, pin in ipairs(SDP_City.OwnPins(part.Scan)) do
    local key = (pin.Icon or ""):gsub("^ICON_", "")
    if GameInfo.Districts[key] ~= nil and Touch(pin.Index, index) then out[#out + 1] = key end
  end
  for _, item in ipairs(plan) do
    if item.City == part.Key and item.Kind ~= "WONDER" and Touch(item.Index, index) then out[#out + 1] = item.Type end
  end
  return out
end

local function CheckMultiSolution(session, label, s)
  local request, playerID = session.Request, session.PlayerID
  local ignore = SDP_City.ScanOptions(request).ignorePins
  local byKey, order = {}, {}
  for _, part in ipairs(session.Participants) do
    byKey[part.Key] = part
    order[#order + 1] = part
  end
  CheckPlots(label, s.Plan, playerID, ignore)
  CheckUnique(label, s.Plan, playerID, ignore)
  CheckParts(label, s)
  local supplied = {}
  for _, item in ipairs(session.Supplied or {}) do supplied[item.City .. "|" .. item.Type] = item.Wonder end
  local wonderAt = {}
  for _, item in ipairs(s.Plan) do
    if item.Kind == "WONDER" then wonderAt[item.Type] = item end
    if byKey[item.City] == nil then Report(label, "reach", Where(item) .. " is recorded for " .. tostring(item.City)
      .. ", not a participating city") end
  end
  -- Per city: count, one of a kind, plots it can take.
  local cityOf = {}
  for _, city in ipairs(s.Cities or {}) do cityOf[city.Key] = city end
  for _, part in ipairs(order) do
    local mine, blocked = {}, {}
    for _, item in ipairs(s.Plan) do
      if item.City == part.Key then mine[#mine + 1] = item else blocked[item.Index] = true end
    end
    local where = label .. ", " .. tostring(part.Key)
    CheckOneCity(where, mine, part.Scan)
    CheckCandidates(where, mine, part.Scan, blocked)
    local count = (request.Counts and request.Counts[part.Key]) or request.Count
    if count ~= nil then
      local asked = (cityOf[part.Key] and cityOf[part.Key].Plan) or {}
      if request.Target and part.Kind == "CITY" then
        count = count - SDP_City.HaveCount(SDP_City.SpecialtyHave(part.Scan), Set(asked))
      end
      local required = 0
      for _, districtType in ipairs(asked) do
        if Specialty(districtType) and supplied[part.Key .. "|" .. districtType] == nil then required = required + 1 end
      end
      local placed = 0
      for _, item in ipairs(mine) do
        if item.Kind ~= "WONDER" and Specialty(item.Type) then placed = placed + 1 end
      end
      if placed > math.max(count, required) then
        Report(where, "count", placed .. " districts that take population, room for " .. count .. ", "
          .. required .. " required")
      end
    end
  end
  -- Wonders: the recorded city can build it there.
  for _, item in ipairs(s.Plan) do
    local part = byKey[item.City]
    if item.Kind == "WONDER" and part ~= nil then
      local row = GameInfo.Buildings[item.Type]
      local needs = row and row.AdjacentDistrict or nil
      if needs ~= nil then
        local ok = false
        for _, districtType in ipairs(OwnNeighbours(part, item.Index, s.Plan)) do
          if Base(districtType) == needs then ok = true end
        end
        if not ok then
          Report(label, "wonder", Where(item) .. " is recorded for " .. tostring(item.City) .. ", which has no "
            .. needs .. " next to it")
        end
      end
    end
    if item.ForWonder ~= nil and item.Kind ~= "WONDER" then
      local wonder = wonderAt[item.ForWonder]
      if wonder ~= nil and not Touch(wonder.Index, item.Index) then
        Report(label, "wonder", Where(item) .. " supplied for " .. item.ForWonder .. " is not next to it ("
          .. Where(wonder) .. ")")
      end
    end
  end
  -- Unplaced: never both placed and listed; everything asked accounted for.
  local placed = {}
  for _, item in ipairs(s.Plan) do
    placed[(item.Kind == "WONDER" and "WONDERS" or item.City) .. "|" .. item.Type] = true
  end
  local listed = {}
  for _, u in ipairs(s.Unplaced or {}) do
    if u.Type ~= "POOL" then
      local key = tostring(u.City) .. "|" .. tostring(u.Type)
      if placed[key] then
        Report(label, "unplaced", key .. " placed and listed as " .. tostring(u.Reason))
      end
      listed[key] = true
    end
  end
  for _, city in ipairs(s.Cities or {}) do
    for _, districtType in ipairs(city.Plan or {}) do
      local key = city.Key .. "|" .. districtType
      if not placed[key] and not listed[key] then
        Report(label, "unplaced", key .. " asked, neither placed nor listed as not placed")
      end
    end
  end
  for _, wonderType in ipairs(request.Wonders or {}) do
    local key = "WONDERS|" .. wonderType
    if not placed[key] and not listed[key] then
      Report(label, "unplaced", wonderType .. " asked, neither placed nor listed as not placed")
    end
  end
end

local function CheckMulti(session, result)
  if not result.Ok then return end
  for n, s in ipairs(result.Solutions or {}) do
    CheckMultiSolution(session, "several cities, solution " .. n, s)
  end
end

-- ---------------------------------------------------------------------------
-- Hooks: every Session:Result of both solvers. The check never raises (a
-- solve runs inside pcall, which would turn an error into a failed solve):
-- what it finds is kept for the runner, a crash of the check included.
-- ---------------------------------------------------------------------------
local function Wrap(module, check)
  if module == nil or module.NewSession == nil or module.__sdp_invariants == module.NewSession then return end
  local new = module.NewSession
  local wrapped
  wrapped = function(...)
    local session = new(...)
    local mt = getmetatable(session)
    if mt ~= nil and not mt.__sdp_invariants then
      mt.__sdp_invariants = true
      local result = mt.Result
      mt.Result = function(self, ...)
        local out = result(self, ...)
        if not Off("*") and type(out) == "table" then
          Inv.Results = Inv.Results + 1
          local ok, err = pcall(check, self, out)
          if not ok then Report("check", "crash", tostring(err)) end
        end
        return out
      end
    end
    return session
  end
  module.NewSession = wrapped
  module.__sdp_invariants = wrapped
end

function Inv.Install()
  Wrap(SDP_Solver, CheckSingle)
  Wrap(SDP_Multi, CheckMulti)
end

-- Check one result by hand; returns what it finds (spec_invariants.lua)
-- instead of failing the test.
function Inv.Check(result)
  local saved = Inv.Found
  Inv.Found = {}
  local session = result and result.Session
  if session ~= nil then
    if session.Participants ~= nil then CheckMulti(session, result) else CheckSingle(session, result) end
  end
  local found = Inv.Found
  Inv.Found = saved
  return found
end

return Inv
