-- Offline: "Improve" (continue) on each tab, through the panel's buttons and
-- the frame-by-frame path the game takes (issue 327, item 6): the panel's
-- SetUpdate function is called once per frame, as the game does, not
-- SDP_Panel.RunTask. On the single-city, several-cities and city-sites tabs:
-- the result after a continue is not worse than before; Cancel stops a
-- continue, the result shown before stays and can be continued again; a
-- continue ends within a bounded number of frames and the buttons come back.
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
World.New({
  rows = MAP, rivers = { "6,4", "7,4", "7,5", "12,7", "13,7" },
  cities = {
    { id = 1, x = 4, y = 5, population = 9, capital = true, radius = 2 },
    { id = 2, x = 9, y = 5, population = 7, radius = 1 },
  },
})
UI_Mock.Install()
include("SDP_Panel")
local c = UI_Mock.Controls
local single, multi, sites = SDP_PageSingle, SDP_PageMulti, SDP_PageSites

local MAX_FRAMES = 20000
-- Frames until the computation ends; how many it took.
local function Frames()
  local n = 0
  while SDP_Task.IsRunning() do
    T.ok(UI_Mock.Update ~= nil, "a running computation has its update function set")
    if UI_Mock.Update == nil then break end
    UI_Mock.Update()
    n = n + 1
    if n > MAX_FRAMES then break end
  end
  T.ok(n <= MAX_FRAMES, "ended within " .. MAX_FRAMES .. " frames")
  T.eq(UI_Mock.Update, nil, "the update function is cleared at the end")
  return n
end

local TABS = {
  { Name = "SINGLE", Page = single, Tier = "FINE",
    Buttons = { Solve = c.SolveButton, Continue = c.ContinueButton, Cancel = c.CancelButton, Place = c.PlaceButton },
    Setup = function()
      single.SelectCity(1)
      for _, d in ipairs({ "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER" }) do single.SetSelected(d, true) end
    end,
    TearDown = function()
      for _, d in ipairs({ "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER" }) do single.SetSelected(d, false) end
    end,
    Gain = function(result) return result.Gain end },
  -- The single-city tab with a wonder: SDP_Multi with this one city.
  { Name = "SINGLE_WONDER", Page = single, Tier = "STANDARD",
    Buttons = { Solve = c.SolveButton, Continue = c.ContinueButton, Cancel = c.CancelButton, Place = c.PlaceButton },
    Setup = function()
      single.SelectCity(1)
      for _, d in ipairs({ "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE" }) do single.SetSelected(d, true) end
      single.SetWonder("BUILDING_STONEHENGE", true)
    end,
    TearDown = function()
      single.SetWonder("BUILDING_STONEHENGE", false)
      for _, d in ipairs({ "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE" }) do single.SetSelected(d, false) end
    end,
    Gain = function(result) return result.Gain end },
  { Name = "MULTI", Page = multi, Tier = "STANDARD",
    Buttons = { Solve = c.MultiSolveButton, Continue = c.MultiContinueButton, Cancel = c.MultiCancelButton,
      Place = c.MultiPlaceButton },
    Setup = function()
      multi.AllCities()
      for _, d in ipairs({ "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE" }) do multi.SetSelected(d, true) end
    end,
    TearDown = function()
      for _, d in ipairs({ "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE" }) do multi.SetSelected(d, false) end
      multi.DefaultCities()
    end,
    Gain = function(result) return result.Gain end },
  { Name = "SITES", Page = sites, Tier = "STANDARD",
    Buttons = { Solve = c.SitesSolveButton, Continue = c.SitesContinueButton, Cancel = c.SitesCancelButton,
      Place = c.SitesPlaceButton },
    Setup = function() end, TearDown = function() end,
    Gain = function(result) return result.Solutions[1].Value end },
}

local function Result(tab)
  return tab.Page.State().Result
end

for _, tab in ipairs(TABS) do
  test(tab.Name .. ": Improve through the buttons, frame by frame: cancel, again, not worse, ends", function()
    SDP_Panel.Open()
    SDP_Panel.SelectTab(tab.Page.Name)
    local tier = tab.Page.Kit.Tier
    local ok, err = pcall(function()
      tab.Setup()
      tab.Page.SetTier(tab.Tier)
      local b = tab.Buttons
      b.Solve:Click()
      local solved = Frames()
      local first = Result(tab)
      T.ok(first and first.Ok, "solved: " .. tostring(first and first.Error))
      T.ok(solved > 1, "the solve ran over several frames (" .. solved .. ")")
      T.ok(first.Quality.CanContinue, "setup: the result can be improved")
      T.eq(b.Continue:IsDisabled(), false, "Improve can be clicked")
      local gain = tab.Gain(first)

      -- Improve, then Cancel after a frame: the result shown before stays.
      b.Continue:Click()
      T.ok(SDP_Task.IsRunning(), "Improve runs over several frames")
      T.eq(b.Cancel:IsHidden(), false, "Cancel shows while it runs")
      T.eq(b.Continue:IsHidden(), true, "Improve is hidden while it runs")
      T.eq(b.Place:IsDisabled(), true, "no placing while it runs")
      UI_Mock.Update()
      T.ok(SDP_Task.IsRunning(), "setup: still running after one frame")
      b.Cancel:Click()
      T.ok(not SDP_Task.IsRunning(), "cancelled")
      T.eq(UI_Mock.Update, nil, "no update function after the cancel")
      local kept = Result(tab)
      T.ok(kept ~= nil and kept.Ok, "a result is still shown")
      T.near(tab.Gain(kept), gain, 1e-9, "the result shown before the cancel")
      T.eq(b.Cancel:IsHidden(), true, "Cancel hidden again")
      T.eq(b.Place:IsDisabled(), false, "it can be placed")

      -- Improve again, to the end: not worse, and the buttons come back.
      T.eq(b.Continue:IsDisabled(), false, "Improve can be clicked again")
      b.Continue:Click()
      local frames = Frames()
      T.ok(frames > 1, "the continue ran over several frames (" .. frames .. ")")
      local after = Result(tab)
      T.ok(after and after.Ok, "improved: " .. tostring(after and after.Error))
      T.ok(after ~= kept, "the continue's own result shows, not the one before")
      T.ok(tab.Gain(after) >= gain - 1e-9, "not worse: " .. tostring(tab.Gain(after)) .. " < " .. tostring(gain))
      T.eq(b.Cancel:IsHidden(), true, "Cancel hidden at the end")
      T.eq(b.Continue:IsHidden(), false, "Improve shown at the end")
      T.eq(b.Solve:IsDisabled(), false, "Solve can be clicked at the end")
      T.eq(b.Place:IsDisabled(), false, "the improved plan can be placed")
      T.eq(b.Continue:IsDisabled(), not after.Quality.CanContinue, "Improve follows whether it can go on")
    end)
    if SDP_Task.IsRunning() then SDP_Task.Cancel() end
    tab.TearDown()
    tab.Page.SetTier(tier)
    SDP_Panel.Close()
    if not ok then error(err, 0) end
  end)
end
