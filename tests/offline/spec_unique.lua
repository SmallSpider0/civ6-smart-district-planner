-- Offline: a district the empire may have only one of (Districts.MaxPerPlayer,
-- e.g. the Government Plaza) built in one of the player's cities (issue 108).
-- The Several cities tab shows it as built and takes no click; the solver
-- never plans another. Everything goes through the controls' own callbacks.
local test, T = ...

local UI_Mock = include("ui")

local MAP = {
  "~~~~~~~~~~~~~~~~~~~~~~",
  "~..f.M..h...f..M..h..~",
  "~.fMj..p.d...fMj..p..~",
  "~h..f.j..M.h..f.j..M.~",
  "~.pM...f.h..pM...f.h.~",
  "~..j.p..q....j.p..q..~",
  "~f..h.M.j..f..h.M.j..~",
  "~.s..f..p...s..f..p..~",
  "~..p...h...p...h.....~",
  "~.M..f..j..M..f..j...~",
  "~..h..p...h..p...h...~",
  "~.f..M..p..f..M..p...~",
  "~..j...h..j...h..j...~",
  "~~~~~~~~~~~~~~~~~~~~~~",
}

-- The capital (4,5) and a second city (11,5) close enough to plan together,
-- and a city-center pin (8,9).
local w = World.New({
  rows = MAP, rivers = { "6,4", "7,4", "7,5", "12,7", "13,7" },
  cities = {
    { id = 1, x = 4, y = 5, population = 8, capital = true, radius = 1 },
    { id = 2, x = 11, y = 5, population = 8, radius = 1 },
  },
  pins = { { 8, 9, "ICON_DISTRICT_CITY_CENTER", "" } },
})
UI_Mock.Install()
include("SDP_Panel")

local PLAZA = "DISTRICT_GOVERNMENT"

local function Limited()
  local out = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(0)) do
    if d.MaxPerPlayer and d.MaxPerPlayer > 0 then out[#out + 1] = d.Type end
  end
  return out
end

local function Row(multi, districtType)
  for _, d in ipairs(multi.State().View.Districts) do
    if d.Type == districtType then return d end
  end
end

test("the empire-limited districts come from Districts.MaxPerPlayer", function()
  T.same(Limited(), { PLAZA }, "the government plaza only, in this world")
end)

test("several cities tab: an empire-limited district not built yet can be required", function()
  SDP_Panel.Open()
  SDP_Panel.SelectTab("MULTI")
  local multi = SDP_Panel.Multi
  multi.Refresh()
  local row = Row(multi, PLAZA)
  T.ok(not row.Cell:IsDisabled(), "the cell takes clicks")
  T.eq(row.Built, nil, "not built")
  row.Cell:Click()
  T.eq(Row(multi, PLAZA).State, "MUST", "required after a click")
end)

test("several cities tab: a built government plaza shows as built, takes no click and is never planned (issue 108)", function()
  -- Required before it was built (the list is remembered between openings).
  local multi = SDP_Panel.Multi
  multi.SetPlanFor("ALL")
  multi.SetSelected(PLAZA, true)
  multi.SetSelected("DISTRICT_CAMPUS", true)
  T.eq(Row(multi, PLAZA).State, "MUST", "required")
  -- Built in the capital (complete or not: the game counts both).
  w:AddDistrict(1, PLAZA, 5, 4, false)
  multi.Refresh()
  local row = Row(multi, PLAZA)
  T.eq(row.Built, true, "shown as built")
  T.ok(row.Cell:IsDisabled(), "the cell takes no click")
  T.ok(row.Status:find("LIMITED_BUILT", 1, true) ~= nil, "the tooltip says where it stands: " .. row.Status)
  row.Cell:Click()
  T.eq(Row(multi, PLAZA).Built, true, "still built after a click")
  local request = multi.Request()
  for _, districtType in ipairs(request.Districts) do T.ok(districtType ~= PLAZA, "not sent as required") end
  for _, districtType in ipairs(request.Pool) do T.ok(districtType ~= PLAZA, "not sent as a candidate") end
  -- A city's own list: the same.
  local second
  for _, part in ipairs(multi.Participants()) do
    if part.Kind == "CITY" and part.CityID == 2 then second = part.Key end
  end
  T.ok(second ~= nil, "the second city takes part")
  multi.SetPlanFor(second)
  multi.SetState(PLAZA, "MUST")
  T.eq(Row(multi, PLAZA).Built, true, "built on a city's own list too")
  request = multi.Request()
  for _, districtType in ipairs(request.Plans[second]) do T.ok(districtType ~= PLAZA, "not in the city's own list") end
  multi.ApplyPlan(nil)
  multi.SetPlanFor("ALL")

  multi.SetCount(0)
  multi.SetTier("FAST")
  T.ok(multi.Solve(), "started")
  SDP_Panel.RunTask(500)
  local result = multi.State().Result
  T.ok(result and result.Ok, "multi result: " .. tostring(result and result.Error))
  for _, p in ipairs(result.Plan) do T.ok(p.Type ~= PLAZA, "no second government plaza: " .. p.City) end
  for _, u in ipairs(result.Unplaced) do T.ok(u.Type ~= PLAZA, "not listed as left out: " .. u.City) end
end)

test("single city tab: built here, or the empire's limit reached elsewhere", function()
  SDP_Panel.SelectTab("SINGLE")
  local function Status(cityID)
    SDP_Panel.SelectCity(cityID)
    for _, r in ipairs(SDP_Panel.State().DistrictRows) do
      if r.Type == PLAZA then return r.Status, r.Cell end
    end
  end
  local status, cell = Status(1)
  T.eq(status, "BUILT", "the capital")
  T.ok(cell:IsDisabled(), "greyed out")
  status, cell = Status(2)
  T.eq(status, "MAX_PER_PLAYER", "the other city")
  T.ok(cell:IsDisabled(), "greyed out")
end)
