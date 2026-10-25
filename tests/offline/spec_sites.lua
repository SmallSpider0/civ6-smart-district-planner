-- Offline: SDP_Sites and SDP_SiteSolver, choosing new city sites.
local test, T = ...

include("SDP_Rules")
include("SDP_City")
include("SDP_Overlay")
include("SDP_Tiers")
include("SDP_Task")
include("SDP_Board")
include("SDP_Land")
include("SDP_Appeal")
include("SDP_Search")
include("SDP_Solver")
include("SDP_Wonders")
include("SDP_Multi")
include("SDP_Sites")
include("SDP_SiteSolver")

local PLAN = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_COMMERCIAL_HUB" }

-- A random 24 x 16 map; our capital at (4, 8), a foreign city at (20, 8),
-- a city-center pin at (9, 4); the far right columns unrevealed.
local function NewWorld(seed, extra)
  local spec = World.RandomSpec(seed or 7, 24, 16)
  local function Land(x, y)
    local row = spec.rows[y + 1]
    spec.rows[y + 1] = row:sub(1, x) .. "." .. row:sub(x + 2)
  end
  Land(4, 8)
  Land(20, 8)
  Land(9, 4)
  spec.cities = {
    { id = 1, x = 4, y = 8, population = 6, capital = true, radius = 1 },
    { id = 1, owner = 1, x = 20, y = 8, population = 5, radius = 2 },
  }
  spec.pins = { { 9, 4, "ICON_DISTRICT_CITY_CENTER", "planned" } }
  spec.unrevealed = {}
  for y = 0, 15 do
    for x = 22, 23 do spec.unrevealed[#spec.unrevealed + 1] = x .. "," .. y end
  end
  for k, v in pairs(extra or {}) do spec[k] = v end
  return World.New(spec)
end

test("candidates follow the exclusion rules", function()
  NewWorld()
  local K, D = 2, 6
  local list, centers = SDP_Sites.Candidates(0, { K = K, D = D })
  T.ok(#list > 10, "some candidates")
  local minRange = SDP_Sites.MinRange()
  for _, c in ipairs(list) do
    local plot = Map.GetPlotByIndex(c.Index)
    T.ok(not plot:IsWater() and not plot:IsMountain() and not plot:IsImpassable(), "terrain " .. c.X .. "," .. c.Y)
    local feature = plot:GetFeatureType()
    T.ok(feature == -1 or GameInfo.Features[feature].Settlement ~= false, "feature")
    T.ok(plot:GetOwner() == -1 or plot:GetOwner() == 0, "foreign plot")
    local nearOwn = math.huge
    for _, center in ipairs(centers) do
      T.ok(Map.GetPlotDistance(c.X, c.Y, center.X, center.Y) > minRange, "too close to a city or pin")
      if center.Own then nearOwn = math.min(nearOwn, Map.GetPlotDistance(c.X, c.Y, center.X, center.Y)) end
    end
    T.ok(nearOwn <= K * D, "beyond K * D")
    T.ok(c.Unrevealed * 2 <= c.Rings, "too much unrevealed")
  end
end)

test("the minimum city distance comes from the game data", function()
  NewWorld(7, { cityMinRange = 4 })
  local list, centers = SDP_Sites.Candidates(0, { K = 3, D = 8 })
  for _, c in ipairs(list) do
    for _, center in ipairs(centers) do
      T.ok(Map.GetPlotDistance(c.X, c.Y, center.X, center.Y) > 4, "CITY_MIN_RANGE 4")
    end
  end
end)

test("site factors: water, luxuries, strategic resources", function()
  local w = World.New({
    rows = {
      "............",
      "............",
      ".....~~.....",
      "............",
      "............",
      "............",
      "............",
    },
    rivers = { "2,3" },
    cities = { { id = 1, x = 9, y = 5, population = 3, capital = true } },
    resources = { { 3, 3, "RESOURCE_WINE", 1 }, { 1, 3, "RESOURCE_WINE", 1 }, { 2, 4, "RESOURCE_HORSES", 1 },
      { 3, 4, "RESOURCE_IRON", 1 } },
  })
  local _ = w
  local ctx = SDP_Sites.Context(0, { Districts = PLAN })
  local centers = SDP_Sites.Centers(0)
  local river = SDP_Sites.Coarse(ctx, { X = 2, Y = 3, Index = Map.GetPlotIndex(2, 3), Unrevealed = 0 }, centers)
  T.eq(river.Info.WaterKind, "FRESH", "river")
  T.eq(river.Parts.Water, (5 - 2) * 1, "fresh water housing")
  local coast = SDP_Sites.Coarse(ctx, { X = 6, Y = 3, Index = Map.GetPlotIndex(6, 3), Unrevealed = 0 }, centers)
  T.eq(coast.Info.WaterKind, "COAST", "coast")
  T.eq(river.Luxury.RESOURCE_WINE, 2, "two wine copies")
  T.eq(river.Parts.Luxury, 4 + 1, "a new kind: Happiness 4, the second copy 1")
  T.eq(river.Strategic.RESOURCE_HORSES, 2, "Gathering Storm extraction rate")
  T.eq(river.Strategic.RESOURCE_IRON, nil, "iron is not visible without its tech")
  T.ok(river.Info.UnknownStrategic, "unknown strategic resources hinted")
  T.eq(river.Parts.Strategic, 2 + 2, "amount plus a new kind")

  -- Housing (issues 55, 56): its own weight, not food's; worth 1 each up to
  -- the population the plan needs (three specialty districts: 7), half the
  -- one before after that.
  local food = SDP_Sites.Context(0, { Districts = PLAN, Weights = { YIELD_FOOD = 3 } })
  T.eq(SDP_Sites.Coarse(food, { X = 2, Y = 3, Index = Map.GetPlotIndex(2, 3), Unrevealed = 0 }, centers).Parts.Water, 3,
    "the food weight leaves the water part alone")
  local housing = SDP_Sites.Context(0, { Districts = PLAN, Weights = { HOUSING = 2 } })
  T.eq(SDP_Sites.Coarse(housing, { X = 2, Y = 3, Index = Map.GetPlotIndex(2, 3), Unrevealed = 0 }, centers).Parts.Water, 6,
    "weighted by housing")
  local small = SDP_Sites.Context(0, { Districts = { "DISTRICT_CAMPUS" } })
  T.eq(small.Population, 1, "one district needs population 1")
  -- Housing 2 -> 5 against a target of 1: 0.25 + 0.125 + 0.0625.
  T.eq(SDP_Sites.Coarse(small, { X = 2, Y = 3, Index = Map.GetPlotIndex(2, 3), Unrevealed = 0 }, centers).Parts.Water,
    0.4375, "housing past the target is worth less")
end)

test("housing value: 1 each up to the target, half the one before after it", function()
  T.eq(SDP_Land.HousingValue(5, 7), 5, "below the target")
  T.eq(SDP_Land.HousingValue(7, 7), 7, "at the target")
  T.eq(SDP_Land.HousingValue(8, 7), 7.5, "one past")
  T.eq(SDP_Land.HousingValue(10, 7), 7.875, "three past")
  T.ok(math.abs(SDP_Land.HousingValue(7.5, 7) - (8 - 0.5 ^ 0.5)) < 1e-12, "continuous between whole numbers")
end)

test("combinations: spacing, relay, distinct solutions; deterministic", function()
  NewWorld()
  local request = { PlayerID = 0, K = 2, D = 6, Districts = PLAN, Tier = "FAST" }
  local result = SDP_SiteSolver.Solve(request)
  T.ok(result.Ok, tostring(result.Error))
  T.ok(#result.Solutions >= 2, "several solutions")
  local minRange = SDP_Sites.MinRange()
  local centers = SDP_Sites.Centers(0)
  for n, solution in ipairs(result.Solutions) do
    T.eq(#solution.Sites, 2, "K sites")
    local a, b = solution.Sites[1], solution.Sites[2]
    T.ok(Map.GetPlotDistance(a.X, a.Y, b.X, b.Y) > minRange, "spacing")
    -- Relay: each site within D of our city, our pin or the other site that is.
    local function NearOwn(site)
      for _, c in ipairs(centers) do
        if c.Own and Map.GetPlotDistance(site.X, site.Y, c.X, c.Y) <= 6 then return true end
      end
      return false
    end
    local linked = (NearOwn(a) or (NearOwn(b) and Map.GetPlotDistance(a.X, a.Y, b.X, b.Y) <= 6))
      and (NearOwn(b) or (NearOwn(a) and Map.GetPlotDistance(a.X, a.Y, b.X, b.Y) <= 6))
    T.ok(linked, "solution " .. n .. " not linked back")
    if n > 1 then T.ok(solution.Value <= result.Solutions[n - 1].Value + 1e-9, "best first") end
  end
  local again = SDP_SiteSolver.Solve(request)
  T.eq(again.Solutions[1].Value, result.Solutions[1].Value, "same value")
  T.eq(again.Solutions[1].Sites[1].Index, result.Solutions[1].Sites[1].Index, "same sites")
end)

test("the combination search finds the best pair among the refined sites", function()
  NewWorld()
  local session = SDP_Overlay.With(0, function()
    local s = SDP_SiteSolver.NewSession({ PlayerID = 0, K = 2, D = 6, Districts = PLAN, Tier = "FAST", Params = { Refined = 12 } })
    s:Run()
    return s
  end)
  local best = nil
  local minRange = SDP_Sites.MinRange()
  for i = 1, #session.Pool do
    for j = i + 1, #session.Pool do
      local a, b = session.Pool[i], session.Pool[j]
      if Map.GetPlotDistance(a.X, a.Y, b.X, b.Y) > minRange and session:Connected({ i, j }) then
        local v = session:Value({ i, j })
        if best == nil or v > best then best = v end
      end
    end
  end
  T.near(session.Kept[1].Value, best, 1e-9, "branch and bound vs every pair")
  -- The correction never adds: a combination is worth at most its sites' scores.
  for _, entry in ipairs(session.Kept) do
    local sum = 0
    for _, s in ipairs(entry.Chosen) do sum = sum + session.Pool[s].Fine end
    T.ok(entry.Value <= sum + 1e-9, "value above the sum of the site scores")
  end
end)

test("refinement takes the sites that link back, even when far ones score higher", function()
  NewWorld()
  -- A short relay distance and a small refine budget: several of the best
  -- coarse sites are out of reach, and the refined ones must still connect
  -- (found in the game: an explored map gave 20 far sites and no solution).
  local request = { PlayerID = 0, K = 2, D = 4, Districts = PLAN, Tier = "FAST", Params = { Refined = 4 } }
  local result = SDP_SiteSolver.Solve(request)
  T.ok(result.Ok, tostring(result.Error))
  local session = result.Session
  -- Some site ranks above a refined one by coarse score but was passed over.
  local last = 0
  for n, site in ipairs(session.Sites) do
    if site.Refined then last = n end
  end
  local skipped = 0
  for n = 1, last do
    if not session.Sites[n].Refined then skipped = skipped + 1 end
  end
  T.ok(skipped > 0, "the test needs a better site out of reach")
  for _, site in ipairs(session.Order) do
    T.ok(site.Hops ~= nil and site.Hops <= request.K, "refined a site that cannot link back")
  end
  for _, solution in ipairs(result.Solutions) do T.eq(#solution.Sites, 2, "K sites") end
end)

test("each site's resources and distances in a solution (issues 8, 9)", function()
  NewWorld()
  -- Three sites with a long relay: rings overlap in some solutions.
  local request = { PlayerID = 0, K = 3, D = 6, Districts = PLAN, Tier = "FAST" }
  local result = SDP_SiteSolver.Solve(request)
  T.ok(result.Ok, tostring(result.Error))
  local ctx = result.Session.Ctx
  local centers = SDP_Sites.Centers(0)
  local withResources = 0
  for n, solution in ipairs(result.Solutions) do
    -- The sites' values and resource shares add up to the solution's.
    local sum, resources = 0, 0
    for _, site in ipairs(solution.Sites) do
      sum = sum + site.Value
      resources = resources + site.Parts.Luxury + site.Parts.Strategic
    end
    T.near(sum - solution.Conflict, solution.Value, 1e-6, "solution " .. n .. ": site values")
    T.near(resources, solution.Resources, 1e-6, "solution " .. n .. ": resource shares")
    -- Every visible luxury or strategic copy on the sites' workable plots
    -- is counted once, at one site.
    local onMap, counted, seen = {}, {}, {}
    for _, site in ipairs(solution.Sites) do
      local scan = SDP_City.ScanSite(0, site.X, site.Y, { population = ctx.Population })
      for _, index in ipairs(SDP_Land.Workable(scan)) do
        local plot = Map.GetPlotByIndex(index)
        local resource = plot:GetResourceType()
        if not seen[index] and resource ~= -1 then
          seen[index] = true
          local row = GameInfo.Resources[resource]
          if ctx.Visible[row.ResourceType] and row.ResourceClassType ~= "RESOURCECLASS_BONUS" then
            onMap[row.ResourceType] = (onMap[row.ResourceType] or 0) + math.max(1, plot:GetResourceCount())
          end
        end
      end
      for _, copies in ipairs({ site.Luxury, site.Strategic }) do
        for kind, count in pairs(copies) do
          counted[kind] = (counted[kind] or 0) + count
          withResources = withResources + 1
        end
      end
      for kind in pairs(site.Strategic) do
        T.eq(GameInfo.Resources[kind].ResourceClassType, "RESOURCECLASS_STRATEGIC", kind .. " listed as strategic")
      end
    end
    T.same(counted, onMap, "solution " .. n .. ": copies counted once")
    -- A kind the player lacks is new at exactly one site.
    local newAt = {}
    for _, site in ipairs(solution.Sites) do
      for kind in pairs(site.NewKinds) do newAt[kind] = (newAt[kind] or 0) + 1 end
    end
    for kind in pairs(onMap) do
      T.eq(newAt[kind], (not ctx.Owned[kind]) and 1 or nil, "solution " .. n .. ": " .. kind .. " new once")
    end
    -- Distances: to our cities and pins; to the nearest other site.
    for _, site in ipairs(solution.Sites) do
      local own, other = math.huge, nil
      for _, c in ipairs(centers) do
        if c.Own then own = math.min(own, Map.GetPlotDistance(site.X, site.Y, c.X, c.Y)) end
      end
      for _, s in ipairs(solution.Sites) do
        if s ~= site then
          local d = Map.GetPlotDistance(site.X, site.Y, s.X, s.Y)
          if other == nil or d < other then other = d end
        end
      end
      T.eq(site.OwnDistance, own, "distance to our cities and pins")
      T.eq(site.SiteDistance, other, "distance to the other sites")
    end
  end
  T.ok(withResources > 0, "the test needs sites with luxury or strategic resources")
end)

test("a resource kind new to the player is new at one site only", function()
  -- Two wine plots, one near each of two sites: the first site (by plot) gets
  -- the new kind's amenities, the other a copy's worth.
  local ctx = { Owned = {}, Weights = SDP_Sites.Weights() }
  local taken = {}
  local first = SDP_Sites.LuxuryValue(ctx, { RESOURCE_WINE = 1 }, taken)
  local second = SDP_Sites.LuxuryValue(ctx, { RESOURCE_WINE = 1 }, taken)
  NewWorld()
  T.eq(first, GameInfo.Resources.RESOURCE_WINE.Happiness, "first: the kind's amenities")
  T.eq(second, SDP_Sites.DUPLICATE_VALUE, "second: a duplicate")
  T.eq(first + second, SDP_Sites.LuxuryValue(ctx, { RESOURCE_WINE = 2 }, {}), "same as counted together")
end)

test("one site: no distance to other sites", function()
  NewWorld()
  local result = SDP_SiteSolver.Solve({ PlayerID = 0, K = 1, D = 6, Districts = PLAN, Tier = "FAST" })
  T.ok(result.Ok, tostring(result.Error))
  T.eq(result.Solutions[1].Sites[1].SiteDistance, nil, "no other site")
end)

test("a site's plot yields weigh the fixed numbers times the tab's weights (issue 53)", function()
  NewWorld()
  local balanced = SDP_Sites.PlotWeights(SDP_Sites.Weights(nil))
  T.eq(balanced.YIELD_GOLD, 1 / 4, "gold: 1/4")
  T.eq(balanced.YIELD_FAITH, 1 / 2, "faith: 1/2")
  T.eq(balanced.YIELD_SCIENCE, 5 / 6, "science: 5/6")
  T.eq(balanced.YIELD_FOOD, 1, "food: 1")
  T.eq(balanced.FEATURE, 1, "one-time yields: the tab's weight")
  local growth = SDP_Sites.PlotWeights(SDP_Sites.Weights(SDP_Sites.PRESETS.GROWTH))
  T.eq(growth.YIELD_FOOD, 2, "growth first: food leans twice")
  local ctx = SDP_Sites.Context(0, { Districts = PLAN, Weights = { YIELD_GOLD = 2 } })
  T.eq(ctx.Land.W.YIELD_GOLD, 2 / 4, "the context's land part: gold 2 x 1/4")
end)
