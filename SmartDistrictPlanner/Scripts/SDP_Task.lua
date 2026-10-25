-- SDP_Task: runs one long computation a slice per frame
-- (docs/multicity-design.md section 6).
--
-- The computation is ordinary code run in a coroutine. It reports its work
-- with SDP_Task.Tick(units) (one DMT call = 1 unit, SDP_Tiers); when the
-- frame's quota is used up, Tick yields and the next frame resumes it. The
-- quota adapts to the frame time (UI.GetElapsedTime advances per frame; the
-- game's clocks only tick in whole seconds), aiming at about TARGET_FRAME
-- seconds per frame. A long frame shrinks the quota only when the task's own
-- slice is a real part of it: when the game itself is slow (other programs
-- busy), a smaller slice would not shorten the frame and would only starve
-- the task (issue 65). Results never depend on where the slices fall: the
-- computation is the same code whatever the quota (constraint 6).
--
-- Rules for the computation:
--   - never call Tick inside a pcall: Lua 5.1 cannot yield across it;
--   - leave the overlay layer as it found it between Ticks only if it does
--     not own it: the task suspends the overlay with its layer between frames
--     (SDP_Overlay.Suspend / Resume), so the rest of the game never sees it.
-- Without coroutines (Risk 1 in the design) a task runs to the end in its
-- first step, as one long frame.
--
-- One task at a time. The panel drives it from ContextPtr:SetUpdate.

SDP_Task = {}

SDP_Task.TARGET_FRAME = 1 / 30   -- seconds per frame we aim to keep
SDP_Task.MIN_QUOTA = 4
SDP_Task.MAX_QUOTA = 2000
SDP_Task.START_QUOTA = 40
-- Units per second of waiting, before this game has measured its own.
-- Measured in the game (2026-10-20): about 20000 units per second at once
-- (SDP_Tiers); a sliced task, at TARGET_FRAME, does 7400-9900 per second of
-- waiting for one city and about 15000 for several (lighter units); the game
-- draws the rest of each ~30 ms frame. Refined by every finished task.
SDP_Task.DEFAULT_SPEED = 11000
SDP_Task.AT_ONCE_SPEED = 20000
-- A finished task whose frames averaged longer than this many TARGET_FRAMEs
-- ran while the game itself was slow; its speed says nothing about the usual
-- wait and is not kept.
SDP_Task.SLOW_FRAMES = 3

local m_job = nil         -- the running job
local m_inWorker = false  -- our coroutine is running (Tick may yield)
local m_quota = SDP_Task.START_QUOTA
local m_used = 0
local m_speed = nil       -- measured units per second of waiting

local function HasCoroutines()
  return coroutine ~= nil and coroutine.create ~= nil and coroutine.resume ~= nil
    and coroutine.status ~= nil and coroutine.yield ~= nil
end
SDP_Task.HasCoroutines = HasCoroutines

-- Count `units` of work; yields to the next frame when the quota is used.
-- Does nothing outside a task (synchronous solves call it too).
function SDP_Task.Tick(units)
  if not m_inWorker then return end
  m_used = m_used + units
  if m_used >= m_quota then
    m_inWorker = false
    coroutine.yield()
    m_inWorker = true
  end
end

function SDP_Task.IsRunning()
  return m_job ~= nil
end

function SDP_Task.Current()
  return m_job
end

-- Start a job. job = {
--   Name, PlayerID       the overlay is installed for this player while it runs
--   Run()                the computation; returns its result
--   Estimate             expected units (progress display), optional
--   IsStale()            optional: true when the inputs changed (turn, pins)
--   OnDone(result, job), OnError(message, job), OnCancel(job)   optional
-- }
-- Returns false when another job is running.
function SDP_Task.Start(job)
  if m_job ~= nil then return false end
  job.Units, job.Frames, job.Seconds, job.Status = 0, 0, 0, "running"
  if HasCoroutines() then
    job.Worker = coroutine.create(function() return job.Run() end)
  end
  m_job = job
  m_quota = SDP_Task.START_QUOTA
  job.LastTime = UI.GetElapsedTime()
  return true
end

local function Finish(job, status, value)
  m_job = nil
  job.Status = status
  if status == "done" then
    local slow = job.Frames > 0 and job.Seconds / job.Frames > SDP_Task.TARGET_FRAME * SDP_Task.SLOW_FRAMES
    if job.Seconds > 0 and job.Units > 0 and not slow then
      local speed = job.Units / job.Seconds
      m_speed = m_speed and (m_speed + speed) / 2 or speed
    end
    if job.OnDone then job.OnDone(value, job) end
  elseif status == "error" then
    if job.OnError then job.OnError(value, job) end
  elseif status == "cancelled" then
    if job.OnCancel then job.OnCancel(job) end
  end
  return status
end

-- Adapt the quota to the last frame's length. The slice's own share is
-- estimated from its units (the game's clocks cannot time it).
local function Adapt(job)
  local now = UI.GetElapsedTime()
  local frame = now - (job.LastTime or now)
  job.LastTime = now
  if job.Frames > 0 and frame > 0 then
    job.Seconds = job.Seconds + frame
    local target = SDP_Task.TARGET_FRAME
    local own = (job.LastUsed or 0) / SDP_Task.AT_ONCE_SPEED
    local grow = frame < target * 0.75
    if frame > target * 1.25 then
      if own > target * 0.5 then
        m_quota = math.max(SDP_Task.MIN_QUOTA, math.floor(m_quota * 0.75))
      elseif own < target * 0.25 then
        grow = true -- the game's own frame is long; our slice is small
      end
    end
    if grow then m_quota = math.min(SDP_Task.MAX_QUOTA, math.ceil(m_quota * 1.25)) end
  end
end

-- Run the next slice. `quota` (optional, tests) fixes the units per slice.
-- Returns "idle", "running", "done", "error" or "cancelled".
function SDP_Task.Step(quota)
  local job = m_job
  if job == nil then return "idle" end
  if job.IsStale ~= nil and job.IsStale() then return Finish(job, "error", "STALE") end
  Adapt(job)
  if quota ~= nil then m_quota = quota end

  if job.Overlay == nil then
    SDP_Overlay.Install(job.PlayerID)
  else
    SDP_Overlay.Resume(job.Overlay)
  end
  m_used = 0
  local ok, result, finished
  if job.Worker ~= nil then
    m_inWorker = true
    ok, result = coroutine.resume(job.Worker)
    m_inWorker = false
    finished = coroutine.status(job.Worker) == "dead"
  else
    ok, result = pcall(job.Run)
    finished = true
  end
  job.Overlay = SDP_Overlay.Suspend()
  job.Units = job.Units + m_used
  job.LastUsed = m_used
  job.Frames = job.Frames + 1

  if not ok then return Finish(job, "error", tostring(result)) end
  if finished then return Finish(job, "done", result) end
  return "running"
end

-- Run a job to the end now (tests; the quota only changes how often it
-- pauses). Returns the final status and the result or error.
function SDP_Task.RunAll(job, quota)
  local result, message
  local onDone, onError = job.OnDone, job.OnError
  job.OnDone = function(value, j)
    result = value
    if onDone then onDone(value, j) end
  end
  job.OnError = function(value, j)
    message = value
    if onError then onError(value, j) end
  end
  if not SDP_Task.Start(job) then return "busy" end
  local status = "running"
  while status == "running" do status = SDP_Task.Step(quota) end
  return status, result or message
end

function SDP_Task.Cancel()
  local job = m_job
  if job == nil then return false end
  Finish(job, "cancelled")
  return true
end

-- { Units, Estimate, Frames, Seconds } of the running job, or nil.
function SDP_Task.Progress()
  local job = m_job
  if job == nil then return nil end
  return { Units = job.Units, Estimate = job.Estimate, Frames = job.Frames, Seconds = job.Seconds }
end

-- Units per second of waiting: measured by finished tasks, or the default.
function SDP_Task.Speed()
  return m_speed or SDP_Task.DEFAULT_SPEED
end

-- Expected seconds of waiting for `units` of work: as a task over several
-- frames, or (`atOnce`) in one go.
function SDP_Task.EstimateSeconds(units, atOnce)
  if atOnce then return units / SDP_Task.AT_ONCE_SPEED end
  return units / SDP_Task.Speed()
end
