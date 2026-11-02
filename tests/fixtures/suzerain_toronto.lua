-- Issue 197: give the local player Toronto's suzerain bonus (+3 regional
-- range for the industrial zone, entertainment complex and water park).
-- With Toronto in the game the player is made its suzerain through envoys;
-- without it the bonus's modifier is attached to the player directly (the
-- same modifier the suzerain bonus attaches). Lasts for the rest of the game:
-- use a throwaway game (tests/bench/probe_regional_range.lua).
local pid = Game.GetLocalPlayer()
local player = Players[pid]
local BONUS = "MINOR_CIV_TORONTO_REGIONAL_RANGE_BONUS"
for _, minor in ipairs(PlayerManager.GetAliveMinors()) do
  local civ = PlayerConfigurations[minor:GetID()]:GetCivilizationTypeName()
  if civ == "CIVILIZATION_TORONTO" then
    local influence = player:GetInfluence()
    for _ = 1, 6 do influence:GiveFreeTokenToPlayer(minor:GetID()) end
    print("SDP_SUZERAIN envoys", minor:GetID(), "suzerain", minor:GetInfluence():GetSuzerain())
    return
  end
end
player:AttachModifierByID(BONUS)
print("SDP_SUZERAIN attached", BONUS)
