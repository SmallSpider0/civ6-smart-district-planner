-- @state GameCore_Tuner
-- Like unlock_all.lua, for every city of the local player: every technology
-- and civic, the unowned plots within 3 rings of each city, and population
-- 25 so the ruleset's district slots never limit the engine's placement
-- targets (AGENTS pitfall 18). Changes the game for good: use it on a
-- throwaway game or save (tests/bench/audit_engine.lua).
local pid = Game.GetLocalPlayer()
local player = Players[pid]
local granted = { techs = 0, civics = 0, plots = 0, cities = 0, pop = 0 }
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
for _, city in player:GetCities():Members() do
  granted.cities = granted.cities + 1
  for dx = -3, 3 do
    for dy = -3, 3 do
      local plot = Map.GetPlotXYWithRangeCheck(city:GetX(), city:GetY(), dx, dy, 3)
      if plot ~= nil and plot:GetOwner() == -1 then
        WorldBuilder.CityManager():SetPlotOwner(plot:GetX(), plot:GetY(), pid, city:GetID())
        granted.plots = granted.plots + 1
      end
    end
  end
  local pop = city:GetPopulation()
  if pop < 25 then
    city:ChangePopulation(25 - pop)
    granted.pop = granted.pop + 1
  end
end
print("granted", granted.techs, "technologies,", granted.civics, "civics,", granted.plots, "plots,",
  granted.pop, "cities raised to population 25 of", granted.cities)
