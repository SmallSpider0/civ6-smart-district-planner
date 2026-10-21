-- Offline: SDP_Task frame slicing.
local test, T = ...

include("SDP_Rules")
include("SDP_City")
include("SDP_Overlay")
include("SDP_Tiers")
include("SDP_Task")
include("SDP_Board")
include("SDP_Land")
include("SDP_Appeal")
include("SDP_Search")
include("SDP_Solver")

local function CountingJob(n, log)
  return {
    Name = "count", PlayerID = 0,
    Run = function()
      local sum = 0
      for i = 1, n do
        sum = sum + i
        log[#log + 1] = SDP_Overlay.IsInstalled()
        SDP_Task.Tick(1)
      end
      return sum
    end,
  }
end

test("the result does not depend on the quota", function()
  World.New({ rows = { "..." } })
  local log1, log2 = {}, {}
  local job1, job2 = CountingJob(50, log1), CountingJob(50, log2)
  local status1, sum1 = SDP_Task.RunAll(job1, 1)
  local status2, sum2 = SDP_Task.RunAll(job2, 1000)
  T.eq(status1, "done", "status, quota 1")
  T.eq(status2, "done", "status, quota 1000")
  T.eq(sum1, 1275, "sum")
  T.eq(sum2, sum1, "same result")
  T.eq(job1.Frames, 51, "one unit per frame, then the frame that returns")
  T.eq(job2.Frames, 1, "everything in one frame")
  for _, installed in ipairs(log1) do T.ok(installed, "the overlay is installed while the job runs") end
  T.ok(not SDP_Overlay.IsInstalled(), "and removed afterwards")
end)

test("between frames the overlay is out and its layer kept", function()
  World.New({ rows = { "....." } })
  local job = {
    PlayerID = 0,
    Run = function()
      SDP_Overlay.Put(1, 0, SDP_Overlay.Subject("DISTRICT_CAMPUS", 1, 0))
      SDP_Task.Tick(1)
      local subject = GetMapPinSubject(0, 1, 0)
      SDP_Overlay.Put(1, 0, nil)
      return subject and subject.Key
    end,
  }
  T.ok(SDP_Task.Start(job), "started")
  T.eq(SDP_Task.Step(1), "running", "first slice")
  T.ok(not SDP_Overlay.IsInstalled(), "overlay out between frames")
  T.eq(GetMapPinSubject(0, 1, 0), nil, "the game does not see the planned subject")
  T.eq(SDP_Task.Step(1), "done", "second slice")
  T.eq(job.Status, "done", "status")
end)

test("only one task at a time; cancel; stale inputs", function()
  World.New({ rows = { "..." } })
  local job = CountingJob(10, {})
  T.ok(SDP_Task.Start(job), "first starts")
  T.ok(not SDP_Task.Start(CountingJob(1, {})), "second is refused")
  SDP_Task.Step(1)
  local cancelled = false
  job.OnCancel = function() cancelled = true end
  T.ok(SDP_Task.Cancel(), "cancel")
  T.ok(cancelled, "cancel callback")
  T.ok(not SDP_Task.IsRunning(), "nothing running")
  T.ok(not SDP_Overlay.IsInstalled(), "overlay out")

  local stale = CountingJob(10, {})
  local turn = 1
  stale.IsStale = function() return turn ~= 1 end
  SDP_Task.Start(stale)
  SDP_Task.Step(1)
  turn = 2
  local message
  stale.OnError = function(m) message = m end
  T.eq(SDP_Task.Step(1), "error", "stale")
  T.eq(message, "STALE", "message")
end)

test("errors end the task and leave the overlay out", function()
  World.New({ rows = { "..." } })
  local status, message = SDP_Task.RunAll({ PlayerID = 0, Run = function()
    SDP_Task.Tick(1)
    error("boom")
  end }, 1)
  T.eq(status, "error", "status")
  T.ok(tostring(message):find("boom") ~= nil, "message")
  T.ok(not SDP_Overlay.IsInstalled(), "overlay out")
end)

test("a sliced solve equals the solve at once", function()
  World.New({
    rows = {
      "~~~~~~~~~~",
      "~..f.M..h~",
      "~.fMj..p.~",
      "~h..f.j..~",
      "~.pM...f.~",
      "~..j.p..q~",
      "~~~~~~~~~~",
    },
    rivers = { "6,4", "6,3" },
    cities = { { id = 1, x = 5, y = 3, population = 7, capital = true } },
  })
  local request = { PlayerID = 0, CityID = 1, Tier = "FINE", Land = true,
    Districts = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER", "DISTRICT_COMMERCIAL_HUB" },
    Params = { ExactLimit = 0 } }
  local direct = SDP_Solver.Solve(request)
  local function Sliced(quota)
    local scan = SDP_City.Scan(0, 1)
    local status, result = SDP_Task.RunAll({ PlayerID = 0, Run = function() return SDP_Solver.SolveScan(request, scan) end }, quota)
    T.eq(status, "done", "status")
    return result
  end
  for _, quota in ipairs({ 1, 7, 1000 }) do
    local sliced = Sliced(quota)
    T.same(sliced.Plan, direct.Plan, "plan, quota " .. quota)
    T.eq(sliced.Gain, direct.Gain, "gain, quota " .. quota)
    T.same(sliced.Stats, direct.Stats, "stats, quota " .. quota)
  end
end)
