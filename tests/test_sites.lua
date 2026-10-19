-- @state SDP_Panel
-- @timeout 600
-- Site selection with the real map and DMT (docs/multicity-design.md 3).
-- Needs a city: run tests/fixtures/found_capital.lua first;
-- game.py newgame --capital --reveal also reveals the land around it.
local test, T = ...

local pid = Game.GetLocalPlayer()

test("game data the site score reads", function()
  T.ok(GlobalParameters.CITY_MIN_RANGE ~= nil, "CITY_MIN_RANGE")
  T.ok(GlobalParameters.CITY_POPULATION_RIVER_LAKE ~= nil, "CITY_POPULATION_RIVER_LAKE")
  local resources = Players[pid]:GetResources()
  for row in GameInfo.Resources() do
    T.ok(resources:IsResourceVisible(row.Hash) ~= nil, row.ResourceType .. " visibility")
  end
  if SDP_Rules.Ruleset() == "RULESET_EXPANSION_2" then T.ok(GameInfo.Resource_Consumption ~= nil, "GS extraction rates") end
end)

test("candidates follow the rules on the real map", function()
  if Players[pid]:GetCities():GetCapitalCity() == nil then T.skip("no capital") end
  local list, centers = SDP_Sites.Candidates(pid, { K = 2, D = 8 })
  if #list == 0 then T.skip("no candidate: explore first (game.py newgame --capital --reveal)") end
  local minRange = SDP_Sites.MinRange()
  for _, c in ipairs(list) do
    local plot = Map.GetPlotByIndex(c.Index)
    T.ok(PlayersVisibility[pid]:IsRevealed(c.Index), "unrevealed candidate")
    T.ok(not plot:IsWater() and not plot:IsMountain(), "terrain")
    for _, center in ipairs(centers) do
      T.ok(Map.GetPlotDistance(c.X, c.Y, center.X, center.Y) > minRange, "too close")
    end
  end
  print(string.format("%d candidates", #list))
end)

test("two sites: spaced, linked back, deterministic", function()
  if Players[pid]:GetCities():GetCapitalCity() == nil then T.skip("no capital") end
  local request = { PlayerID = pid, Tier = "FAST", K = 2, D = 8, Districts = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE" } }
  local a = SDP_SiteSolver.Solve(request)
  if not a.Ok and a.Error == "NO_SITE" then T.skip("no room for two sites yet") end
  T.ok(a.Ok, tostring(a.Error))
  local b = SDP_SiteSolver.Solve(request)
  T.eq(b.Solutions[1].Value, a.Solutions[1].Value, "same value")
  local s = a.Solutions[1].Sites
  if #s == 2 then T.ok(Map.GetPlotDistance(s[1].X, s[1].Y, s[2].X, s[2].Y) > SDP_Sites.MinRange(), "spacing") end
  print(string.format("best %.1f with %d candidates, %d refined, %d DMT calls", a.Solutions[1].Value, a.Stats.Candidates,
    a.Stats.Refined, a.Stats.Calls))
end)
