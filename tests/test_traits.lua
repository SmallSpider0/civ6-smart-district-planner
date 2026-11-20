-- @state SDP_Panel
-- Plot yields of the player's traits (issue 361). The game gives them only
-- on the player's own plots, so the land part adds them to the plots it does
-- not own yet. Each bare land plot near the capital (no resource,
-- improvement, district or city) is checked against the rules: its
-- terrain's and feature's yields (Terrain_YieldChanges,
-- Feature_YieldChanges) plus the trait yields SDP_Land.TraitYields says it
-- has, of which plot:GetYield holds all on an owned plot and none on an
-- unowned one. Judged by the player's own modifiers, so any civilization
-- passes; Rome has none, so run it also in a game of a civilization with one
-- (game.py newgame --leader LEADER_PETER_GREAT: Russia's tundra) to see it
-- count something. (Giving the player a plot through WorldBuilder does not
-- add the trait yields until the next turn, so the test reads the map as
-- it is.)
local test, T = ...

local pid = Game.GetLocalPlayer()

test("the game's yields are the rules' plus the trait yields of owned plots only", function()
  local city = Players[pid]:GetCities():GetCapitalCity()
  if city == nil then T.skip("no capital") end
  local ctx = SDP_Land.Context(pid, {}, true)
  local base = {}
  local function Add(key, yieldType, n)
    base[key] = base[key] or {}
    base[key][yieldType] = (base[key][yieldType] or 0) + n
  end
  for row in GameInfo.Terrain_YieldChanges() do Add(row.TerrainType, row.YieldType, row.YieldChange) end
  for row in GameInfo.Feature_YieldChanges() do Add(row.FeatureType, row.YieldType, row.YieldChange) end
  local checked, owned, unowned = 0, 0, 0
  for dx = -4, 4 do
    for dy = -4, 4 do
      local plot = Map.GetPlotXYWithRangeCheck(city:GetX(), city:GetY(), dx, dy, 4)
      if plot ~= nil and not plot:IsWater() and not plot:IsCity() and not plot:IsNaturalWonder()
          and plot:GetResourceType() == -1 and plot:GetImprovementType() == -1 and plot:GetDistrictType() == -1
          and (plot:GetOwner() == -1 or plot:GetOwner() == pid) then
        local terrain = GameInfo.Terrains[plot:GetTerrainType()].TerrainType
        local feature = plot:GetFeatureType() ~= -1 and GameInfo.Features[plot:GetFeatureType()].FeatureType or nil
        local traits, unheld = SDP_Land.TraitYields(plot, ctx)
        local any = false
        for row in GameInfo.Yields() do
          local y = row.YieldType
          local add = traits[y] or 0
          if add ~= 0 then any = true end
          local expected = ((base[terrain] or {})[y] or 0) + (feature and (base[feature] or {})[y] or 0)
          if plot:GetOwner() == pid then expected = expected + add end
          T.eq(plot:GetYield(row.Index), expected, string.format("(%d,%d) %s %s owner %d %s: trait %s",
            plot:GetX(), plot:GetY(), terrain, tostring(feature), plot:GetOwner(), y, add))
          T.eq((unheld[y] or 0), plot:GetOwner() == pid and 0 or add, "what the game's yields do not hold yet")
        end
        checked = checked + 1
        if any and plot:GetOwner() == pid then owned = owned + 1 end
        if any and plot:GetOwner() ~= pid then unowned = unowned + 1 end
      end
    end
  end
  T.ok(checked > 0, "some bare plots")
  print(string.format("SDP_TRAITS %d bare plots, trait yields on %d owned and %d unowned, %d plot-yield modifiers",
    checked, owned, unowned, #ctx.Traits.Yields))
end)
