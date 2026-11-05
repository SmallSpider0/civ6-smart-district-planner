-- @state GameCore_Tuner
-- Another major civ completes a world wonder (issue 294): the first alive
-- major after the local player gets a city where the local player has not
-- looked, when it has none yet, and a finished wonder next to it. The wonder
-- is the first one by type that the world allows once and nobody has built.
-- Undo with wonder_elsewhere_teardown.lua, which removes this wonder only
-- (the city stays: use a new game).
local me = Game.GetLocalPlayer()
local other = nil
for id = 0, 63 do
  local p = Players[id]
  if other == nil and id ~= me and p ~= nil and p:IsAlive() and p:IsMajor() then other = p end
end
if other == nil then error("no other major civ") end
local visibility = PlayersVisibility[me]
local function Land(plot)
  return plot ~= nil and not plot:IsWater() and not plot:IsImpassable() and not plot:IsMountain()
    and not plot:IsNaturalWonder() and plot:GetResourceType() == -1 and plot:GetDistrictType() == -1
    and plot:GetWonderType() == -1 and not plot:IsCity()
end
local city = nil
for _, c in other:GetCities():Members() do
  if city == nil then city = c end
end
if city == nil then
  -- Unrevealed land at least 8 tiles from every city, by plot index.
  for index = 0, Map.GetPlotCount() - 1 do
    local plot = Map.GetPlotByIndex(index)
    if city == nil and Land(plot) and plot:GetOwner() == -1 and not visibility:IsRevealed(index) then
      local far = true
      for id = 0, 63 do
        local p = Players[id]
        if p ~= nil and p:IsAlive() then
          for _, c in p:GetCities():Members() do
            if Map.GetPlotDistance(c:GetX(), c:GetY(), plot:GetX(), plot:GetY()) < 8 then far = false end
          end
        end
      end
      if far then city = other:GetCities():Create(plot:GetX(), plot:GetY()) end
    end
  end
end
if city == nil then error("could not found a city for player " .. other:GetID()) end
local built = {}
for index = 0, Map.GetPlotCount() - 1 do
  local plot = Map.GetPlotByIndex(index)
  if plot:GetWonderType() ~= -1 then built[plot:GetWonderType()] = true end
end
local types = {}
for row in GameInfo.Buildings() do
  if row.IsWonder and row.MaxWorldInstances == 1 and not built[row.Index] then types[#types + 1] = row.BuildingType end
end
table.sort(types)
if #types == 0 then error("no world wonder left") end
local row = GameInfo.Buildings[types[1]]
local spot = nil
for ring = 1, 2 do
  for dx = -ring, ring do
    for dy = -ring, ring do
      local plot = Map.GetPlotXYWithRangeCheck(city:GetX(), city:GetY(), dx, dy, ring)
      if spot == nil and plot ~= nil and Map.GetPlotDistance(city:GetX(), city:GetY(), plot:GetX(), plot:GetY()) == ring
          and Land(plot) then
        spot = plot
      end
    end
  end
end
if spot == nil then error("no free land next to the other civ's city") end
if spot:GetOwner() == -1 then
  WorldBuilder.CityManager():SetPlotOwner(spot:GetX(), spot:GetY(), other:GetID(), city:GetID())
end
city:GetBuildQueue():CreateIncompleteBuilding(row.Index, spot:GetIndex(), 100)
-- The teardown removes only this wonder (by this property), never others.
Game:SetProperty("SDP_TEST_WONDER_ELSEWHERE", spot:GetIndex())
print("player " .. other:GetID() .. " built " .. row.BuildingType .. " at " .. spot:GetX() .. "," .. spot:GetY()
  .. ": complete " .. tostring(spot:IsWonderComplete()) .. ", in the city " .. tostring(city:GetBuildings():HasBuilding(row.Index))
  .. ", revealed to the local player " .. tostring(visibility:IsRevealed(spot:GetIndex())))
