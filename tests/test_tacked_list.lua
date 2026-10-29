-- @state SDP_Panel
-- @timeout 400
-- @setup GameCore_Tuner tests/fixtures/build_campus.lua
-- @teardown GameCore_Tuner tests/fixtures/destroy_campus.lua
-- Districts a city already has are not offered again (issue 165): a built
-- district (the campus the setup builds) and a district type the player
-- has tacked for the city but not built are greyed out in the city's list,
-- on the single-city tab and in the city's own list on the Several cities
-- tab, and are neither candidates nor required. The tack is removed at the
-- end. Needs a capital (game.py newgame --capital).
local test, T = ...

local pid = Game.GetLocalPlayer()

local function Capital()
  local city = Players[pid]:GetCities():GetCapitalCity()
  if city == nil then T.skip("no capital: run tests/fixtures/found_capital.lua") end
  return city
end

-- A district type that takes population, one per city, without an empire
-- limit, that the capital has neither built nor tacked; first by type.
local function FreeType(city)
  local status = SDP_City.BuiltHereStatus(pid, city:GetID(), SDP_Rules.PlannableDistricts(pid))
  local tacked = SDP_City.TackedStatus(pid, city:GetID(), SDP_Rules.PlannableDistricts(pid))
  local types = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do
    if d.Specialty and d.OnePerCity and not (d.MaxPerPlayer and d.MaxPerPlayer > 0)
        and status[d.Type] == nil and tacked[d.Type] == nil then
      types[#types + 1] = d.Type
    end
  end
  table.sort(types)
  if #types == 0 then T.skip("no free district type") end
  return types[1]
end

-- A land plot the capital owns with no district and no pin; nearest first.
local function FreePlot(city)
  local cfg = PlayerConfigurations[pid]
  local pinned = {}
  for _, pin in ipairs(cfg:GetMapPins()) do pinned[Map.GetPlotIndex(pin:GetHexX(), pin:GetHexY())] = true end
  local best = nil
  for dx = -3, 3 do
    for dy = -3, 3 do
      local plot = Map.GetPlotXYWithRangeCheck(city:GetX(), city:GetY(), dx, dy, 3)
      if plot ~= nil and not plot:IsWater() and plot:GetDistrictType() == -1 and not pinned[plot:GetIndex()]
          and plot:GetOwner() == pid then
        local owner = Cities.GetPlotPurchaseCity(plot)
        local ring = Map.GetPlotDistance(city:GetX(), city:GetY(), plot:GetX(), plot:GetY())
        if owner ~= nil and owner:GetID() == city:GetID() and ring > 0
            and (best == nil or ring < best.Ring or (ring == best.Ring and plot:GetIndex() < best.Plot:GetIndex())) then
          best = { Ring = ring, Plot = plot }
        end
      end
    end
  end
  if best == nil then T.skip("no free plot the capital owns") end
  return best.Plot
end

-- The player's own tack (unnamed, as one placed by hand) of `districtType`.
local function Tack(plot, districtType)
  local cfg = PlayerConfigurations[pid]
  local pin = cfg:GetMapPin(plot:GetX(), plot:GetY())
  pin:SetName("")
  pin:SetIconName("ICON_" .. districtType)
  local id = pin:GetID()
  Network.BroadcastPlayerInfo()
  LuaEvents.DMT_MapPinAdded(cfg:GetMapPinID(id))
  return id
end

local function Untack(id)
  local cfg = PlayerConfigurations[pid]
  if cfg:GetMapPinID(id) == nil then return end
  LuaEvents.DMT_MapPinRemoved(cfg:GetMapPinID(id))
  cfg:DeleteMapPin(id)
  Network.BroadcastPlayerInfo()
end

local function Has(list, x)
  for _, v in ipairs(list or {}) do
    if v == x then return true end
  end
  return false
end

local function SingleRow(districtType)
  for _, r in ipairs(SDP_Panel.State().DistrictRows) do
    if r.Type == districtType then return r end
  end
end

local function MultiRow(districtType)
  for _, r in ipairs(SDP_Panel.Multi.State().View.Districts) do
    if r.Type == districtType then return r end
  end
end

test("a tacked district type and a built one are greyed out in the city's lists", function()
  local city = Capital()
  if not city:GetDistricts():HasDistrict(GameInfo.Districts["DISTRICT_CAMPUS"].Index) then
    T.skip("no campus: the setup could not build one")
  end
  local districtType = FreeType(city)
  local plot = FreePlot(city)
  local id = Tack(plot, districtType)
  local ok, err = pcall(function()
    -- Single-city tab.
    SDP_Panel.SelectTab("SINGLE")
    SDP_Panel.SelectCity(city:GetID())
    T.eq(SingleRow(districtType).Status, "TACKED", districtType .. " tacked")
    T.eq(SingleRow("DISTRICT_CAMPUS").Status, "BUILT", "campus built")
    SDP_Panel.SetState(districtType, "POOL")
    local request = SDP_Panel.Request()
    T.ok(request == nil or not Has(request.Pool, districtType), "single: not a candidate")
    SDP_Panel.SetState(districtType, "MUST")
    request = SDP_Panel.Request()
    T.ok(request == nil or not Has(request.Districts, districtType), "single: not required")
    SDP_Panel.SetState(districtType, "POOL")
    -- The capital's own list on the Several cities tab.
    SDP_Panel.SelectTab("MULTI")
    local multi = SDP_Panel.Multi
    multi.Refresh()
    local key = "C" .. city:GetID()
    local taking = false
    for _, part in ipairs(multi.Participants()) do
      if part.Key == key then taking = true end
    end
    if not taking then T.skip("the capital does not take part") end
    multi.SetPlanFor(key)
    multi.ApplyPlan({ districtType })
    T.eq(MultiRow(districtType).Why, "TACKED", "multi: " .. districtType .. " tacked")
    T.eq(MultiRow("DISTRICT_CAMPUS").Why, "BUILT", "multi: campus built")
    request = multi.Request()
    T.ok(request == nil or not Has(request.Plans and request.Plans[key], districtType), "multi: not required")
    T.ok(request == nil or not Has(request.Pools and request.Pools[key], districtType), "multi: not a candidate")
    multi.ApplyPlan(nil)
    multi.SetPlanFor("ALL")
  end)
  Untack(id)
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(city:GetID())
  if not ok then error(err, 0) end
  T.eq(SingleRow(districtType).Status, nil, "untacked: " .. districtType .. " can be planned again")
end)
