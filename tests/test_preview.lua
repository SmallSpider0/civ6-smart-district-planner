-- @state SDP_Panel
-- Map preview (risk 10, 11): draws and clears without placing map tacks.
local test, T = ...

local pid = Game.GetLocalPlayer()

test("preview shows and clears; no map tack is made", function()
  local city = Players[pid]:GetCities():GetCapitalCity()
  if city == nil then T.skip("no capital") end
  local before = 0
  for _ in pairs(PlayerConfigurations[pid]:GetMapPins()) do before = before + 1 end
  local plots = {}
  for _, e in ipairs(SDP_City.PlotsInRange(city:GetX(), city:GetY(), 3)) do plots[#plots + 1] = e.Index end
  SDP_Preview.Show(pid, { { Plots = plots, Color = 1 } },
    { { X = city:GetX() + 1, Y = city:GetY(), Icon = "ICON_DISTRICT_CAMPUS", Text = "+3" } })
  T.ok(SDP_Preview.IsShown(), "shown")
  local after = 0
  for _ in pairs(PlayerConfigurations[pid]:GetMapPins()) do after = after + 1 end
  T.eq(after, before, "map tacks")
  SDP_Preview.Clear()
  T.ok(not SDP_Preview.IsShown(), "cleared")
end)
