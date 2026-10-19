-- @state SDP_Panel
-- @timeout 300
-- SDP_Task in the game: coroutines exist (risk 1), a sliced solve equals the
-- solve at once whatever the slices, and the panel's fine tier runs as a task.
-- Needs a city: run tests/fixtures/found_capital.lua first on a fresh game.
local test, T = ...

local pid = Game.GetLocalPlayer()

local function City()
  local city = Players[pid]:GetCities():GetCapitalCity()
  if city == nil then T.skip("no capital: run tests/fixtures/found_capital.lua") end
  return city
end

local function Districts(count)
  local list = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do
    if #list < count then list[#list + 1] = d.Type end
  end
  return list
end

test("coroutines are available in the panel's Lua state", function()
  T.ok(SDP_Task.HasCoroutines(), "no coroutine library: SDP_Task runs each computation in one frame")
end)

test("a sliced solve equals the solve at once", function()
  local city = City()
  local request = { PlayerID = pid, CityID = city:GetID(), Districts = Districts(5), Tier = "FINE", Land = true,
    Params = { NodeLimit = 50000, TryLimit = 3000 } }
  local direct = SDP_Solver.Solve(request)
  for _, quota in ipairs({ 1, 50, 100000 }) do
    local scan = SDP_City.Scan(pid, city:GetID())
    local status, result = SDP_Task.RunAll({ PlayerID = pid, Run = function() return SDP_Solver.SolveScan(request, scan) end }, quota)
    T.eq(status, "done", "status, quota " .. quota)
    T.same(result.Plan, direct.Plan, "plan, quota " .. quota)
    T.eq(result.Gain, direct.Gain, "gain, quota " .. quota)
  end
  T.ok(not SDP_Overlay.IsInstalled(), "overlay left installed")
end)

test("the panel runs the fine tier as a task and can cancel it", function()
  local city = City()
  SDP_Panel.SelectCity(city:GetID())
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do SDP_Panel.SetSelected(d.Type, false) end
  for _, d in ipairs(Districts(4)) do SDP_Panel.SetSelected(d, true) end
  SDP_Panel.SetTier("FINE")
  T.eq(SDP_Panel.Solve(), nil, "a sliced solve returns at once")
  T.ok(SDP_Panel.State().Running, "running")
  T.ok(SDP_Panel.Cancel(), "cancel")
  T.ok(not SDP_Panel.State().Running, "cancelled")
  SDP_Panel.Solve()
  local result = SDP_Panel.RunTask(1000)
  T.ok(result ~= nil and result.Ok, "result after the task: " .. tostring(result and result.Error))
  T.eq(result.Stats.Tier, "FINE", "tier")
  SDP_Panel.SetTier("STANDARD")
end)
