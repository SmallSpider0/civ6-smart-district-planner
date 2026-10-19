-- @state SDP_Panel
-- SDP_Rules: ruleset, plannable districts, district adjacency table.
local test, T = ...

local pid = Game.GetLocalPlayer()

test("ruleset is one of the three", function()
  local known = { RULESET_STANDARD = true, RULESET_EXPANSION_1 = true, RULESET_EXPANSION_2 = true }
  T.ok(known[SDP_Rules.Ruleset()], "unexpected ruleset " .. tostring(SDP_Rules.Ruleset()))
end)

test("plannable districts: sorted, unique, no city center or wonder", function()
  local list = SDP_Rules.PlannableDistricts(pid)
  T.ok(#list >= 5, "too few districts: " .. #list)
  for i, d in ipairs(list) do
    local row = GameInfo.Districts[d.Type]
    T.ok(row ~= nil, d.Type .. " not in GameInfo")
    T.ok(not row.CityCenter, "city center listed")
    T.ok(d.Type ~= "DISTRICT_WONDER", "wonder pseudo-district listed")
    T.eq(d.Icon, "ICON_" .. d.Type, "icon")
    T.eq(d.Specialty, row.RequiresPopulation == true, d.Type .. " specialty flag")
    if i > 1 then T.ok(list[i - 1].Type < d.Type, "not strictly sorted at " .. d.Type) end
  end
end)

test("unique districts replace their base and other civs' uniques are absent", function()
  local listed = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do listed[d.Type] = true end
  local traits = MapTacks.PlayerTraits(pid)
  for row in GameInfo.Districts() do
    if row.TraitType ~= nil and not traits[row.TraitType] then
      T.ok(not listed[row.DistrictType], "another civ's unique listed: " .. row.DistrictType)
    end
  end
  for row in GameInfo.DistrictReplaces() do
    if listed[row.CivUniqueDistrictType] then
      T.ok(not listed[row.ReplacesDistrictType], "base district listed next to its unique: " .. row.ReplacesDistrictType)
    end
  end
end)

test("adjacency table holds every applicable district-to-district row", function()
  local adjacency = SDP_Rules.AdjacencyTable(pid)
  local checked = 0
  for link in GameInfo.District_Adjacencies() do
    local row = GameInfo.Adjacency_YieldChanges[link.YieldChangeId]
    local unconditional = row.PrereqTech == nil and row.PrereqCivic == nil
      and row.ObsoleteTech == nil and row.ObsoleteCivic == nil
    if unconditional and (row.OtherDistrictAdjacent or row.AdjacentDistrict) then
      local entry = adjacency[link.DistrictType]
      T.ok(entry ~= nil, link.DistrictType .. " missing")
      local bucket = row.OtherDistrictAdjacent and entry.Any or entry.From[row.AdjacentDistrict]
      T.ok(bucket ~= nil and (bucket[row.YieldType] or 0) ~= 0, row.ID .. " not counted")
      checked = checked + 1
    end
  end
  T.ok(checked > 0, "no rows checked")
end)

test("known Gathering Storm values", function()
  if SDP_Rules.Ruleset() ~= "RULESET_EXPANSION_2" then T.skip("not Gathering Storm") end
  local adjacency = SDP_Rules.AdjacencyTable(pid)
  -- Campus: +1 science per 2 adjacent districts.
  T.near(adjacency.DISTRICT_CAMPUS.Any.YIELD_SCIENCE, 0.5, 1e-9, "campus per district")
  -- Commercial hub: +0.5 gold per district, +2 more from a harbor.
  local gain = SDP_Rules.NeighbourGain(adjacency, "DISTRICT_COMMERCIAL_HUB", "DISTRICT_HARBOR")
  T.near(gain.YIELD_GOLD, 2.5, 1e-9, "commercial hub next to harbor")
  -- Industrial zone: +2 production from an aqueduct.
  gain = SDP_Rules.NeighbourGain(adjacency, "DISTRICT_INDUSTRIAL_ZONE", "DISTRICT_AQUEDUCT")
  T.near(gain.YIELD_PRODUCTION, 2.5, 1e-9, "industrial zone next to aqueduct")
end)

test("adjacency table is deterministic", function()
  T.same(SDP_Rules.AdjacencyTable(pid), SDP_Rules.AdjacencyTable(pid))
end)
