-- SDP_Task: runs one long computation a slice per frame
-- (docs/multicity-design.md section 6).
--
-- The computation is ordinary code run in a coroutine. It reports its work
-- with SDP_Task.Tick(units) (one DMT call = 1 unit, SDP_Tiers); when the
-- frame's quota is used up, Tick yields and the next frame resumes it. The
-- quota adapts to the frame time (UI.GetElapsedTime advances per frame; the
-- game's clocks only tick in whole seconds), aiming at about TARGET_FRAME
-- seconds per frame. Results never depend on where the slices fall: the
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
-- Units per second of waiting, before this game has measured its own: about
-- 0.07 ms per unit (SDP_Tiers) at about 60% of each frame. Refined by every
-- finished task.
SDP_Task.DEFAULT_SPEED = 8000

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
    if job.Seconds > 0 and job.Units > 0 then
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

-- Adapt the quota to the last frame's length.
local function Adapt(job)
  local now = UI.GetElapsedTime()
  local frame = now - (job.LastTime or now)
  job.LastTime = now
  if job.Frames > 0 and frame > 0 then
    job.Seconds = job.Seconds + frame
    if frame > SDP_Task.TARGET_FRAME * 1.25 then
      m_quota = math.max(SDP_Task.MIN_QUOTA, math.floor(m_quota * 0.75))
    elseif frame < SDP_Task.TARGET_FRAME * 0.75 then
      m_quota = math.min(SDP_Task.MAX_QUOTA, math.ceil(m_quota * 1.25))
    end
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

-- Expected seconds of waiting for `units` of work.
function SDP_Task.EstimateSeconds(units)
  return units / SDP_Task.Speed()
end
