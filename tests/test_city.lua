-- @state SDP_Panel
-- SDP_City: plots in range, candidates, locked pins, built districts.
-- Needs a city: run tests/fixtures/found_capital.lua first on a fresh game.
local test, T = ...

local pid = Game.GetLocalPlayer()

local function capital()
  local city = Players[pid]:GetCities():GetCapitalCity()
  if city == nil then T.skip("no capital: run tests/fixtures/found_capital.lua") end
  return city
end

test("specialty capacity formula", function()
  local expected = { [1] = 1, [3] = 1, [4] = 2, [6] = 2, [7] = 3, [10] = 4 }
  for population, slots in pairs(expected) do
    T.eq(SDP_City.SpecialtyCapacity(population), slots, "population " .. population)
  end
end)

test("plots in range: three rings, sorted, unique", function()
  local city = capital()
  local plots = SDP_City.PlotsInRange(city:GetX(), city:GetY(), 3)
  T.ok(#plots <= 36 and #plots >= 30, "plot count " .. #plots)
  local perRing = { 0, 0, 0 }
  for i, p in ipairs(plots) do
    T.ok(p.Ring >= 1 and p.Ring <= 3, "ring " .. p.Ring)
    T.eq(Map.GetPlotDistance(city:GetX(), city:GetY(), p.X, p.Y), p.Ring, "distance")
    if i > 1 then T.ok(plots[i - 1].Index < p.Index, "not strictly sorted") end
    perRing[p.Ring] = perRing[p.Ring] + 1
  end
  if #plots == 36 then T.same(perRing, { 6, 12, 18 }, "plots per ring") end
end)

test("scan splits the range into candidates and excluded plots", function()
  local city = capital()
  local scan = SDP_City.Scan(pid, city:GetID())
  local seen = {}
  for i, c in ipairs(scan.Candidates) do
    T.ok(scan.Excluded[c.Index] == nil, "candidate also excluded")
    if i > 1 then T.ok(scan.Candidates[i - 1].Index < c.Index, "candidates not sorted") end
    seen[c.Index] = true
  end
  for _, p in ipairs(SDP_City.PlotsInRange(city:GetX(), city:GetY(), 3)) do
    T.ok(seen[p.Index] or scan.Excluded[p.Index], "plot " .. p.Index .. " neither candidate nor excluded")
  end
  T.ok(#scan.Candidates > 0, "no candidates")
  for _, c in ipairs(scan.Candidates) do
    T.ok(PlayersVisibility[pid]:IsRevealed(c.Index), "unrevealed candidate " .. c.Index)
  end
  T.eq(scan.SpecialtyCapacity, SDP_City.SpecialtyCapacity(city:GetPopulation()), "capacity")
end)

test("an existing pin locks its plot and is listed", function()
  local city = capital()
  local before = SDP_City.Scan(pid, city:GetID())
  local target = before.Candidates[1]
  local cfg = PlayerConfigurations[pid]
  local pin = cfg:GetMapPin(target.X, target.Y)
  pin:SetName("SDP test pin")
  local pinID = pin:GetID()
  Network.BroadcastPlayerInfo()
  local ok, err = pcall(function()
    local scan = SDP_City.Scan(pid, city:GetID())
    T.eq(scan.Excluded[target.Index], SDP_City.EXCLUDED.PIN, "pinned plot")
    local listed = false
    for _, p in ipairs(scan.Pins) do
      if p.ID == pinID then listed = true end
    end
    T.ok(listed, "pin not in scan.Pins")
  end)
  -- Deleted the way DMT does (pitfall 19): without the broadcast the pin stays.
  cfg:DeleteMapPin(pinID)
  Network.BroadcastPlayerInfo()
  if not ok then error(err, 0) end
  local after = SDP_City.Scan(pid, city:GetID())
  T.same(after.Candidates, before.Candidates, "candidates after deleting the pin")
end)

test("turning feature removal off excludes woods, rainforest and marsh", function()
  local city = capital()
  local allowed = SDP_City.Scan(pid, city:GetID())
  local strict = SDP_City.Scan(pid, city:GetID(), { allowFeatureRemoval = false })
  for _, c in ipairs(strict.Candidates) do
    local feature = Map.GetPlotByIndex(c.Index):GetFeatureType()
    T.ok(feature == -1 or not GameInfo.Features[feature].Removable, "removable feature kept at " .. c.Index)
  end
  for index, reason in pairs(strict.Excluded) do
    if reason == SDP_City.EXCLUDED.FEATURE then
      -- Unless it also holds a resource no district may cover (woods on
      -- a luxury): the feature check comes first, so strict calls it FEATURE.
      T.ok(allowed.Excluded[index] == nil or allowed.Excluded[index] == SDP_City.EXCLUDED.RESOURCE,
        "FEATURE plot " .. index .. " was not a candidate before")
    end
  end
end)

test("district status: nothing built at the start", function()
  local city = capital()
  local scan = SDP_City.Scan(pid, city:GetID())
  local status = SDP_City.DistrictStatus(scan, SDP_Rules.PlannableDistricts(pid))
  for _, built in ipairs(scan.Built) do
    T.eq(status[built.Type], "BUILT", built.Type)
  end
  if #scan.Built == 0 then T.same(status, {}, "status with nothing built") end
end)

test("scan is deterministic", function()
  local city = capital()
  T.same(SDP_City.Scan(pid, city:GetID()), SDP_City.Scan(pid, city:GetID()))
end)

test("visible luxury and strategic resources are excluded, bonus resources are not", function()
  local city = capital()
  local scan = SDP_City.Scan(pid, city:GetID())
  local candidate = {}
  for _, c in ipairs(scan.Candidates) do candidate[c.Index] = true end
  local harvest = {}
  for row in GameInfo.Resource_Harvests() do harvest[row.ResourceType] = true end
  local seen = { kept = 0, excluded = 0 }
  for _, p in ipairs(SDP_City.PlotsInRange(city:GetX(), city:GetY(), 3)) do
    local plot = Map.GetPlotByIndex(p.Index)
    local resource = plot:GetResourceType()
    if resource ~= -1 and Players[pid]:GetResources():IsResourceVisible(GameInfo.Resources[resource].Hash) then
      local row = GameInfo.Resources[resource]
      local where = row.ResourceType .. " at " .. p.X .. "," .. p.Y
      if harvest[row.ResourceType] then
        T.ok(scan.Excluded[p.Index] ~= SDP_City.EXCLUDED.RESOURCE, where .. ": a harvestable resource was excluded")
        if candidate[p.Index] then seen.kept = seen.kept + 1 end
      else
        T.eq(candidate[p.Index], nil, where .. ": a district may not cover it")
        if scan.Excluded[p.Index] == SDP_City.EXCLUDED.RESOURCE then seen.excluded = seen.excluded + 1 end
      end
    end
  end
  print(string.format("resources in range: %d harvestable kept, %d excluded", seen.kept, seen.excluded))
end)

test("candidates are joined to the city's territory; unowned plots and missing techs are flagged (issue 35)", function()
  local city = capital()
  local scan = SDP_City.Scan(pid, city:GetID())
  T.ok(scan.Reach ~= nil and scan.Reach.Start[Map.GetPlotIndex(city:GetX(), city:GetY())], "the center starts the chain")
  local techs = Players[pid]:GetTechs()
  for _, c in ipairs(scan.Candidates) do
    T.ok(scan.Reach.Reached[c.Index], "candidate " .. c.X .. "," .. c.Y .. " not reached")
    local plot = Map.GetPlotByIndex(c.Index)
    local owner = plot:GetOwner() == pid and Cities.GetPlotPurchaseCity(plot) or nil
    local owned = owner ~= nil and owner:GetID() == city:GetID()
    T.eq(c.Unowned, (not owned) or nil, "Unowned at " .. c.X .. "," .. c.Y)
    -- The feature's removal technology, else the visible bonus resource's
    -- harvest technology (issue 52; measured 2026-10-23: a campus could go
    -- on bananas only once Irrigation was known).
    local feature = plot:GetFeatureType()
    local row = feature ~= -1 and GameInfo.Features[feature] or nil
    local tech = row and row.Removable and row.RemoveTech and GameInfo.Technologies[row.RemoveTech] or nil
    local expected = (tech ~= nil and not techs:HasTech(tech.Index)) and tech.TechnologyType or nil
    local resource = plot:GetResourceType() ~= -1 and GameInfo.Resources[plot:GetResourceType()] or nil
    if expected == nil and resource ~= nil and Players[pid]:GetResources():IsResourceVisible(resource.Hash) then
      for harvest in GameInfo.Resource_Harvests() do
        local need = harvest.ResourceType == resource.ResourceType and harvest.PrereqTech and GameInfo.Technologies[harvest.PrereqTech]
        if expected == nil and need and not techs:HasTech(need.Index) then expected = need.TechnologyType end
      end
    end
    T.eq(c.RemoveTech, expected, "RemoveTech at " .. c.X .. "," .. c.Y)
  end
  -- Every plot the city owns is a start; every unowned plot in range that a
  -- candidate touches is reachable too (no enclave on an open map).
  for _, p in ipairs(SDP_City.PlotsInRange(city:GetX(), city:GetY(), 3)) do
    local plot = Map.GetPlotByIndex(p.Index)
    local owner = plot:GetOwner() == pid and Cities.GetPlotPurchaseCity(plot) or nil
    if owner ~= nil and owner:GetID() == city:GetID() then T.ok(scan.Reach.Start[p.Index], "owned plot not a start") end
  end
  T.ok(SDP_City.EXCLUDED.UNREACHABLE ~= nil, "reason defined")
end)
