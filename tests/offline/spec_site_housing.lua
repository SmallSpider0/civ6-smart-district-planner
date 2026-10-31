-- Offline: what the housing line of a city site's tooltip adds up (issue
-- 188). A site's housing counts the water housing, the first-era city-center
-- buildings (the granary) and the buildings of a planned harbor (lighthouse,
-- with Gathering Storm's +2 for a city on the coast, and seaport); the line
-- says how much of it comes from the water and how much from each building
-- once built, so "Housing 11" on a river site with a harbor reads as 5 from
-- water plus the buildings. Driven through the panel's own controls.
local test, T = ...

local UI_Mock = include("ui")

-- Our capital at (4, 7), inland. The north coast (row 2) has a river along
-- it: sites there have fresh water and the coast, and a harbor in reach.
local MAP = {
  "~~~~~~~~~~~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~",
  "~~....................",
  "~.....................",
  "~.....................",
  "~.....................",
  "~.....................",
  "~.....................",
  "~.....................",
  "~~~~~~~~~~~~~~~~~~~~~~",
}
local rivers = {}
for x = 2, 21 do rivers[#rivers + 1] = x .. ",2" end
World.New({
  rows = MAP, rivers = rivers, housingBuildings = true,
  cities = { { id = 1, x = 4, y = 7, population = 6, capital = true, radius = 1 } },
})
UI_Mock.Install()
include("SDP_Panel")

local HARBOR = "DISTRICT_HARBOR"
local c = UI_Mock.Controls

local function Row(sites, districtType)
  for _, r in ipairs(sites.State().View.Districts) do
    if r.Type == districtType then return r end
  end
  error("no row " .. districtType)
end

-- The housing the game gives, from its rules: water housing by kind, plus
-- each building's Housing and its owner-city housing modifiers that need only
-- a center next to the coast.
local function WaterHousing(kind)
  local p = GlobalParameters
  return (kind == "FRESH" and p.CITY_POPULATION_RIVER_LAKE) or (kind == "COAST" and p.CITY_POPULATION_COAST)
    or p.CITY_POPULATION_NO_WATER
end
local function Building(buildingType, coastal)
  local n = GameInfo.Buildings[buildingType].Housing or 0
  for link in GameInfo.BuildingModifiers() do
    local m = GameInfo.Modifiers[link.ModifierId]
    if link.BuildingType == buildingType and m.ModifierType == "MODIFIER_CITY_OWNER_ADJUST_BUILDING_HOUSING" and coastal then
      for a in GameInfo.ModifierArguments() do
        if a.ModifierId == link.ModifierId and a.Name == "Amount" then n = n + tonumber(a.Value) end
      end
    end
  end
  return n
end

test("the rules: granary, lighthouse with the coast bonus, seaport", function()
  T.eq(SDP_Land.CenterHousing(), GameInfo.Buildings.BUILDING_GRANARY.Housing, "the granary")
  T.eq(SDP_Land.BuildingHousing(HARBOR, true), Building("BUILDING_LIGHTHOUSE", true) + Building("BUILDING_SEAPORT", true),
    "the harbor's buildings")
  T.eq(Building("BUILDING_LIGHTHOUSE", true), 3, "lighthouse: 1 + 2 on the coast")
end)

test("a river site with a harbor: the tooltip splits its housing into water and buildings", function()
  SDP_Panel.Open()
  SDP_Panel.SelectTab("SITES")
  local sites = SDP_Panel.Sites
  -- The harbor required; nothing else picked.
  for _ = 1, 4 do
    if Row(sites, HARBOR).State == "MUST" then break end
    Row(sites, HARBOR).Cell:Click()
  end
  T.eq(Row(sites, HARBOR).State, "MUST", "harbor required")
  for _ = 1, 6 do c.SitesPlanLess:Click() end
  for _ = 1, 3 do c.SitesCountLess:Click() end
  c.SitesSolveButton:Click()
  SDP_Panel.RunTask(500)
  local result = sites.State().Result
  T.ok(result and result.Ok, "sites result: " .. tostring(result and result.Error))
  local checked = 0
  for s, site in ipairs(result.Solutions[1].Sites) do
    local hasHarbor = false
    for _, d in ipairs(site.Districts or {}) do
      if d.Type == HARBOR then hasHarbor = true end
    end
    local plot = Map.GetPlot(site.X, site.Y)
    local kind = site.Info.WaterKind
    local coastal = plot:IsCoastalLand()
    local water = WaterHousing(kind)
    local parts = { { "BUILDING_GRANARY", Building("BUILDING_GRANARY", coastal) } }
    if hasHarbor then
      parts[#parts + 1] = { "BUILDING_LIGHTHOUSE", Building("BUILDING_LIGHTHOUSE", coastal) }
      parts[#parts + 1] = { "BUILDING_SEAPORT", Building("BUILDING_SEAPORT", coastal) }
    end
    local total, list = water, {}
    for _, p in ipairs(parts) do
      total = total + p[2]
      list[#list + 1] = "LOC_SDP_SITES_HOUSING_PART(" .. GameInfo.Buildings[p[1]].Name .. "," .. p[2] .. ")"
    end
    T.eq(site.Info.Housing, total, "housing at " .. site.X .. "," .. site.Y)
    local tip = sites.State().View.Results[s].ToolTip
    local line = "LOC_SDP_SITES_HOUSING_BUILT(" .. total .. "," .. water .. "," .. table.concat(list, ", ") .. ")"
    T.ok(tip:find(line, 1, true), "the housing line: " .. line .. " in " .. tip)
    T.ok(tip:find("LOC_SDP_SITES_HOUSING(", 1, true) == nil, "no bare total")
    if hasHarbor and kind == "FRESH" and coastal then
      T.eq(total, 11, "the issue's case: 5 + granary 2 + lighthouse 3 + seaport 1")
      checked = checked + 1
    end
  end
  T.ok(checked > 0, "a river site on the coast with a harbor among the sites")
  SDP_Panel.Close()
end)
