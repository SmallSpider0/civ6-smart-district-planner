-- Offline: partner districts kept apart (SDP_Rules.Apart; 2026-10-21
-- feedback: the harbor and the commercial hub). The rule is read from the
-- trade route modifiers (the lighthouse's needs a city without a market);
-- picking from a pool never puts both in one city unless the count needs it;
-- required ones are never touched, only reported.
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

-- A coastal capital at (5, 2): a harbor next to the center (+2) and a
-- commercial hub next to the harbor (+2) beat any other pair on this bare
-- land, the pair a plain search picks.
local MAP = {
  "~~~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~",
  "~~~......~~~~~",
  "~~........~~~~",
  "~~........~~~~",
  "~~.........~~~",
  "~~.........~~~",
  "~~.........~~~",
  "~~~~~~~~~~~~~~",
}

local function NewWorld(extra)
  local spec = { rows = MAP, cities = { { id = 1, x = 5, y = 2, population = 7, capital = true } } }
  for k, v in pairs(extra or {}) do spec[k] = v end
  return World.New(spec)
end

local ONES = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }
local HUB, HARBOR = "DISTRICT_COMMERCIAL_HUB", "DISTRICT_HARBOR"
local POOL = { "DISTRICT_CAMPUS", HUB, HARBOR, "DISTRICT_HOLY_SITE" }

local function Has(plan, districtType)
  for _, p in ipairs(plan) do
    if p.Type == districtType then return true end
  end
  return false
end

local function Single(extra)
  local request = { PlayerID = 0, CityID = 1, Districts = {}, Pool = POOL, Count = 2, Weights = ONES, Tier = "STANDARD" }
  for k, v in pairs(extra or {}) do request[k] = v end
  return SDP_Solver.Solve(request)
end

