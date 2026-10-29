-- Offline: replacing this mod's earlier pins plans a wonder again when its
-- only pin is one of them (issue 154). Before the fix the wonder stayed
-- "pinned" (not planned), while its pin was ignored: the plan lost the
-- wonder and the districts next to it lost its bonus, and placing deleted
-- the old wonder pin. Driven through the panel's own hooks (SDP_Panel).
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

local w = World.New({
  rows = MAP, rivers = { "6,4", "7,4", "7,5", "12,7", "13,7" },
  cities = { { id = 1, x = 4, y = 5, population = 6, capital = true, radius = 1 } },
})
UI_Mock.Install()
include("SDP_Panel")

local WONDER = "BUILDING_HANGING_GARDENS"

-- "Type@plot" of every planned item, sorted, and the plan's yields.
local function Layout(plan)
  local list = {}
  for _, p in ipairs(plan) do list[#list + 1] = p.Type .. "@" .. p.Index end
  table.sort(list)
  return table.concat(list, " ")
end

local function Planned(plan, itemType)
  for _, p in ipairs(plan) do
    if p.Type == itemType then return p end
  end
  return nil
end

local function WonderPins()
  local n = 0
  for _, pin in ipairs(w:Pins()) do
    if pin:GetIconName() == "ICON_" .. WONDER then n = n + 1 end
  end
  return n
end

test("single-city tab: replacing the earlier pins plans their wonder again", function()
  SDP_Panel.Open()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(1)
  SDP_Panel.SetSelected("DISTRICT_THEATER", true)
  SDP_Panel.SetSelected("DISTRICT_HOLY_SITE", true)
  SDP_Panel.SetState("DISTRICT_AQUEDUCT", "OFF")
  SDP_Panel.SetRemind(false)
  SDP_Panel.SetReplace(false)
  SDP_Panel.SetTier("FAST")
  SDP_Panel.SetWonder(WONDER, true)
  T.same(SDP_Panel.State().Wonders, { WONDER }, "the wonder is chosen")
  T.eq(SDP_Panel.Solve(), nil, "with a wonder the city is solved as a task")
  local first = SDP_Panel.RunTask(500)
  T.ok(first and first.Ok, "first plan: " .. tostring(first and first.Error))
  T.ok(Planned(first.Plan, WONDER) ~= nil, "the wonder is planned")
  local theater = Planned(first.Plan, "DISTRICT_THEATER")
  T.ok(theater ~= nil, "the theater is planned")
  T.eq(SDP_Panel.PlacePins(), #first.Plan, "placed")
  T.eq(WonderPins(), 1, "the wonder's pin")
  -- Its pin is there: the wonder is pinned and not planned again.
  T.same(SDP_Panel.State().Wonders, {}, "a pinned wonder is left out")

  -- Replace: the earlier pins count as gone, the wonder's among them.
  SDP_Panel.SetReplace(true)
  T.same(SDP_Panel.State().Wonders, { WONDER }, "with replace the wonder is chosen again")
  T.eq(SDP_Panel.Solve(), nil, "solved as a task again")
  local again = SDP_Panel.RunTask(500)
  T.ok(again and again.Ok, "plan with replace: " .. tostring(again and again.Error))
  T.ok(Planned(again.Plan, WONDER) ~= nil, "the wonder is in the plan")
  for _, u in ipairs(again.Unplaced or {}) do T.ok(u.Type ~= WONDER, "the wonder is not left out: " .. tostring(u.Reason)) end
  -- The same input as the first time: the same plan, the same bonus.
  T.eq(Layout(again.Plan), Layout(first.Plan), "the same plan as before")
  local theater2 = Planned(again.Plan, "DISTRICT_THEATER")
  T.eq(theater2 and theater2.Score, theater.Score, "the theater keeps its bonus")
  T.eq(SDP_Panel.PlacePins(), #again.Plan, "placed over the earlier pins")
  T.eq(WonderPins(), 1, "one wonder pin, not none and not two")

  SDP_Panel.UndoPins()
  SDP_Panel.SetReplace(false)
  while SDP_Pins.CanUndo() do SDP_Pins.UndoLast() end
  T.eq(WonderPins(), 0, "clean")
  SDP_Panel.SetWonder(WONDER, false)
  SDP_Panel.SetSelected("DISTRICT_THEATER", false)
  SDP_Panel.SetSelected("DISTRICT_HOLY_SITE", false)
  SDP_Panel.SetState("DISTRICT_AQUEDUCT", "AUTO")
  SDP_Panel.SetRemind(true)
end)

test("several cities tab: replacing the earlier pins plans their wonder again", function()
  SDP_Panel.SelectTab("MULTI")
  local multi = SDP_Panel.Multi
  multi.Refresh()
  multi.SetCount(0)
  multi.SetPlanFor("ALL")
  multi.ApplyPlan({ "DISTRICT_THEATER" })
  multi.SetReplace(false)
  multi.SetTier("FAST")
  multi.SetWonder(WONDER, true)
  T.ok(multi.Solve(), "started")
  SDP_Panel.RunTask(500)
  local first = multi.State().Result
  T.ok(first and first.Ok, "first plan: " .. tostring(first and first.Error))
  T.ok(Planned(first.Plan, WONDER) ~= nil, "the wonder is planned")
  T.ok(multi.Place() > 0, "placed")
  T.eq(WonderPins(), 1, "the wonder's pin")
  local function Status()
    for _, v in ipairs(multi.State().View.Wonders) do
      if v.Type == WONDER then return v.Status or "NONE" end
    end
    return "MISSING"
  end
  T.eq(Status(), "PINNED", "without replace the wonder shows as pinned")

  multi.SetReplace(true)
  T.eq(Status(), "NONE", "with replace the wonder can be planned again")
  T.ok(multi.Solve(), "started again")
  SDP_Panel.RunTask(500)
  local again = multi.State().Result
  T.ok(again and again.Ok, "plan with replace: " .. tostring(again and again.Error))
  T.ok(Planned(again.Plan, WONDER) ~= nil, "the wonder is in the plan")
  T.eq(Layout(again.Plan), Layout(first.Plan), "the same plan as before")
  multi.Place()
  T.eq(WonderPins(), 1, "one wonder pin, not none and not two")

  multi.Undo()
  multi.SetReplace(false)
  while SDP_Pins.CanUndo() do SDP_Pins.UndoLast() end
  T.eq(WonderPins(), 0, "clean")
  multi.SetWonder(WONDER, false)
end)
