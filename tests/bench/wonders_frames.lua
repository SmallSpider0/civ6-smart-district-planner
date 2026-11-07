-- Issue 307: many wonders ticked on the Several cities tab must not freeze
-- the game. Run in the SDP_Panel state by tests/bench/wonders_frames.py on a
-- loaded game with several cities (a stress save). Loading this file defines
-- SDP_WonderFrames; the driver calls one function per Tuner request:
--   Start(cities, wonders, tier, everyDistrict)  the tab set as a player
--                    would: the `cities` cities nearest the capital take
--                    part (the capital first), the first `wonders` wonders
--                    the player can build ticked (-1: all of them), the
--                    tier, with `everyDistrict` every district required in
--                    the shared list (issue 331); then the Solve button's
--                    own callback. Every frame is timed while
--                    the task runs (the panel's own per-frame step).
--   Running()        "RUNNING 1" while the task runs, else "RUNNING 0"
--   Report()         one line "SDP_WFRAMES {json}": frames, the longest
--                    frame and the slices' units, the result
--   Clear()          leaves the tab as it was set before (no wonders ticked;
--                    the districts made required back to their default)
-- Changes nothing in the game (no pins are placed).
SDP_WonderFrames = {}
local M = SDP_WonderFrames
local P = SDP_PageMulti

local function Json(v)
  local t = type(v)
  if t == "number" then return string.format("%.6g", v) end
  if t == "string" then return string.format("%q", v) end
  if t == "boolean" then return tostring(v) end
  if t ~= "table" then return "null" end
  if #v > 0 then
    local parts = {}
    for _, x in ipairs(v) do parts[#parts + 1] = Json(x) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = string.format("%q:%s", k, Json(v[k])) end
  return "{" .. table.concat(parts, ",") .. "}"
end

function M.Start(cities, wonders, tier, everyDistrict)
  local pid = Game.GetLocalPlayer()
  local player = Players[pid]
  local capital = player:GetCities():GetCapitalCity()
  local list = {}
  for _, city in player:GetCities():Members() do
    local d = Map.GetPlotDistance(city:GetX(), city:GetY(), capital:GetX(), capital:GetY())
    list[#list + 1] = { City = city, Distance = d }
  end
  table.sort(list, function(a, b)
    if a.Distance ~= b.Distance then return a.Distance < b.Distance end
    return a.City:GetID() < b.City:GetID()
  end)
  SDP_Panel.Open()
  SDP_Panel.SelectTab("MULTI")
  P.SetCenter(capital:GetID())
  P.ClearCities()
  M.cities = {}
  for k = 1, math.min(cities, #list) do
    P.SetExisting(list[k].City:GetID(), true)
    M.cities[k] = list[k].City:GetID()
  end
  M.wonders = {}
  for _, w in ipairs(SDP_Wonders.List(pid)) do
    if w.Status == nil and (wonders < 0 or #M.wonders < wonders) then
      M.wonders[#M.wonders + 1] = w.Type
      P.SetWonder(w.Type, true)
    end
  end
  M.districts = {}
  if everyDistrict then
    for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do
      M.districts[#M.districts + 1] = d
      P.SetState(d.Type, "MUST")
    end
  end
  P.SetTier(tier or "STANDARD")
  M.rows, M.started = {}, UI.GetElapsedTime()
  P.Solve() -- what the Solve button calls
  local running = SDP_Task.IsRunning()
  if running then
    -- The panel's own step (OnUpdate), timed.
    local last, lastUnits = UI.GetElapsedTime(), 0
    ContextPtr:SetUpdate(function()
      local now = UI.GetElapsedTime()
      SDP_Task.Step()
      local p = SDP_Task.Progress()
      local units = p and p.Units or lastUnits
      M.rows[#M.rows + 1] = { now - last, units - lastUnits }
      last, lastUnits = now, units
      if not SDP_Task.IsRunning() then M.ended = UI.GetElapsedTime() end
    end)
  end
  print("STARTED " .. tostring(running) .. " cities=" .. #M.cities .. " wonders=" .. #M.wonders
    .. " districts=" .. #M.districts)
end

function M.Running()
  print("RUNNING " .. (SDP_Task.IsRunning() and "1" or "0"))
end

function M.Report()
  local frames, max, sum, maxUnits = #M.rows, 0, 0, 0
  local over = { 0, 0, 0 } -- frames over 0.1, 0.5 and 2 seconds
  for _, r in ipairs(M.rows) do
    sum = sum + r[1]
    if r[1] > max then max = r[1] end
    if r[2] > maxUnits then maxUnits = r[2] end
    if r[1] > 0.1 then over[1] = over[1] + 1 end
    if r[1] > 0.5 then over[2] = over[2] + 1 end
    if r[1] > 2 then over[3] = over[3] + 1 end
  end
  local result = P.State().Result
  local placed = 0
  for _, p in ipairs(result and result.Plan or {}) do
    if p.Kind == "WONDER" then placed = placed + 1 end
  end
  print("SDP_WFRAMES " .. Json({ Cities = #M.cities, Wonders = #M.wonders, Districts = #(M.districts or {}), Frames = frames, MaxFrame = max,
    MeanFrame = frames > 0 and sum / frames or 0, Over = over, MaxUnits = maxUnits,
    Seconds = (M.ended or UI.GetElapsedTime()) - M.started, Ok = result and result.Ok or false,
    Error = result and result.Error or nil, WondersPlaced = placed,
    Unplaced = result and result.Unplaced and #result.Unplaced or 0 }))
end

function M.Clear()
  if SDP_Task.IsRunning() then SDP_Task.Cancel() end
  for _, w in ipairs(M.wonders or {}) do P.SetWonder(w, false) end
  for _, d in ipairs(M.districts or {}) do P.SetState(d.Type, SDP_UI.DefaultState(d)) end
  print("CLEARED")
end
