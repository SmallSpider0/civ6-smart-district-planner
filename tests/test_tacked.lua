-- @state SDP_Panel
-- @timeout 600
-- Several cities in two batches with the shared list (issue 64): the
-- second city keeps districts its neighbour has tacked, and a city replanned
-- after its own tacks says why it skips them. Needs two of the player's
-- cities within 7 plots (a late save: tools/stress.py load pangaea-gs);
-- skipped otherwise. The tacks are undone at the end.
local test, T = ...

local pid = Game.GetLocalPlayer()

local function Types(bases)
  local plannable, out = {}, {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do plannable[d.Type] = true end
  for _, base in ipairs(bases) do
    local t = base
    if not plannable[t] then
      for row in GameInfo.DistrictReplaces() do
        if row.ReplacesDistrictType == base and plannable[row.CivUniqueDistrictType] then t = row.CivUniqueDistrictType end
      end
    end
    if plannable[t] then out[#out + 1] = t end
  end
  return out
end

-- The two nearest cities (ties by IDs) and the district types neither has
-- built or tacked, at most three.
local function Pair()
  local cities = {}
  for _, city in Players[pid]:GetCities():Members() do cities[#cities + 1] = city end
  table.sort(cities, function(a, b) return a:GetID() < b:GetID() end)
  local best = nil
  for i = 1, #cities do
    for j = i + 1, #cities do
      local d = Map.GetPlotDistance(cities[i]:GetX(), cities[i]:GetY(), cities[j]:GetX(), cities[j]:GetY())
      if d <= SDP_Multi.NEAR and (best == nil or d < best.D) then best = { A = cities[i], B = cities[j], D = d } end
    end
  end
  if best == nil then T.skip("no two cities within " .. SDP_Multi.NEAR .. " plots: load a late save") end
  local scans = { SDP_City.Scan(pid, best.A:GetID()), SDP_City.Scan(pid, best.B:GetID()) }
  local plannable = SDP_Rules.PlannableDistricts(pid)
  local types = {}
  for _, t in ipairs(Types({ "DISTRICT_CAMPUS", "DISTRICT_THEATER", "DISTRICT_COMMERCIAL_HUB", "DISTRICT_HOLY_SITE",
      "DISTRICT_INDUSTRIAL_ZONE", "DISTRICT_ENTERTAINMENT_COMPLEX" })) do
    local free = true
    for _, scan in ipairs(scans) do
      if SDP_City.DistrictStatus(scan, plannable)[t] or SDP_City.TackedDistricts(scan)[t]
          or SDP_City.BuiltTypes(scan)[t] then
        free = false
      end
    end
    if free and #types < 3 then types[#types + 1] = t end
  end
  if #types == 0 then T.skip("both cities have every district of the list") end
  return best, types
end

local function Planned(result, key)
  local out = {}
  for _, p in ipairs(result.Plan or {}) do
    if p.City == key and (p.Kind == nil or p.Kind == "DISTRICT") then out[#out + 1] = p.Type end
  end
  table.sort(out)
  return out
end

local function Solve(cityIDs, types, own)
  local existing, plans = {}, nil
  for _, city in Players[pid]:GetCities():Members() do existing[city:GetID()] = false end
  for _, id in ipairs(cityIDs) do existing[id] = true end
  if own then
    plans = {}
    for _, id in ipairs(cityIDs) do plans["C" .. id] = types end
  end
  -- City-center tacks stay out: only these cities take part.
  local sites = {}
  for _, site in ipairs(SDP_City.Sites(pid)) do sites["S" .. site.Index] = false end
  local result = SDP_Multi.Solve({ PlayerID = pid, Tier = "FAST", Districts = plans and {} or types, Plans = plans,
    Existing = existing, Sites = sites, Land = false })
  T.ok(result.Ok, tostring(result.Error))
  return result
end

test("two batches with the shared list: the second city keeps its districts; tacked ones are reported", function()
  local pair, types = Pair()
  local a, b = pair.A:GetID(), pair.B:GetID()
  print(string.format("cities %s and %s, %d plots apart; %s", Locale.Lookup(pair.A:GetName()),
    Locale.Lookup(pair.B:GetName()), pair.D, table.concat(types, ", ")))
  local first = Solve({ a }, types)
  local numbers = SDP_City.CityNumbers(pid)
  local entries = {}
  for _, p in ipairs(first.Plan) do
    if p.Kind == nil or p.Kind == "DISTRICT" then
      entries[#entries + 1] = { Type = p.Type, X = p.X, Y = p.Y, Name = tostring(numbers[a]) }
    end
  end
  T.ok(#entries > 0, "the first city has a plan")
  local placed = SDP_Pins.Place(pid, entries)
  local ok, err = pcall(function()
    local near = 0
    for _, e in ipairs(entries) do
      if Map.GetPlotDistance(pair.B:GetX(), pair.B:GetY(), e.X, e.Y) <= SDP_City.RADIUS + 1 then near = near + 1 end
    end
    print(string.format("%d tacks placed, %d within four plots of the second city", placed, near))
    -- Second batch: the shared list plans what the city's own list plans.
    local shared, own = Solve({ b }, types), Solve({ b }, types, true)
    T.same(Planned(shared, "C" .. b), Planned(own, "C" .. b), "shared list = the city's own list")
    for _, u in ipairs(shared.Unplaced) do
      T.ok(not (u.City == "C" .. b and u.Reason == "TACKED"), "the neighbour's tack taken as own: " .. u.Type)
    end
    -- The first city again: its tacked districts are reported, not planned.
    local again = Solve({ a }, types)
    local tacked = {}
    for _, u in ipairs(again.Unplaced) do
      if u.City == "C" .. a and u.Reason == "TACKED" then tacked[#tacked + 1] = u.Type end
    end
    table.sort(tacked)
    local wanted = {}
    for _, e in ipairs(entries) do wanted[#wanted + 1] = e.Type end
    table.sort(wanted)
    T.same(tacked, wanted, "the first city's tacks are reported")
    T.ok(Locale.Lookup("LOC_SDP_REASON_TACKED") ~= "LOC_SDP_REASON_TACKED", "reason text loaded")
    print("reason: " .. Locale.Lookup("LOC_SDP_REASON_TACKED"))
  end)
  SDP_Pins.UndoLast(pid)
  if not ok then error(err, 0) end
end)
