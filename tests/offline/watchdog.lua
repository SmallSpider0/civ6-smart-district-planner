-- Frame watchdog (issue 327): no frame of a sliced computation does much
-- more work than the game can do in about a fifth of a second.
-- tools/offline_tests.mjs loads this file into every state as SDP_Watchdog
-- and counts the Lua VM instructions run (a count hook, every
-- tools/offline_tests.mjs WATCH_STEP instructions); every SDP_Task.Step, one
-- frame of a panel task, is measured, and a test with a frame over LIMIT
-- fails, naming the task and the frame. A frame over the limit is stopped
-- there (the hook raises an error in it), so a runaway loop (issue 307: one
-- frame of 482 s) fails in seconds instead of running on.
--
-- The work between two SDP_Task.Tick calls is what makes a frame long, and
-- every loop has to report its work for the frames; a new loop that does
-- not, or reports far less than it does (issues 226, 307), shows up here
-- whatever test runs it.
--
-- A test that makes a long frame on purpose opts out with a reason:
--   SDP_Watchdog.OptOut("reason")
-- Called while a test runs, for the rest of that test; at the top of a spec
-- file, for the whole file.

local W = { Found = {}, FileOff = nil, TestOff = nil, Running = false, Longest = nil }

-- Instructions in one frame. About 0.2 s of the game's Lua: fengari runs
-- about 4.5 million lines a second, 20-27 times slower than the game, and
-- about LINE_INSTRUCTIONS instructions a line, so 0.2 s in the game is about
-- 20 million lines here (docs/notes/issue-327-test-infra.md, the
-- watchdog's section). The frames the panel asks for (SDP_Task.MAX_QUOTA units, about
-- 1/30 s) stay far below it. A test that fixes a larger quota
-- (SDP_Panel.RunTask(5000)) gets a limit as many times larger.
W.LIMIT_LINES = 20000000
W.LINE_INSTRUCTIONS = 3
W.LIMIT = W.LIMIT_LINES * W.LINE_INSTRUCTIONS

function W.OptOut(reason)
  assert(type(reason) == "string" and reason ~= "", "SDP_Watchdog.OptOut needs a reason")
  if W.Running then W.TestOff = reason else W.FileOff = reason end
end

local function Off()
  return W.FileOff or W.TestOff
end

-- Wrap SDP_Task.Step; tools/offline_tests.mjs calls this when a script
-- includes SDP_Task, and every test's start does too.
function W.Install()
  if SDP_Task == nil or SDP_Task.Step == nil or SDP_Task.SDP_Watched then return end
  local step = SDP_Task.Step
  SDP_Task.SDP_Watched = true
  SDP_Task.Step = function(quota)
    local job = SDP_Task.Current()
    if job == nil then return step(quota) end
    local frame = (job.Frames or 0) + 1
    local name = tostring(job.Name or "(unnamed task)") .. (job.Page and " (" .. tostring(job.Page) .. ")" or "")
    -- A test that fixes a quota above the panel's largest asks for a frame
    -- that many game frames long; its limit grows as much.
    local limit = W.LIMIT * math.max(1, (quota or 0) / (SDP_Task.MAX_QUOTA or 2000))
    local start = sdp_work()
    if not Off() then sdp_frame_limit(start + limit, "frame watchdog: task " .. name .. ", frame " .. frame) end
    local ok, status = pcall(step, quota)
    local stopped = sdp_frame_limit(nil)
    local used = sdp_work() - start
    if W.Longest == nil or used > W.Longest.Work then
      W.Longest = { Work = used, Task = name, Frame = frame }
    end
    if used > limit and not Off() and #W.Found < 20 then
      W.Found[#W.Found + 1] = string.format("task %s, frame %d: %.0f instructions (limit %.0f)%s",
        name, frame, used, limit, stopped and ("; stopped in\n    " .. stopped:gsub("\n", "\n    ")) or "")
    end
    if not ok then error(status, 0) end
    return status
  end
end

-- The runner calls these around every test.
function W.BeginTest()
  W.Found, W.TestOff, W.Running, W.Longest = {}, nil, true, nil
  W.Install()
end
function W.EndTest()
  W.Running = false
  local found = W.Found
  W.Found = {}
  if #found == 0 then return nil end
  return "frame watchdog (tests/offline/watchdog.lua):\n  " .. table.concat(found, "\n  ")
end

return W
