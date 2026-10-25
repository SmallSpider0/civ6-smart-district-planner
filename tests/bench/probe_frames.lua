-- Frame length and the sliced task's share while the game window is in
-- front, behind other apps, or hidden (issue 65). Run in the SDP_Panel state
-- by tests/bench/probe_frames.py. Loading this file defines SDP_Frames; the
-- driver calls one function per Tuner request:
--   Start(withTask, slowRounds)  time every frame from now on; withTask
--                    also runs a synthetic SDP_Task job (units of fixed busy
--                    work), stepped once per frame as the panel does;
--                    slowRounds adds that much busy work to every frame
--                    outside the task, as a slow game would
--   Phase(name)      label the frames that follow
--   Stop()           end the frames (and the job: it finishes as "done", so
--                    SDP_Task calibrates its speed on it as on a real one)
--   Report()         one line "SDP_FRAMES {json}" per phase, then "SDP_SPEED"
--   AtOnce(n)        n units in one go (the driver times the request)
-- Changes nothing in the game; the task's measured speed stays changed
-- until the panel is reloaded.
SDP_Frames = {}
local M = SDP_Frames
local WORK = 2500 -- busy-loop rounds per unit

local function Work(n)
  local x = 0
  for i = 1, n do x = x + i % 7 end
  return x
end

function M.AtOnce(n)
  for _ = 1, n do Work(WORK) end
  print("ATONCE " .. n)
end

local function Shown(on)
  if on then
    Controls.DropShadow:SetHide(true)
    ContextPtr:SetHide(false)
  else
    if not UIManager:IsInPopupQueue(ContextPtr) then ContextPtr:SetHide(true) end
    Controls.DropShadow:SetHide(false)
  end
end

function M.Start(withTask, slowRounds)
  M.rows, M.phase, M.stop = {}, "start", false
  M.withTask = withTask and true or false
  if withTask then
    SDP_Task.Start({
      Name = "probe", PlayerID = Game.GetLocalPlayer(),
      Run = function()
        while not M.stop do
          Work(WORK)
          SDP_Task.Tick(1)
        end
        return 0
      end,
    })
  end
  local last, lastUnits = UI.GetElapsedTime(), 0
  Shown(true)
  ContextPtr:SetUpdate(function()
    if slowRounds then Work(slowRounds) end
    local now = UI.GetElapsedTime()
    local units = lastUnits
    if M.withTask then
      local status = SDP_Task.Step()
      local p = SDP_Task.Progress()
      units = p and p.Units or lastUnits
      if status ~= "running" then M.withTask = false end
    end
    table.insert(M.rows, { M.phase, now - last, units - lastUnits })
    last, lastUnits = now, units
  end)
  print("STARTED " .. tostring(SDP_Task.IsRunning()))
end

function M.Phase(name)
  M.phase = name
  print("PHASE " .. name)
end

function M.Stop()
  M.stop = true
  if SDP_Task.IsRunning() then SDP_Task.Step() end
  ContextPtr:ClearUpdate()
  Shown(false)
  print("STOPPED " .. tostring(SDP_Task.IsRunning()))
end

local function Json(t)
  local parts = {}
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local v = t[k]
    local s = type(v) == "string" and string.format("%q", v) or string.format("%.6g", v)
    parts[#parts + 1] = string.format("%q:%s", k, s)
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

function M.Report()
  local order, by = {}, {}
  for _, r in ipairs(M.rows or {}) do
    local p = by[r[1]]
    if p == nil then
      p = { dts = {}, units = 0, slices = {} }
      by[r[1]] = p
      order[#order + 1] = r[1]
    end
    p.dts[#p.dts + 1] = r[2]
    p.units = p.units + r[3]
    p.slices[#p.slices + 1] = r[3]
  end
  for _, name in ipairs(order) do
    local p = by[name]
    local sum, max = 0, 0
    for _, d in ipairs(p.dts) do sum = sum + d; if d > max then max = d end end
    local sorted = {}
    for i, d in ipairs(p.dts) do sorted[i] = d end
    table.sort(sorted)
    local slices = {}
    for i, s in ipairs(p.slices) do slices[i] = s end
    table.sort(slices)
    print("SDP_FRAMES " .. Json({
      Phase = name, Frames = #p.dts, Seconds = sum, MeanFrame = sum / math.max(1, #p.dts),
      MedianFrame = sorted[math.ceil(#sorted / 2)] or 0, MaxFrame = max,
      Units = p.units, UnitsPerSecond = sum > 0 and p.units / sum or 0,
      MedianSlice = slices[math.ceil(#slices / 2)] or 0, LastSlice = p.slices[#p.slices] or 0,
    }))
  end
  print("SDP_SPEED " .. string.format("%.6g", SDP_Task.Speed()))
end
