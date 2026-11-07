-- Offline: SDP_Panel.Defaults (issue 327), the entry the in-game tests
-- (tools/run_tests.py, before each file) and the screenshot stages
-- (tools/shots.py) use to put the panel back as a new game shows it, so a
-- file never runs on what an earlier one left (issue 320: a plan on the
-- Several cities tab; issue 325: a stage on changed settings). Every change
-- here goes through the tab's own controls. And the page self-check: a body
-- the page cannot hold writes one SDP_LAYOUT_OVERFLOW line to the log.
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
  rows = MAP, rivers = { "6,4", "7,4", "7,5" },
  cities = { { id = 1, x = 4, y = 5, population = 6, capital = true, radius = 1 } },
  pins = { { 13, 9, "ICON_DISTRICT_CITY_CENTER", "" } },
})
UI_Mock.Install()
include("SDP_Panel")
local c = UI_Mock.Controls
local cfg = PlayerConfigurations[0]

local function Copy(t)
  local out = {}
  for k, v in pairs(t or {}) do out[k] = v end
  return out
end

local function Rows(rows)
  local out = {}
  for _, row in ipairs(rows or {}) do out[row.Type] = row.State end
  return out
end

-- What each tab shows and would plan with: settings, lists, cities, result.
local function Snapshot()
  local s, sites, multi = SDP_Panel.State(), SDP_Panel.Sites.State(), SDP_Panel.Multi.State()
  local cities = {}
  for _, v in ipairs(multi.View.Cities or {}) do cities[#cities + 1] = v.Key .. "=" .. tostring(v.Included) end
  local mrows = {}
  for _, row in ipairs(multi.View.Districts or {}) do mrows[row.Type] = row.State end
  return {
    Tab = SDP_Panel.Tab(), Peek = s.Peek,
    Single = { CityID = s.CityID, Result = s.Result ~= nil, Weights = Copy(s.Weights), Tier = s.Tier, Preset = s.Preset,
      Fold = s.Fold, Remind = s.Remind, Removal = s.AllowFeatureRemoval, Swap = s.Swap, Replace = s.Replace,
      Improve = s.Improve, Worked = s.Worked, Wonders = table.concat(s.Wonders, ","), Heat = s.HeatDistrict or "",
      Count = s.Count, Target = s.Target, Rows = Rows(s.DistrictRows), FoldText = s.FoldText, Summary = s.SummaryText },
    Sites = { Result = sites.Result ~= nil, K = sites.K, D = sites.D, Dense = sites.Dense, Weights = Copy(sites.Weights),
      Tier = sites.Tier, Preset = sites.Preset, Fold = sites.Fold, Count = sites.DistrictCount, States = Copy(sites.States),
      FoldText = sites.FoldText },
    Multi = { Result = multi.Result ~= nil, Weights = Copy(multi.Weights), Tier = multi.Tier, Preset = multi.Preset,
      Fold = multi.Fold, Remind = multi.Remind, Swap = multi.Swap, Replace = multi.Replace, Improve = multi.Improve,
      Worked = multi.Worked, Cities = table.concat(cities, ","), Rows = mrows, FoldText = multi.FoldText,
      Summary = multi.SummaryText },
  }
end

local function Entry(pull, n) return pull._entries[n] end

-- The panel as a new game first shows it, each tab drawn once.
SDP_Panel.Open()
for _, tab in ipairs({ "SITES", "MULTI", "SINGLE" }) do SDP_Panel.SelectTab(tab) end
local FRESH = Snapshot()
local FRESH_TEXT = {}
for _, tab in ipairs({ "SINGLE", "SITES", "MULTI" }) do FRESH_TEXT[tab] = cfg:GetValue("SDP_Settings_" .. tab) end
SDP_Panel.Close()

test("Defaults puts every tab back as a new game shows it", function()
  SDP_Panel.Open()
  -- One city: districts, count, weights, tier, preset, switches, a wonder, the good places.
  SDP_Panel.SelectTab("SINGLE")
  local s = SDP_Panel.State()
  s.DistrictRows[1].Click()
  c.CountMore:Click()
  s.WeightCells[2].More:Click()
  Entry(c.TierPull, 3).Button:Click()
  for _, check in ipairs({ c.FeatureCheck, c.SwapCheck, c.RemindCheck, c.ImproveCheck, c.WorkedCheck, c.ReplaceCheck }) do
    check:Toggle()
  end
  local wonder = nil
  for _, wd in ipairs(SDP_Wonders.List(0)) do
    if wonder == nil and wd.Status == nil then wonder = wd.Type end
  end
  T.ok(wonder ~= nil, "a wonder to choose")
  SDP_Panel.SetWonder(wonder, true)
  c.FoldButton:Click()
  Entry(c.HeatPull, 2).Button:Click()
  T.ok(SDP_Panel.State().HeatDistrict ~= nil, "the good places shown")
  -- City sites: count, distance, dense packing, a preset.
  SDP_Panel.SelectTab("SITES")
  c.SitesCountMore:Click()
  c.SitesDistanceMore:Click()
  c.SitesPlanMore:Click()
  Entry(c.SitesPresetPull, 2).Button:Click()
  c.SitesDenseCheck:Toggle()
  -- Several cities: the city-center pin on, a district, a plan solved and shown (issue 320).
  SDP_Panel.SelectTab("MULTI")
  for _, view in ipairs(SDP_Panel.Multi.State().View.Cities) do
    if not view.Included then view.Chip:Click() end
  end
  SDP_Panel.Multi.State().View.Districts[1].Cell:Click()
  Entry(c.MultiPresetPull, 3).Button:Click()
  c.MultiImproveCheck:Toggle()
  c.MultiSolveButton:Click()
  SDP_Panel.RunTask(50)
  T.ok(SDP_Panel.Multi.State().Result ~= nil, "a plan on the Several cities tab")
  c.PeekButton:Click()
  local changed = Snapshot()
  for _, part in ipairs({ "Single", "Sites", "Multi" }) do
    T.ok(T.dump(changed[part]) ~= T.dump(FRESH[part]), part .. ": changed before the reset")
  end

  SDP_Panel.Defaults()
  local after = Snapshot()
  T.same(after.Single, FRESH.Single, "one city")
  T.same(after.Sites, FRESH.Sites, "city sites")
  T.same(after.Multi, FRESH.Multi, "several cities")
  T.eq(after.Tab, "SINGLE", "the one city tab")
  T.eq(after.Peek, false, "no peek")
  T.eq(UI_Mock.Lenses.hexes[SDP_Preview.LAYER] or 0, 0, "nothing drawn on the map")
  T.ok(SDP_Panel.IsOpen(), "still open")
  -- Kept as the defaults, so the save does not bring the changes back.
  for _, tab in ipairs({ "SINGLE", "SITES", "MULTI" }) do
    local text = cfg:GetValue("SDP_Settings_" .. tab)
    if FRESH_TEXT[tab] ~= nil then T.eq(text, FRESH_TEXT[tab], tab .. " kept") end
    T.ok(text == nil or not text:find("=", ("v1;preset="):len() + 1, true), tab .. " keeps only a preset: " .. tostring(text))
  end
  SDP_Panel.Refresh()
  T.same(Snapshot().Single, FRESH.Single, "a refresh reads nothing else back")
  SDP_Panel.Close()
end)

test("Defaults stops a running computation and works on a closed panel", function()
  SDP_Panel.Open()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SetState("DISTRICT_CAMPUS", "MUST")
  SDP_Panel.SetTier("FINE")
  T.eq(SDP_Panel.Solve(), nil, "runs as a task")
  T.ok(SDP_Task.IsRunning(), "running")
  SDP_Panel.Close()
  SDP_Panel.Defaults()
  T.ok(not SDP_Task.IsRunning(), "stopped")
  T.ok(not SDP_Panel.IsOpen(), "still closed")
  SDP_Panel.Open()
  T.same(Snapshot().Single, FRESH.Single, "one city at its defaults")
  SDP_Panel.Close()
end)

-- The self-check after a tab fits its page: silent while the body fits,
-- one SDP_LAYOUT_OVERFLOW line naming the tab when it does not.
test("a body the page cannot hold writes one SDP_LAYOUT_OVERFLOW line", function()
  local lines = {}
  local log = SDP_UI.Log
  SDP_UI.Log = function(text) lines[#lines + 1] = text end
  local ok, err = pcall(function()
    local function Overflows()
      local n = 0
      for _, line in ipairs(lines) do
        if line:find(SDP_UI.OVERFLOW .. " ", 1, true) == 1 then n = n + 1 end
      end
      return n
    end
    SDP_Panel.Open()
    for _, tab in ipairs({ { "SINGLE", c.Body, c.FoldButton }, { "SITES", c.SitesBody, c.SitesFoldButton },
        { "MULTI", c.MultiBody, c.MultiFoldButton } }) do
      local name, body, fold = tab[1], tab[2], tab[3]
      SDP_Panel.SelectTab(name)
      lines = {}
      fold:Click()
      fold:Click()
      T.eq(Overflows(), 0, name .. ": fits, nothing written")
      function body:GetSizeY() return 5000 end
      lines = {}
      fold:Click()
      body.GetSizeY = nil
      T.eq(Overflows(), 1, name .. ": one line: " .. table.concat(lines, " | "))
      T.ok(lines[#lines]:find(name, 1, true) ~= nil, name .. ": named")
    end
    SDP_Panel.SelectTab("SINGLE")
    SDP_Panel.Close()
  end)
  SDP_UI.Log = log
  if not ok then error(err, 0) end
end)
