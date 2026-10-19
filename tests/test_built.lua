-- @state SDP_Panel
-- @setup GameCore_Tuner tests/fixtures/build_campus.lua
-- @teardown GameCore_Tuner tests/fixtures/destroy_campus.lua
-- A district already built in the city: greyed out in the panel, never
-- planned again, its plot excluded, and its adjacency counted as a neighbour.
local test, T = ...

local pid = Game.GetLocalPlayer()

local function Built()
  local city = Players[pid]:GetCities():GetCapitalCity()
  if city == nil then T.skip("no capital") end
  local plannable = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do plannable[d.Type] = true end
  if not plannable.DISTRICT_CAMPUS then T.skip("this civ has a unique campus") end
  local scan = SDP_City.Scan(pid, city:GetID())
  for _, b in ipairs(scan.Built) do
    if b.Type == "DISTRICT_CAMPUS" then return city, scan, b end
  end
  error("setup did not build a campus")
end

test("the built campus is excluded from candidates and marked BUILT", function()
  local _, scan, campus = Built()
  T.eq(scan.Excluded[campus.Index], SDP_City.EXCLUDED.DISTRICT, "campus plot")
  T.eq(SDP_City.DistrictStatus(scan, SDP_Rules.PlannableDistricts(pid)).DISTRICT_CAMPUS, "BUILT", "status")
end)

test("the panel greys the campus out and cannot select it", function()
  local city = Built()
  SDP_Panel.SelectCity(city:GetID())
  SDP_Panel.Refresh()
  local found = false
  for _, row in ipairs(SDP_Panel.State().DistrictRows) do
    if row.Type == "DISTRICT_CAMPUS" then
      found = true
      T.eq(row.Status, "BUILT", "row status")
      T.eq(row.Check:IsDisabled(), true, "checkbox enabled")
      T.eq(row.Check:IsChecked(), false, "checkbox checked")
    end
  end
  T.ok(found, "no campus row")
end)

test("solving skips the built campus and scores it as a neighbour", function()
  local city, _, campus = Built()
  local result = SDP_Solver.Solve({ PlayerID = pid, CityID = city:GetID(), Districts = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE" } })
  T.ok(result.Ok, "solve failed: " .. tostring(result.Error))
  T.same(result.Unplaced, { { Type = "DISTRICT_CAMPUS", Reason = "BUILT" } }, "unplaced")
  T.eq(#result.Plan, 1, "plan size")
  local fixed = SDP_Overlay.With(pid, SDP_Overlay.FixedSubjects, SDP_City.Scan(pid, city:GetID()))
  local seen = false
  for _, s in ipairs(fixed) do
    if s.X == campus.X and s.Y == campus.Y and s.Key == "DISTRICT_CAMPUS" then seen = true end
  end
  T.ok(seen, "built campus not among the fixed subjects")
end)
