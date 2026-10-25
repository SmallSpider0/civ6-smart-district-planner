-- cmp_longrun.lua: the long-run reference for several cities (issue 40),
-- variant sdp:LONGRUN (cmp_sdp.lua).
--
-- Several cities cannot be solved exactly (four cities of six districts is
-- some 30^24 layouts), so the reference is a range: the best layout a long
-- run finds below, the oracle's bound above. The long run is the fine tier,
-- 20 more rounds of "continue", then simulated annealing from the best
-- layout (a fixed pseudo-random sequence, so it is reproducible); the
-- oracle (cmp_oracle.lua) then starts from that layout and runs to its node
-- limit: its value is the lower end, its largest open bound the upper end.
-- The value is the DMT adjacency gain (the judge's), as sdp:ORACLE.
--
-- TwoSlot checks whether a layout is a local optimum of order two: every
-- two placed slots moved at once to any two free legal plots (or onto each
-- other's: a swap). Search:Kicks and the local search move one slot at a
-- time; a joint shape that needs two districts to move together is what
-- they miss (design 21).

CmpLongrun = CmpLongrun or {}

local EPS = 1e-6

local function Value(search, layout)
  local _, legal = search:Evaluate(layout)
  return search.Board:Total(), legal
end

local function Copy(layout, k)
  local out = {}
  for m = 1, k do out[m] = layout[m] end
  return out
end

-- Park-Miller with floats (as CmpOracle.Climb): the same sequence anywhere.
local function Generator(seed)
  local x = (seed % 2147483646) + 1.0
  return function()
    x = (x * 16807.0) % 2147483647.0
    return x / 2147483647.0
  end
end

local function Slots(search, layout)
  local slots, legal = {}, {}
  for m = 1, search.K do
    if layout[m] ~= 0 then
      slots[#slots + 1] = m
      local list = {}
      for i = 1, search.N do
        if search.Legal[m][i] then list[#list + 1] = i end
      end
      legal[m] = list
    end
  end
  return slots, legal
end

-- Simulated annealing over the slots `start` places, for `evaluations`
-- evaluations. A move takes one slot to a random free legal plot or swaps
-- two slots' plots; a worse layout is kept with probability exp(delta / T),
-- T falling geometrically from `hot` to `cold`. Returns the best value,
-- its layout and the evaluations made.
function CmpLongrun.Anneal(search, start, evaluations, seed, hot, cold)
  local k = search.K
  search.Board:Clear()
  hot, cold = hot or 3, cold or 0.05
  local random = Generator(seed)
  local slots, legal = Slots(search, start)
  local layout, used = Copy(start, k), {}
  for _, m in ipairs(slots) do used[layout[m]] = m end
  local value, ok = Value(search, layout)
  if not ok or #slots == 0 then return value, Copy(layout, k), 1 end
  local best, bestLayout = value, Copy(layout, k)
  local count, ratio = 1, (cold / hot) ^ (1 / math.max(1, evaluations))
  local t, tries = hot, 0
  while count < evaluations and tries < 50 * evaluations do
    tries = tries + 1
    t = t * ratio
    local a = slots[math.floor(random() * #slots) + 1]
    local from = layout[a]
    if #slots > 1 and random() < 0.3 then
      local b = slots[math.floor(random() * #slots) + 1]
      local to = layout[b]
      if b ~= a and search.Legal[a][to] and search.Legal[b][from] then
        layout[a], layout[b] = to, from
        local v, l = Value(search, layout)
        count = count + 1
        if l and (v >= value - EPS or random() < math.exp((v - value) / t)) then
          used[to], used[from], value = a, b, v
          if v > best + EPS then best, bestLayout = v, Copy(layout, k) end
        else
          layout[a], layout[b] = from, to
        end
      end
    else
      local list = legal[a]
      local to = list[math.floor(random() * #list) + 1]
      if used[to] == nil then
        layout[a] = to
        local v, l = Value(search, layout)
        count = count + 1
        if l and (v >= value - EPS or random() < math.exp((v - value) / t)) then
          used[from], used[to], value = nil, a, v
          if v > best + EPS then best, bestLayout = v, Copy(layout, k) end
        else
          layout[a] = from
        end
      end
    end
  end
  return best, bestLayout, count
end

-- Every pair of placed slots moved at once (free plots, or each other's).
-- Returns { improving = pairs of moves that beat the layout, best = the
-- best value found, layout = its layout, evaluations }.
function CmpLongrun.TwoSlot(search, start)
  local k = search.K
  search.Board:Clear()
  local slots, legal = Slots(search, start)
  local layout, used = Copy(start, k), {}
  for _, m in ipairs(slots) do used[layout[m]] = m end
  local base, ok = Value(search, layout)
  local out = { base = base, best = base, layout = nil, improving = 0, evaluations = 1 }
  if not ok then return out end
  for x = 1, #slots do
    local a = slots[x]
    for y = x + 1, #slots do
      local b = slots[y]
      local fa, fb = layout[a], layout[b]
      for _, i in ipairs(legal[a]) do
        if used[i] == nil or i == fb then
          for _, j in ipairs(legal[b]) do
            if j ~= i and (used[j] == nil or j == fa) and not (i == fa and j == fb) then
              layout[a], layout[b] = i, j
              local v, l = Value(search, layout)
              out.evaluations = out.evaluations + 1
              if l and v > base + EPS then
                out.improving = out.improving + 1
                if v > out.best + EPS then out.best, out.layout = v, Copy(layout, k) end
              end
            end
          end
        end
      end
      layout[a], layout[b] = fa, fb
    end
  end
  return out
end
