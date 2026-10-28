-- @state SDP_Panel
-- @timeout 400
-- @setup GameCore_Tuner tests/fixtures/build_campus.lua
-- @teardown GameCore_Tuner tests/fixtures/destroy_campus.lua
-- The district count is a target (issue 144): how many districts that take
-- population the city ends with, counting built ones (the campus the setup
-- builds) and the city's own district tacks; the panel plans the rest. The
-- default follows the city: three, or one more than it has. On the Several
-- cities tab each city fills up to the count. Needs a capital
-- (game.py newgame --capital).
local test, T = ...

local pid = Game.GetLocalPlayer()

local function Capital()
  local city = Players[pid]:GetCities():GetCapitalCity()
  if city == nil then T.skip("no capital: run tests/fixtures/found_capital.lua") end
  local plannable = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do plannable[d.Type] = true end
  if not plannable.DISTRICT_CAMPUS then T.skip("this civ has a unique campus") end
  return city
end

local function Specialty(plan, key)
  local n = 0
  for _, p in ipairs(plan) do
    if (key == nil or p.City == key) and GameInfo.Districts[p.Type].RequiresPopulation then n = n + 1 end
  end
  return n
end

local function Shown() return tonumber(Controls.CountValue:GetText()) end

-- Every district that takes population a candidate, the rest off.
local function PoolOnly()
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do SDP_Panel.SetState(d.Type, d.Specialty and "POOL" or "OFF") end
end

test("single-city tab: what the city has counts, the default follows it", function()
  local city = Capital()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(city:GetID())
  PoolOnly()
  -- Earlier test files set the capital's count; a set count stays with its
  -- city for the game session, so start from the default.
  SDP_Panel.ForgetCounts()
  local have = SDP_City.HaveCount(SDP_City.HaveOf(pid, city:GetID()))
  T.ok(have >= 1, "the built campus counts: " .. have)
  T.eq(SDP_Panel.State().Have, have, "the panel reads the same")
  T.eq(SDP_Panel.State().Target, SDP_UI.DefaultTarget(have), "default target")
  T.eq(Shown(), SDP_UI.DefaultTarget(have), "shown")
  T.eq(SDP_Panel.State().Count, SDP_UI.DefaultTarget(have) - have, "the rest to plan")
  SDP_Panel.SetCount(0)
  T.eq(Shown(), have, "not below what the city has")
  T.eq(SDP_Panel.State().Count, 0, "nothing to plan")
end)

test("single-city tab: one more than the city has plans one", function()
  local city = Capital()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(city:GetID())
  PoolOnly()
  local have = SDP_Panel.State().Have
  SDP_Panel.SetCount(have + 1)
  SDP_Panel.SetTier("FAST")
  T.eq(SDP_Panel.State().Count, 1, "one to plan")
  T.eq(SDP_Panel.Solve(), nil, "a task")
  local result = SDP_Panel.RunTask(1000)
  T.ok(result and result.Ok, tostring(result and result.Error))
  for n, sol in ipairs(result.Solutions) do
    T.eq(Specialty(sol.Plan), 1, "one district that takes population in solution " .. n)
  end
  -- Its tack counts once placed; undone, it does not.
  local placed = SDP_Panel.PlacePins()
  T.ok(placed >= 1, "placed")
  T.eq(SDP_Panel.State().Have, have + 1, "the tack counts")
  SDP_Panel.UndoPins()
  T.eq(SDP_Panel.State().Have, have, "undone")
  SDP_Panel.SetTier("STANDARD")
end)

test("several cities tab: the capital fills up to the count", function()
  local city = Capital()
  local have = SDP_City.HaveCount(SDP_City.HaveOf(pid, city:GetID()))
  SDP_Panel.SelectTab("MULTI")
  local multi = SDP_Panel.Multi
  multi.Refresh()
  multi.SetPlanFor("ALL")
  multi.SetTier("FAST")
  local key = "C" .. city:GetID()
  local taking = false
  for _, part in ipairs(multi.Participants()) do
    if part.Key == key then taking = true end
  end
  if not taking then T.skip("the capital does not take part") end
  local request = multi.Request()
  T.ok(request ~= nil and request.Target == true, "the count is sent as a target")
  T.ok(multi.Solve(), "started")
  local result = SDP_Panel.RunTask(5000) or multi.State().Result
  T.ok(result and result.Ok, tostring(result and result.Error))
  T.ok(Specialty(result.Plan, key) <= math.max(0, request.Count - have),
    "the capital plans at most the count minus what it has")
  SDP_Panel.SelectTab("SINGLE")
end)
