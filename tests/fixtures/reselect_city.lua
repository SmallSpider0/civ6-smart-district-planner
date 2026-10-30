-- Setup of tests/test_reselect.lua (issue 178), in the SDP_Panel state: the
-- capital selected on the map, the panel opened on it, moved to the Several
-- cities tab and closed; then the capital unselected and selected again.
-- The game tells of the selections (Events.CitySelectionChanged) a few
-- frames later, so the test opens the panel in a later call.
local capital = Players[Game.GetLocalPlayer()]:GetCities():GetCapitalCity()
UI.DeselectAllCities()
UI.SelectCity(capital)
SDP_Panel.Open()
SDP_Panel.SelectTab("MULTI")
SDP_Panel.Close()
UI.DeselectAllCities()
UI.SelectCity(capital)
print("reselect_city: capital selected again, panel closed on " .. SDP_Panel.Tab())
