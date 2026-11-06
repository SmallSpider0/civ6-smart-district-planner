-- Offline: issue 307. Many wonders ticked (19 over six cities, or all of
-- them) froze the game: counting the layouts of a block of wonders before
-- choosing how to search it went through every way to put the first wonders
-- down when the last few wanted the same few plots, all within one frame.
-- The count now knows at once when a block cannot stand (a matching), stops
-- after a bounded walk, and counts its work for the frames; a solve with
-- many wonders over several cities ends in a bounded number of frames.
local test, T = ...

include("SDP_Rules")
include("SDP_City")
include("SDP_Overlay")
include("SDP_Tiers")
include("SDP_Task")
include("SDP_Board")
include("SDP_Land")
include("SDP_Appeal")
include("SDP_Improve")
include("SDP_Coverage")
include("SDP_Search")
include("SDP_Pins")
include("SDP_Remind")
include("SDP_Solver")
include("SDP_Wonders")
include("SDP_Multi")

-- A search over `n` plots whose slot m may stand on rows[m]; reads.n counts
-- every look at a slot's legal plots (the work of the walks).
local function CountingSearch(rows, n)
  World.New({ rows = { "..." } })
  local candidates = {}
  for i = 1, n do candidates[i] = { Index = i, X = i, Y = 0 } end
  local search = SDP_Search.New({ PlayerID = 0, Params = SDP_Tiers.Params(SDP_Tiers.Single, "STANDARD"),
    Candidates = candidates, Weights = {} })
  local reads = { n = 0 }
  local legal = {}
  for m, row in ipairs(rows) do
    local data = {}
    for _, i in ipairs(row) do data[i] = true end
    legal[m] = setmetatable({}, { __index = function(_, i)
      reads.n = reads.n + 1
      return data[i]
    end })
  end
  search.Legal, search.K = legal, #rows
  return search, reads
end

local function Range(a, b)
  local out = {}
  for i = a, b do out[#out + 1] = i end
  return out
end

local function Order(k)
  local order = {}
  for m = 1, k do order[m] = m end
  return order
end

test("a block that cannot stand counts no layouts at once", function()
  -- Six wonders anywhere on twelve plots, then three that only fit on the
  -- same two plots: before, every way to put the six down was tried first.
  local rows = {}
  for m = 1, 6 do rows[m] = Range(1, 12) end
  for m = 7, 9 do rows[m] = { 11, 12 } end
  local search, reads = CountingSearch(rows, 12)
  T.eq(search:CountLayouts(Order(9), {}, 2000), 0, "no layout")
  T.ok(reads.n < 2000, "a few looks, not every way to place the first six (" .. reads.n .. ")")
  T.ok(not search:AllFit(Order(9), {}), "the matching says so")
  T.ok(search:AllFit(Order(7), {}), "seven fit")
  T.ok(not search:AllFit(Order(7), { [11] = true, [12] = true }), "not with the two plots taken")
end)

test("a walk through many dead ends stops early and counts as above the limit", function()
  -- Every layout needs plots 1 and 2 for the last two slots; the walk puts
  -- the first slots there first, so it meets dead ends long before it finds
  -- enough layouts. A full matching exists, so only the walk can tell.
  local rows = {}
  for m = 1, 6 do rows[m] = Range(1, 12) end
  rows[7], rows[8] = { 1 }, { 2 }
  local search, reads = CountingSearch(rows, 12)
  local limit = 100
  local count = search:CountLayouts(Order(8), {}, limit)
  T.ok(count > limit, "counts as above the limit: " .. count)
  local cap = SDP_Search.COUNT_NODES * (limit + 1) * 9
  T.ok(reads.n <= (cap + 50) * 12, "the walk is bounded (" .. reads.n .. " looks)")
end)

test("a walk without dead ends stays exact", function()
  local rows = { Range(1, 5), Range(1, 5), Range(1, 5) }
  local search = CountingSearch(rows, 5)
  T.eq(search:CountLayouts(Order(3), {}, 1000), 60, "5 x 4 x 3")
  T.eq(search:CountLayouts(Order(3), {}, 10), 11, "stops just above the limit")
  T.eq(search:CountLayouts(Order(3), { [1] = true, [2] = true }, 1000), 6, "with two plots taken")
end)

test("the count's work is spread over frames", function()
  local rows = {}
  for m = 1, 6 do rows[m] = Range(1, 12) end
  rows[7], rows[8] = { 1 }, { 2 }
  local search, reads = CountingSearch(rows, 12)
  local worst, last = 0, 0
  local job = { PlayerID = 0, Run = function() return search:CountLayouts(Order(8), {}, 100) end }
  T.ok(SDP_Task.Start(job), "started")
  local status = "running"
  while status == "running" do
    status = SDP_Task.Step(5)
    worst = math.max(worst, reads.n - last)
    last = reads.n
  end
  T.eq(status, "done", "done")
  -- Five units a frame: 5 x NODES_PER_UNIT nodes, each looking at 12 plots.
  T.ok(worst <= 5 * SDP_Tiers.NODES_PER_UNIT * 12 + 12, "looks in the longest frame: " .. worst)
  T.ok(job.Frames > 1, "several frames: " .. job.Frames)
end)

-- Six cities in a row, every one asking for a campus, with 18 wonders that
-- want the same few plots (flat land, a river): the Several cities tab's
-- request, run as the panel runs it.
local function SixCities()
  local rows = {
    "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~",
    "~..h....h....h....h....h....h..~",
    "~.....h....h....h....h....h....~",
    "~..h....h....h....h....h....h..~",
    "~.h..h....h....h....h....h...h.~",
    "~..h....h....h....h....h....h..~",
    "~.....h....h....h....h....h....~",
    "~..h....h....h....h....h....h..~",
    "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~",
  }
  local cities = {}
  for c = 1, 6 do
    cities[c] = { id = c, x = 3 + 5 * (c - 1), y = 4, population = 10, capital = c == 1, radius = 2 }
  end
  World.New({ rows = rows, rivers = { "4,3", "9,3", "14,3" }, cities = cities, manyWonders = 18 })
  local wonders, existing = {}, {}
  for _, w in ipairs(SDP_Wonders.List(0)) do
    if w.Type:find("^BUILDING_TEST_WONDER_") then wonders[#wonders + 1] = w.Type end
  end
  table.sort(wonders)
  for c = 1, 6 do existing[c] = true end
  return { PlayerID = 0, Tier = "FAST", Districts = { "DISTRICT_CAMPUS" }, Wonders = wonders, Existing = existing,
    Land = true, Improvements = true, Apart = true, Target = true }
end

test("many wonders over six cities: bounded frames, wonders placed", function()
  local request = SixCities()
  T.eq(#request.Wonders, 18, "eighteen wonders")
  local frames, worst = 0, 0
  local job = { PlayerID = 0, Run = function() return SDP_Multi.SolveNow(request) end }
  local result
  job.OnDone = function(value) result = value end
  T.ok(SDP_Task.Start(job), "started")
  local status = "running"
  while status == "running" and frames < 20000 do
    status = SDP_Task.Step(50)
    frames = frames + 1
    worst = math.max(worst, job.LastUsed or 0)
  end
  T.eq(status, "done", "done in " .. frames .. " frames")
  T.ok(result ~= nil and result.Ok, "a plan")
  local placed = 0
  for _, p in ipairs(result.Plan or {}) do
    if p.Type:find("^BUILDING_TEST_WONDER_") then placed = placed + 1 end
  end
  T.ok(placed >= 1, "wonders placed: " .. placed)
  T.ok(worst < 50 + 2, "no frame much over its quota: " .. worst)
end)
