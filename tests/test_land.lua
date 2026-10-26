-- @state SDP_Panel
-- The land part and housing read from the game's own rules (issues 52, 55):
-- the rule columns come in the game's types (Improvements.RequiresRiver is a
-- number there, which once dropped every improvement), and the values
-- follow from the plots of the test game.
local test, T = ...

local pid = Game.GetLocalPlayer()

test("improvement rules are read from the game", function()
  local ctx = SDP_Land.Context(pid, {}, true)
  local names = {}
  for _, entry in ipairs(ctx.Rules.Improvements) do names[entry.Type] = true end
  T.ok(names.IMPROVEMENT_FARM and names.IMPROVEMENT_MINE and names.IMPROVEMENT_PASTURE, "farm, mine and pasture among the rules")
  T.ok(not names.IMPROVEMENT_FORT, "an improvement without yields is left out")
  local mine = nil
  for _, entry in ipairs(SDP_Land.ValidImprovements(ctx, false, "TERRAIN_GRASS_HILLS", nil, nil)) do
    if entry.Type == "IMPROVEMENT_MINE" then mine = entry end
  end
  T.ok(mine ~= nil, "a mine on grassland hills")
  T.ok(ctx.Gain[mine] >= 1, "worth at least its production")
end)

test("a plot is worth at least its yields after removing what it can", function()
  local ctx = SDP_Land.Context(pid, {}, true)
  local city = Players[pid]:GetCities():GetCapitalCity()
  local checked = 0
  for dx = -3, 3 do
    for dy = -3, 3 do
      local plot = Map.GetPlotXYWithRangeCheck(city:GetX(), city:GetY(), dx, dy, 3)
      if plot ~= nil and not plot:IsCity() and plot:GetImprovementType() == -1 and plot:GetFeatureType() == -1
          and plot:GetResourceType() == -1 and not plot:IsWater() and not plot:IsMountain() then
        local now = 0
        for _, yieldType in ipairs(SDP_Land.TILE_YIELDS) do now = now + plot:GetYield(GameInfo.Yields[yieldType].Index) end
        local value, once = SDP_Land.PlotValues(plot, ctx)
        T.ok(value >= now, string.format("(%d,%d) %s: %s >= %s", plot:GetX(), plot:GetY(), tostring(plot:GetTerrainType()), value, now))
        T.eq(once, 0, "nothing to remove")
        checked = checked + 1
      end
    end
  end
  T.ok(checked > 0, "some bare plots")
end)

test("housing from the rules: granary for a new city, harbor buildings", function()
  T.eq(SDP_Land.CenterHousing(), 2, "the granary")
  local coastal = SDP_Land.BuildingHousing("DISTRICT_HARBOR", true)
  local inland = SDP_Land.BuildingHousing("DISTRICT_HARBOR", false)
  T.ok(inland >= 2, "lighthouse and seaport")
  T.ok(coastal >= inland, "coastal at least as much")
  if SDP_Rules.Ruleset() == "RULESET_EXPANSION_2" then T.eq(coastal - inland, 2, "Gathering Storm: the lighthouse's +2") end
  T.eq(SDP_Land.HousingValue(9, 7), 8.5, "two past the target: the first past it counts 1 (issue 91)")
end)
