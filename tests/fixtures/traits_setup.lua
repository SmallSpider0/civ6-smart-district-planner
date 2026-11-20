-- @state GameCore_Tuner
-- For tests/test_traits.lua (issue 361): the yields the game shows on every
-- land plot within three rings of the capital that nobody owns, then the
-- capital is given those plots (traits_teardown.lua takes them back). The
-- plots and their yields before go into a game property:
-- "index:y1,y2,...;..." with the yields in GameInfo.Yields order.
local pid = Game.GetLocalPlayer()
local city = Players[pid]:GetCities():GetCapitalCity()
if city == nil then error("no capital: run found_capital.lua first") end
local parts, plots = {}, {}
for dx = -3, 3 do
  for dy = -3, 3 do
    local p = Map.GetPlotXYWithRangeCheck(city:GetX(), city:GetY(), dx, dy, 3)
    if p ~= nil and p:GetOwner() == -1 and not p:IsWater() and not p:IsNaturalWonder() then
      local yields = {}
      for row in GameInfo.Yields() do yields[#yields + 1] = tostring(p:GetYield(row.Index)) end
      parts[#parts + 1] = p:GetIndex() .. ":" .. table.concat(yields, ",")
      plots[#plots + 1] = p
    end
  end
end
for _, p in ipairs(plots) do WorldBuilder.CityManager():SetPlotOwner(p:GetX(), p:GetY(), pid, city:GetID()) end
Game:SetProperty("SDP_TEST_TRAIT_PLOTS", table.concat(parts, ";"))
print("SDP_TRAIT_PLOTS", #plots)
