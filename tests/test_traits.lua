-- @state SDP_Panel
-- @setup GameCore_Tuner tests/fixtures/traits_setup.lua
-- @teardown GameCore_Tuner tests/fixtures/traits_teardown.lua
-- Plot yields of the player's traits (issue 361): the game gives them only
-- on the player's own plots, so the land part adds them to the plots it
-- does not own yet. The setup recorded the yields of the unowned plots
-- around the capital and then gave them to it: what the game adds to each
-- once owned is what SDP_Land.TraitYields says the traits give it, no more
-- and no less. Judged by the player's own modifiers, so any civilization
-- passes; with no such trait (Rome) every plot's yields stay the same. Run
-- it in a game of a civilization with one (game.py newgame --leader
-- LEADER_PETER_GREAT, Russia's tundra) to see it count something.
local test, T = ...

local pid = Game.GetLocalPlayer()

test("what owning a plot adds is the trait yields the land part counts", function()
  local data = Game:GetProperty("SDP_TEST_TRAIT_PLOTS")
  T.ok(data ~= nil and data ~= "", "setup recorded unowned plots")
  local ctx = SDP_Land.Context(pid, {}, true)
  local checked, counted = 0, 0
  for index, list in data:gmatch("(%d+):([^;]*)") do
    local plot = Map.GetPlotByIndex(tonumber(index))
    T.eq(plot:GetOwner(), pid, "setup gave the plot to the capital")
    local before = {}
    for n in list:gmatch("[^,]+") do before[#before + 1] = tonumber(n) end
    local traits, unheld = SDP_Land.TraitYields(plot, ctx)
    T.eq(next(unheld), nil, "an owned plot's yields hold its trait yields")
    local k, any = 0, false
    for row in GameInfo.Yields() do
      k = k + 1
      local add = traits[row.YieldType] or 0
      if add ~= 0 then any = true end
      T.eq(plot:GetYield(row.Index), before[k] + add,
        string.format("(%d,%d) %s: before %s, trait %s", plot:GetX(), plot:GetY(), row.YieldType, before[k], add))
    end
    checked = checked + 1
    if any then counted = counted + 1 end
  end
  T.ok(checked > 0, "some plots")
  print(string.format("SDP_TRAITS checked %d plots, %d with trait yields, %d plot-yield modifiers", checked, counted,
    #ctx.Traits.Yields))
end)