test("the rule comes from the trade route modifiers; a unique harbor counts as a harbor", function()
  NewWorld()
  local apart = SDP_Rules.Apart()
  T.eq(#apart.Pairs, 1, "one pair")
  local pair = apart.Pairs[1]
  T.same({ pair.A, pair.B, pair.Building, pair.Other }, { HARBOR, HUB, "BUILDING_LIGHTHOUSE", "BUILDING_MARKET" }, "the pair")
  T.ok(apart.Partners[HARBOR][HUB] and apart.Partners[HUB][HARBOR], "both ways")
  T.ok(apart.Partners.DISTRICT_COTHON[HUB] and apart.Partners[HUB].DISTRICT_COTHON, "the cothon stands for the harbor")
  T.eq(apart.Partners.DISTRICT_CAMPUS, nil, "others have no partner")
  T.eq(#SDP_Rules.Together({ HARBOR, "DISTRICT_CAMPUS" }), 0, "one of them: none")
  T.eq(#SDP_Rules.Together({ "DISTRICT_COTHON", HUB }), 1, "a unique one counts")
  T.eq(#SDP_Rules.Together({ "DISTRICT_CAMPUS" }, { [HARBOR] = true, [HUB] = true }), 0, "a pair the city had already is not the plan's")
  T.eq(#SDP_Rules.Together({ HUB }, { [HARBOR] = true }), 1, "the plan adds the second one")
end)

test("single city: off, the search picks both; on, no solution has both and the best allowed is found", function()
  NewWorld()
  local off = Single({ Apart = false })
  T.ok(off.Ok, tostring(off.Error))
  T.ok(Has(off.Plan, HUB) and Has(off.Plan, HARBOR), "off: the harbor and the hub together (the map makes them best)")
  T.eq(off.Together, nil, "off: nothing reported")
  local on = Single()
  T.ok(on.Ok, tostring(on.Error))
  for n, sol in ipairs(on.Solutions) do
    T.ok(not (Has(sol.Plan, HUB) and Has(sol.Plan, HARBOR)), "solution " .. n .. " keeps them apart")
    T.eq(#sol.Together, 0, "solution " .. n .. ": nothing together")
  end
  T.ok(on.Gain <= off.Gain + 1e-9, "the rule costs adjacency here")
  -- Not worse than any allowed pair solved directly.
  for a = 1, #POOL do
    for b = a + 1, #POOL do
      local pair = { POOL[a], POOL[b] }
      if not (pair[1] == HUB and pair[2] == HARBOR) then
        local direct = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = pair, Weights = ONES, Tier = "FINE" })
        T.ok(on.Gain >= direct.Gain - 1e-9, string.format("%s+%s: %.2f >= %.2f", pair[1], pair[2], on.Gain, direct.Gain))
      end
    end
  end
  local again = Single()
  T.eq(again.Gain, on.Gain, "deterministic")
  T.same(again.Picked, on.Picked, "same picks")
end)

test("single city: a required hub keeps the harbor out of the picks; a pinned harbor keeps the hub out", function()
  NewWorld()
  local required = Single({ Districts = { HUB }, Pool = { "DISTRICT_CAMPUS", HARBOR, "DISTRICT_HOLY_SITE" } })
  T.ok(required.Ok, tostring(required.Error))
  T.ok(Has(required.Plan, HUB), "the hub is placed")
  T.ok(not Has(required.Plan, HARBOR), "the harbor is not picked")
  -- A harbor pin next to the city center.
  local world = NewWorld({ pins = { { 5, 1, "ICON_DISTRICT_HARBOR", "1" } } })
  T.ok(SDP_City.PresentDistricts(SDP_City.Scan(0, 1))[HARBOR], "the pin counts as the city's harbor")
  local pinned = Single({ Pool = { "DISTRICT_CAMPUS", HUB, "DISTRICT_HOLY_SITE" }, Count = 1 })
  T.ok(pinned.Ok, tostring(pinned.Error))
  T.ok(not Has(pinned.Plan, HUB), "the hub is not picked: " .. table.concat(pinned.Picked, ","))
  T.ok(world ~= nil, "world")
end)

test("single city: when only the pair fills the count it is picked, and reported", function()
  NewWorld()
  local result = Single({ Pool = { HUB, HARBOR } })
  T.ok(result.Ok, tostring(result.Error))
  T.ok(Has(result.Plan, HUB) and Has(result.Plan, HARBOR), "both, the count needs them")
  T.eq(#result.Together, 1, "reported")
  T.eq(result.Together[1].Building, "BUILDING_LIGHTHOUSE", "the lighthouse loses its route")
  local both = SDP_Solver.Solve({ PlayerID = 0, CityID = 1, Districts = { HUB, HARBOR }, Weights = ONES })
  T.ok(Has(both.Plan, HUB) and Has(both.Plan, HARBOR), "required ones are placed as asked")
  T.eq(#both.Together, 1, "and reported")
end)

test("several cities: no city picks both; with the rule off one does", function()
  -- A second coastal city-center pin to the south-east.
  NewWorld({ pins = { { 9, 6, "ICON_DISTRICT_CITY_CENTER", "" } } })
  local function Run(apart)
    return SDP_Multi.Solve({ PlayerID = 0, Tier = "FAST", Districts = {}, Pool = POOL, Count = 2, Weights = ONES,
      Existing = { [1] = true }, Apart = apart })
  end
  local on = Run(nil)
  T.ok(on.Ok, tostring(on.Error))
  T.ok(not on.Stats.Mismatch, "board and full evaluation agree")
  for _, city in ipairs(on.Cities) do
    local types = {}
    for _, p in ipairs(on.Plan) do
      if p.City == city.Key then types[#types + 1] = p.Type end
    end
    T.eq(#SDP_Rules.Together(types), 0, city.Key .. ": " .. table.concat(types, ","))
    T.eq(#city.Together, 0, city.Key .. ": nothing together")
  end
  local off = Run(false)
  T.ok(off.Ok, tostring(off.Error))
  local together = 0
  for _, city in ipairs(off.Cities) do
    local types = {}
    for _, p in ipairs(off.Plan) do
      if p.City == city.Key then types[#types + 1] = p.Type end
    end
    together = together + #SDP_Rules.Together(types)
  end
  T.ok(together > 0, "off: some city has both")
end)
