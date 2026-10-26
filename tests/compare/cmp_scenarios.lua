-- cmp_scenarios.lua: the situations the planners are compared on.
--
-- Each scenario is a game situation a player meets: a civilization (many
-- with district rules of their own), a biome, a stage of the game (how big
-- the city is, what it owns and has built), the districts the player wants
-- and what else is around (neighbours, a natural wonder, pins placed by
-- hand, unexplored tiles). Districts are named by their base type; each
-- planner gets the civilization's own replacement (Seowon for Campus, ...).
--
-- kind = "single": one city. kind = "multi": three or four of the player's
-- cities planned together (every city wants the same list; one-per-empire
-- districts such as the Government Plaza may go to only one of them; the
-- coverage set "V" gives each city its own list, `plans`).

CmpScenarios = {}

local CIVS = {
  rome = { "CIVILIZATION_ROME", "LEADER_TRAJAN", "no special district rules" },
  japan = { "CIVILIZATION_JAPAN", "LEADER_HOJO", "districts +1 per adjacent district" },
  korea = { "CIVILIZATION_KOREA", "LEADER_SEONDEOK", "Seowon: loses yield next to districts" },
  germany = { "CIVILIZATION_GERMANY", "LEADER_BARBAROSSA", "Hansa: commercial hub and resource adjacency" },
  brazil = { "CIVILIZATION_BRAZIL", "LEADER_PEDRO", "rainforest adjacency" },
  netherlands = { "CIVILIZATION_NETHERLANDS", "LEADER_WILHELMINA", "river adjacency" },
  gaul = { "CIVILIZATION_GAUL", "LEADER_AMBIORIX", "no specialty district next to the city center; mine adjacency" },
  vietnam = { "CIVILIZATION_VIETNAM", "LEADER_LADY_TRIEU", "specialty districts only on woods, rainforest, marsh" },
  greece = { "CIVILIZATION_GREECE", "LEADER_PERICLES", "Acropolis on hills" },
  mali = { "CIVILIZATION_MALI", "LEADER_MANSA_MUSA", "Suguba; desert city center" },
  russia = { "CIVILIZATION_RUSSIA", "LEADER_PETER_GREAT", "Lavra" },
  indonesia = { "CIVILIZATION_INDONESIA", "LEADER_GITARJA", "coast adjacency" },
  egypt = { "CIVILIZATION_EGYPT", "LEADER_CLEOPATRA", "districts on floodplains" },
  byzantium = { "CIVILIZATION_BYZANTIUM", "LEADER_THEODORA", "farm adjacency for holy sites" },
  kongo = { "CIVILIZATION_KONGO", "LEADER_MVEMBA", "Mbanza; no holy site" },
  australia = { "CIVILIZATION_AUSTRALIA", "LEADER_JOHN_CURTIN", "appeal" },
  maya = { "CIVILIZATION_MAYA", "LEADER_LADY_SIX_SKY", "Observatory: farm and plantation adjacency" },
}
CmpScenarios.CIVS = CIVS

-- Single-city situations: civ, biome, and what is special about the place.
local SINGLE = {
  { "rome", "temperate" }, { "rome", "coastal", { foreign = true } }, { "rome", "desert" },
  { "japan", "coastal" }, { "japan", "temperate", { naturalWonder = "FEATURE_DEVILSTOWER" } },
  { "korea", "temperate" }, { "korea", "highland" },
  { "germany", "temperate", { cityState = true } },
  { "brazil", "jungle" }, { "netherlands", "temperate" }, { "gaul", "highland" },
  { "vietnam", "jungle" }, { "greece", "highland", { naturalWonder = "FEATURE_KILIMANJARO" } },
  { "mali", "desert" }, { "russia", "tundra" }, { "indonesia", "island" }, { "egypt", "desert" },
  { "byzantium", "temperate" }, { "kongo", "jungle" }, { "australia", "coastal" }, { "maya", "jungle" },
  { "rome", "volcanic" }, { "japan", "volcanic", { foreign = true } }, { "netherlands", "coastal" },
}

local COASTAL = { coastal = true, island = true }

