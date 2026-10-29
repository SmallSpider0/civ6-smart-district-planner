-- Offline: replacing this mod's earlier pins plans a wonder again when its
-- only pin is one of them (issue 154). Before the fix the wonder stayed
-- "pinned" (not planned), while its pin was ignored: the plan lost the
-- wonder and the districts next to it lost its bonus, and placing deleted
-- the old wonder pin. The wonder, the replace switch, solving, placing and
-- undoing go through the controls' own callbacks; the district lists are
-- set up through the panel's hooks (SDP_Panel).
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
local c = UI_Mock.Controls

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

-- Choose a wonder in a tab's "add" pulldown, as a click on its entry.
local function PickWonder(pull, wonderType)
  for _, entry in ipairs(pull._entries) do
    if entry.Button:GetText() == "LOC_" .. wonderType .. "_NAME" then
      entry.Button:Click()
      return true
    end
  end
  return false
end

local function InPull(pull, wonderType)
  for _, entry in ipairs(pull._entries) do
    if entry.Button:GetText() == "LOC_" .. wonderType .. "_NAME" then return true end
  end
  return false
end

-- Set a switch through its check box.
local function SetCheck(check, on)
  if (check:IsChecked() == true) ~= on then check:Toggle() end
  T.eq(check:IsChecked() == true, on, "the switch")
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
  SetCheck(c.RemindCheck, false)
  SetCheck(c.ReplaceCheck, false)
  SDP_Panel.SetTier("FAST")
  T.ok(PickWonder(c.WonderPull, WONDER), "the wonder is in the pulldown")
  T.same(SDP_Panel.State().Wonders, { WONDER }, "the wonder is chosen")
  c.SolveButton:Click()
  local first = SDP_Panel.RunTask(500)
  T.ok(first and first.Ok, "first plan: " .. tostring(first and first.Error))
  T.ok(Planned(first.Plan, WONDER) ~= nil, "the wonder is planned")
  local theater = Planned(first.Plan, "DISTRICT_THEATER")
  T.ok(theater ~= nil, "the theater is planned")
  local pins = #w:Pins()
  c.PlaceButton:Click()
  T.eq(#w:Pins(), pins + #first.Plan, "placed")
  T.eq(WonderPins(), 1, "the wonder's pin")
  -- Its pin is there: the wonder is pinned and not planned again.
  T.same(SDP_Panel.State().Wonders, {}, "a pinned wonder is left out")
  T.ok(not InPull(c.WonderPull, WONDER), "and is not offered")

  -- Replace: the earlier pins count as gone, the wonder's among them.
  c.ReplaceCheck:Toggle()
  T.eq(SDP_Panel.State().Replace, true, "replace on")
  T.same(SDP_Panel.State().Wonders, { WONDER }, "with replace the wonder is chosen again")
  T.eq(c.SolveButton:IsDisabled(), false, "and can be solved")
  c.SolveButton:Click()
  local again = SDP_Panel.RunTask(500)
  T.ok(again and again.Ok, "plan with replace: " .. tostring(again and again.Error))
  T.ok(Planned(again.Plan, WONDER) ~= nil, "the wonder is in the plan")
  for _, u in ipairs(again.Unplaced or {}) do T.ok(u.Type ~= WONDER, "the wonder is not left out: " .. tostring(u.Reason)) end
  -- The same input as the first time: the same plan, the same bonus.
  T.eq(Layout(again.Plan), Layout(first.Plan), "the same plan as before")
  local theater2 = Planned(again.Plan, "DISTRICT_THEATER")
  T.eq(theater2 and theater2.Score, theater.Score, "the theater keeps its bonus")
  c.PlaceButton:Click()
  T.eq(#w:Pins(), pins + #again.Plan, "placed over the earlier pins")
  T.eq(WonderPins(), 1, "one wonder pin, not none and not two")

  c.UndoButton:Click()
  c.ReplaceCheck:Toggle()
  T.eq(SDP_Panel.State().Replace, false, "replace off")
  while SDP_Pins.CanUndo() do c.UndoButton:Click() end
  T.eq(WonderPins(), 0, "clean")
  SDP_Panel.SetWonder(WONDER, false)
  SDP_Panel.SetSelected("DISTRICT_THEATER", false)
  SDP_Panel.SetSelected("DISTRICT_HOLY_SITE", false)
  SDP_Panel.SetState("DISTRICT_AQUEDUCT", "AUTO")
  SetCheck(c.RemindCheck, true)
end)

local function MultiStatus()
  for _, v in ipairs(SDP_Panel.Multi.State().View.Wonders) do
    if v.Type == WONDER then return v.Status or "NONE" end
  end
  return "MISSING"
end

test("several cities tab: replacing the earlier pins plans their wonder again", function()
  SDP_Panel.SelectTab("MULTI")
  local multi = SDP_Panel.Multi
  multi.Refresh()
  multi.SetCount(0)
  multi.SetPlanFor("ALL")
  multi.ApplyPlan({ "DISTRICT_THEATER" })
  SetCheck(c.MultiReplaceCheck, false)
  multi.SetTier("FAST")
  T.ok(PickWonder(c.MultiWonderPull, WONDER), "the wonder is in the pulldown")
  c.MultiSolveButton:Click()
  SDP_Panel.RunTask(500)
  local first = multi.State().Result
  T.ok(first and first.Ok, "first plan: " .. tostring(first and first.Error))
  T.ok(Planned(first.Plan, WONDER) ~= nil, "the wonder is planned")
  c.MultiPlaceButton:Click()
  T.eq(multi.State().Result.Placed, true, "placed")
  T.eq(WonderPins(), 1, "the wonder's pin")
  T.eq(MultiStatus(), "PINNED", "without replace the wonder shows as pinned")
  T.ok(not InPull(c.MultiWonderPull, WONDER), "and is not offered")

  c.MultiReplaceCheck:Toggle()
  T.eq(multi.State().Replace, true, "replace on")
  T.eq(MultiStatus(), "NONE", "with replace the wonder can be planned again")
  c.MultiSolveButton:Click()
  SDP_Panel.RunTask(500)
  local again = multi.State().Result
  T.ok(again and again.Ok, "plan with replace: " .. tostring(again and again.Error))
  T.ok(Planned(again.Plan, WONDER) ~= nil, "the wonder is in the plan")
  T.eq(Layout(again.Plan), Layout(first.Plan), "the same plan as before")
  c.MultiPlaceButton:Click()
  T.eq(multi.State().Result.Placed, true, "placed again")
  T.eq(WonderPins(), 1, "one wonder pin, not none and not two")

  c.MultiUndoButton:Click()
  c.MultiReplaceCheck:Toggle()
  T.eq(multi.State().Replace, false, "replace off")
  while SDP_Pins.CanUndo() do c.MultiUndoButton:Click() end
  T.eq(WonderPins(), 0, "clean")
  multi.SetWonder(WONDER, false)
end)

-- The shared list with only a wonder, already pinned: nothing to plan, the
-- solve button greyed out. The replace switch brings the wonder back, and
-- the button has to follow, also when there is no result to clear.
test("several cities tab: the solve button follows the replace switch for a pinned wonder", function()
  SDP_Panel.SelectTab("MULTI")
  local multi = SDP_Panel.Multi
  multi.Refresh()
  multi.SetPlanFor("ALL")
  multi.ApplyPlan({})
  multi.SetCount(0)
  SetCheck(c.MultiReplaceCheck, false)
  multi.SetTier("FAST")
  T.eq(c.MultiSolveButton:IsDisabled(), true, "nothing chosen: nothing to plan")
  T.ok(PickWonder(c.MultiWonderPull, WONDER), "the wonder is in the pulldown")
  T.eq(c.MultiSolveButton:IsDisabled(), false, "the wonder alone can be planned")
  c.MultiSolveButton:Click()
  SDP_Panel.RunTask(500)
  local first = multi.State().Result
  T.ok(first and first.Ok, "plan: " .. tostring(first and first.Error))
  T.ok(Planned(first.Plan, WONDER) ~= nil, "the wonder is planned")
  c.MultiPlaceButton:Click()
  T.eq(WonderPins(), 1, "the wonder's pin")

  -- On clears the result; off again leaves no result, and the wonder pinned.
  c.MultiReplaceCheck:Toggle()
  T.eq(multi.State().Result, nil, "the result is gone")
  T.eq(c.MultiSolveButton:IsDisabled(), false, "replace on: the wonder can be planned again")
  c.MultiReplaceCheck:Toggle()
  T.eq(multi.State().Result, nil, "still no result")
  T.eq(c.MultiSolveButton:IsDisabled(), true, "replace off: the wonder is pinned, nothing to plan")
  T.eq(multi.State().SummaryText, "LOC_SDP_MULTI_NONE", "and the summary says so")
  c.MultiReplaceCheck:Toggle()
  T.eq(c.MultiSolveButton:IsDisabled(), false, "replace on again, with no result: the button follows")
  T.eq(multi.State().SummaryText, "LOC_SDP_RESULT_READY", "ready")
  c.MultiSolveButton:Click()
  SDP_Panel.RunTask(500)
  local again = multi.State().Result
  T.ok(again and again.Ok, "plan with replace: " .. tostring(again and again.Error))
  T.eq(Layout(again.Plan), Layout(first.Plan), "the same plan as before")

  c.MultiReplaceCheck:Toggle()
  while SDP_Pins.CanUndo() do c.MultiUndoButton:Click() end
  T.eq(WonderPins(), 0, "clean")
  multi.SetWonder(WONDER, false)
end)
