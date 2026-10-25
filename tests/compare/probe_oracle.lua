-- probe_oracle.lua: the oracle's checks value every layout as a fresh
-- evaluation does (issue 48).
--
--   node tools/compare.mjs --probe tests/compare/probe_oracle.lua [--arg '[LAND ]^S0[1-4]%-']
--
-- sdp:ORACLE_CHECK runs CmpOracle.Run, then BruteForce and Climb, each on a
-- freshly installed overlay (cmp_sdp.lua). This probe does the same on the
-- single-city scenes matched by the pattern (a Lua pattern on the scene id;
-- "LAND " in front: the whole objective with the land part on, as
-- ORACLE_LAND_CHECK), records the DMT adjacency gain the search's board gave
-- every layout the two checks valued, and values each of those layouts again
-- on a new board on a new overlay (nothing carried over from the oracle).
-- The layouts whose gains differ are counted, the first few printed, and
-- checked once more with a full evaluation (SDP_Overlay.Evaluate, no board).
-- Prints one line per scene; errors when any layout differs.
--
-- "CHECKS " in front (before "LAND "): only the two checks, without the
-- oracle, on every single-city scene the pattern matches (weight profiles
-- included), printing one JSON line per scene ("CHECK {...}": brute, its
-- layout count, climb, its evaluations). The climbs place every required
-- slot, as they do after an oracle that places them all (scenes with pools
-- are skipped). For rerunning the checks of an ORACLE_CHECK result whose
-- oracle values stay as they are.

include("cmp_lib")

local arg = (PROBE_ARG ~= nil and PROBE_ARG ~= "") and PROBE_ARG or "^S0[1-4]%-[^~]+$"
local checksOnly = arg:match("^CHECKS ") ~= nil
arg = arg:gsub("^CHECKS ", "")
local land = arg:match("^LAND ") ~= nil
local pattern = arg:gsub("^LAND ", "")
local EPS = 1e-6
local NAMES = { "SDP_Rules", "SDP_City", "SDP_Overlay", "SDP_Tiers", "SDP_Task", "SDP_Board", "SDP_Land", "SDP_Appeal",
  "SDP_Coverage", "SDP_Search", "SDP_Solver" }

local function Key(layout, k)
  local parts = {}
  for m = 1, k do parts[m] = tostring(layout[m]) end
  return table.concat(parts, ",")
end

local ids = {}
for _, s in ipairs(CmpScenarios.List) do
  if s.id:match(pattern) and s.kind == "single" then ids[#ids + 1] = s.id end
end
local scenes, differ = 0, 0
for _, id in ipairs(ids) do
  local scn, w, request = CmpRun.Setup(id)
  if #(request.wonders or {}) == 0 then
    include("MapTacks")
    for _, name in ipairs(NAMES) do include(name) end
    include("cmp_oracle")
    w.Events.LoadGameViewStateDone()
    local r = SDP_Solver.Solve({ PlayerID = 0, CityID = request.target:GetID(), Districts = request.districts,
      Land = land, Tier = "FINE", Weights = request.weights })
    if not r.Ok then error(id .. ": " .. tostring(r.Error)) end
    local session, search = r.Session, r.Session.Search
    local k, options = search.K, { Land = land }
    if checksOnly then
      if #(search.PoolGroups or {}) > 0 then
        print("CHECK " .. CmpRun.Json.Encode({ scenario = id, skipped = "pools" }))
      else
        local brute, count = SDP_Overlay.With(0, CmpOracle.BruteForce, search, 400000, options)
        local active = {}
        for m = 1, k do active[m] = not search.Optional[m] end
        local climb, evaluations = SDP_Overlay.With(0, CmpOracle.Climb, search, active, 8, 20261023, options)
        print("CHECK " .. CmpRun.Json.Encode({ scenario = id, land = land, brute = brute, bruteLayouts = count,
          climb = climb, climbEvaluations = evaluations }))
      end
    else
      local o = SDP_Overlay.With(0, CmpOracle.Run, search, search.BestLayout, options)

      -- Record the board's gain of every layout the checks value.
      local seen, keys, phase = {}, {}, nil
      search.Evaluate = function(self, layout)
        local results = { getmetatable(self).__index.Evaluate(self, layout) }
        local key = Key(layout, k)
        if seen[key] == nil then
          seen[key] = { Gain = self.Board:Total(), Phase = phase, Layout = { unpack(layout, 1, k) } }
          keys[#keys + 1] = key
        end
        return unpack(results, 1, 2)
      end
      phase = "brute"
      local brute = SDP_Overlay.With(0, CmpOracle.BruteForce, search, 400000, options)
      phase = "climb"
      local active = {}
      for m = 1, k do active[m] = (o.Layout and o.Layout[m] or 0) ~= 0 end
      local climb = SDP_Overlay.With(0, CmpOracle.Climb, search, active, 8, 20261023, options)
      search.Evaluate = nil

      -- The same layouts on a new board on a new overlay.
      local bases = {}
      for f, item in ipairs(session.Base.Fixed) do bases[f] = item.Score end
      local bad = {}
      SDP_Overlay.With(0, function()
        local board = SDP_Board.New(0, session.Fixed, search.Board.Weights, bases)
        for _, key in ipairs(keys) do
          local entry = seen[key]
          for m = 1, k do
            local i = entry.Layout[m]
            if board:PlotOf(m) ~= (i ~= 0 and search.Candidates[i].Index or nil) then board:Put(m, nil) end
          end
          for m = 1, k do
            local i = entry.Layout[m]
            if i ~= 0 and board:PlotOf(m) == nil then board:Put(m, search:Subject(m, i)) end
          end
          local gain = board:Total()
          if math.abs(gain - entry.Gain) > EPS then bad[#bad + 1] = { Entry = entry, Fresh = gain } end
        end
      end)
      -- The first few once more with a full evaluation (no board at all).
      local shown = math.min(5, #bad)
      SDP_Overlay.With(0, function()
        for x = 1, shown do
          local subjects = {}
          for m = 1, k do
            local i = bad[x].Entry.Layout[m]
            if i ~= 0 then subjects[#subjects + 1] = search:Subject(m, i) end
          end
          bad[x].Full = SDP_Overlay.Evaluate(subjects, session.Fixed, search.Board.Weights).Total - session.Base.Total
        end
      end)
      local counts = { brute = 0, climb = 0 }
      for _, b in ipairs(bad) do counts[b.Entry.Phase] = counts[b.Entry.Phase] + 1 end
      scenes, differ = scenes + 1, differ + #bad
      print(string.format("%-36s oracle %s brute %s climb %s  layouts %6d  differ %d (brute %d, climb %d)", id,
        tostring(o.Value), tostring(brute), tostring(climb), #keys, #bad, counts.brute, counts.climb))
      for x = 1, shown do
        local b = bad[x]
        print(string.format("    %s layout {%s}: board %.4f, new board %.4f, full evaluation %.4f", b.Entry.Phase,
          Key(b.Entry.Layout, k), b.Entry.Gain, b.Fresh, b.Full))
      end
    end
  end
end
print(string.format("probe_oracle: %d scenes, %d layouts differ", scenes, differ))
if differ > 0 then error("the oracle's checks valued " .. differ .. " layouts differently from a fresh evaluation") end
