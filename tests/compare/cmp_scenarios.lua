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
-- districts such as the Government Plaza may go to only one of them).

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

local seed = 1000
for n, entry in ipairs(SINGLE) do
  local civKey, biome, extra = entry[1], entry[2], entry[3] or {}
  for _, stage in ipairs({ "early", "mid", "late" }) do
    seed = seed + 7
    local civ = CIVS[civKey]
    local req = Request(stage, biome, civKey)
    local s = {
      id = string.format("S%02d-%s-%s-%s", n, civKey, biome, stage), kind = "single", title = civ[3],
      seed = seed, biome = biome, civKey = civKey, civ = civ[1], leader = civ[2], stage = stage,
      cities = 1, districts = req.districts, built = { req.built }, population = req.population,
      foreign = extra.foreign, cityState = extra.cityState, naturalWonder = extra.naturalWonder,
    }
    -- Pins the player placed by hand, on every third situation.
    if n % 3 == 0 and stage ~= "early" then
      s.pins = { { icon = "ICON_DISTRICT_NEIGHBORHOOD", ring = 2 }, { icon = "ICON_DISTRICT_WONDER", ring = 2 } }
    end
    -- Part of the map not explored yet, on every fourth.
    if n % 4 == 1 and stage == "early" then s.hidden = 0.35 end
    -- Same input twice: is the plan the same (requirement: deterministic)?
    s.runs = Runs("single", (n % 6 == 0 and stage == "mid") and {
      { planner = "sdp", variant = "STANDARD#2" }, { planner = "amt", variant = "#2" }, { planner = "ep", variant = "#2" },
    } or nil)
    Add(s)
  end
end

-- Multi-city situations.
local MULTI = {
  { "rome", "temperate", 3, "mid" }, { "rome", "coastal", 4, "late" }, { "japan", "temperate", 3, "late" },
  { "korea", "highland", 3, "mid" }, { "germany", "temperate", 4, "mid" }, { "brazil", "jungle", 3, "late" },
  { "netherlands", "temperate", 3, "late" }, { "gaul", "highland", 3, "mid" }, { "indonesia", "island", 3, "mid" },
  { "egypt", "desert", 3, "late" }, { "russia", "tundra", 4, "mid" }, { "maya", "jungle", 4, "late" },
}
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
    id = string.format("M%02d-%s-%s-%dc-%s", n, civKey, biome, count, stage), kind = "multi", title = civ[3],
    seed = seed, biome = biome, civKey = civKey, civ = civ[1], leader = civ[2], stage = stage, cities = count,
    districts = districts, built = built, population = stage == "late" and 19 or 16, samePopulation = true,
    runs = Runs("multi"),
  })
end

CmpScenarios.List = list
CmpScenarios.ById = byId
return CmpScenarios
