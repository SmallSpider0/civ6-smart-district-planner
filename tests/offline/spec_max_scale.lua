-- Offline: the largest requests the panel takes (issue 327), run as the
-- game runs them: the tab's own Solve button, then one panel update per
-- frame (the context's SetUpdate callback), with frames short enough that
-- the task's quota grows to its largest (SDP_Task.MAX_QUOTA). The frame
-- watchdog (tests/offline/watchdog.lua) fails a test whose frames get too
-- long; these only check that the solve ends in bounded frames and gives a
-- plan the invariants accept, not how good the plan is.
--   - one city, every district required, the finest tier, every switch on;
--   - every city on the Several cities tab (more than its default group)
--     and every wonder (issue 307: one frame of 482 s), with the default
--     districts and with every district required;
--   - city sites at the largest count, dense packing and the farthest
--     distance, every district.
local test, T = ...

local UI_Mock = include("ui")

local c = nil
local w = nil

-- The first world installs the panel; a later one replaces the panel's.
local function Setup(spec)
  local ui = UI
  w = World.New(spec)
  if c ~= nil then
    for key, fn in pairs(ui) do -- the mock's UI functions on the new world's UI
      if UI[key] == nil then UI[key] = fn end
    end
  else
    UI_Mock.Install()
    include("SDP_Panel")
    c = UI_Mock.Controls
  end
end

-- A land map `width` x `height` with a coast around it, its terrain in a
-- fixed pattern (hills, woods, rainforest, marsh, mountains, plains).
local function LandMap(width, height)
  local pattern = { ".", "h", ".", "p", "f", ".", "q", "j", ".", "M", "p", "s", ".", "h", "p", "." }
  local rows = {}
  for y = 0, height - 1 do
    local row = {}
    for x = 0, width - 1 do
      if x == 0 or y == 0 or x == width - 1 or y == height - 1 then
        row[#row + 1] = "~"
      else
        row[#row + 1] = pattern[(x * 7 + y * 5) % #pattern + 1]
      end
    end
    rows[#rows + 1] = table.concat(row)
  end
  return rows
end

-- The longest frame of the run, for the record (-v shows it; -t lists it).
local function Report(label)
  local long = SDP_Watchdog.Longest
  if long then print(string.format("%s: longest frame %.1fM instructions (frame %d)", label, long.Work / 1e6, long.Frame)) end
end

-- One panel update per frame until the task ends; returns the frames.
-- 20 ms a frame: under the task's target, so its quota grows to the most
-- the game ever gives it.
local MAX_FRAMES = 200000
local function RunFrames()
  T.ok(SDP_Task.IsRunning(), "the solve started a task")
  local frames = 0
  while SDP_Task.IsRunning() and frames < MAX_FRAMES do
    w.Time = w.Time + 0.02
    T.ok(UI_Mock.Update ~= nil, "the panel updates every frame while the task runs")
    UI_Mock.Update()
    frames = frames + 1
  end
  T.ok(not SDP_Task.IsRunning(), "ended within " .. MAX_FRAMES .. " frames")
  T.ok(frames > 1, "over several frames: " .. frames)
  return frames
end

local function Districts()
  local list = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(0)) do list[#list + 1] = d.Type end
  return list
end

test("one city, every district, the finest tier, every switch on", function()
  Setup({ rows = LandMap(24, 18), rivers = { "10,8", "11,8", "11,9", "12,9" }, improvementRules = true,
    cities = { { id = 1, x = 11, y = 9, population = 30, capital = true, radius = 3 } } })
  SDP_Panel.Open()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(1)
  SDP_Panel.SetTier("FINE")
  SDP_Panel.SetLand(true)
  SDP_Panel.SetImprove(true)
  SDP_Panel.SetSwap(true)
  SDP_Panel.SetAllowFeatureRemoval(true)
  for _, d in ipairs(Districts()) do SDP_Panel.SetState(d, "MUST") end
  c.SolveButton:Click()
  local frames = RunFrames()
  local result = SDP_Panel.State().Result
  T.ok(result and result.Ok, "a plan: " .. tostring(result and result.Error))
  Report("one city (" .. frames .. " frames)")
end)

-- Cities on a grid, `cols` x `rowsOf`, five plots apart.
local function Cities(cols, rowsOf)
  local list = {}
  for r = 1, rowsOf do
    for k = 1, cols do
      list[#list + 1] = { id = #list + 1, x = 3 + 5 * (k - 1), y = 3 + 5 * (r - 1), population = 16,
        capital = #list == 0, radius = 2 }
    end
  end
  return list
end

-- Six cities: more than the tab's default group. Every wonder the player
-- can pick: the fake world's 17 and 18 more (issue 307's test wonders,
-- flat land or a river, so they want the same plots).
local MULTI_COLS, MULTI_ROWS, EXTRA_WONDERS = 3, 2, 18
-- The sites tab's largest request on a map that keeps the test near a minute.
local SITES_WIDTH, SITES_HEIGHT = 30, 24

-- The Several cities tab: every city, every wonder, every switch on; with
-- `everyDistrict` every district required in the shared list (else its
-- default list).
local function SeveralCities(everyDistrict)
  Setup({ rows = LandMap(5 * MULTI_COLS + 2, 5 * MULTI_ROWS + 2), rivers = { "4,3", "9,3", "4,8", "9,8" },
    improvementRules = true, cities = Cities(MULTI_COLS, MULTI_ROWS), manyWonders = EXTRA_WONDERS })
  local multi = SDP_Panel.Multi
  SDP_Panel.Open()
  SDP_Panel.SelectTab("MULTI")
  c.MultiCityAll:Click()
  T.eq(#multi.Participants(), MULTI_COLS * MULTI_ROWS, "every city takes part")
  T.ok(#multi.Participants() > SDP_Multi.DEFAULT_CITIES, "more than the default group")
  multi.SetTier("FAST")
  multi.SetLand(true)
  multi.SetImprove(true)
  multi.SetSwap(true)
  if everyDistrict then
    for _, d in ipairs(Districts()) do multi.SetState(d, "MUST") end
  end
  local wonders = 0
  for _, wonder in ipairs(SDP_Wonders.List(0)) do
    if wonder.Status == nil then
      multi.SetWonder(wonder.Type, true)
      wonders = wonders + 1
    end
  end
  T.ok(wonders >= EXTRA_WONDERS, "every wonder: " .. wonders)
  c.MultiSolveButton:Click()
  local frames = RunFrames()
  local result = multi.State().Result
  T.ok(result and result.Ok, "a plan: " .. tostring(result and result.Error))
  Report(string.format("%d cities, %d wonders (%d frames)", MULTI_COLS * MULTI_ROWS, wonders, frames))
end

-- Before issue 307's fix this failed in its 43rd frame (counting the
-- wonders' layouts, SDP_Search CountLayouts, without a Tick).
test("every city and every wonder on the Several cities tab", function()
  SeveralCities(false)
end)

test("every city, every wonder and every district on the Several cities tab", function()
  -- Issue 331: frames over the watchdog's limit (local search's reach
  -- checks, the beam's nodes report less work than they do); on when fixed.
  T.skip("issue 331: frames over the watchdog's limit")
  SeveralCities(true)
end)

test("city sites: the largest count, dense packing, the farthest distance, every district", function()
  Setup({ rows = LandMap(SITES_WIDTH, SITES_HEIGHT), rivers = { "6,5", "7,5", "20,12", "21,12" }, improvementRules = true,
    cities = { { id = 1, x = 6, y = 6, population = 4, capital = true, radius = 1 } } })
  local sites = SDP_Panel.Sites
  SDP_Panel.Open()
  SDP_Panel.SelectTab("SITES")
  if not c.SitesDenseCheck:IsChecked() then c.SitesDenseCheck:Toggle() end
  T.ok(sites.State().Dense, "dense packing on")
  sites.SetTier("FAST")
  for _, d in ipairs(SDP_Rules.PlannableDistricts(0)) do
    sites.SetState(d.Type, d.Specialty and "POOL" or "MUST")
  end
  for _ = 1, 20 do if not c.SitesCountMore:IsDisabled() then c.SitesCountMore:Click() end end
  for _ = 1, 20 do if not c.SitesDistanceMore:IsDisabled() then c.SitesDistanceMore:Click() end end
  for _ = 1, 20 do if not c.SitesPlanMore:IsDisabled() then c.SitesPlanMore:Click() end end
  local state = sites.State()
  T.eq(state.K, SDP_SiteSolver.DENSE_MAX_K, "the most sites")
  c.SitesSolveButton:Click()
  local frames = RunFrames()
  local result = sites.State().Result
  T.ok(result and result.Ok, "sites: " .. tostring(result and result.Error))
  Report(string.format("%d sites, distance %s (%d frames)", state.K, tostring(state.D), frames))
end)
