"""Own-plot appeal when a district clears a feature, by the normal flow.

For woods, rainforest and marsh plots across the player's cities (three
plots or more apart; improved plots too, with river, improvement and resource noted), order a neighborhood there (CityOperationTypes.BUILD)
and finish it (FinishProgress); read the plot's own appeal and its
neighbours' before and after. A neighborhood has no appeal of its own.
Changes the game in memory (do not save).

    python3 -I tests/bench/probe_ownplot.py [MAX_PER_KIND]
"""
import json
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import civ6tuner  # noqa: E402


def run(state, code, timeout=60):
    resp = civ6tuner.request({"op": "exec", "state": state, "code": code, "timeout": timeout})
    if not resp.get("ok"):
        raise SystemExit("%s: %s" % (state, resp.get("error")))
    return resp.get("output") or []


PICK = """
local pid = Game.GetLocalPlayer()
local hood = GameInfo.Districts["DISTRICT_NEIGHBORHOOD"]
local left = { FEATURE_FOREST = %(n)d, FEATURE_JUNGLE = %(n)d, FEATURE_MARSH = %(n)d }
local out, picked = {}, {}
for _, city in Players[pid]:GetCities():Members() do
  for dx = -3, 3 do for dy = -3, 3 do
    local p = Map.GetPlotXYWithRangeCheck(city:GetX(), city:GetY(), dx, dy, 3)
    local f = p and p:GetFeatureType() or -1
    local ft = f ~= -1 and GameInfo.Features[f].FeatureType or nil
    if ft and left[ft] and left[ft] > 0 then
      local far = true
      for _, q in ipairs(picked) do if Map.GetPlotDistance(q[1], q[2], p:GetX(), p:GetY()) < 3 then far = false end end
      local t = {}
      t[CityOperationTypes.PARAM_X] = p:GetX(); t[CityOperationTypes.PARAM_Y] = p:GetY()
      t[CityOperationTypes.PARAM_DISTRICT_TYPE] = hood.Hash
      if far and CityManager.CanStartOperation(city, CityOperationTypes.BUILD, t) then
        left[ft] = left[ft] - 1
        picked[#picked + 1] = { p:GetX(), p:GetY() }
        out[#out + 1] = string.format('{"City":%%d,"X":%%d,"Y":%%d,"Feature":"%%s","River":%%s,"Improvement":%%d,"Resource":%%d}',
          city:GetID(), p:GetX(), p:GetY(), ft, tostring(p:IsRiver()), p:GetImprovementType(), p:GetResourceType())
      end
    end
  end end
end
print("PICK [" .. table.concat(out, ",") .. "]")
"""
READ = """
local p = Map.GetPlot(%(x)d, %(y)d)
local n = {}
local kinds = {}
for dir = 0, 5 do
  local q = Map.GetAdjacentPlot(p:GetX(), p:GetY(), dir)
  if q then
    n[#n + 1] = q:GetAppeal()
    kinds[#kinds + 1] = '"' .. ((q:IsWater() and "water") or (q:IsMountain() and "mountain") or (q:IsCity() and "city")
      or (q:GetDistrictType() ~= -1 and "district") or (q:GetWonderType() ~= -1 and "wonder")
      or (q:GetImprovementType() ~= -1 and "improved") or "land") .. '"'
  end
end
print(string.format('STATE {"Appeal":%%d,"Feature":%%d,"District":%%d,"Neighbours":[%%s],"Kinds":[%%s]}', p:GetAppeal(),
  p:GetFeatureType(), p:GetDistrictType(), table.concat(n, ","), table.concat(kinds, ",")))
"""
ORDER = """
local city = CityManager.GetCity(Game.GetLocalPlayer(), %(city)d)
local t = {}
t[CityOperationTypes.PARAM_X] = %(x)d; t[CityOperationTypes.PARAM_Y] = %(y)d
t[CityOperationTypes.PARAM_DISTRICT_TYPE] = GameInfo.Districts["DISTRICT_NEIGHBORHOOD"].Hash
t[CityOperationTypes.PARAM_INSERT_MODE] = CityOperationTypes.VALUE_EXCLUSIVE
CityManager.RequestOperation(city, CityOperationTypes.BUILD, t)
"""
FINISH = "CityManager.GetCity(Game.GetLocalPlayer(), %(city)d):GetBuildQueue():FinishProgress()"


def state(x, y):
    line = next(l for l in run("GameCore_Tuner", READ % {"x": x, "y": y}) if l.startswith("STATE "))
    return json.loads(line[6:])


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 3
    line = next(l for l in run("InGame", PICK % {"n": n}) if l.startswith("PICK "))
    for pick in json.loads(line[5:]):
        before = state(pick["X"], pick["Y"])
        run("InGame", ORDER % {"city": pick["City"], "x": pick["X"], "y": pick["Y"]})
        time.sleep(1.5)
        run("GameCore_Tuner", FINISH % {"city": pick["City"]})
        time.sleep(2)
        after = state(pick["X"], pick["Y"])
        time.sleep(6)
        later = state(pick["X"], pick["Y"])
        dn = ["%s %+d" % (k, a - b) for a, b, k in zip(after["Neighbours"], before["Neighbours"], before["Kinds"])]
        extra = "%s%s%s" % (" river" if pick["River"] else "", " improved" if pick["Improvement"] != -1 else "",
                            " resource" if pick["Resource"] != -1 else "")
        print("%-15s (%d,%d)%s: built %s, feature %d -> %d; own %d -> %d (%+d), 8 s later %d; neighbours %s" % (
            pick["Feature"], pick["X"], pick["Y"], extra, after["District"] != -1, before["Feature"], after["Feature"],
            before["Appeal"], after["Appeal"], after["Appeal"] - before["Appeal"], later["Appeal"], ", ".join(dn)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
