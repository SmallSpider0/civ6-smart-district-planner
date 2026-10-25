-- probe_land.lua: the consistency check of the judge's land values (issue 48).
--
--   node tools/compare.mjs --probe tests/compare/probe_land.lua [--arg '^[SM]%d']
--
-- The judge values plots on its own (cmp_lib.lua, CmpLand) so that a
-- mistake in reading the rules does not show up on both sides. Set to this
-- mod's assumptions (mode "mod": the player's technologies, improvements
-- every player can build, an improved plot as it is, one-time yields
-- charged against keeping with the same growth), it must give every plot
-- a city could work (within three rings, no district or wonder) in every scene matched by the pattern
-- (a Lua pattern on the scene id; default the dev set) the same tile and
-- one-time values as SDP_Land.PlotValues. Prints one line per scene and
-- the first differing plots; errors when any differ.

include("cmp_lib")

local pattern = (PROBE_ARG ~= nil and PROBE_ARG ~= "") and PROBE_ARG or "^[SM]%d%d%-[^~]+$"
local EPS = 1e-9

-- How far the player is through the technology and civic trees (the larger
-- share): one-time yields grow with it in the mod (SDP_Land.ONE_TIME_GROWTH).
local function Progress()
  local techs, culture = Players[0]:GetTechs(), Players[0]:GetCulture()
  local function Share(rows, has)
    local total, done = 0, 0
    for row in rows do
      total = total + 1
      if has(row.Index) then done = done + 1 end
    end
    return total > 0 and done / total or 0
  end
  return math.max(Share(GameInfo.Technologies(), function(i) return techs:HasTech(i) end),
    Share(GameInfo.Civics(), function(i) return culture:HasCivic(i) end))
end

local ids = {}
for _, s in ipairs(CmpScenarios.List) do
  if s.id:match(pattern) and s.kind ~= "sites" then ids[#ids + 1] = s.id end
end
local scenes, plots, differ = 0, 0, 0
for _, id in ipairs(ids) do
  local scn, w, request = CmpRun.Setup(id)
  -- The mod's scripts read GameInfo when loaded: after the first world.
  include("MapTacks")
  include("SDP_Rules")
  include("SDP_City")
  include("SDP_Land")
  local weights = {}
  for k, v in pairs(request.weights) do weights[k] = v end
  local feature = weights.FEATURE == nil and 1 or weights.FEATURE
  local scale = feature * (1 + 9 * Progress()) / 20
  local judge = CmpLand.Context({ mode = "mod", weights = weights, oneTimeScale = scale })
  local mod = SDP_Land.Context(0, weights, true)
  local seen, count, bad = {}, 0, {}
  for _, c in ipairs(request.cities) do
    for i = 0, w.Width * w.Height - 1 do
      local plot = Map.GetPlotByIndex(i)
      if not seen[i] and Map.GetPlotDistance(plot:GetX(), plot:GetY(), c:GetX(), c:GetY()) <= 3 and not plot:IsCity()
          and plot:GetDistrictType() == -1 and plot:GetWonderType() == -1 then
        seen[i] = true
        count = count + 1
        local tile, once = CmpLand.PlotValues(plot, judge)
        local modTile, modOnce = SDP_Land.PlotValues(plot, mod)
        -- The mod charges one-time yields scaled; the judge reports them unscaled.
        if math.abs(tile - modTile) > EPS or math.abs(once * scale - modOnce) > EPS then
          bad[#bad + 1] = string.format("    plot %d,%d: judge %.4f / %.4f, mod %.4f / %.4f", plot:GetX(), plot:GetY(),
            tile, once * scale, modTile, modOnce)
        end
      end
    end
  end
  scenes, plots, differ = scenes + 1, plots + count, differ + #bad
  print(string.format("%-36s plots %4d  differ %d", id, count, #bad))
  for n = 1, math.min(5, #bad) do print(bad[n]) end
end
print(string.format("probe_land: %d scenes, %d plots, %d differ", scenes, plots, differ))
if differ > 0 then error("land values differ on " .. differ .. " plots") end
