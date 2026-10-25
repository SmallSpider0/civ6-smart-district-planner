-- How the number of cities on the Several cities tab changes the wait and
-- the plan (issue 63). Run in the SDP_Panel state by
-- tests/bench/multi_size.py, after tests/bench/stress.lua (SDP_Stress places
-- the city-center pins). Loading this file defines SDP_MultiSize; the driver
-- calls one function per Tuner request. Every report prints one line
-- "SDP_MSIZE {json}". Solves go through the tab itself (SDP_PageMulti), so
-- they run over frames as the player sees them; the driver times them.
--   Order()        the capital, then the other cities and the city-center
--                  pins by distance from it (ties: cities first, by ID / key)
--   Select(a, b)   take part: entries a..b of that order, nobody else
--   Setup(tier, count)  tier, districts per city (picked from the default pool)
--   Start()        solve over frames; Running() while it computes; Report(label) after
--   SolveNow()     solve at once (the driver times the request); Report(label)
--   Place(), Undo(n)    tack the plan; undo the last n batches
-- Over frames, the task's quota shrinks to its minimum when the game's own
-- frames are slow (game window in the background, other programs busy), so
-- such waits say little; at once is what the stress test measures.
SDP_MultiSize = {}
local M = SDP_MultiSize
local pid = Game.GetLocalPlayer()
local P = SDP_PageMulti

