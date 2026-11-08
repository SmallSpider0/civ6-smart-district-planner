-- @state SDP_Panel
-- @setup GameCore_Tuner tests/fixtures/pillage_setup.lua
-- @teardown GameCore_Tuner tests/fixtures/pillage_teardown.lua
-- A pillaged improvement in the land part (issue 345): the game gives its
-- plot no improvement yields until a builder repairs it, so a district on a
-- pillaged farm cost less than one on bare plains next to it. The plot is
-- worth it repaired, as much as the bare plot with the farm it would get.
local test, T = ...

local pid = Game.GetLocalPlayer()

test("a pillaged farm is worth as much as the bare plot of its terrain", function()
  local index, bareIndex = Game:GetProperty("SDP_TEST_PILLAGED"), Game:GetProperty("SDP_TEST_PILLAGED_BARE")
  T.ok(index ~= nil and bareIndex ~= nil, "setup put down a pillaged farm")
  local plot, bare = Map.GetPlotByIndex(index), Map.GetPlotByIndex(bareIndex)
  T.ok(plot:IsImprovementPillaged(), "the farm is pillaged")
  local food = GameInfo.Yields["YIELD_FOOD"].Index
  T.eq(plot:GetYield(food), bare:GetYield(food), "the game: a pillaged farm gives no food of its own")
  local ctx = SDP_Land.Context(pid, {}, true)
  local repaired = SDP_Land.PlotValues(plot, ctx)
  local assumed = SDP_Land.PlotValues(bare, ctx)
  local imp = SDP_Land.AssumedImprovement(bare, ctx)
  T.eq(imp and imp.Entry.Type, "IMPROVEMENT_FARM", "the bare plot is valued with a farm")
  T.near(repaired, assumed, 1e-9, "the pillaged farm counts repaired")
end)
