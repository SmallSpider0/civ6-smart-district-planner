-- Found the local player's capital with the first settler when the player has
-- no city yet (a fresh auto-started game). The city appears a moment later.
--   python3 -I tools/civ6tuner.py exec -f tests/fixtures/found_capital.lua
local player = Players[Game.GetLocalPlayer()]
local capital = player:GetCities():GetCapitalCity()
if capital ~= nil then
  print("capital exists", capital:GetName(), capital:GetX(), capital:GetY())
  return
end
for _, unit in player:GetUnits():Members() do
  if GameInfo.Units[unit:GetType()].FoundCity then
    if UnitManager.CanStartOperation(unit, UnitOperationTypes.FOUND_CITY, nil, true) then
      UnitManager.RequestOperation(unit, UnitOperationTypes.FOUND_CITY)
      print("founding city at", unit:GetX(), unit:GetY())
    else
      print("settler cannot found a city at", unit:GetX(), unit:GetY())
    end
    return
  end
end
print("no settler")
