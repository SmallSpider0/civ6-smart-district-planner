-- @state SDP_Panel
-- @setup GameCore_Tuner tests/fixtures/suzerain_toronto.lua
-- Issue 197: with Toronto's suzerain bonus the planner reads the longer
-- regional range from the game's modifiers (SDP_Coverage.ExtraRanges).
-- Not a regular test (no test_ prefix): the setup gives the bonus for the
-- rest of the game, so run it alone on a throwaway game:
--   python3 -I tools/run_tests.py tests/bench/probe_regional_range.lua
local test, T = ...

local pid = Game.GetLocalPlayer()
local IZ, EC = "DISTRICT_INDUSTRIAL_ZONE", "DISTRICT_ENTERTAINMENT_COMPLEX"
local BONUS = "MINOR_CIV_TORONTO_REGIONAL_RANGE_BONUS"

test("the bonus's modifier is in play, owned by the player", function()
  local found = {}
  for _, id in ipairs(GameEffects.GetModifiers()) do
    local def = GameEffects.GetModifierDefinition(id)
    if def ~= nil and def.Id == BONUS then
      local owner = GameEffects.GetModifierOwner(id)
      found[#found + 1] = string.format("active=%s ownerPlayer=%s ownerType=%s",
        tostring(GameEffects.GetModifierActive(id)), tostring(GameEffects.GetObjectsPlayerId(owner)),
        tostring(GameEffects.GetObjectType(owner)))
    end
  end
  print("SDP_PROBE " .. BONUS .. ": " .. table.concat(found, "; "))
  T.ok(#found > 0, "the modifier is in GameEffects")
end)

test("the reach of the industrial zone and entertainment complex is 3 longer", function()
  if GameInfo.Districts[IZ] == nil then T.skip("no industrial zone") end
  local extra = SDP_Coverage.ExtraRanges(pid)
  T.eq(extra[IZ], 3, "industrial zone")
  T.eq(extra[EC], 3, "entertainment complex")
  T.eq(extra.DISTRICT_CAMPUS, nil, "not a campus")
  local base = 0
  for row in GameInfo.Buildings() do
    if row.PrereqDistrict == IZ and row.TraitType == nil then base = math.max(base, row.RegionalRange or 0) end
  end
  local reach = SDP_Coverage.Reaches(pid)[IZ]
  T.eq(reach.Range, base + 3, "the reach used for planning")
  T.eq(reach.Extra, 3, "the bonus noted")
  -- The water park only where the ruleset's requirement set names it (not
  -- in Gathering Storm, 2026-11-02).
  local set, named = GameInfo.Modifiers[BONUS].SubjectRequirementSetId, false
  for row in GameInfo.RequirementSetRequirements() do
    if row.RequirementSetId == set then
      for arg in GameInfo.RequirementArguments() do
        if arg.RequirementId == row.RequirementId and arg.Value == "DISTRICT_WATER_ENTERTAINMENT_COMPLEX" then named = true end
      end
    end
  end
  T.eq(extra.DISTRICT_WATER_ENTERTAINMENT_COMPLEX, named and 3 or nil, "the water park as the rules say")
end)

-- How a suzerain bonus shows: the modifier a city-state's trait attaches to
-- its suzerain is owned by the suzerain player, as the bonus attached above.
test("a suzerain bonus's attached modifier is owned by the suzerain", function()
  local attached = {}
  for row in GameInfo.Modifiers() do
    if row.ModifierType == "MODIFIER_ALL_PLAYERS_ATTACH_MODIFIER" and row.SubjectRequirementSetId == "PLAYER_IS_SUZERAIN" then
      for arg in GameInfo.ModifierArguments() do
        if arg.ModifierId == row.ModifierId and arg.Name == "ModifierId" then attached[arg.Value] = true end
      end
    end
  end
  local suzerainOf = 0
  for _, minor in ipairs(PlayerManager.GetAliveMinors()) do
    if minor:GetInfluence():GetSuzerain() == pid then suzerainOf = suzerainOf + 1 end
  end
  if suzerainOf == 0 then T.skip("the player is suzerain of no city-state") end
  local owned = {}
  for _, id in ipairs(GameEffects.GetModifiers()) do
    local def = GameEffects.GetModifierDefinition(id)
    if def ~= nil and attached[def.Id] and GameEffects.GetModifierActive(id) then
      owned[#owned + 1] = def.Id .. "@" .. tostring(GameEffects.GetObjectsPlayerId(GameEffects.GetModifierOwner(id)))
    end
  end
  print("SDP_PROBE suzerain bonuses: " .. table.concat(owned, ", "))
  local mine = 0
  for _, s in ipairs(owned) do
    if s:sub(-#("@" .. pid)) == "@" .. pid then mine = mine + 1 end
  end
  T.ok(mine >= 1, "an attached suzerain bonus owned by the player")
end)
