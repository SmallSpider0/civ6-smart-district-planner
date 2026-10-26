-- @state InGame
-- Step 2 (see limited_prepare.lua): order the district in the capital on the
-- first tile, nearest ring first and then by tile index, where the game lets
-- the city start it (CityManager.CanStartOperation).
local pid = Game.GetLocalPlayer()
local city = Players[pid]:GetCities():GetCapitalCity()
if city == nil then error("no capital: run found_capital.lua first") end
local types = {}
for row in GameInfo.Districts() do
  if row.MaxPerPlayer ~= nil and row.MaxPerPlayer > 0 and row.TraitType == nil then types[#types + 1] = row.DistrictType end
end
table.sort(types)
if #types == 0 then
  print("no empire-limited district in this ruleset")
  return
end
local row = GameInfo.Districts[types[1]]
for _, district in Players[pid]:GetDistricts():Members() do
  if district:GetType() == row.Index then
    print(row.DistrictType .. " already built")
    return
  end
end
local plots = {}
for dx = -3, 3 do
  for dy = -3, 3 do
    local plot = Map.GetPlotXYWithRangeCheck(city:GetX(), city:GetY(), dx, dy, 3)
    if plot ~= nil then
      local ring = Map.GetPlotDistance(city:GetX(), city:GetY(), plot:GetX(), plot:GetY())
      if ring > 0 then plots[#plots + 1] = { Ring = ring, Plot = plot } end
    end
  end
end
table.sort(plots, function(a, b)
  if a.Ring ~= b.Ring then return a.Ring < b.Ring end
  return a.Plot:GetIndex() < b.Plot:GetIndex()
end)
local function Params(plot)
  local t = {}
  t[CityOperationTypes.PARAM_X] = plot:GetX()
  t[CityOperationTypes.PARAM_Y] = plot:GetY()
  t[CityOperationTypes.PARAM_DISTRICT_TYPE] = row.Hash
  t[CityOperationTypes.PARAM_INSERT_MODE] = CityOperationTypes.VALUE_EXCLUSIVE
  return t
end
local reasons, seen = {}, {}
for _, entry in ipairs(plots) do
  local t = Params(entry.Plot)
  local can, results = CityManager.CanStartOperation(city, CityOperationTypes.BUILD, t, true)
  if can then
    CityManager.RequestOperation(city, CityOperationTypes.BUILD, t)
    print("ordered " .. row.DistrictType .. " at " .. entry.Plot:GetX() .. "," .. entry.Plot:GetY())
    return
  end
  -- Why not (the production panel's own failure reasons), once each.
  local key = CityOperationResults ~= nil and CityOperationResults.FAILURE_REASONS or nil
  local failures = (results ~= nil and key ~= nil and results[key]) or {}
  for _, reason in ipairs(failures) do
    local text = Locale.Lookup(reason)
    if not seen[text] then
      seen[text] = true
      reasons[#reasons + 1] = text
    end
  end
end
-- 2026-10-27, Gathering Storm on the fixed test map: no tile passed this
-- check two seconds after limited_prepare.lua, while Rise and Fall's did.
-- Print what the interface thinks, then order on the first owned land tile
-- the district can stand on anyway: the game core checks the order against
-- its own state, and limited_finish.lua reports whether the district stands.
local culture = Players[pid]:GetCulture()
print("no tile passed CanStartOperation; civic seen here: "
  .. tostring(row.PrereqCivic == nil or culture:HasCivic(GameInfo.Civics[row.PrereqCivic].Index))
  .. "; population " .. city:GetPopulation() .. "; reasons: " .. table.concat(reasons, " | "))
for _, entry in ipairs(plots) do
  local plot = entry.Plot
  if entry.Ring == 1 and plot:GetOwner() == pid and not plot:IsWater() and not plot:IsImpassable()
      and not plot:IsNaturalWonder() and plot:GetDistrictType() == -1 and plot:GetWonderType() == -1
      and plot:GetResourceType() == -1 then
    CityManager.RequestOperation(city, CityOperationTypes.BUILD, Params(plot))
    print("ordered " .. row.DistrictType .. " at " .. plot:GetX() .. "," .. plot:GetY() .. " without the interface's check")
    return
  end
end
error("the capital cannot start " .. row.DistrictType .. " on any tile within three rings: " .. table.concat(reasons, " | "))
