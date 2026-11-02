-- Issue 197: give the local player Toronto's suzerain bonus (+3 regional
-- range for the industrial zone, entertainment complex and water park).
-- With Toronto in the game the player is made its suzerain through envoys;
-- without it the bonus's modifier is attached to the player directly (the
-- same modifier the suzerain bonus attaches), and the player is made suzerain
-- of the first city-state (by ID) to see how a suzerain bonus shows in the
-- game's modifiers. Lasts for the rest of the game: use a throwaway game
-- (tests/bench/probe_regional_range.lua).
local pid = Game.GetLocalPlayer()
local player = Players[pid]
local BONUS = "MINOR_CIV_TORONTO_REGIONAL_RANGE_BONUS"
for _, minor in ipairs(PlayerManager.GetAliveMinors()) do
  local civ = PlayerConfigurations[minor:GetID()]:GetCivilizationTypeName()
  if civ == "CIVILIZATION_TORONTO" then
    player:GetDiplomacy():SetHasMet(minor:GetID())
    local influence = player:GetInfluence()
    for _ = 1, 6 do influence:GiveFreeTokenToPlayer(minor:GetID()) end
    print("SDP_SUZERAIN envoys", minor:GetID(), "suzerain", minor:GetInfluence():GetSuzerain())
    return
  end
end
local attached = false
for _, id in ipairs(GameEffects.GetModifiers()) do
  local def = GameEffects.GetModifierDefinition(id)
  if def ~= nil and def.Id == BONUS and GameEffects.GetObjectsPlayerId(GameEffects.GetModifierOwner(id)) == pid then attached = true end
end
if not attached then player:AttachModifierByID(BONUS) end
print("SDP_SUZERAIN attached", BONUS, attached and "(already)" or "")
local minors = PlayerManager.GetAliveMinors()
local first
for _, minor in ipairs(minors) do
  if first == nil or minor:GetID() < first:GetID() then first = minor end
end
if first ~= nil then
  player:GetDiplomacy():SetHasMet(first:GetID())
  local influence = player:GetInfluence()
  for _ = 1, 6 do influence:GiveFreeTokenToPlayer(first:GetID()) end
  print("SDP_SUZERAIN envoys", first:GetID(), PlayerConfigurations[first:GetID()]:GetCivilizationTypeName(),
    "suzerain", first:GetInfluence():GetSuzerain())
end