local function Json(v)
  local t = type(v)
  if t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    return string.format("%.10g", v)
  end
  if t == "string" then
    local q = string.format("%q", v):gsub("\\\n", "\\n")
    return (q:gsub("%c", function(c) return string.format("\\u%04x", c:byte()) end))
  end
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
    for _, k in ipairs(keys) do parts[#parts + 1] = string.format("%q", k) .. ":" .. Json(v[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end
local function Emit(t) print("SDP_MSIZE " .. Json(t)) end

M.List = {}

function M.Order()
  local capital = Players[pid]:GetCities():GetCapitalCity()
  local cx, cy = capital:GetX(), capital:GetY()
  local list = {}
  for _, city in Players[pid]:GetCities():Members() do
    list[#list + 1] = { Kind = "CITY", ID = city:GetID(), Key = "C" .. city:GetID(), X = city:GetX(), Y = city:GetY(),
      Name = Locale.Lookup(city:GetName()) }
  end
  for _, site in ipairs(SDP_City.Sites(pid)) do
    list[#list + 1] = { Kind = "SITE", Key = "S" .. site.Index, X = site.X, Y = site.Y, Name = "site" }
  end
  for _, e in ipairs(list) do e.Distance = Map.GetPlotDistance(cx, cy, e.X, e.Y) end
  table.sort(list, function(a, b)
    if a.Distance ~= b.Distance then return a.Distance < b.Distance end
    if a.Kind ~= b.Kind then return a.Kind == "CITY" end
    return a.Key < b.Key
  end)
  M.List = list
  -- Pairwise distances: how far apart the cities taking part are.
  local pairs_ = {}
  for i = 1, #list do
    local row = {}
    for j = 1, #list do row[j] = Map.GetPlotDistance(list[i].X, list[i].Y, list[j].X, list[j].Y) end
    pairs_[i] = row
  end
  Emit({ Step = "Order", List = list, Distances = pairs_ })
end

function M.Select(a, b)
  local on = {}
  for i = a, b do if M.List[i] then on[M.List[i].Key] = true end end
  for _, e in ipairs(M.List) do
    if e.Kind == "CITY" then P.SetExisting(e.ID, on[e.Key] == true) else P.SetSite(e.Key, on[e.Key] == true) end
  end
  local parts = P.Participants()
  local keys = {}
  for _, part in ipairs(parts) do keys[#keys + 1] = part.Key end
  M.Selected = keys
  return #parts
end

function M.Setup(tier, count)
  P.SetTier(tier)
  P.SetCount(count)
  P.SetLand(true)
  P.SetRemind(false)
  P.SetReplace(false)
  P.SetSwap(false)
end

-- The panel's own estimate (SDP_PageMulti's Estimate, reproduced: average
-- districts per city, the pool).
local function EstimateUnits(request, tier)
  local participants = SDP_Multi.Participants(request.PlayerID, { Existing = request.Existing, Sites = request.Sites })
  local total, pick, pool = 0, 0, 0
  for _, part in ipairs(participants) do
    local must = request.Districts
    total = total + #must
    local mustSpecialty = 0
    for _, t in ipairs(must) do
      local row = GameInfo.Districts[t]
      if row and row.RequiresPopulation then mustSpecialty = mustSpecialty + 1 end
    end
    pick = math.max(pick, (request.Count or 0) - mustSpecialty)
    pool = math.max(pool, #(request.Pool or {}))
  end
  local n = math.max(1, #participants)
  return SDP_Multi.EstimateUnits(#participants, math.ceil(total / n), #request.Wonders,
    SDP_Tiers.Params(SDP_Tiers.Multi, tier), pick, pool)
end

function M.Start(label)
  local request = P.Request()
  local units = request and EstimateUnits(request, request.Tier) or 0
  M.Label = label
  M.Estimate = { Units = units, Speed = SDP_Task.Speed(), Seconds = SDP_Task.EstimateSeconds(units),
    Text = Controls.MultiEstimate:GetText() }
  M.Result = nil
  local ok = P.Solve()
  M.Job = SDP_Task.Current()
  print("STARTED " .. tostring(ok))
end

function M.SolveNow(label)
  local request = P.Request()
  M.Label, M.Job = label, nil
  M.Estimate = { Units = request and EstimateUnits(request, request.Tier) or 0, Speed = SDP_Task.Speed() }
  M.Estimate.Seconds = SDP_Task.EstimateSeconds(M.Estimate.Units)
  M.Result = request and SDP_Multi.Solve(request) or { Ok = false, Error = "no request" }
  print("SOLVED " .. tostring(M.Result.Ok))
end

function M.Running()
  print("RUNNING " .. (SDP_Task.IsRunning() and "1" or "0"))
end

function M.Report(label)
  local r = M.Result or P.State().Result
  local out = { Step = "Solve", Label = label, Selected = M.Selected, Estimate = M.Estimate }
  local job = M.Job
  if job ~= nil then out.Job = { Units = job.Units, Frames = job.Frames, Seconds = job.Seconds, Status = job.Status } end
  if r == nil or not r.Ok then
    out.Ok, out.Error = false, r and tostring(r.Error) or "no result"
    Emit(out)
    return
  end
  out.Ok = true
  out.Gain, out.Adjacency, out.Land = r.Gain, r.Adjacency, r.LandDelta
  out.Placed, out.Unplaced = #(r.Plan or {}), #(r.Unplaced or {})
  out.Calls, out.Tries = r.Stats and r.Stats.Calls, r.Stats and r.Stats.Tries
  out.Exhaustive = r.Quality and r.Quality.Exhaustive or false
  out.Cities = #(r.Cities or {})
  -- New districts of different cities next to each other, by how far apart
  -- their cities are.
  local where = {}
  for _, c in ipairs(r.Cities or {}) do where[c.Key] = { X = c.X, Y = c.Y } end
  local cross = {}
  local plan = r.Plan or {}
  out.Plan = {}
  for i, a in ipairs(plan) do
    out.Plan[i] = { City = a.City, Type = a.Type, X = a.X, Y = a.Y }
    for j = i + 1, #plan do
      local b = plan[j]
      if a.City ~= b.City and Map.GetPlotDistance(a.X, a.Y, b.X, b.Y) == 1 and where[a.City] and where[b.City] then
        local d = Map.GetPlotDistance(where[a.City].X, where[a.City].Y, where[b.City].X, where[b.City].Y)
        cross[#cross + 1] = { A = a.City, B = b.City, Distance = d }
      end
    end
  end
  out.Cross = cross
  out.CityXY = where
  Emit(out)
end

function M.Place()
  local r = M.Result or P.State().Result
  local names = {}
  for _, c in ipairs(r.Cities or {}) do names[c.Key] = tostring(c.Number or "") end
  local entries = {}
  for _, p in ipairs(r.Plan or {}) do
    if p.Kind == nil or p.Kind == "DISTRICT" then
      entries[#entries + 1] = { Type = p.Type, X = p.X, Y = p.Y, Name = names[p.City] or "" }
    end
  end
  print("PLACED " .. tostring(SDP_Pins.Place(pid, entries)))
end

function M.Undo(n)
  local removed = 0
  for _ = 1, n do removed = removed + SDP_Pins.UndoLast(pid) end
  print("UNDONE " .. tostring(removed))
end