-- What the player asks for at each stage (base types) and what is built.
local function Request(stage, biome, civ)
  local holy = civ ~= "kongo"
  if stage == "early" then
    return { districts = holy and { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE" } or { "DISTRICT_CAMPUS", "DISTRICT_THEATER" },
      built = {}, population = 5 }
  elseif stage == "mid" then
    local list = { "DISTRICT_CAMPUS", "DISTRICT_THEATER", "DISTRICT_COMMERCIAL_HUB", "DISTRICT_INDUSTRIAL_ZONE" }
    if COASTAL[biome] then list[#list + 1] = "DISTRICT_HARBOR" end
    return { districts = list, built = { holy and "DISTRICT_HOLY_SITE" or "DISTRICT_ENCAMPMENT" }, population = 16 }
  else
    local list = { "DISTRICT_CAMPUS", "DISTRICT_THEATER", "DISTRICT_INDUSTRIAL_ZONE", "DISTRICT_ENTERTAINMENT_COMPLEX",
      "DISTRICT_GOVERNMENT", "DISTRICT_AQUEDUCT" }
    if COASTAL[biome] then list[#list + 1] = "DISTRICT_HARBOR" else list[#list + 1] = "DISTRICT_ENCAMPMENT" end
    if biome == "desert" then list[#list + 1] = "DISTRICT_DAM" end
    return { districts = list, built = { holy and "DISTRICT_HOLY_SITE" or "DISTRICT_CAMPUS", "DISTRICT_COMMERCIAL_HUB" },
      population = 25 }
  end
end

local function Runs(kind, extra)
  local runs = {}
  for _, tier in ipairs({ "FAST", "STANDARD", "FINE" }) do runs[#runs + 1] = { planner = "sdp", variant = tier } end
  runs[#runs + 1] = { planner = "sdp", variant = "STANDARD_LAND" } -- the panel's default: land part on
  if kind == "multi" then runs[#runs + 1] = { planner = "sdp", variant = "CITY_BY_CITY" } end
  -- Competitors twice: with the comparison's weights (all yields 1, as our
  -- planner and the judge use; their panels cannot set this) and with the
  -- settings their panel sends by default (what a player actually gets).
  runs[#runs + 1] = { planner = "amt", variant = "" }
  runs[#runs + 1] = { planner = "ep", variant = "" }
  if kind == "single" then
    runs[#runs + 1] = { planner = "amt", variant = "DEFAULTW" }
    runs[#runs + 1] = { planner = "ep", variant = "DEFAULT" }
  end
  for _, r in ipairs(extra or {}) do runs[#runs + 1] = r end
  return runs
end

local list, byId = {}, {}
local function Add(s)
  list[#list + 1] = s
  byId[s.id] = s
end

-- Multi-city situations.
local MULTI = {
  { "rome", "temperate", 3, "mid" }, { "rome", "coastal", 4, "late" }, { "japan", "temperate", 3, "late" },
  { "korea", "highland", 3, "mid" }, { "germany", "temperate", 4, "mid" }, { "brazil", "jungle", 3, "late" },
  { "netherlands", "temperate", 3, "late" }, { "gaul", "highland", 3, "mid" }, { "indonesia", "island", 3, "mid" },
  { "egypt", "desert", 3, "late" }, { "russia", "tundra", 4, "mid" }, { "maya", "jungle", 4, "late" },
}

-- One set of situations: 72 single-city ("<S>nn-civ-biome-stage") and 12
-- multi-city ("<M>nn-...") ones from `seed`. The development set ("S", "M",
-- seed 1000) is what the planners were debugged on; the held-out set ("HS",
-- "HM", seed 50000) has new maps nobody looked at while changing a planner
-- (docs/multicity-design.md 18.1, item 5).
local function BuildSet(prefixS, prefixM, seed, repeats)
  for n, entry in ipairs(SINGLE) do
    local civKey, biome, extra = entry[1], entry[2], entry[3] or {}
    for _, stage in ipairs({ "early", "mid", "late" }) do
      seed = seed + 7
      local civ = CIVS[civKey]
      local req = Request(stage, biome, civKey)
      local s = {
        id = string.format("%s%02d-%s-%s-%s", prefixS, n, civKey, biome, stage), kind = "single", title = civ[3],
        seed = seed, biome = biome, civKey = civKey, civ = civ[1], leader = civ[2], stage = stage,
        cities = 1, districts = req.districts, built = { req.built }, population = req.population,
        foreign = extra.foreign, cityState = extra.cityState, naturalWonder = extra.naturalWonder, set = prefixS,
      }
      -- Pins the player placed by hand, on every third situation.
      if n % 3 == 0 and stage ~= "early" then
        s.pins = { { icon = "ICON_DISTRICT_NEIGHBORHOOD", ring = 2 }, { icon = "ICON_DISTRICT_WONDER", ring = 2 } }
      end
      -- Part of the map not explored yet, on every fourth.
      if n % 4 == 1 and stage == "early" then s.hidden = 0.35 end
      -- Same input twice: is the plan the same (requirement: deterministic)?
      s.runs = Runs("single", (repeats and n % 6 == 0 and stage == "mid") and {
        { planner = "sdp", variant = "STANDARD#2" }, { planner = "amt", variant = "#2" }, { planner = "ep", variant = "#2" },
      } or nil)
      Add(s)
    end
  end
  for n, entry in ipairs(MULTI) do
    local civKey, biome, count, stage = entry[1], entry[2], entry[3], entry[4]
    seed = seed + 11
    local civ = CIVS[civKey]
    local districts = { "DISTRICT_CAMPUS", "DISTRICT_THEATER", "DISTRICT_COMMERCIAL_HUB", "DISTRICT_GOVERNMENT" }
    if stage == "late" then
      districts = { "DISTRICT_CAMPUS", "DISTRICT_THEATER", "DISTRICT_COMMERCIAL_HUB", "DISTRICT_INDUSTRIAL_ZONE",
        "DISTRICT_GOVERNMENT" }
    end
    if civKey ~= "kongo" and stage == "mid" then districts[#districts + 1] = "DISTRICT_HOLY_SITE" end
    local built = {}
    for c = 1, count do built[c] = {} end
    Add({
      id = string.format("%s%02d-%s-%s-%dc-%s", prefixM, n, civKey, biome, count, stage), kind = "multi", title = civ[3],
      seed = seed, biome = biome, civKey = civKey, civ = civ[1], leader = civ[2], stage = stage, cities = count,
      districts = districts, built = built, population = stage == "late" and 19 or 16, samePopulation = true,
      runs = Runs("multi"), set = prefixM,
    })
  end
end

BuildSet("S", "M", 1000, true)
BuildSet("HS", "HM", 50000, false)

-- Small multi-city situations with a provable optimum (issue 48): two or
-- three cities, six districts in all, none limited to one per empire, so
-- the exact reference (sdp:ORACLE, cmp_oracle.lua) can search every layout.
-- Two cities want a campus, a theater square and a commercial hub each;
-- three cities a campus and a commercial hub (an industrial zone where the
-- civilization has no holy site rule to show). "OMnn-civ-biome-Nc".
local SMALL_MULTI = {
  { "rome", "temperate", 2 }, { "japan", "temperate", 2 }, { "korea", "highland", 2 }, { "germany", "temperate", 3 },
  { "brazil", "jungle", 2 }, { "netherlands", "temperate", 3 }, { "gaul", "highland", 2 }, { "indonesia", "island", 2 },
  { "egypt", "desert", 3 }, { "russia", "tundra", 2 }, { "maya", "jungle", 3 }, { "byzantium", "temperate", 2 },
  { "japan", "coastal", 3 }, { "rome", "volcanic", 2 }, { "mali", "desert", 2 }, { "vietnam", "jungle", 2 },
}
local omseed = 70000
for n, entry in ipairs(SMALL_MULTI) do
  local civKey, biome, count = entry[1], entry[2], entry[3]
  omseed = omseed + 23
  local civ = CIVS[civKey]
  local districts = count == 2 and { "DISTRICT_CAMPUS", "DISTRICT_THEATER", "DISTRICT_COMMERCIAL_HUB" }
    or { "DISTRICT_CAMPUS", n % 2 == 0 and "DISTRICT_INDUSTRIAL_ZONE" or "DISTRICT_COMMERCIAL_HUB" }
  local built = {}
  for c = 1, count do built[c] = {} end
  Add({
    id = string.format("OM%02d-%s-%s-%dc", n, civKey, biome, count), kind = "multi", title = civ[3] .. "; small",
    seed = omseed, biome = biome, civKey = civKey, civ = civ[1], leader = civ[2], stage = "mid", cities = count,
    districts = districts, built = built, population = 16, samePopulation = true, set = "OM",
    runs = Runs("multi", { { planner = "sdp", variant = "ORACLE" } }),
  })
end

-- A wonder that must stand next to an improvement (issue 51): the Temple of
-- Artemis next to a Camp. One city, mid game, camp resources (deer, furs,
-- ivory, truffles as the biome allows) placed near the city and no camp
-- built yet, so a planner has to plan one with the wonder; half the scenes
-- also want the Great Library (next to a campus). "WAnn-civ-biome".
local ARTEMIS = {
  { "rome", "temperate", 2 }, { "russia", "tundra", 2 }, { "brazil", "jungle", 1 }, { "germany", "temperate", 1 },
  { "japan", "coastal", 2 }, { "korea", "highland", 1 }, { "maya", "jungle", 2 }, { "netherlands", "temperate", 1 },
}
local aseed = 90000
for n, entry in ipairs(ARTEMIS) do
  local civKey, biome, camps = entry[1], entry[2], entry[3]
  aseed = aseed + 17
  local civ = CIVS[civKey]
  local req = Request("mid", biome, civKey)
  local wonders = { "BUILDING_TEMPLE_ARTEMIS" }
  if n % 2 == 0 then wonders[#wonders + 1] = "BUILDING_GREAT_LIBRARY" end
  Add({
    id = string.format("WA%02d-%s-%s", n, civKey, biome), kind = "single", title = civ[3] .. "; Temple of Artemis",
    seed = aseed, biome = biome, civKey = civKey, civ = civ[1], leader = civ[2], stage = "mid", cities = 1,
    districts = req.districts, built = { req.built }, population = req.population, wantWonders = wonders,
    campResources = camps, set = "WA",
    runs = { { planner = "sdp", variant = "STANDARD" }, { planner = "sdp", variant = "STANDARD_LAND" },
      { planner = "amt", variant = "" }, { planner = "ep", variant = "" } },
  })
end

-- Weight profiles (18.1, item 4): the development single-city situations
-- with one yield weighted 3 and the others 1 ("S01-...~SCI"); the judge
-- weighs the same way. The competitors get the same weights injected.
local PROFILES = { { "SCI", "YIELD_SCIENCE" }, { "PROD", "YIELD_PRODUCTION" }, { "FAITH", "YIELD_FAITH" } }
local base = {}
for _, s in ipairs(list) do
  if s.set == "S" then base[#base + 1] = s end
end
for _, profile in ipairs(PROFILES) do
  for _, b in ipairs(base) do
    local s = {}
    for k, v in pairs(b) do s[k] = v end
    s.id = b.id .. "~" .. profile[1]
    s.weights = { [profile[2]] = 3 }
    s.profile = profile[1]
    s.set = "W" .. profile[1]
    s.runs = { { planner = "sdp", variant = "STANDARD" }, { planner = "amt", variant = "" }, { planner = "ep", variant = "" } }
    Add(s)
  end
end

-- Wonders with the districts (one city, mid game): two wonders that suit
-- the biome and that a city there can have, some of which need a district
-- next to them (Great Library: campus; Colossus, Great Lighthouse: harbor;
-- Forbidden City, St. Basil's: city center). Wonders that need something
-- the scenario does not give (a founded religion for Mahabodhi, Stone for
-- Stonehenge, a mountain for Machu Picchu, an encampment for the Terracotta
-- Army) were dropped: no planner could place them, so they compared nothing.
-- "Wnn-civ-biome".
local WONDERS = {
  temperate = { "BUILDING_HANGING_GARDENS", "BUILDING_GREAT_LIBRARY" },
  coastal = { "BUILDING_COLOSSUS", "BUILDING_GREAT_LIBRARY" },
  island = { "BUILDING_COLOSSUS", "BUILDING_GREAT_LIGHTHOUSE" },
  desert = { "BUILDING_PYRAMIDS", "BUILDING_PETRA" },
  jungle = { "BUILDING_CHICHEN_ITZA", "BUILDING_GREAT_LIBRARY" },
  highland = { "BUILDING_POTALA_PALACE", "BUILDING_ORACLE" },
  tundra = { "BUILDING_ST_BASILS_CATHEDRAL", "BUILDING_FORBIDDEN_CITY" },
  volcanic = { "BUILDING_FORBIDDEN_CITY", "BUILDING_ORACLE" },
}
local wseed = 30000
for n, entry in ipairs(SINGLE) do
  local civKey, biome, extra = entry[1], entry[2], entry[3] or {}
  wseed = wseed + 13
  local civ = CIVS[civKey]
  local req = Request("mid", biome, civKey)
  Add({
    id = string.format("W%02d-%s-%s", n, civKey, biome), kind = "single", title = civ[3] .. "; wonders", seed = wseed,
    biome = biome, civKey = civKey, civ = civ[1], leader = civ[2], stage = "mid", cities = 1, districts = req.districts,
    built = { req.built }, population = req.population, foreign = extra.foreign, cityState = extra.cityState,
    naturalWonder = extra.naturalWonder, wantWonders = WONDERS[biome], set = "W",
    runs = { { planner = "sdp", variant = "STANDARD" }, { planner = "sdp", variant = "STANDARD_LAND" },
      { planner = "amt", variant = "" }, { planner = "ep", variant = "" } },
  })
end

-- New city sites (Empire Planner also picks them; AMT does not): the
-- capital at mid game, the land around revealed, two sites wanted within
-- 8 plots, scored with three districts. "Cnn-civ-biome".
local SITES = {
  { "rome", "temperate" }, { "japan", "coastal" }, { "korea", "highland" }, { "brazil", "jungle" },
  { "netherlands", "temperate" }, { "mali", "desert" }, { "russia", "tundra" }, { "indonesia", "island" },
  { "egypt", "desert" }, { "gaul", "highland" }, { "maya", "jungle" }, { "germany", "volcanic" },
}
local cseed = 40000
for n, entry in ipairs(SITES) do
  local civKey, biome = entry[1], entry[2]
  cseed = cseed + 17
  local civ = CIVS[civKey]
  Add({
    id = string.format("C%02d-%s-%s", n, civKey, biome), kind = "sites", title = civ[3] .. "; new city sites",
    seed = cseed, biome = biome, civKey = civKey, civ = civ[1], leader = civ[2], stage = "mid", cities = 1,
    districts = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_COMMERCIAL_HUB" }, built = { {} }, population = 10,
    sites = { count = 2, distance = 5 }, set = "C",
    runs = { { planner = "sdp", variant = "STANDARD" }, { planner = "ep", variant = "" } },
  })
end

-- Coverage (design 19.5): late game, three or four cities, each with its own
-- list. Only one or two of them want an industrial zone or an entertainment
-- complex, so where those go decides how many cities they reach (Factory,
-- Zoo: Buildings.RegionalRange). Odd n: the capital wants both; even n: the
-- capital the industrial zone, the second city the entertainment complex.
-- The other cities want a campus, a commercial hub and a theater square.
-- Empire Planner cannot take a list per city and does not count district
-- reach, so it does not take part. "Vnn-civ-biome-Nc".
local vseed = 60000
for n, entry in ipairs(MULTI) do
  local civKey, biome, count = entry[1], entry[2], entry[3]
  vseed = vseed + 19
  local civ = CIVS[civKey]
  local others = { "DISTRICT_CAMPUS", "DISTRICT_COMMERCIAL_HUB", "DISTRICT_THEATER" }
  local plans = {}
  if n % 2 == 1 then
    plans[1] = { "DISTRICT_CAMPUS", "DISTRICT_THEATER", "DISTRICT_COMMERCIAL_HUB", "DISTRICT_INDUSTRIAL_ZONE",
      "DISTRICT_ENTERTAINMENT_COMPLEX" }
    for c = 2, count do plans[c] = others end
  else
    plans[1] = { "DISTRICT_CAMPUS", "DISTRICT_COMMERCIAL_HUB", "DISTRICT_INDUSTRIAL_ZONE" }
    plans[2] = { "DISTRICT_THEATER", "DISTRICT_CAMPUS", "DISTRICT_ENTERTAINMENT_COMPLEX" }
    for c = 3, count do plans[c] = others end
  end
  local union, seen = {}, {}
  for c = 1, count do
    for _, t in ipairs(plans[c]) do
      if not seen[t] then
        seen[t] = true
        union[#union + 1] = t
      end
    end
  end
  local built = {}
  for c = 1, count do built[c] = {} end
  Add({
    id = string.format("V%02d-%s-%s-%dc", n, civKey, biome, count), kind = "multi", title = civ[3] .. "; reach",
    seed = vseed, biome = biome, civKey = civKey, civ = civ[1], leader = civ[2], stage = "late", cities = count,
    districts = union, plans = plans, built = built, population = 19, samePopulation = true, set = "V",
    runs = { { planner = "sdp", variant = "STANDARD" }, { planner = "sdp", variant = "STANDARD_COV1" },
      { planner = "sdp", variant = "STANDARD_COV3" }, { planner = "sdp", variant = "FINE" },
      { planner = "sdp", variant = "FINE_COV1" }, { planner = "sdp", variant = "FINE_COV3" },
      { planner = "amt", variant = "" } },
  })
end

-- The true-optimum benchmark (issue 48). Every kind of situation comes in
-- three parts: development (tune on these), held-out (check after each
-- change) and sealed ("F", new seeds, run only for releases and published
-- evaluations so that numbers are not tuned to it).
BuildSet("FS", "FM", 90000, false)

-- More small multi-city situations (see OM01-OM16 above): two to four
-- cities, six to eight districts in all. OM17-OM32 join the development
-- set; HOM and FOM are the held-out and sealed parts.
local SMALL_MULTI_MORE = {
  { "rome", "coastal", 4 }, { "korea", "temperate", 3 }, { "germany", "highland", 2 }, { "greece", "highland", 3 },
  { "netherlands", "coastal", 2 }, { "australia", "coastal", 3 }, { "japan", "volcanic", 4 }, { "kongo", "jungle", 2 },
  { "egypt", "desert", 2 }, { "russia", "tundra", 3 }, { "indonesia", "island", 3 }, { "maya", "jungle", 2 },
  { "byzantium", "temperate", 4 }, { "mali", "desert", 3 }, { "brazil", "jungle", 4 }, { "gaul", "highland", 3 },
}
local function SmallMulti(prefix, first, seed, entries)
  for x, entry in ipairs(entries) do
    local n = first + x - 1
    local civKey, biome, count = entry[1], entry[2], entry[3]
    seed = seed + 23
    local civ = CIVS[civKey]
    local holy = civKey ~= "kongo"
    local districts
    if count == 2 then
      districts = { "DISTRICT_CAMPUS", "DISTRICT_THEATER", n % 2 == 0 and "DISTRICT_INDUSTRIAL_ZONE" or "DISTRICT_COMMERCIAL_HUB" }
    elseif count == 3 then
      districts = { "DISTRICT_CAMPUS", n % 2 == 0 and "DISTRICT_INDUSTRIAL_ZONE" or "DISTRICT_COMMERCIAL_HUB" }
    else
      districts = { holy and n % 2 == 0 and "DISTRICT_HOLY_SITE" or "DISTRICT_CAMPUS", "DISTRICT_COMMERCIAL_HUB" }
    end
    local built = {}
    for c = 1, count do built[c] = {} end
    Add({
      id = string.format("%s%02d-%s-%s-%dc", prefix, n, civKey, biome, count), kind = "multi", title = civ[3] .. "; small",
      seed = seed, biome = biome, civKey = civKey, civ = civ[1], leader = civ[2], stage = "mid", cities = count,
      districts = districts, built = built, population = 16, samePopulation = true, set = prefix,
      runs = Runs("multi", { { planner = "sdp", variant = "ORACLE" } }),
    })
  end
end
SmallMulti("OM", 17, 71000, SMALL_MULTI_MORE)
SmallMulti("HOM", 1, 72000, SMALL_MULTI)
SmallMulti("HOM", 17, 72500, SMALL_MULTI_MORE)
SmallMulti("FOM", 1, 73000, SMALL_MULTI)
SmallMulti("FOM", 17, 73500, SMALL_MULTI_MORE)

-- Random weights (issue 48): every development, held-out and sealed
-- single-city situation once more with each of the five yields weighted
-- 0-3, from the situation's seed ("S01-...~RND"), so the benchmark is not
-- tied to one objective. The competitors get the same weights injected.
local YIELD_ORDER = { "YIELD_SCIENCE", "YIELD_CULTURE", "YIELD_FAITH", "YIELD_GOLD", "YIELD_PRODUCTION" }
local randomBase = {}
for _, s in ipairs(list) do
  if (s.set == "S" or s.set == "HS" or s.set == "FS") and s.kind == "single" and s.weights == nil then
    randomBase[#randomBase + 1] = s
  end
end
for _, b in ipairs(randomBase) do
  local s = {}
  for k, v in pairs(b) do s[k] = v end
  local weights, total, x = {}, 0, b.seed % 9973
  for i, y in ipairs(YIELD_ORDER) do
    x = (x * 31 + 17 * i) % 9973
    weights[y] = x % 4
    total = total + weights[y]
  end
  if total == 0 then weights.YIELD_SCIENCE = 1 end
  s.id = b.id .. "~RND"
  s.weights = weights
  s.profile = "RND"
  s.set = "R" .. b.set
  s.runs = { { planner = "sdp", variant = "FAST" }, { planner = "sdp", variant = "STANDARD" }, { planner = "sdp", variant = "FINE" },
    { planner = "amt", variant = "" }, { planner = "ep", variant = "" }, { planner = "sdp", variant = "ORACLE" } }
  Add(s)
end

-- Three chosen districts plus an Aqueduct and a Government Plaza (issue 48):
-- the size District & Wonder Planner plans (at most three districts; it adds
-- an Aqueduct for every city and one Government Plaza by itself), so every
-- planner gets the same list. One city at mid game ("D3nn"), and two or three
-- cities with two chosen districts and an Aqueduct each ("DMnn"); "H" and "F"
-- in front for the held-out and sealed parts.
local TRIPLES = {
  { "DISTRICT_CAMPUS", "DISTRICT_COMMERCIAL_HUB", "DISTRICT_INDUSTRIAL_ZONE" },
  { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER" },
  { "DISTRICT_INDUSTRIAL_ZONE", "DISTRICT_COMMERCIAL_HUB", "DISTRICT_THEATER" },
  { "DISTRICT_CAMPUS", "DISTRICT_THEATER", "DISTRICT_ENTERTAINMENT_COMPLEX" },
}
local function DwpRuns(kind)
  return Runs(kind, { { planner = "dwp", variant = "" }, { planner = "dwp", variant = "DEFAULT" },
    { planner = "sdp", variant = "ORACLE" } })
end
local function ThreeDistricts(prefix, seed)
  for n, entry in ipairs(SINGLE) do
    local civKey, biome, extra = entry[1], entry[2], entry[3] or {}
    seed = seed + 7
    local civ = CIVS[civKey]
    local list = {}
    for _, t in ipairs(TRIPLES[(n - 1) % #TRIPLES + 1]) do
      if t == "DISTRICT_HOLY_SITE" and civKey == "kongo" then t = "DISTRICT_COMMERCIAL_HUB" end
      list[#list + 1] = t
    end
    list[#list + 1] = "DISTRICT_AQUEDUCT"
    list[#list + 1] = "DISTRICT_GOVERNMENT"
    Add({
      id = string.format("%s%02d-%s-%s", prefix, n, civKey, biome), kind = "single", title = civ[3] .. "; three districts",
      seed = seed, biome = biome, civKey = civKey, civ = civ[1], leader = civ[2], stage = "mid", cities = 1,
      districts = list, built = { {} }, population = 10, foreign = extra.foreign, cityState = extra.cityState,
      naturalWonder = extra.naturalWonder, set = prefix, runs = DwpRuns("single"),
    })
  end
end
ThreeDistricts("D3", 80000)
ThreeDistricts("HD3", 81000)
ThreeDistricts("FD3", 82000)
local function TwoEachMulti(prefix, seed)
  for x, entry in ipairs(SMALL_MULTI) do
    local civKey, biome, count = entry[1], entry[2], entry[3]
    seed = seed + 23
    local civ = CIVS[civKey]
    local pair = x % 2 == 0 and { "DISTRICT_CAMPUS", "DISTRICT_INDUSTRIAL_ZONE" }
      or { "DISTRICT_CAMPUS", "DISTRICT_COMMERCIAL_HUB" }
    local districts = { pair[1], pair[2], "DISTRICT_AQUEDUCT" }
    local built = {}
    for c = 1, count do built[c] = {} end
    Add({
      id = string.format("%s%02d-%s-%s-%dc", prefix, x, civKey, biome, count), kind = "multi",
      title = civ[3] .. "; two districts and an aqueduct each", seed = seed, biome = biome, civKey = civKey,
      civ = civ[1], leader = civ[2], stage = "mid", cities = count, districts = districts, built = built,
      population = 16, samePopulation = true, set = prefix, runs = DwpRuns("multi"),
    })
  end
end
TwoEachMulti("DM", 83000)
TwoEachMulti("HDM", 84000)
TwoEachMulti("FDM", 85000)


-- The harder parts of the true-optimum benchmark (issue 48), each in a
-- development, a held-out ("H") and a sealed ("F") part like the others.
--
-- Large cities ("Lnn-civ-biome"): one late-game city that asks for 9 to 12
-- districts at once (n mod 4: 9, 10, 11, 12), nothing built yet: the eight
-- of a full city (a Holy Site where the civilization may have one, else an
-- Encampment), then a Harbor where the sea is near, an Encampment, a
-- Neighborhood, a Dam in the desert, an Aerodrome and a Spaceport, in that
-- order, as many as the size takes. The population leaves a slot for each.
local function LargeCities(prefix, seed)
  for n, entry in ipairs(SINGLE) do
    local civKey, biome, extra = entry[1], entry[2], entry[3] or {}
    seed = seed + 7
    local civ = CIVS[civKey]
    local size = 9 + (n - 1) % 4
    local list = { "DISTRICT_CAMPUS", "DISTRICT_THEATER", "DISTRICT_COMMERCIAL_HUB", "DISTRICT_INDUSTRIAL_ZONE",
      civKey ~= "kongo" and "DISTRICT_HOLY_SITE" or "DISTRICT_ENCAMPMENT", "DISTRICT_ENTERTAINMENT_COMPLEX",
      "DISTRICT_GOVERNMENT", "DISTRICT_AQUEDUCT" }
    local extras = { COASTAL[biome] and "DISTRICT_HARBOR" or nil, "DISTRICT_ENCAMPMENT", "DISTRICT_NEIGHBORHOOD",
      biome == "desert" and "DISTRICT_DAM" or nil, "DISTRICT_AERODROME", "DISTRICT_SPACEPORT" }
    local seen = {}
    for _, t in ipairs(list) do seen[t] = true end
    for x = 1, 6 do
      local t = extras[x]
      if #list < size and t ~= nil and not seen[t] then
        seen[t] = true
        list[#list + 1] = t
      end
    end
    Add({
      id = string.format("%s%02d-%s-%s", prefix, n, civKey, biome), kind = "single",
      title = civ[3] .. "; " .. #list .. " districts", seed = seed, biome = biome, civKey = civKey, civ = civ[1],
      leader = civ[2], stage = "late", cities = 1, districts = list, built = { {} }, population = 3 * (#list - 1) + 1,
      foreign = extra.foreign, cityState = extra.cityState, naturalWonder = extra.naturalWonder, set = prefix,
      runs = Runs("single"),
    })
  end
end
LargeCities("L", 86000)
LargeCities("HL", 87000)
LargeCities("FL", 88000)

-- Picking from a pool ("Pnn-civ-biome"): one mid-game city (a Holy Site, or
-- for Kongo an Encampment, built) that must have a Campus and a Commercial
-- Hub and wants two more specialty districts (odd n) or three (even n) out
-- of a Theater Square, an Industrial Zone, an Entertainment Complex and a
-- Harbor where the sea is near (else an Encampment, or for Kongo an
-- Aerodrome): the panel's "pick from these" (SDP_Solver Pool and Count).
-- Only this mod's tiers take part; the other planners have no such choice.
local function PoolCities(prefix, seed)
  for n, entry in ipairs(SINGLE) do
    local civKey, biome, extra = entry[1], entry[2], entry[3] or {}
    seed = seed + 7
    local civ = CIVS[civKey]
    local req = Request("mid", biome, civKey)
    local fourth = COASTAL[biome] and "DISTRICT_HARBOR" or (civKey ~= "kongo" and "DISTRICT_ENCAMPMENT" or "DISTRICT_AERODROME")
    local pool = { "DISTRICT_THEATER", "DISTRICT_INDUSTRIAL_ZONE", "DISTRICT_ENTERTAINMENT_COMPLEX", fourth }
    local pick = n % 2 == 1 and 2 or 3
    Add({
      id = string.format("%s%02d-%s-%s", prefix, n, civKey, biome), kind = "single",
      title = civ[3] .. "; pick " .. pick .. " of 4", seed = seed, biome = biome, civKey = civKey, civ = civ[1],
      leader = civ[2], stage = "mid", cities = 1, districts = { "DISTRICT_CAMPUS", "DISTRICT_COMMERCIAL_HUB" },
      pool = pool, count = 2 + pick, built = { req.built }, population = req.population, foreign = extra.foreign,
      cityState = extra.cityState, naturalWonder = extra.naturalWonder, set = prefix,
      runs = { { planner = "sdp", variant = "FAST" }, { planner = "sdp", variant = "STANDARD" },
        { planner = "sdp", variant = "FINE" }, { planner = "sdp", variant = "STANDARD_LAND" } },
    })
  end
end
PoolCities("P", 89000)
PoolCities("HP", 89500)
PoolCities("FP", 95000)

-- Wonders with the districts: held-out and sealed parts of "W" (new maps,
-- the same wonders per biome).
local function WonderCities(prefix, seed)
  for n, entry in ipairs(SINGLE) do
    local civKey, biome, extra = entry[1], entry[2], entry[3] or {}
    seed = seed + 13
    local civ = CIVS[civKey]
    local req = Request("mid", biome, civKey)
    Add({
      id = string.format("%s%02d-%s-%s", prefix, n, civKey, biome), kind = "single", title = civ[3] .. "; wonders",
      seed = seed, biome = biome, civKey = civKey, civ = civ[1], leader = civ[2], stage = "mid", cities = 1,
      districts = req.districts, built = { req.built }, population = req.population, foreign = extra.foreign,
      cityState = extra.cityState, naturalWonder = extra.naturalWonder, wantWonders = WONDERS[biome], set = prefix,
      runs = { { planner = "sdp", variant = "STANDARD" }, { planner = "sdp", variant = "STANDARD_LAND" },
        { planner = "amt", variant = "" }, { planner = "ep", variant = "" } },
    })
  end
end
WonderCities("HW", 31000)
WonderCities("FW", 32000)

CmpScenarios.List = list
CmpScenarios.ById = byId
CmpScenarios.Runs = Runs -- for the scenes cmp_lib adds from files
CmpScenarios.Add = Add
return CmpScenarios
