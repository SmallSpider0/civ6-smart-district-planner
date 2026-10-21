"""Does the game give the plots around a preserve the yields of
Adjacent_AppealYieldChanges (grove, sanctuary)? The appeal part (SDP_Appeal)
counts them. Build a preserve with both buildings for a city (in the game
core) and read each plot around it in the UI state: Plot:GetYield in the
GameCore_Tuner state leaves out what buildings give other plots (even a farm
does not show there; 2026-10-21), so the first calibration read no change.
Compares with the rows for the plot's appeal as the game has it, at once and
after one autoplayed turn (with --turn). Changes the game in memory (do not
save).

    python3 -I tests/bench/probe_preserve.py CITY_ID X Y [--turn]
"""
import json
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import civ6tuner  # noqa: E402
import game  # noqa: E402

READ = """
local out = {}
local plot = Map.GetPlot(%(x)d, %(y)d)
for dir = 0, 5 do
  local n = Map.GetAdjacentPlot(plot:GetX(), plot:GetY(), dir)
  if n ~= nil then
    local y = {}
    for row in GameInfo.Yields() do y[#y + 1] = n:GetYield(row.Index) end
    out[#out + 1] = string.format('{"X":%%d,"Y":%%d,"Appeal":%%d,"Improved":%%s,"Blocked":%%s,"Water":%%s,"Yields":[%%s]}',
      n:GetX(), n:GetY(), n:GetAppeal(), tostring(n:GetImprovementType() ~= -1),
      tostring(n:GetDistrictType() ~= -1 or n:GetWonderType() ~= -1 or n:IsCity()), tostring(n:IsWater()), table.concat(y, ","))
  end
end
print("PLOTS [" .. table.concat(out, ",") .. "]")
"""
BUILD = """
local city = CityManager.GetCity(Game.GetLocalPlayer(), %(city)d)
local plot = Map.GetPlot(%(x)d, %(y)d)
local preserve
for row in GameInfo.Districts() do
  local base = GameInfo.DistrictReplaces[row.DistrictType]
  if row.DistrictType == "DISTRICT_PRESERVE" or (base and base.ReplacesDistrictType == "DISTRICT_PRESERVE") then preserve = row end
end
city:GetBuildQueue():CreateDistrict(preserve.Index, plot:GetIndex())
for _, b in ipairs({ "BUILDING_GROVE", "BUILDING_SANCTUARY" }) do
  WorldBuilder.CityManager():CreateBuilding(city, b, 100, plot:GetIndex())
end
local has = {}
for _, b in ipairs({ "BUILDING_GROVE", "BUILDING_SANCTUARY" }) do has[#has + 1] = b .. "=" .. tostring(city:GetBuildings():HasBuilding(GameInfo.Buildings[b].Index)) end
print("BUILT " .. tostring(plot:GetDistrictType() == preserve.Index) .. " " .. table.concat(has, " "))
"""


def run(state, code, timeout=60):
    resp = civ6tuner.request({"op": "exec", "state": state, "code": code, "timeout": timeout})
    if not resp.get("ok"):
        raise SystemExit("%s: %s" % (state, resp.get("error")))
    return resp.get("output") or []


def plots(x, y):
    line = next(l for l in run("InGame", READ % {"x": x, "y": y}) if l.startswith("PLOTS "))
    return json.loads(line[6:])


def rows():
    code = """
local out = {}
for r in GameInfo.Adjacent_AppealYieldChanges() do
  out[#out + 1] = string.format('{"Building":"%s","Yield":"%s","Min":%d,"Max":%d,"Change":%d,"Unimproved":%s}',
    r.BuildingType, r.YieldType, r.MinimumValue, r.MaximumValue, r.YieldChange, tostring(r.Unimproved == true))
end
local names = {}
for row in GameInfo.Yields() do names[#names + 1] = '"' .. row.YieldType .. '"' end
print("ROWS [" .. table.concat(out, ",") .. "]")
print("YIELDS [" .. table.concat(names, ",") .. "]")
"""
    lines = run("GameCore_Tuner", code)
    r = json.loads(next(l for l in lines if l.startswith("ROWS "))[5:])
    y = json.loads(next(l for l in lines if l.startswith("YIELDS "))[7:])
    return r, y


def expect(rows_, plot):
    out = {}
    if plot["Blocked"] or plot["Water"]:
        return out
    for r in rows_:
        if r["Min"] <= plot["Appeal"] <= r["Max"] and not (r["Unimproved"] and plot["Improved"]):
            out[r["Yield"]] = out.get(r["Yield"], 0) + r["Change"]
    return out


# A plot the rows give yields must change by exactly them. Other plots may
# change for other reasons (a farm the preserve took away lowers the farms
# next to it): listed, not counted.
def compare(label, before, after, rows_, names):
    rowed = same = 0
    for b, a in zip(before, after):
        want = expect(rows_, a)
        got = {names[k]: a["Yields"][k] - b["Yields"][k] for k in range(len(names)) if a["Yields"][k] != b["Yields"][k]}
        note = ""
        if want:
            rowed += 1
            same += got == want
            note = "" if got == want else "DIFFERENT"
        elif got:
            note = "(other effect)"
        print("  %s (%d,%d) appeal %d%s%s: rules %s, game %s %s" % (label, a["X"], a["Y"], a["Appeal"],
              " improved" if a["Improved"] else "", " blocked" if a["Blocked"] else "",
              {k[6:]: v for k, v in want.items()}, {k[6:]: v for k, v in got.items()}, note))
    print("%s: %d/%d plots with yields from the rows as the rules say" % (label, same, rowed))
    return same == rowed


def main():
    city, x, y = (int(v) for v in sys.argv[1:4])
    rows_, names = rows()
    before = plots(x, y)
    print(" ".join(run("GameCore_Tuner", BUILD % {"city": city, "x": x, "y": y})))
    time.sleep(2)  # the UI state sees the change a frame later
    now = plots(x, y)
    ok = compare("at once", before, now, rows_, names)
    if "--turn" not in sys.argv:
        return 0 if ok else 1
    start = int(run("InGame", "print(Game.GetCurrentGameTurn())")[-1])
    run("InGame", "AutoplayManager.SetTurns(1); AutoplayManager.SetReturnAsPlayer(Game.GetLocalPlayer()); "
                  "AutoplayManager.SetObserveAsPlayer(PlayerTypes.OBSERVER); AutoplayManager.SetActive(true)")
    deadline = time.monotonic() + 600
    while time.monotonic() < deadline:
        time.sleep(5)
        for name in game.queued_popups() or []:
            game.exec_lua(name, game.CLOSE_POPUP, timeout=3)
        try:
            lines = run("InGame", "print(Game.GetCurrentGameTurn(), AutoplayManager.IsActive())")
        except SystemExit:
            continue
        turn, active = lines[-1].split()
        if int(turn) > start and active == "false":
            break
    time.sleep(3)
    later = plots(x, y)
    ok = compare("next turn", before, later, rows_, names)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
