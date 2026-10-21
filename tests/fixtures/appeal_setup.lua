-- @state GameCore_Tuner
-- For tests/bench/calibrate_appeal.py: unlock every technology and civic
-- (unless SDP_APPEAL_UNLOCK is false), let the capital own its three rings and grow it to 25 (room for every
-- specialty district, pitfall 18). Changes the game for good: use a
-- throwaway game.
-- SDP_APPEAL_UNLOCK = false (set before this chunk) skips the unlocking:
-- building through the build queue does not need the prerequisites.
local pid = Game.GetLocalPlayer()
local player = Players[pid]
if SDP_APPEAL_UNLOCK ~= false then
  local techs, culture = player:GetTechs(), player:GetCulture()
  for row in GameInfo.Technologies() do
    if not techs:HasTech(row.Index) then techs:SetTech(row.Index, true) end
  end
  for row in GameInfo.Civics() do
    if not culture:HasCivic(row.Index) then culture:SetCivic(row.Index, true) end
  end
end
local city = player:GetCities():GetCapitalCity()
if city == nil then error("no capital: run found_capital.lua first") end
if city:GetPopulation() < 25 then city:ChangePopulation(25 - city:GetPopulation()) end
for dx = -3, 3 do
  for dy = -3, 3 do
    local plot = Map.GetPlotXYWithRangeCheck(city:GetX(), city:GetY(), dx, dy, 3)
    if plot ~= nil and plot:GetOwner() == -1 then
      WorldBuilder.CityManager():SetPlotOwner(plot:GetX(), plot:GetY(), pid, city:GetID())
    end
  end
end
print("appeal setup done: population", city:GetPopulation())
