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
  if GameInfo.Districts.DISTRICT_WATER_ENTERTAINMENT_COMPLEX ~= nil then
    T.eq(extra.DISTRICT_WATER_ENTERTAINMENT_COMPLEX, 3, "the water park")
  end
end)
