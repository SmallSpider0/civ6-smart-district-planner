-- @state SDP_Panel
-- @timeout 60
-- @setup SDP_Panel tests/fixtures/reselect_city.lua
-- Issue 178: a city selected on the map again, after the panel moved away
-- from it, is followed when the panel opens: the single-city tab, on that
-- city. The setup selects the capital, opens the panel on it, moves to the
-- Several cities tab, closes, and selects the capital again; the game's
-- selection events arrive before this file runs. Leaves no city selected.
local test, T = ...

test("the city selected again: the panel opens on its single-city tab", function()
  local capital = Players[Game.GetLocalPlayer()]:GetCities():GetCapitalCity()
  local ok, err = pcall(function()
    local selected = UI.GetHeadSelectedCity()
    T.ok(selected ~= nil and selected:GetID() == capital:GetID(), "the capital selected on the map")
    T.eq(SDP_Panel.Tab(), "MULTI", "closed on the Several cities tab")
    LuaEvents.SDP_OpenPanel()
    T.eq(SDP_Panel.Tab(), "SINGLE", "opened on the single-city tab")
    T.eq(SDP_Panel.State().CityID, capital:GetID(), "on the capital")
    T.eq(SDP_Panel.Multi.State().View.Center, "C" .. capital:GetID(), "the Several cities tab around it")
    LuaEvents.SDP_ClosePanel()
    -- No new selection: the tab the player picks stays.
    LuaEvents.SDP_OpenPanel()
    SDP_Panel.SelectTab("MULTI")
    LuaEvents.SDP_ClosePanel()
    LuaEvents.SDP_OpenPanel()
    T.eq(SDP_Panel.Tab(), "MULTI", "the same selection: the tab stays")
  end)
  LuaEvents.SDP_ClosePanel()
  UI.DeselectAllCities()
  SDP_Panel.SelectTab("SINGLE")
  if not ok then error(err, 0) end
end)
