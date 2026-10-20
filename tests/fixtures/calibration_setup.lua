-- @state GameCore_Tuner
-- For tests/bench/calibrate_judge.lua (docs/multicity-design.md 18.1, item 6):
-- unlock every technology and civic, let the capital own its three rings
-- (as tests/fixtures/unlock_all.lua), then build a cluster of districts next
-- to each other in ring 2, so district-to-district adjacency is exercised.
-- Changes the game for good: use a throwaway game.
local pid = Game.GetLocalPlayer()
local player = Players[pid]
local techs, culture = player:GetTechs(), player:GetCulture()
for row in GameInfo.Technologies() do
  if not techs:HasTech(row.Index) then techs:SetTech(row.Index, true) end
end
for row in GameInfo.Civics() do
  if not culture:HasCivic(row.Index) then culture:SetCivic(row.Index, true) end
end
local city = player:GetCities():GetCapitalCity()
if city == nil then error("no capital: run found_capital.lua first") end
-- Population 25 allows 9 specialty districts (1 + floor((25 - 1) / 3)): with
-- 1 the cluster below uses up the limit and the engine stops offering plots
-- for every other specialty district, which would leave test A almost empty.
if city:GetPopulation() < 25 then city:ChangePopulation(25 - city:GetPopulation()) end
local cx, cy = city:GetX(), city:GetY()
local plots = {}
for dx = -3, 3 do
  for dy = -3, 3 do
    local plot = Map.GetPlotXYWithRangeCheck(cx, cy, dx, dy, 3)
    if plot ~= nil then
      if plot:GetOwner() == -1 then WorldBuilder.CityManager():SetPlotOwner(plot:GetX(), plot:GetY(), pid, city:GetID()) end
      plots[#plots + 1] = plot
    end
  end
end
table.sort(plots, function(a, b) return a:GetIndex() < b:GetIndex() end)
local function Buildable(plot)
  if plot:IsWater() or plot:IsMountain() or plot:IsImpassable() or plot:IsNaturalWonder() or plot:IsCity() then return false end
  if plot:GetDistrictType() ~= -1 or plot:GetWonderType() ~= -1 or plot:GetResourceType() ~= -1 then return false end
  local feature = plot:GetFeatureType()
  return feature == -1 or GameInfo.Features[feature].Removable
end
-- Anchor: the first buildable ring-2 plot with the most buildable neighbours.
local anchor, best = nil, -1
for _, plot in ipairs(plots) do
  if Map.GetPlotDistance(cx, cy, plot:GetX(), plot:GetY()) == 2 and Buildable(plot) then
    local n = 0
    for _, other in ipairs(plots) do
      if Map.GetPlotDistance(plot:GetX(), plot:GetY(), other:GetX(), other:GetY()) == 1 and Buildable(other) then n = n + 1 end
    end
    if n > best then anchor, best = plot, n end
  end
end
if anchor == nil then error("no buildable ring-2 plot") end
local spots = { anchor }
for _, other in ipairs(plots) do
  if #spots < 5 and Map.GetPlotDistance(anchor:GetX(), anchor:GetY(), other:GetX(), other:GetY()) == 1 and Buildable(other)
      and Map.GetPlotDistance(cx, cy, other:GetX(), other:GetY()) >= 1 then
    spots[#spots + 1] = other
  end
end
local wanted = { "DISTRICT_CAMPUS", "DISTRICT_THEATER", "DISTRICT_COMMERCIAL_HUB", "DISTRICT_HOLY_SITE", "DISTRICT_INDUSTRIAL_ZONE" }
local built = 0
for i, plot in ipairs(spots) do
  local row = GameInfo.Districts[wanted[i]]
  if row ~= nil and not city:GetDistricts():HasDistrict(row.Index) then
    city:GetBuildQueue():CreateDistrict(row.Index, plot:GetIndex())
    built = built + 1
    print("built", wanted[i], plot:GetX(), plot:GetY())
  end
end
print("calibration setup: cluster of", built, "districts around", anchor:GetX(), anchor:GetY())
