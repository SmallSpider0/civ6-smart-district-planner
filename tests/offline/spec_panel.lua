-- Offline: the planner panel's logic on every tab, with stub controls
-- (tests/offline/ui.lua). Catches script errors and wiring mistakes; the
-- layout and real clicks are checked in the game.
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
  pins = { { 13, 9, "ICON_DISTRICT_CITY_CENTER", "" } },
})
UI_Mock.Install()
include("SDP_Panel")

local SINGLE = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER" }

test("single-city tab: solve now, solve as a task, continue, place and undo", function()
  SDP_Panel.Open()
  T.ok(SDP_Panel.IsOpen(), "open")
  SDP_Panel.SelectCity(1)
  for _, d in ipairs(SINGLE) do SDP_Panel.SetSelected(d, true) end
  T.ok(SDP_Panel.State().EstimateText ~= "", "estimate shown")
  local result = SDP_Panel.Solve()
  T.ok(result and result.Ok, "solve: " .. tostring(result and result.Error))
  T.ok(#SDP_Panel.State().ResultRows >= 3, "result rows")
  SDP_Panel.SetTier("FINE")
  T.eq(SDP_Panel.Solve(), nil, "the fine tier runs as a task")
  T.ok(SDP_Panel.State().Running, "running")
  local fine = SDP_Panel.RunTask(50)
  T.ok(fine and fine.Ok, "task result: " .. tostring(fine and fine.Error))
  T.eq(fine.Stats.Tier, "FINE", "tier")
  SDP_Panel.SetTier("STANDARD")
  SDP_Panel.SetRemind(false)
  local placedPlan = SDP_Panel.Solve()
  -- Three asked; the capital has no fresh water, so an aqueduct may join (AUTO).
  T.ok(#placedPlan.Plan >= 3, "the three districts")
  local pins = #w:Pins()
  T.eq(SDP_Panel.PlacePins(), #placedPlan.Plan, "a pin per district")
  T.eq(#w:Pins(), pins + #placedPlan.Plan, "pins on the map")
  -- Named with the city's number, not the district (the icon shows that).
  for i = pins + 1, pins + #placedPlan.Plan do T.eq(w:Pins()[i]:GetName(), "1", "pin name") end
  T.eq(SDP_Panel.UndoPins(), #placedPlan.Plan, "undo")
  T.eq(#w:Pins(), pins, "pins gone")
  SDP_Panel.SetRemind(true)
end)

test("single-city tab: district states and the count; picking from the pool; three solutions; reminder pins", function()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(1)
  local states = {}
  for _, row in ipairs(SDP_Panel.State().DistrictRows) do states[row.Type] = row.State end
  T.eq(states.DISTRICT_CAMPUS, "MUST", "the campus is still required from the first test")
  T.eq(states.DISTRICT_ENTERTAINMENT_COMPLEX, "POOL", "districts that take population are candidates")
  T.eq(states.DISTRICT_GOVERNMENT, "OFF", "one per empire: not a candidate")
  T.eq(states.DISTRICT_AQUEDUCT, "AUTO", "the aqueduct is automatic")
  T.eq(states.DISTRICT_NEIGHBORHOOD, "OFF", "the neighborhood is off")
  for _, d in ipairs(SINGLE) do SDP_Panel.SetSelected(d, false) end
  SDP_Panel.SetSelected("DISTRICT_CAMPUS", true)
  T.eq(SDP_Panel.State().Count, SDP_UI.DEFAULT_COUNT, "three by default (issue 71)")
  SDP_Panel.SetCount(0)
  T.eq(SDP_Panel.State().Count, 1, "down to the required districts")
  SDP_Panel.SetCount(3)
  T.eq(SDP_Panel.State().Count, 3, "count")
  T.eq(SDP_Panel.Solve(), nil, "picking runs as a task")
  local result = SDP_Panel.RunTask(500)
  T.ok(result and result.Ok, "result: " .. tostring(result and result.Error))
  T.eq(#result.Solutions, 3, "three solutions")
  for n, sol in ipairs(result.Solutions) do
    local campus, specialty = false, 0
    for _, p in ipairs(sol.Plan) do
      if p.Type == "DISTRICT_CAMPUS" then campus = true end
      if GameInfo.Districts[p.Type].RequiresPopulation then specialty = specialty + 1 end
    end
    T.ok(campus, "the campus in solution " .. n)
    T.eq(specialty, 3, "three districts that take population in solution " .. n)
  end
  SDP_Panel.SelectSolution(2)
  T.eq(SDP_Panel.State().Solution, 2, "second solution shown")
  -- Placing the shown solution puts its reminder pins too.
  local pins = #w:Pins()
  local second = result.Solutions[2]
  local placed = SDP_Panel.PlacePins()
  T.eq(placed, #second.Plan + #(second.Remind or {}), "district and reminder pins")
  local reminders = 0
  for i = pins + 1, #w:Pins() do
    local pin = w:Pins()[i]
    if pin:GetIconName() == SDP_Pins.REMIND_ICON then
      reminders = reminders + 1
      T.ok(pin:GetName():match("^1 ") ~= nil, "a reminder is named with the city number first")
    end
  end
  T.eq(reminders, #(second.Remind or {}), "reminders")
  T.eq(#SDP_Pins.Own(0, { 1 }), placed, "all of them are this mod's pins of the city")
  T.eq(SDP_Panel.UndoPins(), placed, "undo takes all")
  -- The count cannot go below the required districts.
  SDP_Panel.SetCount(0)
  T.eq(SDP_Panel.State().Count, 1, "clamped")
end)

test("single-city tab: the record survives a reload; replace plans over this mod's pins and undo brings them back", function()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(1)
  for _, d in ipairs(SINGLE) do SDP_Panel.SetSelected(d, false) end
  SDP_Panel.SetSelected("DISTRICT_CAMPUS", true)
  SDP_Panel.SetState("DISTRICT_AQUEDUCT", "OFF") -- the campus alone
  SDP_Panel.SetRemind(false)
  SDP_Panel.SetTier("STANDARD")
  local first = SDP_Panel.Solve()
  local campus = first.Plan[1]
  local pins = #w:Pins()
  T.eq(SDP_Panel.PlacePins(), 1, "one pin")
  -- A saved game: the record is in the player's configuration.
  SDP_Pins.Reset()
  T.ok(SDP_Pins.CanUndo(), "undo after a reload")
  T.eq(#SDP_Pins.Own(0, { 1 }), 1, "the campus pin is ours")
  T.eq(#SDP_Pins.Own(0, { 2 }), 0, "nothing for another city")

  -- Without replace the pin is a fixed plot: the campus goes elsewhere.
  local locked = SDP_Panel.Solve()
  T.ok(locked.Plan[1].Index ~= campus.Index, "the pinned plot is taken")
  -- With replace, the plan is made as if the pin were gone: the same plot again.
  SDP_Panel.SetReplace(true)
  local replanned = SDP_Panel.Solve()
  T.eq(replanned.Plan[1].Index, campus.Index, "planned over this mod's own pin")
  T.eq(SDP_Panel.PlacePins(), 1, "placed")
  T.eq(#w:Pins(), pins + 1, "the old pin was replaced, not doubled")
  -- Undo removes the new pin and puts the old one back.
  T.eq(SDP_Panel.UndoPins(), 1, "undo")
  T.eq(#w:Pins(), pins + 1, "the replaced pin is back")
  T.eq(SDP_Panel.State().Result, nil, "plan again after the replaced pins came back")
  T.eq(#SDP_Pins.Own(0, { 1 }), 1, "and it is ours again")

  -- A pin the player edits is theirs: never replaced.
  local own = SDP_Pins.Own(0, { 1 })[1]
  PlayerConfigurations[0]:GetMapPinID(own.ID):SetName("mine")
  T.eq(#SDP_Pins.Own(0, { 1 }), 0, "an edited pin is not ours")
  local after = SDP_Panel.Solve()
  T.ok(after.Plan[1].Index ~= campus.Index, "the player's pin stays a fixed plot")
  SDP_Panel.SetReplace(false)
  SDP_Panel.SetRemind(true)
  SDP_Panel.SetState("DISTRICT_AQUEDUCT", "AUTO")
  while SDP_Pins.CanUndo() do SDP_Pins.UndoLast() end
  PlayerConfigurations[0]:DeleteMapPin(own.ID)
  T.eq(#w:Pins(), pins, "clean")
end)

test("single-city tab: wonders go with the districts; the good-places map; the open key", function()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(1)
  for _, d in ipairs(SINGLE) do SDP_Panel.SetSelected(d, false) end
  SDP_Panel.SetSelected("DISTRICT_CAMPUS", true)
  SDP_Panel.SetState("DISTRICT_AQUEDUCT", "OFF") -- the campus alone
  SDP_Panel.SetTier("FAST")
  -- The pulldown lists the wonders by era, then cost (issue 7), with the era as tooltip.
  local entries = Controls.WonderPull._entries
  local names = {}
  for _, entry in ipairs(entries) do names[#names + 1] = entry.Button:GetText() end
  T.same(names, { "LOC_BUILDING_HANGING_GARDENS_NAME", "LOC_BUILDING_STONEHENGE_NAME", "LOC_BUILDING_PYRAMIDS_NAME",
    "LOC_BUILDING_COLOSSEUM_NAME", "LOC_BUILDING_GREAT_LIBRARY_NAME" }, "pulldown order")
  T.eq(entries[1].Button:GetToolTipString(), "LOC_ERA_ANCIENT_NAME", "era tooltip")
  -- Two wonders: the request keeps type order whatever the list's order.
  SDP_Panel.SetWonder("BUILDING_STONEHENGE", true)
  SDP_Panel.SetWonder("BUILDING_COLOSSEUM", true)
  T.same(SDP_Panel.State().Wonders, { "BUILDING_COLOSSEUM", "BUILDING_STONEHENGE" }, "type order")
  T.eq(#Controls.WonderPull._entries, 3, "chosen wonders leave the pulldown")
  SDP_Panel.SetWonder("BUILDING_STONEHENGE", false)
  SDP_Panel.SetWonder("BUILDING_COLOSSEUM", false)
  SDP_Panel.SetWonder("BUILDING_HANGING_GARDENS", true)
  T.same(SDP_Panel.State().Wonders, { "BUILDING_HANGING_GARDENS" }, "wonder chosen")
  T.eq(SDP_Panel.Solve(), nil, "with a wonder the city is solved as a task")
  local result = SDP_Panel.RunTask(500)
  T.ok(result and result.Ok, "result: " .. tostring(result and result.Error))
  local types = {}
  for _, p in ipairs(result.Plan) do
    types[p.Type] = true
    T.eq(p.City, "C1", p.Type .. " in the selected city")
  end
  T.ok(types.DISTRICT_CAMPUS and types.BUILDING_HANGING_GARDENS, "the campus and the wonder are planned")
  local pins = #w:Pins()
  T.eq(SDP_Panel.PlacePins(), #result.Plan, "pins")
  local icons = {}
  for i = pins + 1, #w:Pins() do icons[w:Pins()[i]:GetIconName()] = true end
  T.ok(icons.ICON_BUILDING_HANGING_GARDENS, "the wonder's pin has its icon")
  T.eq(SDP_Panel.UndoPins(), #result.Plan, "undo")
  SDP_Panel.SetWonder("BUILDING_HANGING_GARDENS", false)
  SDP_Panel.SetTier("STANDARD")

  -- Good places for the campus: legal plots best first, drawn on the map.
  local before = UI_Mock.Lenses.hexes[SDP_Preview.LAYER] or 0
  SDP_Panel.ShowHeat("DISTRICT_CAMPUS")
  local spots = SDP_Panel.Heat()
  T.ok(spots ~= nil and #spots > 3, "spots")
  for i = 2, #spots do T.ok(spots[i - 1].Gain >= spots[i].Gain, "best first") end
  T.ok((UI_Mock.Lenses.hexes[SDP_Preview.LAYER] or 0) > before, "colored on the map")
  -- Turning the layer on makes the minimap fill in the appeal colors, by an
  -- event that comes later; the preview puts its own hexes back.
  local ours = UI_Mock.Lenses.hexes[SDP_Preview.LAYER]
  UILens.SetLayerHexesColoredArea("Hex_Coloring_Appeal_Level", 0, { 1, 2, 3 }, 0)
  w.Events.LensLayerOn("Hex_Coloring_Appeal_Level")
  T.eq(UI_Mock.Lenses.hexes[SDP_Preview.LAYER], ours, "the minimap's appeal colors are wiped")
  w.Events.LensLayerOn("Hex_Coloring_Religion")
  T.eq(UI_Mock.Lenses.hexes[SDP_Preview.LAYER], ours, "other layers leave it alone")
  T.eq(SDP_Panel.State().HeatDistrict, "DISTRICT_CAMPUS", "shown")
  local solo = SDP_Panel.Solve()
  T.ok(spots[1].Gain >= solo.Adjacency - 1e-9, "no plot beats the best spot's adjacency")
  T.eq(SDP_Panel.State().HeatDistrict, nil, "solving takes the map down")

  -- The open key toggles the panel.
  local open = SDP_Panel.IsOpen()
  Events.InputActionTriggered("action:SDP_OpenPlanner")
  T.eq(SDP_Panel.IsOpen(), not open, "toggled")
  Events.InputActionTriggered("action:SOMETHING_ELSE")
  T.eq(SDP_Panel.IsOpen(), not open, "other keys ignored")
  Events.InputActionTriggered("action:SDP_OpenPlanner")
  T.eq(SDP_Panel.IsOpen(), open, "back")
  SDP_Panel.SetState("DISTRICT_AQUEDUCT", "AUTO")
end)

test("city sites tab: solve, select, place the site tacks", function()
  SDP_Panel.SelectTab("SITES")
  T.eq(SDP_Panel.Tab(), "SITES", "tab")
  local sites = SDP_Panel.Sites
  T.eq(sites.State().D, 5, "default distance 5 (issue 84)")
  sites.SetCount(2)
  sites.SetDistance(7)
  sites.SetSelected("DISTRICT_CAMPUS", true)
  sites.SetSelected("DISTRICT_HOLY_SITE", true)
  T.ok(sites.State().EstimateText ~= "", "estimate")
  T.ok(sites.Solve(), "started")
  SDP_Panel.RunTask(200)
  local result = sites.State().Result
  T.ok(result and result.Ok, "sites result: " .. tostring(result and result.Error))
  T.ok(#sites.State().View.Solutions >= 1, "solutions listed")
  T.ok(UI_Mock.Lenses.hexes[SDP_Preview.LAYER] > 0, "previewed on the map")
  if #result.Solutions > 1 then
    sites.SelectSolution(2)
    T.eq(sites.State().Solution, 2, "second solution selected")
  end
  -- Tooltips: both distances; the resources each site works (issues 8, 9).
  local solution = result.Solutions[sites.State().Solution]
  for s, site in ipairs(solution.Sites) do
    local tip = sites.State().View.Results[s].ToolTip
    T.ok(tip:find("LOC_SDP_SITES_OWN_DISTANCE(" .. site.OwnDistance .. ")", 1, true), "distance to our city: " .. tip)
    T.ok(tip:find("LOC_SDP_SITES_SITE_DISTANCE(" .. site.SiteDistance .. ")", 1, true), "distance to the other site")
    T.eq(tip:find("LOC_SDP_SITES_LUXURY", 1, true) ~= nil, next(site.Luxury) ~= nil, "a luxury line when it has luxuries")
    T.eq(tip:find("LOC_SDP_SITES_STRATEGIC", 1, true) ~= nil, next(site.Strategic) ~= nil, "a strategic line likewise")
    for kind, count in pairs(site.Luxury) do
      local name = GameInfo.Resources[kind].Name
      local item = site.NewKinds[kind] and ("LOC_SDP_SITES_NEW_KIND(" .. name .. "," .. count .. ")") or (name .. " " .. count)
      T.ok(tip:find(item, 1, true), kind .. " listed")
    end
  end
  local pins = #w:Pins()
  T.eq(sites.Place(), 2, "two site tacks")
  T.eq(#w:Pins(), pins + 2, "on the map")
  -- One city and one city-center pin already: the new sites are 3 and 4.
  T.eq(w:Pins()[pins + 1]:GetName() .. "," .. w:Pins()[pins + 2]:GetName(), "3,4", "site numbers")
  T.eq(UI_Mock.Lenses.hexes[SDP_Preview.LAYER], 0, "preview cleared after placing")
end)

test("several cities tab: the new site tacks take part; solve; solutions; place", function()
  SDP_Panel.SelectTab("MULTI")
  local multi = SDP_Panel.Multi
  multi.Refresh()
  T.eq(multi.State().View.Count, SDP_UI.DEFAULT_COUNT, "three districts a city by default (issue 71)")
  -- These tests plan the required districts only: picking makes them slow.
  multi.SetCount(0)
  local sites = 0
  for _, c in ipairs(multi.State().View.Cities) do
    if c.Kind == "SITE" then sites = sites + 1 end
  end
  T.ok(sites >= 3, "the pin and the two site tacks: " .. sites)
  for _, d in ipairs({ "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_COMMERCIAL_HUB", "DISTRICT_GOVERNMENT" }) do
    multi.SetSelected(d, true)
  end
  multi.SetWonder("BUILDING_HANGING_GARDENS", true)
  multi.SetTier("FAST")
  T.ok(multi.Solve(), "started")
  SDP_Panel.RunTask(500)
  local result = multi.State().Result
  T.ok(result and result.Ok, "multi result: " .. tostring(result and result.Error))
  T.ok(not result.Stats.Mismatch, "board and full evaluation agree")
  T.ok(#multi.State().View.Results > 0, "rows")
  local pins = #w:Pins()
  local placed = multi.Place()
  T.ok(placed > 0, "placed")
  T.eq(#w:Pins(), pins + placed, "pins on the map")
  -- Every new pin carries its city's number: the site's own number for a
  -- planned city (its center pin's name), the city's number for a city.
  local numbers = {}
  for _, c in ipairs(result.Cities) do numbers[c.Key] = tostring(c.Number) end
  local byPlot = {}
  for _, p in ipairs(result.Plan) do byPlot[p.X .. "," .. p.Y] = numbers[p.City] end
  local named = 0
  for i = pins + 1, #w:Pins() do
    local pin = w:Pins()[i]
    local want = byPlot[pin:GetHexX() .. "," .. pin:GetHexY()]
    if want ~= nil then
      T.eq(pin:GetName(), want, "pin at " .. pin:GetHexX() .. "," .. pin:GetHexY())
      named = named + 1
    end
  end
  T.ok(named > 0, "district pins named with city numbers")
  for _, c in ipairs(result.Cities) do
    if c.Kind == "SITE" and c.Name ~= "" then T.eq(tostring(c.Number), c.Name, "a numbered site keeps its number") end
  end
  T.eq(multi.Undo(), placed, "undo")
end)

test("several cities tab: a city's own list, role templates, an empire-limited district kept in one city", function()
  SDP_Panel.SelectTab("MULTI")
  local multi = SDP_Panel.Multi
  multi.Refresh()
  multi.SetWonder("BUILDING_HANGING_GARDENS", false)
  multi.SetPlanFor("ALL")
  multi.ApplyPlan({ "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE" })
  -- Templates come from the adjacency rules.
  local byYield = {}
  for _, t in ipairs(SDP_Rules.Templates(0)) do byYield[t.Yield] = t.Districts end
  T.ok(byYield.YIELD_SCIENCE and byYield.YIELD_SCIENCE[1] == "DISTRICT_CAMPUS", "science template")
  T.ok(byYield.YIELD_FAITH and byYield.YIELD_FAITH[1] == "DISTRICT_HOLY_SITE", "faith template")
  T.eq(#multi.State().View.Templates, #SDP_Rules.Templates(0) + 1, "templates and clear on the shared list")

  local capital
  for _, part in ipairs(SDP_Multi.Participants(0, {})) do
    if part.Kind == "CITY" then capital = part.Key end
  end
  T.ok(capital ~= nil, "the capital takes part")
  multi.SetPlanFor(capital)
  T.eq(#multi.State().View.Templates, #SDP_Rules.Templates(0) + 2, "a city's list can go back to the shared one")
  -- The first change starts the city's own list from the shared one.
  multi.SetSelected("DISTRICT_GOVERNMENT", true)
  T.same(multi.State().View.Plans[capital], { "DISTRICT_CAMPUS", "DISTRICT_GOVERNMENT", "DISTRICT_HOLY_SITE" }, "own list")
  local status
  for _, d in ipairs(multi.State().View.Districts) do
    if d.Type == "DISTRICT_GOVERNMENT" then status = d.Status end
  end
  T.ok(status and status:find("LIMITED_ONE", 1, true) or (status and #status > 0), "limited district shows where it goes: " .. tostring(status))
  local request = multi.Request()
  T.same(request.Districts, { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE" }, "shared list")
  T.same(request.Plans[capital], { "DISTRICT_CAMPUS", "DISTRICT_GOVERNMENT", "DISTRICT_HOLY_SITE" }, "the capital's list is sent")

  multi.SetTier("FAST")
  T.ok(multi.Solve(), "started")
  SDP_Panel.RunTask(500)
  local result = multi.State().Result
  T.ok(result and result.Ok, "multi result: " .. tostring(result and result.Error))
  local govs = 0
  for _, p in ipairs(result.Plan) do
    if p.Type == "DISTRICT_GOVERNMENT" then
      govs = govs + 1
      T.eq(p.City, capital, "the government plaza stays in the city whose list has it")
    end
  end
  T.eq(govs, 1, "one government plaza")
  -- A template replaces the edited list; "shared" drops the city's own list.
  multi.ApplyPlan(byYield.YIELD_SCIENCE)
  T.same(multi.State().View.Plans[capital], byYield.YIELD_SCIENCE, "template applied to the city")
  T.eq(multi.State().Result, nil, "a list change clears the result")
  multi.ApplyPlan(nil)
  T.eq(multi.State().View.Plans[capital], nil, "back to the shared list")
  multi.SetPlanFor("ALL")
end)

-- Through the cells' own click handlers, round every state and back. (The
-- game's mouse routing is not modelled here: validate.py checks that nothing
-- covers a cell, see check_click_cover.)
test("district cells: a click goes round the states on both tabs", function()
  local function Round(rows, districtType, want)
    for _, state in ipairs(want) do
      local row = nil
      for _, r in ipairs(rows()) do
        if r.Type == districtType then row = r end
      end
      T.eq(row.State, state, districtType)
      row.Cell:Click()
    end
  end
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(1)
  local single = function() return SDP_Panel.State().DistrictRows end
  Round(single, "DISTRICT_ENTERTAINMENT_COMPLEX", { "POOL", "MUST", "OFF", "POOL" })
  Round(single, "DISTRICT_AQUEDUCT", { "AUTO", "MUST", "OFF", "AUTO" })
  Round(single, "DISTRICT_NEIGHBORHOOD", { "OFF", "MUST", "OFF" })
  SDP_Panel.SelectTab("MULTI")
  local multi = SDP_Panel.Multi
  multi.Refresh()
  local rows = function() return multi.State().View.Districts end
  Round(rows, "DISTRICT_ENTERTAINMENT_COMPLEX", { "POOL", "MUST", "OFF", "POOL" })
  Round(rows, "DISTRICT_AQUEDUCT", { "AUTO", "MUST", "OFF", "AUTO" })
end)

-- The harbor / commercial hub switch (SDP_Rules.Apart): named from the
-- rules, on by default, sent with the request, toggled through its box.
test("the harbor and commercial hub switch on both tabs", function()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(1)
  local c = UI_Mock.Controls
  T.eq(c.ApartBox:IsHidden(), false, "shown: the rules have the pair")
  T.ok(c.ApartLabel:GetText():find("LOC_DISTRICT_HARBOR_NAME", 1, true) ~= nil, "named: " .. c.ApartLabel:GetText())
  T.ok(c.ApartBox:GetToolTipString():find("LOC_BUILDING_LIGHTHOUSE_NAME", 1, true) ~= nil, "the rule in the tooltip")
  T.eq(SDP_Panel.State().Apart, true, "on by default")
  T.eq(c.ApartCheck:IsChecked(), true, "ticked")
  c.ApartCheck:Toggle()
  T.eq(SDP_Panel.State().Apart, false, "off through the box")
  c.ApartCheck:Toggle()
  T.eq(SDP_Panel.State().Apart, true, "on again")
  SDP_Panel.SelectTab("MULTI")
  local multi = SDP_Panel.Multi
  multi.Refresh()
  T.eq(c.MultiApartBox:IsHidden(), false, "shown on the multi-city tab")
  T.eq(multi.State().Apart, true, "on by default")
  multi.SetPlanFor("ALL")
  multi.ApplyPlan({ "DISTRICT_CAMPUS" })
  T.eq(multi.Request().Apart, true, "sent")
  c.MultiApartCheck:Toggle()
  T.eq(multi.Request().Apart, false, "off through the box")
  c.MultiApartCheck:Toggle()
end)

-- The swap switch (issue 54): off by default, sent with the request on both
-- tabs, toggled through its box.
test("the swap switch on both tabs", function()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(1)
  local c = UI_Mock.Controls
  T.eq(SDP_Panel.State().Swap, false, "off by default")
  T.eq(c.SwapCheck:IsChecked(), false, "unticked")
  c.SwapCheck:Toggle()
  T.eq(SDP_Panel.State().Swap, true, "on through the box")
  c.SwapCheck:Toggle()
  T.eq(SDP_Panel.State().Swap, false, "off again")
  SDP_Panel.SelectTab("MULTI")
  local multi = SDP_Panel.Multi
  multi.Refresh()
  multi.SetPlanFor("ALL")
  multi.ApplyPlan({ "DISTRICT_CAMPUS" })
  T.eq(multi.Request().Swap, false, "off by default")
  c.MultiSwapCheck:Toggle()
  T.eq(multi.Request().Swap, true, "on through the box")
  c.MultiSwapCheck:Toggle()
  T.eq(multi.State().Swap, false, "off again")
end)

-- Issue 61: the coverage column on the single-city tab, through its arrows'
-- own click handlers; the solve, the rows and the wonder path carry it.
test("single-city tab: the coverage column", function()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(1)
  local IZ = "DISTRICT_INDUSTRIAL_ZONE"
  for _, d in ipairs(SDP_Rules.PlannableDistricts(0)) do SDP_Panel.SetState(d.Type, SDP_UI.DefaultState(d)) end
  SDP_Panel.SetState(IZ, "MUST")
  SDP_Panel.SetState("DISTRICT_AQUEDUCT", "OFF")
  SDP_Panel.SetTier("FAST")
  local cells = SDP_Panel.State().WeightCells
  -- Issue 53: no food or harvest column; one land column instead of the switch.
  local keys = {}
  for i, c in ipairs(cells) do keys[i] = c.Key end
  T.same(keys, { "YIELD_SCIENCE", "YIELD_CULTURE", "YIELD_FAITH", "YIELD_GOLD", "YIELD_PRODUCTION", "LAND", "DISTANCE",
    "HOUSING", "COVERAGE" }, "the columns")
  T.eq(cells[6].Root:GetToolTipString(), "LOC_SDP_LAND", "the land column explains the fixed plot weights")
  local cell = cells[9]
  T.eq(cell.Key, "COVERAGE", "coverage last")
  T.eq(cell.Root:GetToolTipString(), "LOC_SDP_WEIGHT_COVERAGE", "the same tooltip as the several cities tab")
  T.eq(SDP_Panel.State().Weights.COVERAGE, 0, "off by default")
  T.eq(cell.Value:GetText(), "0", "shows 0")
  T.ok(cell.Less:IsDisabled(), "cannot go below 0")
  local off = SDP_Panel.Solve()
  T.ok(off and off.Ok, "solved: " .. tostring(off and off.Error))
  T.eq(off.Session.Request.Coverage, 0, "weight 0 in the request")
  T.eq(off.Covered, nil, "no coverage figures at 0")
  cell.More:Click()
  T.eq(SDP_Panel.State().Weights.COVERAGE, 0.5, "up by 0.5 (issue 53)")
  T.eq(cell.Value:GetText(), "0.5", "shown")
  for _ = 1, 7 do cell.More:Click() end
  T.eq(SDP_Panel.State().Weights.COVERAGE, SDP_UI.MAX_WEIGHT, "up by the arrow, capped")
  T.ok(cell.More:IsDisabled(), "the arrow stops at the cap")
  cell.Less:Click()
  cell.Less:Click()
  T.eq(SDP_Panel.State().Weights.COVERAGE, SDP_UI.MAX_WEIGHT - 1, "down by the arrow")
  T.eq(cell.Value:GetText(), tostring(SDP_UI.MAX_WEIGHT - 1), "shown")
  T.eq(SDP_Panel.State().Result, nil, "a weight change clears the result")
  local on = SDP_Panel.Solve()
  T.ok(on and on.Ok, "solved: " .. tostring(on and on.Error))
  T.eq(on.Session.Request.Coverage, SDP_UI.MAX_WEIGHT - 1, "the weight is sent")
  T.ok(on.Covered ~= nil and on.Covered >= 1, "the zone covers its own city at least")
  T.near(on.CoverageDelta, (SDP_UI.MAX_WEIGHT - 1) * on.Covered, 1e-9, "weight x newly covered cities")
  local rows = 0
  for _, row in ipairs(SDP_Panel.State().ResultRows) do
    if row.Detail:find("LOC_SDP_COVERAGE_ROW", 1, true) then
      rows = rows + 1
      T.ok(row.ToolTip:find("LOC_SDP_COVERAGE_TIP", 1, true) ~= nil, "the row's tooltip names the cities")
    end
  end
  T.eq(rows, 1, "the industrial zone's row")
  T.ok(UI_Mock.Controls.Summary:GetToolTipString():find("LOC_SDP_COVERAGE_GROUP", 1, true) ~= nil,
    "the summary's tooltip lists the newly covered cities")
  -- With a wonder the city goes to SDP_Multi: the weight goes with it.
  SDP_Panel.SetWonder("BUILDING_STONEHENGE", true)
  T.eq(SDP_Panel.Solve(), nil, "a task")
  local wonder = SDP_Panel.RunTask(500)
  T.ok(wonder and wonder.Ok, "result: " .. tostring(wonder and wonder.Error))
  T.eq(wonder.Session.Request.Coverage, SDP_UI.MAX_WEIGHT - 1, "the weight goes with the wonder request")
  T.ok(wonder.Covered ~= nil, "coverage figures")
  local keys = {}
  for _, target in ipairs(wonder.Session.Coverage.Targets) do keys[#keys + 1] = target.Key end
  local want = { "C1" }
  for _, site in ipairs(SDP_Coverage.SiteTargets(0)) do want[#want + 1] = site.Key end
  T.ok(#want >= 2, "city-center pins on the map")
  T.same(keys, want, "the city and every city-center pin are cities to cover")
  SDP_Panel.SetWonder("BUILDING_STONEHENGE", false)
  for _ = 1, 4 do cell.Less:Click() end
  T.eq(SDP_Panel.State().Weights.COVERAGE, 0, "back to 0")
  for _, d in ipairs(SDP_Rules.PlannableDistricts(0)) do SDP_Panel.SetState(d.Type, SDP_UI.DefaultState(d)) end
  SDP_Panel.SetTier("STANDARD")
end)

-- Through the chip's own callback, as a click would.
test("several cities tab: a click on a chip switches a city-center pin and a city off and on", function()
  SDP_Panel.SelectTab("MULTI")
  local multi = SDP_Panel.Multi
  multi.Refresh()
  local function Find(k)
    for _, c in ipairs(multi.State().View.Cities) do
      if c.Key == k then return c end
    end
  end
  local site = nil
  for _, c in ipairs(multi.State().View.Cities) do
    if c.Kind == "SITE" and c.Included and site == nil then site = c end
  end
  T.ok(site ~= nil, "a city-center pin, on")
  local key = site.Key
  site.Chip:Click()
  T.eq(Find(key).Included, false, "clicked: off")
  for _, part in ipairs(multi.Participants()) do T.ok(part.Key ~= key, "takes no part") end
  Find(key).Chip:Click()
  T.eq(Find(key).Included, true, "clicked again: on")
  local city = Find("C1")
  local on = city.Included
  city.Chip:Click()
  T.eq(Find("C1").Included, not on, "a city switched")
  Find("C1").Chip:Click()
  T.eq(Find("C1").Included, on, "and back")
end)

-- City-center pins from the sites tab are named with their numbers like
-- district pins; "replace" must leave them alone.
test("several cities tab: replacing earlier pins keeps the city-center pins", function()
  SDP_Panel.SelectTab("SITES")
  local sites = SDP_Panel.Sites
  sites.SetCount(2)
  sites.SetDistance(7)
  sites.SetSelected("DISTRICT_CAMPUS", true)
  T.ok(sites.Solve(), "started")
  SDP_Panel.RunTask(200)
  T.eq(sites.Place(), 2, "two site tacks")
  local function Centers()
    local out = {}
    for _, pin in ipairs(w:Pins()) do
      if pin:GetIconName() == "ICON_DISTRICT_CITY_CENTER" then out[#out + 1] = pin:GetHexX() .. "," .. pin:GetHexY() end
    end
    return table.concat(out, " ")
  end
  local before = Centers()
  SDP_Panel.SelectTab("MULTI")
  local multi = SDP_Panel.Multi
  multi.Refresh()
  T.eq(#multi.OwnPins(), 0, "no earlier district pins yet")
  multi.SetPlanFor("ALL")
  multi.ApplyPlan({ "DISTRICT_CAMPUS" })
  multi.SetTier("FAST")
  T.ok(multi.Solve(), "started")
  SDP_Panel.RunTask(500)
  local first = multi.Place()
  T.ok(first > 0, "placed")
  multi.SetReplace(true)
  T.ok(#multi.OwnPins() > 0, "the district pins are ours to replace")
  for _, record in ipairs(multi.OwnPins()) do T.ok(record.Icon ~= "ICON_DISTRICT_CITY_CENTER", "no center pin among them") end
  T.ok(multi.Solve(), "started again")
  SDP_Panel.RunTask(500)
  local result = multi.State().Result
  T.ok(result and result.Ok, "result: " .. tostring(result and result.Error))
  T.eq(#result.Cities, #multi.Participants(), "every site still takes part")
  multi.Place()
  T.eq(Centers(), before, "the city-center pins stay")
  multi.Undo()
  T.eq(Centers(), before, "and stay after undo")
  multi.Undo()
  multi.SetReplace(false)
end)

test("closing the panel clears the preview; a background result marks the launch button", function()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SetTier("FINE")
  SDP_Panel.Solve()
  SDP_Panel.Close()
  T.eq(UI_Mock.Lenses.hexes[SDP_Preview.LAYER] or 0, 0, "no preview while closed")
  -- A hidden context gets no updates: it stays shown, its window hidden.
  T.ok(SDP_Panel.RunsHidden(), "context shown, window hidden while the task runs")
  SDP_Panel.RunTask(1000)
  T.ok(SDP_Panel.State().LaunchMark, "mark on the launch button")
  T.ok(UI_Mock.Controls.DropShadow ~= nil and ContextPtr:IsHidden() and not UI_Mock.Controls.DropShadow:IsHidden(),
    "hidden again, window restored")
  T.eq(UI_Mock.Lenses.hexes[SDP_Preview.LAYER] or 0, 0, "no preview from the result while closed")
  SDP_Panel.Open()
  T.ok(not SDP_Panel.State().LaunchMark, "mark gone after opening")
  SDP_Panel.SetTier("STANDARD")
end)

test("a result that ends while the panel is closed leaves no preview on the map", function()
  SDP_Panel.Open()
  SDP_Panel.SelectTab("SITES")
  SDP_Panel.Sites.Solve()
  SDP_Panel.Close()
  SDP_Panel.RunTask(1000)
  T.eq(UI_Mock.Lenses.hexes[SDP_Preview.LAYER] or 0, 0, "no preview while closed")
  SDP_Panel.Open()
  T.ok((UI_Mock.Lenses.hexes[SDP_Preview.LAYER] or 0) > 0, "preview back when the tab opens")
  SDP_Panel.Close()
end)

-- Issue 67: Solve greyed with nothing to plan, cells without tooltips, the
-- camera beside the panel on a new result or another solution only, result
-- rows that move the camera, summary tooltips without the search's counts,
-- city numbers on the several cities tab's preview pins.
test("issue 67: what to do first, the camera, clickable rows, plain tooltips", function()
  SDP_Panel.Open()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(1)
  for _, row in ipairs(SDP_Panel.State().DistrictRows) do
    SDP_Panel.SetState(row.Type, "OFF")
  end
  SDP_Panel.SetCount(0)
  local state = SDP_Panel.State()
  T.ok(state.SolveDisabled, "Solve greyed with nothing to plan")
  T.eq(state.SummaryText, "LOC_SDP_RESULT_NONE", "the summary says what to do")
  for _, row in ipairs(state.DistrictRows) do
    T.eq(row.Cell:GetToolTipString(), "", "no tooltip on " .. row.Type)
  end
  -- A required district through the cell's own click: Solve comes back.
  local campus = nil
  for _, row in ipairs(SDP_Panel.State().DistrictRows) do
    if row.Type == "DISTRICT_CAMPUS" then campus = row end
  end
  campus.Cell:Click() -- OFF -> POOL
  campus.Cell:Click() -- POOL -> MUST
  state = SDP_Panel.State()
  T.ok(not state.SolveDisabled, "Solve back with a required district")
  T.eq(state.SummaryText, "LOC_SDP_RESULT_READY", "the summary says to press Solve")

  local looks = #UI_Mock.Looks
  local result = SDP_Panel.Solve()
  T.ok(result and result.Ok, "solve")
  T.eq(#UI_Mock.Looks, looks + 1, "the camera moves once for the new result")
  local look = UI_Mock.Looks[#UI_Mock.Looks]
  T.eq(look.X .. "," .. look.Y, "4,5", "to the city")
  T.ok(look.ScreenX > 0.5, "right of the panel")
  T.ok(SDP_Panel.State().SummaryToolTip:find("LOC_SDP_RESULT_STATS", 1, true) == nil, "no search counts")
  -- Reopening shows the same result without moving the camera.
  SDP_Panel.Close()
  SDP_Panel.Open()
  T.eq(#UI_Mock.Looks, looks + 1, "reopening keeps the camera")
  -- A planned district's row: a click moves the camera to its plot.
  local row = nil
  for _, r in ipairs(SDP_Panel.State().ResultRows) do
    if r.X ~= nil and row == nil then row = r end
  end
  T.ok(row ~= nil, "a row with a plot")
  T.ok(row.Row:GetToolTipString():find("LOC_SDP_RESULT_LOOK", 1, true) == 1, "its tooltip says a click moves the camera (issue 75)")
  row.Row:Click()
  look = UI_Mock.Looks[#UI_Mock.Looks]
  T.eq(look.X .. "," .. look.Y, row.X .. "," .. row.Y, "the row's plot")

  -- Several cities: pins carry the city's number, the camera goes to the cities.
  SDP_Panel.SelectTab("MULTI")
  local multi = SDP_Panel.Multi
  multi.Refresh()
  multi.SetSelected("DISTRICT_CAMPUS", true)
  multi.SetTier("FAST")
  looks = #UI_Mock.Looks
  T.ok(not multi.State().SolveDisabled, "Solve on with something to plan")
  T.ok(multi.Solve(), "started")
  SDP_Panel.RunTask(500)
  local mresult = multi.State().Result
  T.ok(mresult and mresult.Ok, "multi result: " .. tostring(mresult and mresult.Error))
  T.eq(#UI_Mock.Looks, looks + 1, "the camera moves once for the new result")
  T.ok(multi.State().SummaryToolTip:find("LOC_SDP_MULTI_STATS", 1, true) == nil, "no search counts")
  local numbers = {}
  for _, c in ipairs(mresult.Cities) do numbers[c.Key] = tostring(c.Number) end
  local byPlot = {}
  for _, p in ipairs(mresult.Plan) do byPlot[p.X .. "," .. p.Y] = numbers[p.City] end
  local checked = 0
  for _, icon in ipairs(multi.State().View.PreviewIcons) do
    local want = byPlot[icon.X .. "," .. icon.Y]
    if want ~= nil and icon.Icon ~= "ICON_DISTRICT_CITY_CENTER" then
      T.ok(icon.Text == want or icon.Text:find("LOC_SDP_PREVIEW_CITY", 1, true) ~= nil, "pin text " .. icon.Text)
      checked = checked + 1
    end
  end
  T.ok(checked > 0, "district pins checked")
  multi.SelectSolution(1)
  T.eq(#UI_Mock.Looks, looks + 2, "another solution moves the camera too")
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.Close()
end)

-- Issue 75: the sites of a solution one after another: the selected
-- solution's button again, the row of a site, "next site" while peeking.
test("issue 75: the selected solution again, a site's row and next site while peeking go through its sites", function()
  SDP_Panel.Open()
  SDP_Panel.SelectTab("SITES")
  local sites = SDP_Panel.Sites
  sites.SetCount(2)
  sites.SetDistance(7)
  sites.SetSelected("DISTRICT_CAMPUS", true)
  T.ok(sites.Solve(), "started")
  SDP_Panel.RunTask(200)
  local result = sites.State().Result
  T.ok(result and result.Ok, "sites result")
  local n = sites.State().Solution
  local solution = result.Solutions[n]
  T.eq(#solution.Sites, 2, "two sites")
  local function Look() local l = UI_Mock.Looks[#UI_Mock.Looks]; return l.X .. "," .. l.Y end
  local function At(s) return solution.Sites[s].X .. "," .. solution.Sites[s].Y end
  T.eq(Look(), At(1), "a new result: the first site")
  local cell = sites.State().View.Solutions[n].Cell
  T.ok(cell:GetToolTipString():find("LOC_SDP_SITES_SOLUTION_NEXT", 1, true), "its tooltip says to click again")
  cell:Click()
  T.eq(Look(), At(2), "clicked again: the second site")
  T.eq(sites.State().Solution, n, "the same solution")
  sites.State().View.Solutions[n].Cell:Click()
  T.eq(Look(), At(1), "after the last, the first")
  -- A site's row: the camera there, and "next" goes on from it.
  local row = sites.State().View.Results[2]
  T.ok(row.Row:GetToolTipString():find("LOC_SDP_RESULT_LOOK", 1, true) == 1, "the row says a click moves the camera")
  row.Row:Click()
  T.eq(Look(), At(2), "the row's site")
  T.eq(sites.State().Site, 2, "remembered")
  -- Peeking: next site while the window is hidden.
  local c = UI_Mock.Controls
  c.PeekButton:Click()
  T.eq(c.PeekNextSite:IsHidden(), false, "next site shown while peeking")
  c.PeekNextSite:Click()
  T.eq(Look(), At(1), "next site: round to the first")
  T.eq(SDP_Panel.State().Peek, true, "still peeking")
  c.PeekReturn:Click()
  T.eq(c.PeekNextSite:IsHidden(), true, "gone with the peek")
  -- Not on the other tabs.
  SDP_Panel.SelectTab("SINGLE")
  c.PeekButton:Click()
  T.eq(c.PeekNextSite:IsHidden(), true, "single-city tab: no next site")
  c.PeekReturn:Click()
  -- One site: nothing to go through.
  SDP_Panel.SelectTab("SITES")
  sites.SetCount(1)
  T.ok(sites.Solve(), "one site")
  SDP_Panel.RunTask(200)
  local one = sites.State().View.Solutions[sites.State().Solution].Cell
  T.ok(one:GetToolTipString():find("LOC_SDP_SITES_SOLUTION_NEXT", 1, true) == nil, "one site: no click-again note")
  c.PeekButton:Click()
  T.eq(c.PeekNextSite:IsHidden(), true, "one site: no next site")
  c.PeekReturn:Click()
  sites.SetSelected("DISTRICT_CAMPUS", false)
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.Close()
end)

-- Issue 71: the window fits the screen, the settings fold, the map can be
-- seen without the window, the solutions are one row of buttons.
test("issue 71: the window's height follows the screen", function()
  T.eq(SDP_UI.WindowHeight(1080), 960, "1080: from below the launch bar to 35 above the bottom")
  T.eq(SDP_UI.WindowHeight(1440), 1320, "a tall screen: higher")
  T.eq(SDP_UI.WindowHeight(768), 648, "a low screen: lower")
  T.eq(SDP_UI.WindowHeight(500), SDP_UI.WINDOW_MIN, "never below the minimum")
  UI_Mock.Screen = 1440
  w.Events.SystemUpdateUI(SystemUpdateUI.ScreenResize)
  T.eq(SDP_Panel.State().WindowHeight, 1320, "a resize fits the window again")
  T.eq(UI_Mock.Controls.Window:GetSizeY(), 1320, "the window")
  T.eq(UI_Mock.Controls.SinglePage:GetSizeY(), 1320 - SDP_UI.PAGE_INSET, "and its pages")
  UI_Mock.Screen = nil
  SDP_Panel.FitWindow()
  -- The result list takes what the page leaves (the stub's stack is 30 high).
  local scroll, body, page = UI_Mock.NewControl("s"), UI_Mock.NewControl("b"), UI_Mock.NewControl("p")
  page:SetSizeY(500)
  function body:GetSizeY() return 400 + scroll:GetSizeY() end
  T.eq(SDP_UI.FitResults(body, page, scroll), 100, "fills the page")
  page:SetSizeY(420)
  T.eq(SDP_UI.FitResults(body, page, scroll), SDP_UI.RESULT_MIN, "never below one row")
end)

test("issue 71: the settings fold after a solve and a click unfolds them; kept in the save", function()
  SDP_Panel.Open()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(1)
  local c = UI_Mock.Controls
  for _, column in ipairs(SDP_UI.WEIGHT_COLUMNS) do SDP_Panel.SetWeight(column.Key, column.Default or 1) end
  SDP_Panel.SetWeight("COVERAGE", 0)
  SDP_Panel.SetFold(false)
  T.eq(c.SettingsStack:IsHidden(), false, "unfolded")
  T.eq(c.FoldAction:GetText(), "LOC_SDP_FOLD_HIDE", "the line offers to hide")
  T.ok(c.FoldText:GetText():find("LOC_SDP_PRESET_BALANCED", 1, true) ~= nil, "the preset named: " .. c.FoldText:GetText())
  SDP_Panel.SetLand(false)
  T.ok(c.FoldText:GetText():find("LOC_SDP_FOLD_LAND_OFF", 1, true) ~= nil, "a switch not as usual is named")
  T.ok(c.FoldText:GetText():find("LOC_SDP_FOLD_EDITED", 1, true) ~= nil, "the preset shows it was changed")
  SDP_Panel.SetLand(true)
  T.ok(c.FoldText:GetText():find("LOC_SDP_FOLD_EDITED", 1, true) == nil, "back as the preset")
  SDP_Panel.SetTier("FAST")
  SDP_Panel.SetState("DISTRICT_CAMPUS", "MUST")
  SDP_Panel.SetState("DISTRICT_AQUEDUCT", "OFF")
  SDP_Panel.SetCount(0)
  local result = SDP_Panel.Solve()
  T.ok(result and result.Ok, "solved")
  T.eq(SDP_Panel.State().Fold, true, "folded by the solve")
  T.eq(c.SettingsStack:IsHidden(), true, "settings hidden")
  T.eq(c.FoldAction:GetText(), "LOC_SDP_FOLD_SHOW", "the line offers to show")
  T.ok(PlayerConfigurations[0]:GetValue("SDP_Settings_SINGLE"):find(";FOLD=1", 1, true) ~= nil, "kept in the save")
  c.FoldButton:Click()
  T.eq(SDP_Panel.State().Fold, false, "a click unfolds")
  T.eq(c.SettingsStack:IsHidden(), false, "settings shown")
  T.ok(PlayerConfigurations[0]:GetValue("SDP_Settings_SINGLE"):find("FOLD", 1, true) == nil, "unfolded is the default")
  -- The other tabs fold the same way.
  local multi = SDP_Panel.Multi
  multi.SetFold(true)
  T.eq(c.MultiSettingsStack:IsHidden(), true, "several cities: folded")
  c.MultiFoldButton:Click()
  T.eq(multi.State().Fold, false, "and a click unfolds")
  local sites = SDP_Panel.Sites
  sites.SetFold(true)
  T.eq(c.SitesSettingsStack:IsHidden(), true, "city sites: folded")
  c.SitesFoldButton:Click()
  T.eq(sites.State().Fold, false, "and unfolded")
end)

test("issue 71: peek hides the window and keeps the preview; the button or Esc bring it back", function()
  SDP_Panel.Open()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(1)
  SDP_Panel.SetTier("FAST")
  SDP_Panel.SetState("DISTRICT_CAMPUS", "MUST")
  SDP_Panel.SetState("DISTRICT_AQUEDUCT", "OFF")
  SDP_Panel.SetCount(0)
  local result = SDP_Panel.Solve()
  T.ok(result and result.Ok, "solved")
  local c = UI_Mock.Controls
  local hexes = UI_Mock.Lenses.hexes[SDP_Preview.LAYER] or 0
  T.ok(hexes > 0, "previewed")
  c.PeekButton:Click()
  T.eq(SDP_Panel.State().Peek, true, "peeking")
  T.eq(c.DropShadow:IsHidden(), true, "the window hidden")
  T.eq(c.PeekReturn:IsHidden(), false, "the way back shown")
  T.ok(SDP_Panel.IsOpen(), "the panel is still open")
  T.eq(ContextPtr:IsHidden(), false, "its context shown (pitfall 23)")
  T.eq(UI_Mock.Lenses.hexes[SDP_Preview.LAYER], hexes, "the preview stays")
  c.PeekReturn:Click()
  T.eq(c.DropShadow:IsHidden(), false, "back")
  T.eq(c.PeekReturn:IsHidden(), true, "the button gone")
  c.PeekButton:Click()
  T.eq(SDP_Panel.HandleInput(KeyEvents.KeyUp, Keys.VK_ESCAPE), true, "Esc taken")
  T.eq(SDP_Panel.State().Peek, false, "Esc ends the peek")
  T.ok(SDP_Panel.IsOpen(), "and leaves the panel open")
  c.PeekButton:Click()
  SDP_Panel.Close()
  T.eq(SDP_Panel.State().Peek, false, "closing ends a peek")
  T.eq(c.PeekReturn:IsHidden(), true, "no button left behind")
  SDP_Panel.Open()
  T.eq(c.DropShadow:IsHidden(), false, "opens with the window")
end)

test("issue 71: the solutions are buttons in one row, their districts in the tooltip", function()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(1)
  SDP_Panel.SetTier("FAST")
  for _, d in ipairs(SDP_Rules.PlannableDistricts(0)) do SDP_Panel.SetState(d.Type, SDP_UI.DefaultState(d)) end
  SDP_Panel.SetState("DISTRICT_CAMPUS", "MUST")
  SDP_Panel.SetCount(3)
  T.eq(SDP_Panel.Solve(), nil, "picking runs as a task")
  local result = SDP_Panel.RunTask(200)
  T.ok(result and result.Ok, "solved")
  local cells = SDP_Panel.State().SolutionCells
  T.ok(#cells >= 2, "several solutions: " .. #cells)
  for n, cell in ipairs(cells) do
    T.eq(cell:GetToolTipString(), SDP_UI.SolutionDetail(result.Solutions[n]), "solution " .. n .. "'s districts")
  end
  cells[2]:Click()
  T.eq(SDP_Panel.State().Solution, 2, "a click selects one")
  SDP_Panel.SetCount(0)
end)

-- Issue 66 (plan A): a chosen wonder's district shows "for wonder" and the
-- solve plans it; the player's "not wanted" wins; the stored state is left.
test("issue 66: a wonder's district is supplied, shown, marked; not wanted stands", function()
  SDP_Panel.Open()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(1)
  local ENT = "DISTRICT_ENTERTAINMENT_COMPLEX"
  for _, d in ipairs(SDP_Rules.PlannableDistricts(0)) do SDP_Panel.SetState(d.Type, SDP_UI.DefaultState(d)) end
  SDP_Panel.SetState("DISTRICT_AQUEDUCT", "OFF")
  SDP_Panel.SetState("DISTRICT_CAMPUS", "MUST")
  SDP_Panel.SetCount(0)
  SDP_Panel.SetTier("FAST")
  local function Row(districtType)
    for _, r in ipairs(SDP_Panel.State().DistrictRows) do
      if r.Type == districtType then return r end
    end
  end
  T.eq(Row(ENT).State, "POOL", "a candidate before")
  SDP_Panel.SetWonder("BUILDING_COLOSSEUM", true)
  T.eq(Row(ENT).State, "WONDER", "for the wonder")
  T.eq(UI_Mock.Controls.DistrictStack ~= nil, true, "grid")
  SDP_Panel.Solve()
  local result = SDP_Panel.RunTask(500)
  T.ok(result and result.Ok, "solved: " .. tostring(result and result.Error))
  local complex, colosseum = nil, nil
  for _, p in ipairs(result.Plan) do
    if p.Type == ENT then complex = p end
    if p.Type == "BUILDING_COLOSSEUM" then colosseum = p end
  end
  T.ok(complex ~= nil and colosseum ~= nil, "both planned")
  T.eq(complex.ForWonder, "BUILDING_COLOSSEUM", "supplied for it")
  local marked = false
  for _, row in ipairs(SDP_Panel.State().ResultRows) do
    if row.Detail:find("LOC_SDP_RESULT_FOR_WONDER(LOC_BUILDING_COLOSSEUM_NAME)", 1, true) then marked = true end
  end
  T.ok(marked, "its row says what it is for")
  -- A click goes on from its own state: candidate -> required.
  Row(ENT).Cell:Click()
  T.eq(Row(ENT).State, "MUST", "required now")
  Row(ENT).Cell:Click()
  T.eq(Row(ENT).State, "OFF", "not wanted: the player's choice")
  SDP_Panel.Solve()
  local off = SDP_Panel.RunTask(500)
  local reason = nil
  for _, u in ipairs(off.Unplaced) do
    if u.Type == "BUILDING_COLOSSEUM" then reason = u.Reason end
  end
  T.eq(reason, "NEEDS_DISTRICT", "the colosseum is left out")
  local named = false
  for _, row in ipairs(SDP_Panel.State().ResultRows) do
    if row.Detail:find("LOC_SDP_REASON_NEEDS_DISTRICT(LOC_DISTRICT_ENTERTAINMENT_COMPLEX_NAME", 1, true) then named = true end
  end
  T.ok(named, "naming the district")
  Row(ENT).Cell:Click()
  T.eq(Row(ENT).State, "WONDER", "back to a candidate: for the wonder again")
  SDP_Panel.SetWonder("BUILDING_COLOSSEUM", false)
  T.eq(Row(ENT).State, "POOL", "without the wonder: as it was")
  -- Several cities: a line says the first city of the list gets it.
  local multi = SDP_Panel.Multi
  SDP_Panel.SelectTab("MULTI")
  multi.SetWonder("BUILDING_COLOSSEUM", true)
  local supply = multi.State().View.Supply
  T.eq(#supply, 1, "one line")
  T.ok(supply[1]:find("LOC_SDP_MULTI_SUPPLY", 1, true) ~= nil, "before a solve: who will get it")
  multi.SetWonder("BUILDING_COLOSSEUM", false)
  T.eq(#multi.State().View.Supply, 0, "no line without the wonder")
  SDP_Panel.SelectTab("SINGLE")
end)

-- Issue 49: a preset from its pulldown entry sets the weights; a change
-- marks it changed; Reset puts it back; the save keeps the preset's name.
test("issue 49: presets through their pulldown, changed, reset, kept", function()
  SDP_Panel.Open()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(1)
  local c = UI_Mock.Controls
  SDP_Panel.SetPreset("BALANCED")
  local entries = c.PresetPull._entries
  T.eq(#entries, #SDP_Settings.PRESET_ORDER, "one entry a preset")
  local science = nil
  for i, name in ipairs(SDP_Settings.PRESET_ORDER) do
    if name == "SCIENCE" then science = entries[i] end
  end
  T.eq(science.Button:GetText(), "LOC_SDP_PRESET_SCIENCE", "named")
  science.Button:Click()
  local s = SDP_Panel.State()
  T.eq(s.Preset, "SCIENCE", "chosen")
  T.eq(s.Weights.YIELD_SCIENCE, SDP_Settings.FOCUS.SCIENCE, "science weight")
  T.eq(s.Weights.YIELD_CULTURE, 1, "the others as balanced")
  T.eq(c.PresetPull:GetButton():GetText(), "LOC_SDP_PRESET_SCIENCE", "shown")
  T.ok(c.PresetReset:IsDisabled(), "nothing to reset")
  T.ok(PlayerConfigurations[0]:GetValue("SDP_Settings_SINGLE"):find("preset=SCIENCE", 1, true) ~= nil, "kept in the save")
  T.ok(PlayerConfigurations[0]:GetValue("SDP_Settings_SINGLE"):find("YIELD_SCIENCE", 1, true) == nil,
    "the preset's own value is not written as a change")
  SDP_Panel.SetWeight("YIELD_GOLD", 2)
  T.eq(c.PresetPull:GetButton():GetText(), "LOC_SDP_FOLD_EDITED(LOC_SDP_PRESET_SCIENCE)", "changed")
  T.ok(c.FoldText:GetText():find("LOC_SDP_FOLD_EDITED(LOC_SDP_PRESET_SCIENCE)", 1, true) ~= nil, "on the fold line too")
  T.eq(c.PresetReset:IsDisabled(), false, "reset offered")
  c.PresetReset:Click()
  T.eq(SDP_Panel.State().Weights.YIELD_GOLD, 1, "reset to the preset")
  T.eq(SDP_Panel.State().Weights.YIELD_SCIENCE, SDP_Settings.FOCUS.SCIENCE, "its own value stays")
  T.ok(c.PresetReset:IsDisabled(), "nothing left to reset")
  -- Several cities: its own preset.
  local multi = SDP_Panel.Multi
  SDP_Panel.SelectTab("MULTI")
  multi.SetPreset("HALF_GOLD_FAITH")
  T.eq(multi.State().Weights.YIELD_GOLD, 0.5, "half gold")
  T.eq(multi.State().Weights.YIELD_FAITH, 0.5, "half faith")
  T.eq(SDP_Panel.State().Preset, "SCIENCE", "the single-city tab keeps its own")
  multi.SetPreset("BALANCED")
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SetPreset("BALANCED")
end)
