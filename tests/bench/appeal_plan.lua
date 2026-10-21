-- Part of tests/bench/calibrate_appeal.py (run in the SDP_Panel state, not
-- by run_tests.py). Picks a plan around the capital where DMT and the engine
-- allow it and prints what the appeal part (SDP_Appeal) predicts, as one
-- line "SDP_APPEAL_PLAN {json}":
--   A  appeal changers: a theater (on a plot whose feature building clears,
--      when there is one), an industrial zone, a holy site; predicted appeal
--      of every plot within 4 of the capital once they stand
--   B  a neighborhood next to the industrial zone: its housing
--   C  a preserve three plots or more from the neighborhood, where the plots
--      around it are most appealing: its housing and the yields its grove and
--      sanctuary give each plot around it
-- The base it predicts from (the game's appeal now, as this state reads it)
-- is printed too, so the driver can tell a stale reading from a wrong rule.
local pid = Game.GetLocalPlayer()
local city = Players[pid]:GetCities():GetCapitalCity()
if city == nil then error("no capital") end
local scan = SDP_City.Scan(pid, city:GetID())
local rules = SDP_Appeal.Rules()

-- The player's own type for a base district (a unique one replaces it).
local own = {}
for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do own[SDP_Rules.BaseDistrict(d.Type)] = d.Type end

local chosen, used = {}, {}
local function Far(c, d)
  for _, other in ipairs(chosen) do
    if Map.GetPlotDistance(c.X, c.Y, other.X, other.Y) < d then return false end
  end
  return true
end
local function Clears(c)
  local feature = Map.GetPlotByIndex(c.Index):GetFeatureType()
  return feature ~= -1 and rules.Feature[feature] ~= nil
end
SDP_Overlay.With(pid, function()
  local function Pick(base, test)
    local districtType = own[base]
    if districtType == nil then return nil end
    for pos, c in ipairs(scan.Candidates) do
      if not used[c.Index] and test(c) and SDP_Overlay.CanPlace(SDP_Overlay.Subject(districtType, c.X, c.Y)) then
        used[c.Index] = true
        local entry = { Type = districtType, X = c.X, Y = c.Y, Index = c.Index, Pos = pos }
        chosen[#chosen + 1] = entry
        return entry
      end
    end
    return nil
  end
  local any = function() return true end
  local theater = Pick("DISTRICT_THEATER", Clears) or Pick("DISTRICT_THEATER", any)
  local iz = Pick("DISTRICT_INDUSTRIAL_ZONE", function(c) return Far(c, 2) end)
  local holy = Pick("DISTRICT_HOLY_SITE", function(c) return Far(c, 2) end)
  local hood = Pick("DISTRICT_NEIGHBORHOOD", function(c)
    return iz ~= nil and Map.GetPlotDistance(c.X, c.Y, iz.X, iz.Y) == 1
  end) or Pick("DISTRICT_NEIGHBORHOOD", any)
  -- The preserve where the most plots around are charming or better.
  local preserveType = own["DISTRICT_PRESERVE"]
  local bestScore, bestC = -1, nil
  for _, c in ipairs(scan.Candidates) do
    if preserveType ~= nil and not used[c.Index] and (hood == nil or Map.GetPlotDistance(c.X, c.Y, hood.X, hood.Y) >= 3)
        and SDP_Overlay.CanPlace(SDP_Overlay.Subject(preserveType, c.X, c.Y)) then
      local score = 0
      local plot = Map.GetPlotByIndex(c.Index)
      for dir = 0, 5 do
        local n = Map.GetAdjacentPlot(plot:GetX(), plot:GetY(), dir)
        if n ~= nil and n:GetAppeal() + 1 >= 2 and n:GetImprovementType() == -1 and n:GetDistrictType() == -1 then
          score = score + 1
        end
      end
      if score > bestScore then bestScore, bestC = score, c end
    end
  end
  local preserve = bestC and Pick("DISTRICT_PRESERVE", function(c) return c.Index == bestC.Index end) or nil
  if theater == nil or iz == nil or holy == nil or hood == nil or preserve == nil then
    error("could not place the whole plan")
  end
end)

local types, kinds = {}, {}
for m, entry in ipairs(chosen) do types[m], kinds[m] = entry.Type, "DISTRICT" end
local workable = {}
for _, index in ipairs(SDP_Land.Workable(scan)) do workable[index] = true end
local model = SDP_Appeal.New({ PlayerID = pid, Types = types, Kinds = kinds, Candidates = scan.Candidates,
  Fixed = SDP_Overlay.FixedSubjects(scan), Weights = {}, Lands = {}, Workable = workable })
local function Layout(count)
  local layout = {}
  for m, entry in ipairs(chosen) do layout[m] = m <= count and entry.Pos or 0 end
  return layout
end
local indices = {}
for dx = -4, 4 do
  for dy = -4, 4 do
    local plot = Map.GetPlotXYWithRangeCheck(city:GetX(), city:GetY(), dx, dy, 4)
    if plot ~= nil then indices[#indices + 1] = plot:GetIndex() end
  end
end
table.sort(indices)
local appealA = model:AppealsUnder(Layout(3), indices)
local hood, preserve = chosen[4], chosen[5]
local appealB = model:AppealsUnder(Layout(4), { hood.Index })
local around = {}
local plot = Map.GetPlotByIndex(preserve.Index)
for dir = 0, 5 do
  local n = Map.GetAdjacentPlot(plot:GetX(), plot:GetY(), dir)
  if n ~= nil then around[#around + 1] = n:GetIndex() end
end
local aroundAll = { preserve.Index }
for _, q in ipairs(around) do aroundAll[#aroundAll + 1] = q end
local appealC = model:AppealsUnder(Layout(5), aroundAll)

-- JSON (numbers, strings, arrays, objects with string keys).
local function Json(v)
  local t = type(v)
  if t == "number" then return string.format("%.17g", v) end
  if t == "string" then return string.format("%q", v) end
  if t == "boolean" then return tostring(v) end
  if t == "table" then
    if #v > 0 or next(v) == nil then
      local parts = {}
      for i = 1, #v do parts[i] = Json(v[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
      local value = v[k]
      if value == nil then value = v[tonumber(k)] end
      parts[#parts + 1] = string.format("%q", k) .. ":" .. Json(value)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end

local out = { City = { X = city:GetX(), Y = city:GetY(), ID = city:GetID() }, Builds = {}, AppealA = {}, Tiles = {} }
for m, entry in ipairs(chosen) do
  out.Builds[m] = { Type = entry.Type, X = entry.X, Y = entry.Y, Index = entry.Index, Step = (m <= 3 and "A") or (m == 4 and "B") or "C" }
end
for _, index in ipairs(indices) do
  out.AppealA[#out.AppealA + 1] = { Index = index, Appeal = appealA[index], Base = Map.GetPlotByIndex(index):GetAppeal() }
end
out.Neighborhood = { Appeal = appealB[hood.Index], Housing = SDP_Appeal.Housing(rules, hood.Type, appealB[hood.Index]) }
out.Preserve = { Appeal = appealC[preserve.Index], Housing = SDP_Appeal.Housing(rules, preserve.Type, appealC[preserve.Index]) }
for _, q in ipairs(around) do
  local qp = Map.GetPlotByIndex(q)
  local blocked = used[q] or qp:GetDistrictType() ~= -1 or qp:GetWonderType() ~= -1 or qp:IsCity()
  local yields = {}
  if not blocked then
    for _, row in ipairs(rules.Tiles[preserve.Type] or {}) do
      if appealC[q] >= row.Min and appealC[q] <= row.Max and not (row.Unimproved and qp:GetImprovementType() ~= -1) then
        yields[row.Yield] = (yields[row.Yield] or 0) + row.Change
      end
    end
  end
  out.Tiles[#out.Tiles + 1] = { Index = q, X = qp:GetX(), Y = qp:GetY(), Appeal = appealC[q], Blocked = blocked == true,
    Workable = workable[q] == true, Yields = yields }
end
print("SDP_APPEAL_PLAN " .. Json(out))
