-- @state GameCore_Tuner
-- Unlock every district for the local player and let the capital own its
-- three rings, so the engine lists where each district can go
-- (CityManager.GetOperationTargets returns nothing for a locked district and
-- only offers plots the city owns). Gives every technology and civic and
-- takes the unowned plots within 3 rings for the capital: changes the game for
-- good, use it on a throwaway game (tests/bench/probe_engine.lua).
local pid = Game.GetLocalPlayer()
local player = Players[pid]
local granted = { techs = 0, civics = 0, plots = 0 }
local techs = player:GetTechs()
for row in GameInfo.Technologies() do
  if not techs:HasTech(row.Index) then
    techs:SetTech(row.Index, true)
    granted.techs = granted.techs + 1
  end
end
local culture = player:GetCulture()
for row in GameInfo.Civics() do
  if not culture:HasCivic(row.Index) then
    culture:SetCivic(row.Index, true)
    granted.civics = granted.civics + 1
  end
end
local city = player:GetCities():GetCapitalCity()
if city ~= nil then
  for dx = -3, 3 do
    for dy = -3, 3 do
      local plot = Map.GetPlotXYWithRangeCheck(city:GetX(), city:GetY(), dx, dy, 3)
      if plot ~= nil and plot:GetOwner() == -1 then
        WorldBuilder.CityManager():SetPlotOwner(plot:GetX(), plot:GetY(), pid, city:GetID())
        granted.plots = granted.plots + 1
      end
    end
  end
end
print("granted", granted.techs, "technologies,", granted.civics, "civics,", granted.plots, "plots")
