-- Offline: generated mixed scenarios (issue 243). Small random worlds from a
-- fixed seed, each with random cities, built districts, tacks (some of them
-- replaced), and a random request: one city without wonders (SDP_Solver),
-- one city with wonders (the One city tab: SDP_Multi with that city alone,
-- as SDP_Panel's WonderRequest), or several cities (SDP_Multi). Every solve
-- goes through the plan invariants (tests/offline/invariants.lua, issue 242).
--
-- One city with wonders is also compared with the single-city path: the
-- same districts solved by SDP_Solver with each planned wonder as a tack on
-- its plot (a fixed neighbour, as the wonder is in the plan). Both then face
-- the same plots, so
--   placed   they place the same required districts (the wonder's own
--            supplied district counted as required) and as many from the pool;
--   reasons  a district one leaves out for a reason that does not depend on
--            plots (not this civ's, built, empire limit, excluded) the other
--            leaves out for the same reason;
--   score    with no land part and no distance cost, the wonder plan's
--            district adjacency, less what the wonders alone change, is no
--            more than the single-city optimum given the wonders (when that
--            solve is exhaustive), and no less than it unless a wonder must
--            touch a district (then the wonder binds that district's plot,
--            which the single-city path does not know).
-- The plans themselves may differ (ties, other plots of equal value). The
-- single-city requests leave out what the panel's list greys out (built,
-- tacked, excluded, at the empire's limit), as the panel does.
--
-- The random numbers come from the small generator below (not the mod's:
-- the mod has none, requirement constraint 6). A failing case prints its
-- world and request; run it alone with -k "case <n> (".
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
include("SDP_Remind")
include("SDP_Solver")
include("SDP_Wonders")
include("SDP_Multi")

local SEED = 243
local CASES = 50 -- about 20 s here, under a minute in CI; raise it locally to look further
local WIDTH, HEIGHT = 13, 11
local EPS = 1e-6

-- Cases skipped for a known bug: { [case] = "issue N" }.
local KNOWN = {}

local DISTRICTS = {
  "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER", "DISTRICT_COMMERCIAL_HUB",
  "DISTRICT_INDUSTRIAL_ZONE", "DISTRICT_ENTERTAINMENT_COMPLEX", "DISTRICT_ENCAMPMENT", "DISTRICT_GOVERNMENT",
  "DISTRICT_HARBOR", "DISTRICT_AQUEDUCT", "DISTRICT_NEIGHBORHOOD", "DISTRICT_PRESERVE",
  "DISTRICT_WATER_ENTERTAINMENT_COMPLEX", "DISTRICT_ACROPOLIS",
}
-- Built and tacked: the player's own districts only.
local OWN = {}
for _, d in ipairs(DISTRICTS) do
  if d ~= "DISTRICT_ACROPOLIS" then OWN[#OWN + 1] = d end
end
local SPECIALTY = {
  "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER", "DISTRICT_COMMERCIAL_HUB",
  "DISTRICT_INDUSTRIAL_ZONE", "DISTRICT_ENTERTAINMENT_COMPLEX", "DISTRICT_HARBOR",
}
local WONDERS = {
  "BUILDING_PYRAMIDS", "BUILDING_HANGING_GARDENS", "BUILDING_GREAT_LIBRARY", "BUILDING_COLOSSEUM",
  "BUILDING_STONEHENGE", "BUILDING_TEMPLE_ARTEMIS",
}
local YIELDS = { "YIELD_SCIENCE", "YIELD_CULTURE", "YIELD_FAITH", "YIELD_GOLD", "YIELD_PRODUCTION" }
-- Reasons that do not depend on which plots are free.
local FIXED = { NOT_AVAILABLE = true, BUILT = true, MAX_PER_PLAYER = true, EXCLUSIVE = true }

-- Park-Miller on doubles: exact (products stay below 2^53), the same in the
-- game's doubles and in fengari, where integers have 32 bits.
local function Rng(seed)
  local s = seed % 2147483646 + 1.0
  return function(n)
    s = (s * 16807.0) % 2147483647.0
    if n == nil then return s / 2147483647.0 end
    return math.floor(s % n) + 1
  end
end

-- k distinct entries of `list`, in list order.
local function Some(rng, list, k)
  local idx = {}
  for i = 1, #list do idx[i] = i end
  for i = #idx, 2, -1 do
    local j = rng(i)
    idx[i], idx[j] = idx[j], idx[i]
  end
  local chosen = {}
  for i = 1, math.min(k, #idx) do chosen[#chosen + 1] = idx[i] end
  table.sort(chosen)
  local out = {}
  for _, i in ipairs(chosen) do out[#out + 1] = list[i] end
  return out
end

local function Show(v)
  if type(v) ~= "table" then return tostring(v) end
  return T.dump(v)
end

-- Plots of the world in (Y, X) order.
local function Plots()
  local out = {}
  for y = 0, HEIGHT - 1 do
    for x = 0, WIDTH - 1 do out[#out + 1] = Map.GetPlot(x, y) end
  end
  return out
end

local function Placeable(districtType, x, y)
  local plot = Map.GetPlot(x, y)
  if plot == nil or plot:IsCity() or plot:GetDistrictType() ~= -1 then return false end
  if GetMapPinSubject(0, x, y) ~= nil then return false end
  return CanPlacePin(0, { Key = districtType, Type = "DISTRICT", X = x, Y = y }) == true
end

-- A random plot within `radius` of the city where the district may go: the
-- player's, and with `own` the city's; nil when none was found.
local function SpotNear(rng, city, districtType, radius, own)
  local spots = {}
  for _, plot in ipairs(Plots()) do
    local x, y = plot:GetX(), plot:GetY()
    if Map.GetPlotDistance(x, y, city.x, city.y) <= radius and plot:GetOwner() == 0
      and (not own or plot.city ~= nil and plot.city.id == city.id) and Placeable(districtType, x, y) then
      spots[#spots + 1] = plot
    end
  end
  if #spots == 0 then return nil end
  return spots[rng(#spots)]
end

-- Builds the world of case `n`; returns the world, its description and the
-- random generator for the request.
local function NewCase(n)
  local seed = SEED * 1000 + n
  local rng = Rng(seed)
  local spec = World.RandomSpec(seed, WIDTH, HEIGHT)
  spec.campWonder = true
  spec.cities = {}
  if rng(3) == 1 then
    spec.resources[#spec.resources + 1] = { 1 + rng(WIDTH - 2), 1 + rng(HEIGHT - 2), "RESOURCE_DEER", 1 }
  end
  local want = rng(3)
  for _ = 1, 80 do
    if #spec.cities >= want then break end
    local x, y = 1 + rng(WIDTH - 2), 1 + rng(HEIGHT - 2)
    local c = spec.rows[y + 1]:sub(x + 1, x + 1)
    local ok = c ~= "M" and c ~= "~" and c ~= "o" and c ~= "N"
    for _, other in ipairs(spec.cities) do
      local dx, dy = math.abs(other.x - x), math.abs(other.y - y)
      if dx + dy < 5 then ok = false end
    end
    if ok then
      spec.cities[#spec.cities + 1] = { id = #spec.cities + 1, x = x, y = y, population = 2 + rng(14),
        capital = #spec.cities == 0, radius = rng(2) }
    end
  end
  local w = World.New(spec)
  local desc = { case = n, cities = {} }
  for _, c in ipairs(spec.cities) do
    desc.cities[#desc.cities + 1] = c.id .. "@" .. c.x .. "," .. c.y .. " pop " .. c.population .. " r" .. c.radius
  end
  -- Built districts and tacks around the cities.
  desc.built, desc.pins = {}, {}
  for _, c in ipairs(spec.cities) do
    for _ = 1, rng(3) - 1 do
      local districtType = OWN[rng(#OWN)]
      local plot = SpotNear(rng, c, districtType, 2, true)
      if plot ~= nil then
        w:AddDistrict(c.id, districtType, plot:GetX(), plot:GetY(), rng(2) == 1)
        desc.built[#desc.built + 1] = districtType .. "@" .. plot:GetX() .. "," .. plot:GetY()
      end
    end
    for _ = 1, rng(3) - 1 do
      local districtType = OWN[rng(#OWN)]
      local plot = SpotNear(rng, c, districtType, 3)
      if plot ~= nil then
        w:AddPin(plot:GetX(), plot:GetY(), "ICON_" .. districtType, "")
        desc.pins[#desc.pins + 1] = districtType .. "@" .. plot:GetX() .. "," .. plot:GetY()
      end
    end
  end
  -- Now and then a city-center tack (a site for several cities).
  if rng(4) == 1 then
    for _ = 1, 30 do
      local x, y = 1 + rng(WIDTH - 2), 1 + rng(HEIGHT - 2)
      local plot = Map.GetPlot(x, y)
      if plot:GetOwner() == -1 and not plot:IsMountain() and not plot:IsWater() and GetMapPinSubject(0, x, y) == nil then
        w:AddPin(x, y, "ICON_DISTRICT_CITY_CENTER", "S")
        desc.pins[#desc.pins + 1] = "CITY_CENTER@" .. x .. "," .. y
        break
      end
    end
  end
  return w, desc, rng, spec.cities
end

local function Weights(rng, plain)
  local weights = {}
  for _, y in ipairs(YIELDS) do weights[y] = plain and 1 or rng(4) - 1 end
  weights.HOUSING = plain and 0 or rng(3) - 1
  weights.LAND = plain and 0 or rng(3) - 1
  return weights
end

-- Options a request of either kind may carry.
local function Options(rng, w, plain)
  local o = { PlayerID = 0, Tier = "FAST", Weights = Weights(rng, plain), Apart = true,
    AllowFeatureRemoval = rng(4) ~= 1, Swap = rng(2) == 1 }
  if not plain then
    o.Land = rng(2) == 1
    if rng(3) == 1 then o.Distance = 1 end
  else
    o.Land = false
  end
  -- Replace some tacks (the mod's earlier pins: any of them here).
  local pins = w:Pins(0)
  if #pins > 0 and rng(2) == 1 then
    o.IgnorePins = {}
    for _, pin in ipairs(pins) do
      if rng(2) == 1 and pin:GetIconName() ~= "ICON_DISTRICT_CITY_CENTER" then
        o.IgnorePins[#o.IgnorePins + 1] = { ID = pin:GetID(), X = pin:GetHexX(), Y = pin:GetHexY() }
      end
    end
  end
  if rng(4) == 1 then o.Auto = { DISTRICT_AQUEDUCT = true } end
  return o
end

-- Districts asked of one city: required ones, and sometimes a pool to pick from.
local function Asked(rng)
  local must = Some(rng, DISTRICTS, rng(4) - 1)
  local pool, count = nil, nil
  if rng(3) == 1 then
    local asked = {}
    for _, d in ipairs(must) do asked[d] = true end
    pool = {}
    for _, d in ipairs(Some(rng, SPECIALTY, 1 + rng(3))) do
      if not asked[d] then pool[#pool + 1] = d end
    end
    local required = 0
    for _, d in ipairs(must) do
      if GameInfo.Districts[d].RequiresPopulation then required = required + 1 end
    end
    count = required + rng(2)
  end
  return must, pool, count
end

-- What the One city tab leaves out of its list (SDP_Panel's m_status):
-- built, excluded, at the empire's limit, or tacked for the city already.
local function Listed(request, types)
  local scan = SDP_City.Scan(0, request.CityID, SDP_City.ScanOptions(request))
  local districts = SDP_Rules.PlannableDistricts(0)
  local status = SDP_City.DistrictStatus(scan, districts)
  local ignore = SDP_City.ScanOptions(request).ignorePins
  for districtType, why in pairs(SDP_City.TackedStatus(0, request.CityID, districts, ignore)) do
    status[districtType] = status[districtType] or why
  end
  local out = {}
  for _, t in ipairs(types or {}) do
    if status[t] == nil then out[#out + 1] = t end
  end
  return out
end

local function Copy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

-- SDP_Panel's WonderRequest: the One city tab with wonders.
local function WonderRequest(request)
  local multi = Copy(request)
  multi.CityID, multi.MustSpecialty = nil, nil
  multi.Only = { [request.CityID] = true }
  multi.Plans = { ["C" .. request.CityID] = request.Districts }
  return multi
end

local function Types(plan, kind)
  local out = {}
  for _, p in ipairs(plan) do
    local isWonder = p.Kind == "WONDER" or (GameInfo.Buildings[p.Type] ~= nil)
    if (kind == "WONDER") == isWonder then out[#out + 1] = p.Type end
  end
  table.sort(out)
  return out
end

local function Reasons(unplaced)
  local out = {}
  for _, u in ipairs(unplaced or {}) do
    if FIXED[u.Reason] and GameInfo.Districts[u.Type] ~= nil then out[#out + 1] = u.Type .. ":" .. u.Reason end
  end
  table.sort(out)
  return out
end

-- The One city tab with wonders against the single-city path (see the top).
local function Compare(label, request, multi, w)
  if not multi.Ok or #Types(multi.Plan, "WONDER") == 0 then return end
  -- The single-city path with the planned wonders as tacks.
  for _, p in ipairs(multi.Plan) do
    if GameInfo.Buildings[p.Type] ~= nil and GetMapPinSubject(0, p.X, p.Y) ~= nil then
      print(label .. ": a wonder on a replaced tack's plot, not compared")
      return
    end
  end
  local districts = Copy(request.Districts)
  for _, s in ipairs(multi.Supplied or {}) do districts[#districts + 1] = s.Type end
  table.sort(districts)
  local plain = Copy(request)
  plain.Districts = districts
  plain.Params = { ExactLimit = 20000 }
  local before = SDP_Solver.Solve(plain)
  for _, p in ipairs(multi.Plan) do
    if GameInfo.Buildings[p.Type] ~= nil then w:AddPin(p.X, p.Y, "ICON_" .. p.Type, "") end
  end
  local single = SDP_Solver.Solve(plain)
  T.ok(single.Ok and before.Ok, label .. ": single-city solve: " .. tostring(single.Error or before.Error))
  -- Required districts by type; the ones picked from the pool (and added
  -- by themselves) only by number: equal picks may differ.
  local required = {}
  for _, d in ipairs(districts) do required[d] = true end
  local function Split(plan)
    local must, others = {}, 0
    for _, t in ipairs(Types(plan, "DISTRICT")) do
      if required[t] then must[#must + 1] = t else others = others + 1 end
    end
    return must, others
  end
  local sMust, sOthers = Split(single.Plan)
  local mMust, mOthers = Split(multi.Plan)
  T.same(sMust, mMust, label .. ": the same required districts placed")
  T.eq(mOthers, sOthers, label .. ": as many districts picked")
  T.same(Reasons(single.Unplaced), Reasons(multi.Unplaced), label .. ": the same fixed reasons")
  if request.Land or (request.Distance or 0) > 0 then return end
  local wonderEffect = single.Baseline - before.Baseline
  local mine = multi.Adjacency - wonderEffect
  if single.Quality and single.Quality.Exhaustive then
    T.ok(mine <= single.Adjacency + EPS, label .. ": the wonder plan's districts (" .. mine
      .. ") beat the single-city optimum (" .. single.Adjacency .. ")")
  end
  -- A wonder that must touch a district binds where that district goes;
  -- the single-city path, with the wonder a mere neighbour, is free.
  for _, p in ipairs(multi.Plan) do
    local row = GameInfo.Buildings[p.Type]
    if row ~= nil and row.AdjacentDistrict ~= nil then return end
  end
  T.ok(mine >= single.Adjacency - EPS, label .. ": the wonder plan's districts (" .. mine
    .. ") below the single-city plan (" .. single.Adjacency .. ")")
end

local function Run(n, out)
  local w, desc, rng, cities = NewCase(n)
  out.desc = desc
  if #cities == 0 then T.skip("no room for a city") end
  local kind = ({ "single", "wonder", "wonder", "multi" })[rng(4)]
  local request
  if kind == "multi" then
    request = Options(rng, w, false)
    request.Districts = {}
    request.Plans, request.Pools, request.Counts, request.Only = {}, {}, {}, {}
    for _, c in ipairs(cities) do
      local key = "C" .. c.id
      local must, pool, count = Asked(rng)
      request.Plans[key], request.Pools[key], request.Counts[key] = must, pool, count
      request.Only[c.id] = true
    end
    if rng(3) == 1 then
      request.Only = nil
      request.Existing = {}
    end
    if rng(3) == 1 then request.Target = true end
    request.Wonders = Some(rng, WONDERS, rng(3) - 1)
  else
    local city = cities[rng(#cities)]
    request = Options(rng, w, kind == "wonder" and rng(2) == 1)
    request.CityID = city.id
    request.Districts, request.Pool, request.Count = Asked(rng)
    request.Districts = Listed(request, request.Districts)
    if request.Pool ~= nil then request.Pool = Listed(request, request.Pool) end
    if kind == "wonder" then request.Wonders = Some(rng, WONDERS, rng(2)) end
  end
  desc.kind, desc.request = kind, request
  local label = "case " .. n .. " " .. kind
  local result
  if kind == "single" then
    result = SDP_Solver.Solve(request)
  elseif kind == "wonder" then
    result = SDP_Multi.Solve(WonderRequest(request))
  else
    result = SDP_Multi.Solve(request)
  end
  T.ok(result.Ok, label .. ": " .. tostring(result.Error))
  T.ok(not result.Stats.Mismatch, label .. ": the board and the full evaluation agree")
  if kind == "wonder" then Compare(label, request, result, w) end
end

for n = 1, CASES do
  local seed = SEED * 1000 + n
  test("case " .. n .. " (seed " .. seed .. ")", function()
    if KNOWN[n] then T.skip(KNOWN[n]) end
    local out = {}
    local ok, err = pcall(Run, n, out)
    -- The case, when it fails (an assertion or a plan invariant).
    if (not ok and not (type(err) == "table" and err.sdp_skip)) or #SDP_Invariants.Found > 0 then
      print("case " .. n .. " (seed " .. seed .. "): " .. Show(out.desc))
    end
    if not ok then error(err, 0) end
  end)
end
