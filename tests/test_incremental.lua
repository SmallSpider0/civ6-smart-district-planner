-- @state SDP_Panel
-- @timeout 180
-- Risk 3 (docs/multicity-design.md): SDP_Board's incremental, memoized
-- totals must equal DMT's full evaluation in the game, for every ruleset.
-- Random-looking but fixed layouts (a fixed linear congruential sequence) of
-- up to eight districts around the capital, each checked after every few
-- moves: total and legality.
-- Needs a city: run tests/fixtures/found_capital.lua first on a fresh game.
local test, T = ...

local pid = Game.GetLocalPlayer()

local function Capital()
  local city = Players[pid]:GetCities():GetCapitalCity()
  if city == nil then T.skip("no capital: run tests/fixtures/found_capital.lua") end
  return city
end

-- A fixed sequence of numbers in 1..n (deterministic: constraint 6).
local function Sequence(seed)
  local state = seed
  return function(n)
    state = (state * 48271) % 2147483647
    return state % n + 1
  end
end

test("incremental totals equal full evaluations", function()
  local city = Capital()
  local scan = SDP_City.Scan(pid, city:GetID())
  local districts = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do
    if #districts < 8 then districts[#districts + 1] = d.Type end
  end
  local weights = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }
  local checks, mismatches = 0, {}
  SDP_Overlay.With(pid, function()
    local fixed = SDP_Overlay.FixedSubjects(scan)
    local base = SDP_Overlay.Evaluate({}, fixed, weights)
    local board = SDP_Board.New(pid, fixed, weights)
    local next = Sequence(20261019)
    local where, subjects = {}, {}
    for step = 1, 400 do
      local slot = next(#districts)
      local c = scan.Candidates[next(#scan.Candidates)]
      local free = true
      for s, other in pairs(where) do
        if other.Index == c.Index and s ~= slot then free = false end
      end
      if free then
        where[slot] = c
        subjects[slot] = SDP_Overlay.Subject(districts[slot], c.X, c.Y)
        board:Put(slot, subjects[slot])
      end
      if step % 4 == 0 then
        local gain, legal = board:Total()
        local list = {}
        for s = 1, #districts do
          if subjects[s] then list[#list + 1] = subjects[s] end
        end
        for _, subject in ipairs(list) do SDP_Overlay.Put(subject.X, subject.Y, nil) end
        local full = SDP_Overlay.Evaluate(list, fixed, weights)
        for _, subject in ipairs(list) do SDP_Overlay.Put(subject.X, subject.Y, subject) end
        SDP_Overlay.ClearCache()
        checks = checks + 1
        if math.abs(gain - (full.Total - base.Total)) > 1e-9 or legal ~= full.Legal then
          mismatches[#mismatches + 1] = string.format("step %d: board %s/%s, full %s/%s", step, tostring(gain), tostring(legal),
            tostring(full.Total - base.Total), tostring(full.Legal))
        end
      end
    end
    board:Clear()
  end)
  print(string.format("%s: %d checks, %d mismatches", SDP_Rules.Ruleset(), checks, #mismatches))
  for _, m in ipairs(mismatches) do print("  " .. m) end
  T.eq(#mismatches, 0, "mismatches")
end)

test("solver results agree with the full evaluation", function()
  local city = Capital()
  local districts = {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do
    if #districts < 6 then districts[#districts + 1] = d.Type end
  end
  for _, tier in ipairs(SDP_Tiers.ORDER) do
    local result = SDP_Solver.Solve({ PlayerID = pid, CityID = city:GetID(), Districts = districts, Tier = tier, Land = true })
    T.ok(result.Ok, tier .. ": " .. tostring(result.Error))
    T.ok(not result.Stats.Mismatch, tier .. ": board and full evaluation disagree")
  end
end)
