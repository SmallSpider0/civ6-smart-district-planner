-- cmp_scene_check.lua: does the offline world built from a scene file say
-- what the game said? The scene carries DMT's verdict and adjacency for
-- every plannable district on every owned plot of its cities, taken in the
-- game (tests/bench/export_scene.lua); this evaluates the same subjects in
-- the simulated engine with the real DMT and lists the differences.
-- Run: node tools/compare.mjs --probe tests/compare/cmp_scene_check.lua --arg RS01-...
-- (tools/snapshot.py check does this for every scene).
include("cmp_lib")
local id = (PROBE_ARG ~= "" and PROBE_ARG) or error("no scene id (--arg)")
local scn, w = CmpRun.Setup(id)
if scn.spec == nil then error(id .. " is not a scene file") end
include("MapTacks")
for _, name in ipairs({ "SDP_Rules", "SDP_City", "SDP_Overlay", "SDP_Tiers", "SDP_Task", "SDP_Board", "SDP_Land",
  "SDP_Appeal", "SDP_Coverage", "SDP_Search", "SDP_Solver", "SDP_Wonders", "SDP_Multi", "SDP_Sites", "SDP_SiteSolver" }) do
  include(name)
end
w.Events.LoadGameViewStateDone()

local WEIGHTS = { YIELD_SCIENCE = 1, YIELD_CULTURE = 1, YIELD_FAITH = 1, YIELD_GOLD = 1, YIELD_PRODUCTION = 1 }
local sample = scn.spec.sample or {}
local n, canDiff, yieldDiff, shown = 0, 0, 0, 0
local byDistrict = {}
for _, s in ipairs(sample) do
  local x, y = s.i % w.Width, math.floor(s.i / w.Width)
  local item = SDP_Overlay.With(0, SDP_Overlay.Evaluate, { SDP_Overlay.Subject(s.d, x, y) }, {}, WEIGHTS).Placements[1]
  n = n + 1
  -- The game's verdict is DMT's plus the engine's; the offline world has no engine.
  local gameCan = s.can or s.engine == true
  local offCan = item.CanPlace == true
  local diff = {}
  if gameCan ~= offCan then
    canDiff = canDiff + 1
    diff[#diff + 1] = string.format("can %s/%s", tostring(gameCan), tostring(offCan))
  end
  if gameCan and offCan then
    local keys = {}
    for k in pairs(s.y or {}) do keys[k] = true end
    for k, v in pairs(item.Yields or {}) do if v ~= 0 then keys[k] = true end end
    local parts = {}
    for k in pairs(keys) do
      local a, b = (s.y or {})[k] or 0, (item.Yields or {})[k] or 0
      if a ~= b then parts[#parts + 1] = string.format("%s %s/%s", k:gsub("YIELD_", ""), tostring(a), tostring(b)) end
    end
    if #parts > 0 then
      yieldDiff = yieldDiff + 1
      table.sort(parts)
      diff[#diff + 1] = table.concat(parts, " ")
    end
  end
  if #diff > 0 then
    byDistrict[s.d] = (byDistrict[s.d] or 0) + 1
    if shown < 30 then
      shown = shown + 1
      local plot = Map.GetPlot(x, y)
      print(string.format("  %s at %d,%d (%s%s): game/offline %s", s.d, x, y,
        GameInfo.Terrains[plot:GetTerrainType()].TerrainType,
        plot:GetFeatureType() ~= -1 and (" " .. GameInfo.Features[plot:GetFeatureType()].FeatureType) or "",
        table.concat(diff, "; ")))
    end
  end
end
local kinds = {}
for d, c in pairs(byDistrict) do kinds[#kinds + 1] = d .. "=" .. c end
table.sort(kinds)
print(string.format("SCENE_CHECK %s: %d samples, placeability differs %d, adjacency differs %d%s", id, n, canDiff,
  yieldDiff, #kinds > 0 and (" (" .. table.concat(kinds, ", ") .. ")") or ""))
if canDiff + yieldDiff > 0 then error("scene differs from the game", 0) end
