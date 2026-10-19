-- @state SDP_Panel
-- @timeout 300
-- Single-city tiers (docs/multicity-design.md 7): exactness on small
-- problems with and without the land part, determinism of every tier,
-- continue, quality flags.
-- Needs a city: run tests/fixtures/found_capital.lua first on a fresh game.
local test, T = ...

local pid = Game.GetLocalPlayer()
local ONES = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }

local function City()
  local city = Players[pid]:GetCities():GetCapitalCity()
  if city == nil then T.skip("no capital: run tests/fixtures/found_capital.lua") end
  return city
end

local function Resolve(base)
  local plannable = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do plannable[d.Type] = true end
  if plannable[base] then return base end
  for row in GameInfo.DistrictReplaces() do
    if row.ReplacesDistrictType == base and plannable[row.CivUniqueDistrictType] then return row.CivUniqueDistrictType end
  end
  T.skip(base .. " not available to this civ")
end

-- Best gain over every placement of two districts, with DMT, optionally
-- with the land part.
local function BruteForceTwo(city, a, b, weights, land)
  local scan = SDP_City.Scan(pid, city:GetID())
  return SDP_Overlay.With(pid, function()
    local fixed = SDP_Overlay.FixedSubjects(scan)
    local baseline = SDP_Overlay.Evaluate({}, fixed, weights).Total
    local model = nil
    if land then
      local specialty = 0
      for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do
        if (d.Type == a or d.Type == b) and d.Specialty then specialty = specialty + 1 end
      end
      model = SDP_Land.ForScan(scan, fixed, weights,
        math.max(scan.Population, SDP_Land.RequiredPopulation(scan.SpecialtyBuilt + specialty)))
    end
    local best = nil
    for _, p in ipairs(scan.Candidates) do
      for _, q in ipairs(scan.Candidates) do
        if p.Index ~= q.Index then
          local res = SDP_Overlay.Evaluate({ SDP_Overlay.Subject(a, p.X, p.Y), SDP_Overlay.Subject(b, q.X, q.Y) }, fixed, weights)
          local gain = res.Total - baseline
          if model then gain = gain + SDP_Land.Score(model, { [p.Index] = true, [q.Index] = true }) - model.Base end
          if res.Legal and (best == nil or gain > best) then best = gain end
        end
      end
    end
    return best
  end)
end

test("two districts: exhaustive and optimal, with and without the land part", function()
  local city = City()
  local campus, holy = Resolve("DISTRICT_CAMPUS"), Resolve("DISTRICT_HOLY_SITE")
  for _, land in ipairs({ false, true }) do
    local result = SDP_Solver.Solve({ PlayerID = pid, CityID = city:GetID(), Districts = { campus, holy }, Weights = ONES, Land = land })
    T.ok(result.Ok, tostring(result.Error))
    T.eq(result.Stats.Method, "exhaustive", "method")
    T.ok(result.Quality.Exhaustive and not result.Quality.CanContinue, "quality flags")
    T.near(result.Gain, BruteForceTwo(city, campus, holy, ONES, land), 1e-6, "land " .. tostring(land))
  end
end)

test("every tier is deterministic", function()
  local city = City()
  local districts = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do
    if #districts < 5 then districts[#districts + 1] = d.Type end
  end
  for _, tier in ipairs(SDP_Tiers.ORDER) do
    local request = { PlayerID = pid, CityID = city:GetID(), Districts = districts, Tier = tier, Land = true }
    local first, second = SDP_Solver.Solve(request), SDP_Solver.Solve(request)
    T.ok(first.Ok, tier .. ": " .. tostring(first.Error))
    T.same(second.Plan, first.Plan, tier .. " plan")
    T.same(second.Stats, first.Stats, tier .. " stats")
    print(string.format("%s: gain %.2f via %s, %d DMT calls, %d tries, %d nodes", tier, first.Gain, first.Stats.Method,
      first.Stats.Calls, first.Stats.Tries, first.Stats.Nodes))
  end
end)

test("continue never gets worse and is reproducible", function()
  local city = City()
  local districts = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do
    if #districts < 6 then districts[#districts + 1] = d.Type end
  end
  local request = { PlayerID = pid, CityID = city:GetID(), Districts = districts, Tier = "FAST", Land = true }
  local a, b = SDP_Solver.Solve(request), SDP_Solver.Solve(request)
  if not a.Quality.CanContinue then T.skip("nothing to continue (" .. a.Stats.Method .. ")") end
  for n = 1, 2 do
    local before = a.Gain
    a, b = SDP_Solver.Continue(a), SDP_Solver.Continue(b)
    T.ok(a.Gain >= before, "continue " .. n .. " got worse")
    T.same(b.Plan, a.Plan, "continue " .. n .. " plan")
    if not a.Quality.CanContinue then break end
  end
end)
