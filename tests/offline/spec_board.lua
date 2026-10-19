-- Offline: SDP_Board's incremental totals equal full evaluations.
local test, T = ...

include("SDP_Rules")
include("SDP_City")
include("SDP_Overlay")
include("SDP_Tiers")
include("SDP_Task")
include("SDP_Board")

local TYPES = { "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_THEATER", "DISTRICT_INDUSTRIAL_ZONE", "DISTRICT_AQUEDUCT",
  "DISTRICT_ENTERTAINMENT_COMPLEX", "DISTRICT_GOVERNMENT" }
local ONES = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }

local function Setup(seed)
  local spec = World.RandomSpec(seed, 13, 11)
  local row = spec.rows[6]
  spec.rows[6] = row:sub(1, 6) .. "." .. row:sub(8)
  spec.cities = { { id = 1, x = 6, y = 5, population = 9, capital = true, radius = 3 } }
  spec.pins = { { 8, 5, "ICON_DISTRICT_COMMERCIAL_HUB", "hub" } }
  World.New(spec)
  return SDP_City.Scan(0, 1)
end

test("random moves: board total and legality match full evaluations", function()
  for _, seed in ipairs({ 3, 8, 21 }) do
    local scan = Setup(seed)
    local rng = World.Rng(seed)
    SDP_Overlay.With(0, function()
      local fixed = SDP_Overlay.FixedSubjects(scan)
      local base = SDP_Overlay.Evaluate({}, fixed, ONES)
      local board = SDP_Board.New(0, fixed, ONES)
      local where = {} -- slot -> candidate
      local subjects = {}
      for step = 1, 300 do
        local slot = rng(#TYPES)
        local c = scan.Candidates[rng(#scan.Candidates)]
        local free = true
        for s, other in pairs(where) do
          if other.Index == c.Index and s ~= slot then free = false end
        end
        if free then
          if rng() < 0.15 then
            where[slot], subjects[slot] = nil, nil
            board:Put(slot, nil)
          else
            where[slot] = c
            subjects[slot] = SDP_Overlay.Subject(TYPES[slot], c.X, c.Y)
            board:Put(slot, subjects[slot])
          end
        end
        if step % 3 == 0 then
          local gain, legal = board:Total()
          local list = {}
          for s = 1, #TYPES do
            if subjects[s] then list[#list + 1] = subjects[s] end
          end
          -- Full evaluation needs a clean layer: take the board's subjects off.
          for s = 1, #TYPES do
            if subjects[s] then SDP_Overlay.Put(subjects[s].X, subjects[s].Y, nil) end
          end
          local full = SDP_Overlay.Evaluate(list, fixed, ONES)
          for s = 1, #TYPES do
            if subjects[s] then SDP_Overlay.Put(subjects[s].X, subjects[s].Y, subjects[s]) end
          end
          T.eq(gain, full.Total - base.Total, "seed " .. seed .. " step " .. step .. " total")
          T.eq(legal, full.Legal, "seed " .. seed .. " step " .. step .. " legality")
        end
      end
      board:Clear()
    end)
  end
end)

test("a layout seen before costs no DMT call", function()
  local scan = Setup(5)
  SDP_Overlay.With(0, function()
    local board = SDP_Board.New(0, SDP_Overlay.FixedSubjects(scan), ONES)
    local a, b = scan.Candidates[3], scan.Candidates[4]
    board:Put(1, SDP_Overlay.Subject("DISTRICT_CAMPUS", a.X, a.Y))
    board:Put(2, SDP_Overlay.Subject("DISTRICT_HOLY_SITE", b.X, b.Y))
    local first = board:Total()
    board:Put(2, nil)
    board:Total()
    local calls = board.Calls
    board:Put(2, SDP_Overlay.Subject("DISTRICT_HOLY_SITE", b.X, b.Y))
    T.eq(board:Total(), first, "same total")
    T.eq(board.Calls, calls, "no new DMT call")
    board:Clear()
    T.eq(board:Total(), 0, "empty board")
  end)
end)

test("a plot cannot hold two subjects", function()
  local scan = Setup(5)
  SDP_Overlay.With(0, function()
    local board = SDP_Board.New(0, SDP_Overlay.FixedSubjects(scan), ONES)
    local a = scan.Candidates[1]
    board:Put(1, SDP_Overlay.Subject("DISTRICT_CAMPUS", a.X, a.Y))
    T.ok(not pcall(board.Put, board, 2, SDP_Overlay.Subject("DISTRICT_THEATER", a.X, a.Y)), "second subject refused")
    board:Clear()
  end)
end)
