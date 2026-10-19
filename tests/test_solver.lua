-- @state SDP_Panel
-- @timeout 120
-- SDP_Solver: optimality against brute force, determinism, locked pins,
-- feature switch, weights, unavailable districts.
-- Needs a city: run tests/fixtures/found_capital.lua first on a fresh game.
local test, T = ...

local pid = Game.GetLocalPlayer()
local ONES = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }

local function City()
  local city = Players[pid]:GetCities():GetCapitalCity()
  if city == nil then T.skip("no capital: run tests/fixtures/found_capital.lua") end
  return city
end

-- This civ's version of a base district (its unique district if it has one).
local function Resolve(base)
  local plannable = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do plannable[d.Type] = true end
  if plannable[base] then return base end
  for row in GameInfo.DistrictReplaces() do
    if row.ReplacesDistrictType == base and plannable[row.CivUniqueDistrictType] then return row.CivUniqueDistrictType end
  end
  T.skip(base .. " not available to this civ")
end

-- Best legal joint gain over every placement of two districts, with DMT.
local function BruteForceTwo(city, a, b, weights, options)
  local scan = SDP_City.Scan(pid, city:GetID(), options)
  return SDP_Overlay.With(pid, function()
    local fixed = SDP_Overlay.FixedSubjects(scan)
    local baseline = SDP_Overlay.Evaluate({}, fixed, weights).Total
    local best = nil
    for _, p in ipairs(scan.Candidates) do
      for _, q in ipairs(scan.Candidates) do
        if p.Index ~= q.Index then
          local res = SDP_Overlay.Evaluate({ SDP_Overlay.Subject(a, p.X, p.Y), SDP_Overlay.Subject(b, q.X, q.Y) }, fixed, weights)
          if res.Legal and (best == nil or res.Total - baseline > best) then best = res.Total - baseline end
        end
      end
    end
    return best
  end)
end

local function Solve(city, districts, weights, extra)
  local request = { PlayerID = pid, CityID = city:GetID(), Districts = districts, Weights = weights }
  for k, v in pairs(extra or {}) do request[k] = v end
  local result = SDP_Solver.Solve(request)
  T.ok(result.Ok, "solve failed: " .. tostring(result.Error))
  return result
end

test("campus + holy site: exhaustive, legal and optimal", function()
  local city = City()
  local campus, holy = Resolve("DISTRICT_CAMPUS"), Resolve("DISTRICT_HOLY_SITE")
  local result = Solve(city, { campus, holy }, ONES)
  T.eq(result.Stats.Method, "exhaustive", "method")
  T.eq(#result.Plan, 2, "plan size")
  T.eq(result.Gain, BruteForceTwo(city, campus, holy, ONES), "gain vs brute force")
  print(string.format("campus+holy site: gain %s, %d layouts, %d DMT evaluations",
    tostring(result.Gain), result.Stats.Layouts, result.Stats.Evaluations))
  for _, p in ipairs(result.Plan) do print(string.format("  %s at %d,%d score %s", p.Type, p.X, p.Y, tostring(p.Score))) end
end)

test("the shortlist path finds the same optimum", function()
  local city = City()
  local campus, holy = Resolve("DISTRICT_CAMPUS"), Resolve("DISTRICT_HOLY_SITE")
  local exhaustive = Solve(city, { campus, holy }, ONES)
  local limit = SDP_Solver.EXACT_LIMIT
  SDP_Solver.EXACT_LIMIT = 0
  local ok, shortlisted = pcall(Solve, city, { campus, holy }, ONES)
  SDP_Solver.EXACT_LIMIT = limit
  if not ok then error(shortlisted, 0) end
  T.eq(shortlisted.Stats.Method, "shortlist", "method")
  T.eq(shortlisted.Gain, exhaustive.Gain, "gain")
end)

test("weights steer the plan", function()
  local city = City()
  local campus, theater = Resolve("DISTRICT_CAMPUS"), Resolve("DISTRICT_THEATER")
  local scienceOnly = { YIELD_SCIENCE = 3, YIELD_CULTURE = 0, YIELD_FAITH = 0, YIELD_GOLD = 0, YIELD_PRODUCTION = 0 }
  local result = Solve(city, { campus, theater }, scienceOnly)
  T.eq(result.Gain, BruteForceTwo(city, campus, theater, scienceOnly), "gain vs brute force")
  local zero = Solve(city, { campus, theater }, { YIELD_SCIENCE = 0, YIELD_CULTURE = 0, YIELD_FAITH = 0, YIELD_GOLD = 0, YIELD_PRODUCTION = 0 })
  T.eq(zero.Gain, 0, "all weights zero")
end)

test("same request, same plan", function()
  local city = City()
  local districts = { Resolve("DISTRICT_CAMPUS"), Resolve("DISTRICT_HOLY_SITE"), Resolve("DISTRICT_THEATER") }
  local first = Solve(city, districts, ONES)
  local second = Solve(city, districts, ONES)
  T.same(second.Plan, first.Plan, "plan")
  T.eq(second.Gain, first.Gain, "gain")
  T.same(second.Stats, first.Stats, "stats")
end)

test("a locked pin is never moved or built over", function()
  local city = City()
  local scan = SDP_City.Scan(pid, city:GetID())
  local target = scan.Candidates[1]
  local cfg = PlayerConfigurations[pid]
  local pin = cfg:GetMapPin(target.X, target.Y)
  pin:SetIconName("ICON_" .. Resolve("DISTRICT_CAMPUS"))
  Network.BroadcastPlayerInfo()
  LuaEvents.DMT_MapPinAdded(pin)
  local pinID = pin:GetID()
  local ok, err = pcall(function()
    local result = Solve(city, { Resolve("DISTRICT_HOLY_SITE"), Resolve("DISTRICT_THEATER") }, ONES)
    for _, p in ipairs(result.Plan) do
      T.ok(p.Index ~= target.Index, p.Type .. " placed on the pinned plot")
    end
    local after = cfg:GetMapPinID(pinID)
    T.ok(after ~= nil and after:GetHexX() == target.X and after:GetHexY() == target.Y, "pin moved or gone")
  end)
  LuaEvents.DMT_MapPinRemoved(cfg:GetMapPinID(pinID))
  cfg:DeleteMapPin(pinID)
  Network.BroadcastPlayerInfo()
  if not ok then error(err, 0) end
end)

test("feature removal off keeps woods, rainforest and marsh", function()
  local city = City()
  local result = Solve(city, { Resolve("DISTRICT_CAMPUS"), Resolve("DISTRICT_HOLY_SITE") }, ONES, { AllowFeatureRemoval = false })
  for _, p in ipairs(result.Plan) do
    local feature = Map.GetPlot(p.X, p.Y):GetFeatureType()
    T.ok(feature == -1 or not GameInfo.Features[feature].Removable, p.Type .. " clears a removable feature")
  end
end)

test("unavailable and duplicate districts are reported, not placed", function()
  local city = City()
  local traits = MapTacks.PlayerTraits(pid)
  local foreign
  for row in GameInfo.Districts() do
    if foreign == nil and row.TraitType ~= nil and not traits[row.TraitType] then foreign = row.DistrictType end
  end
  local campus = Resolve("DISTRICT_CAMPUS")
  local result = Solve(city, { campus, campus, foreign }, ONES)
  T.eq(#result.Plan, 1, "plan size")
  T.eq(result.Plan[1].Type, campus, "placed district")
  T.same(result.Unplaced, { { Type = foreign, Reason = "NOT_AVAILABLE" } }, "unplaced")
end)
