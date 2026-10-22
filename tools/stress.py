"""In-game stress test on complex late-game saves (run before each release).

    python3 -I tools/stress.py prepare NAME [options]   # new game, AI plays N turns, save as SDP_stress_NAME
    python3 -I tools/stress.py load NAME                # back to the main menu if needed, load the save
    python3 -I tools/stress.py run NAME                 # the steps of tests/bench/stress.lua, timed
    python3 -I tools/stress.py check NAME               # the game builds the appeal plans: appeal and housing as predicted?
    python3 -I tools/stress.py all                      # load and run every scenario in SCENARIOS
    python3 -I tools/stress.py summary                  # the results as a table

`prepare` needs the game running (game.py launch); inside a game it leaves
for the main menu first. The local player is handed to the AI for the
autoplay (AutoplayManager, as the game's own automation tests do), so the save holds an empire the AI built: many cities,
built districts, wonders, foreign borders. The UI watches as the observer:
watching as player 0 sends the AI's diplomacy (first meetings, deals) to the
local screen, which waits for an answer and stops the autoplay. Popups
that hold the game's event queue (natural disasters, world crises; AGENTS
pitfall 24) stop it too, so each poll closes them. Saves go to the game's own save
folder (not the repository); results to tests/stress/results/NAME.json.

`check` changes the loaded game (it builds districts; the save stays as it
was): run it last, after any screenshots.

Times are wall-clock per step as the Tuner sees it (one request each, about
0.02 s of round trip). A solve here runs at once; in the panel the same work
is spread over frames, so the time is how long the player waits, not a stall.
"""
import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script dir
import civ6tuner  # noqa: E402
import game  # noqa: E402
import paths  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS = os.path.join(ROOT, "tests", "stress", "results")
STEPS = os.path.join(ROOT, "tests", "bench", "stress.lua")
SAVES = paths.saves_dir()

# The release scenarios: different rules, maps, sizes and civilizations.
SCENARIOS = {
    "pangaea-gs": dict(ruleset="RULESET_EXPANSION_2", script="Pangaea.lua", size="MAPSIZE_STANDARD",
                       era="ERA_ANCIENT", leader="LEADER_HOJO", seed=31, turns=200),
    "continents-gs": dict(ruleset="RULESET_EXPANSION_2", script="Continents.lua", size="MAPSIZE_LARGE",
                          era="ERA_MEDIEVAL", leader="LEADER_WILHELMINA", seed=47, turns=150),
    "islands-rf": dict(ruleset="RULESET_EXPANSION_1", script="Island_Plates.lua", size="MAPSIZE_STANDARD",
                       era="ERA_CLASSICAL", leader="LEADER_PERICLES", seed=59, turns=170),
}

SETUP = """
SDP_TestSetupOriginal = SDP_TestSetupOriginal or GameSetup_RefreshParameters
GameSetup_RefreshParameters = function(...)
  GameConfiguration.SetValue("RULESET", "%(ruleset)s")
  SDP_TestSetupOriginal(...)
  MapConfiguration.SetScript("%(script)s")
  MapConfiguration.SetMapSize("%(size)s")
  GameConfiguration.SetStartEra("%(era)s")
  GameConfiguration.SetGameSpeedType("GAMESPEED_ONLINE")
  PlayerConfigurations[0]:SetLeaderTypeName("%(leader)s")
  GameConfiguration.SetValue("GAME_SYNC_RANDOM_SEED", %(seed)d)
  MapConfiguration.SetValue("RANDOM_SEED", %(seed)d)
end
"""


def exec_lua(state, code, timeout=30.0):
    resp = civ6tuner.request({"op": "exec", "state": state, "code": code, "timeout": timeout})
    if not resp.get("ok"):
        raise RuntimeError("%s: %s" % (state, resp.get("error")))
    return resp.get("output") or []


def turn():
    for line in exec_lua("InGame", "print('TURN', Game.GetCurrentGameTurn(), AutoplayManager.IsActive())"):
        if line.startswith("TURN"):
            parts = line.split()
            return int(parts[1]), parts[2] == "true"
    return None, None


def save_name(name):
    return "SDP_stress_" + name


def cmd_prepare(args):
    sc = dict(SCENARIOS.get(args.name, {}))
    for key in ("ruleset", "script", "size", "era", "leader", "seed", "turns"):
        value = getattr(args, key)
        if value is not None:
            sc[key] = value
    missing = [k for k in ("ruleset", "script", "size", "era", "leader", "seed", "turns") if k not in sc]
    if missing:
        print("missing settings: %s" % ", ".join(missing))
        return 2
    if game.has_state("InGame") and game.cmd_menu(args) != 0:  # e.g. the previous scenario's game
        return 2
    if not game.wait_for("main menu", lambda: game.has_state("MainMenu"), 300):
        return 2
    exec_lua("MainMenu", game.MUTE + "; " + SETUP % sc + "Automation.SetAutoStartEnabled(true); OnPlayCiv6()")
    if not game.wait_for("in game", lambda: game.exec_lua("InGame", "print(1)").get("ok"), 600, 5):
        return 2
    exec_lua("InGame", game.MUTE)
    start, _ = turn()
    target = start + sc["turns"]
    exec_lua("InGame", "AutoplayManager.SetTurns(%d); AutoplayManager.SetReturnAsPlayer(0); "
             "AutoplayManager.SetObserveAsPlayer(PlayerTypes.OBSERVER); AutoplayManager.SetActive(true)" % sc["turns"])
    print("autoplay %d turns from turn %d" % (sc["turns"], start), flush=True)
    began = time.monotonic()
    while True:
        time.sleep(20)
        for name in game.queued_popups() or []:
            game.exec_lua(name, game.CLOSE_POPUP, timeout=3)
        try:
            now, active = turn()
        except RuntimeError:
            continue  # between turns the state can be busy
        print("  turn %s (%.0f min)" % (now, (time.monotonic() - began) / 60), flush=True)
        if now is not None and now >= target and not active:
            break
        if time.monotonic() - began > args.timeout:
            print("autoplay timed out")
            return 2
    game.close_popups()
    path = os.path.join(SAVES, save_name(args.name) + ".Civ6Save")
    before = os.path.getmtime(path) if os.path.exists(path) else 0
    exec_lua("InGame", """
local save = { Name = "%s", Location = SaveLocations.LOCAL_STORAGE, Type = SaveTypes.SINGLE_PLAYER,
  IsAutosave = false, IsQuicksave = false }
Network.SaveGame(save)
""" % save_name(args.name))
    if not game.wait_for("save", lambda: os.path.exists(path) and os.path.getmtime(path) > before, 120, 2):
        return 2
    print("saved %s (turn %s, %.0f min of autoplay)" % (path, turn()[0], (time.monotonic() - began) / 60))
    return 0


def cmd_load(args):
    if game.has_state("InGame"):
        if game.cmd_menu(args) != 0:
            return 2
    if not game.wait_for("main menu", lambda: game.has_state("MainMenu"), 300):
        return 2
    # Auto start: the load screen presses its own continue button
    # (LoadScreen.lua OnLoadGameViewStateDone), as for a new game.
    exec_lua("MainMenu", game.MUTE + """
Automation.SetAutoStartEnabled(true)
local load = { Name = "%s", Location = SaveLocations.LOCAL_STORAGE, Type = SaveTypes.SINGLE_PLAYER,
  IsAutosave = false, IsQuicksave = false, Directory = SaveDirectories.DEFAULT }
Network.LoadGame(load, ServerType.SERVER_TYPE_NONE)
""" % save_name(args.name))
    ready = lambda: game.has_state("SDP_Panel") and game.exec_lua("SDP_Panel", "print(1)").get("ok")  # noqa: E731
    if not game.wait_for("loaded", ready, 600, 5):
        return 2
    exec_lua("InGame", game.MUTE)
    time.sleep(5)
    game.close_popups()
    return 0


class Runner:
    def __init__(self):
        self.records = []

    def step(self, label, code, timeout=600):
        started = time.monotonic()
        lines = exec_lua("SDP_Panel", code, timeout)
        seconds = time.monotonic() - started
        data = None
        for line in lines:
            if line.startswith("SDP_STRESS "):
                try:
                    data = json.loads(line[len("SDP_STRESS "):])
                except ValueError:
                    data = {"Ok": False, "Error": "unreadable output: " + line[:300]}
        record = {"Label": label, "Seconds": round(seconds, 3), "Data": data}
        self.records.append(record)
        brief = {k: v for k, v in (data or {}).items() if k in ("Ok", "Error", "Gain", "Placed", "Mismatch",
                                                                "EngineBad", "Found", "Deterministic", "Together",
                                                                "Preserves", "WithBuildings", "Expected", "Seen",
                                                                "Missing")}
        print("  %-34s %7.2fs  %s" % (label, seconds, json.dumps(brief, ensure_ascii=False)), flush=True)
        return data


def cmd_run(args):
    with open(STEPS, encoding="utf-8") as fh:
        steps = fh.read()
    r = Runner()
    r.step("load steps", steps)
    census = r.step("census", "SDP_Stress.Census()")
    cities = census["Cities"]
    print("turn %s, %d cities, %d districts, %d wonders, %d pins, %d foreign cities" % (
        census["Turn"], len(cities), census["Districts"], census["Wonders"], census["Pins"], census["OtherCities"]))
    r.step("preserves", "SDP_Stress.Preserves()")
    big = [c for c in cities if c["Free"] > 0][:args.cities]
    for c in big:
        for tier in ("FAST", "STANDARD"):
            r.step("single %s %s pool" % (c["Name"], tier), 'SDP_Stress.Single(%d, "POOL", "%s", %s)'
                   % (c["ID"], tier, "true" if tier == "STANDARD" else "false"))
        r.step("single %s must" % c["Name"], 'SDP_Stress.Single(%d, "MUST", "STANDARD")' % c["ID"])
    for c in big[:3]:
        r.step("single %s appeal" % c["Name"], 'SDP_Stress.Single(%d, "APPEAL", "STANDARD")' % c["ID"])
        if c["Coastal"]:
            r.step("single %s harbor" % c["Name"], 'SDP_Stress.Single(%d, "HARBOR", "STANDARD")' % c["ID"])
    if big:
        r.step("single %s fine" % big[0]["Name"], 'SDP_Stress.Single(%d, "POOL", "FINE")' % big[0]["ID"])
    r.step("sites 3 within 8", 'SDP_Stress.Sites(3, 8, "STANDARD")')
    r.step("place sites", "SDP_Stress.PlaceSites()")
    r.step("multi 4 cities standard", 'SDP_Stress.Multi(4, 3, "STANDARD")')
    r.step("place multi", "SDP_Stress.PlaceMulti()")
    r.step("settle after place multi", "print(1)")
    r.step("multi 8 cities standard", 'SDP_Stress.Multi(8, 3, "STANDARD")')
    r.step("multi 4 cities fine", 'SDP_Stress.Multi(4, 3, "FINE")')
    r.step("heavy pins", "SDP_Stress.HeavyPins(150)")
    # DMT updates every new pin and its neighbours, each time reading and
    # writing its whole pin table: the game is busy for a while after many
    # pins at once. This empty request waits for that, so the solves after
    # it are timed alone.
    r.step("settle after heavy pins", "print(1)")
    if big:
        r.step("single %s pool, crowded" % big[0]["Name"], 'SDP_Stress.Single(%d, "POOL", "STANDARD")' % big[0]["ID"])
    r.step("multi 4 cities, crowded", 'SDP_Stress.Multi(4, 3, "STANDARD")')
    r.step("panel", "SDP_Stress.Panel()")
    r.step("undo", "SDP_Stress.UndoAll()")
    os.makedirs(RESULTS, exist_ok=True)
    out = os.path.join(RESULTS, args.name + ".json")
    with open(out, "w", encoding="utf-8") as fh:
        json.dump({"Scenario": args.name, "Settings": SCENARIOS.get(args.name), "Census": census,
                   "Steps": r.records, "When": time.strftime("%Y-%m-%d %H:%M")}, fh, ensure_ascii=False, indent=1)
    # No site within reach is an answer (a late-game map is full), not a failure.
    failures = [rec for rec in r.records if rec["Data"] and ((rec["Data"].get("Ok") is False
                                                              and rec["Data"].get("Error") != "NO_SITE")
                                                             or rec["Data"].get("Mismatch")
                                                            or rec["Data"].get("EngineBad") or rec["Data"].get("Deterministic") is False)]
    print("wrote %s; %d step(s) with a problem" % (out, len(failures)))
    return 0 if not failures else 1


# Districts are built the way the player builds them: ordered on the plot
# (CityOperationTypes.BUILD, in the UI state) and finished (the build
# queue's FinishProgress). The build queue's CreateDistrict, used earlier,
# does not clear features the same way (AGENTS pitfall 36).
ORDER = """
local city = CityManager.GetCity(%(owner)d, %(city)d)
local plot = Map.GetPlotByIndex(%(index)d)
local t = {}
t[CityOperationTypes.PARAM_X] = plot:GetX(); t[CityOperationTypes.PARAM_Y] = plot:GetY()
t[CityOperationTypes.PARAM_DISTRICT_TYPE] = GameInfo.Districts["%(type)s"].Hash
t[CityOperationTypes.PARAM_INSERT_MODE] = CityOperationTypes.VALUE_EXCLUSIVE
local can = CityManager.CanStartOperation(city, CityOperationTypes.BUILD, t)
if can then CityManager.RequestOperation(city, CityOperationTypes.BUILD, t) end
print("ORDER " .. tostring(can))
"""
# What the player needs to order the plan: each district's prerequisite
# technology and civic, and population for the specialty slots. Only these:
# unlocking everything at once leaves some appeal readings stale (22.4).
PREPARE = """
local player = Players[%(owner)d]
local city = CityManager.GetCity(%(owner)d, %(city)d)
for _, t in ipairs(%(types)s) do
  local row = GameInfo.Districts[t]
  if row.PrereqTech and GameInfo.Technologies[row.PrereqTech] then
    player:GetTechs():SetTech(GameInfo.Technologies[row.PrereqTech].Index, true)
  end
  if row.PrereqCivic and GameInfo.Civics[row.PrereqCivic] then
    player:GetCulture():SetCivic(GameInfo.Civics[row.PrereqCivic].Index, true)
  end
end
if city:GetPopulation() < 25 then city:ChangePopulation(25 - city:GetPopulation()) end
"""
FINISH = """
CityManager.GetCity(%(owner)d, %(city)d):GetBuildQueue():FinishProgress()
"""
HOUSING = """
local g = CityManager.GetCity(%(owner)d, %(city)d):GetGrowth()
local appeal = {}
for _, i in ipairs(%(indices)s) do appeal[#appeal + 1] = i .. ":" .. Map.GetPlotByIndex(i):GetAppeal() end
print("HOUSING " .. g:GetHousing() .. " " .. g:GetHousingFromDistricts() .. " " .. g:GetHousingFromImprovements() .. " "
  .. table.concat(appeal, ","))
"""
BUILT = """
print("BUILT " .. tostring(Map.GetPlotByIndex(%(index)d):GetDistrictType() == GameInfo.Districts["%(type)s"].Index))
"""


def build_normal(owner, city, district_type, index):
    """Order and finish one district; whether it stands afterwards."""
    args = {"owner": owner, "city": city, "type": district_type, "index": index}
    if "ORDER true" not in exec_lua("InGame", ORDER % args):
        return False
    time.sleep(1.5)
    exec_lua("GameCore_Tuner", FINISH % args)
    time.sleep(2)
    return any(line == "BUILT true" for line in exec_lua("GameCore_Tuner", BUILT % args))


def read_housing(owner, city, indices):
    line = next(l for l in exec_lua("GameCore_Tuner", HOUSING % {"owner": owner, "city": city,
                                                                "indices": "{" + ",".join(map(str, indices)) + "}"})
                if l.startswith("HOUSING "))
    parts = line.split(" ")
    appeal = {int(i): int(a) for i, a in (x.split(":") for x in (parts[4] if len(parts) > 4 else "").split(",") if x)}
    return float(parts[1]), float(parts[2]), float(parts[3]), appeal


def cmd_check(args):
    """Build each appeal plan of the last run in the game (the other districts
    first, then those that give housing) and compare appeal and housing."""
    out = os.path.join(RESULTS, args.name + ".json")
    with open(out, encoding="utf-8") as fh:
        data = json.load(fh)
    owner = int(exec_lua("InGame", "print(Game.GetLocalPlayer())")[-1])
    checks, problems = [], 0
    for rec in data["Steps"]:
        d = rec["Data"] or {}
        if d.get("Mode") != "APPEAL" or not d.get("Ok") or not d.get("Plan"):
            continue
        housing = {(h["X"], h["Y"]): h for h in d.get("Housing") or []}
        others = [p for p in d["Plan"] if (p["X"], p["Y"]) not in housing]
        homes = [p for p in d["Plan"] if (p["X"], p["Y"]) in housing]
        indices = [p["Index"] for p in homes]
        exec_lua("GameCore_Tuner", PREPARE % {"owner": owner, "city": d["City"],
                                             "types": "{" + ",".join('"%s"' % p["Type"] for p in d["Plan"]) + "}"})
        time.sleep(2)
        _, _, i0, _ = read_housing(owner, d["City"], indices)
        built = []
        for p in others:
            built.append("%s=%s" % (p["Type"], str(build_normal(owner, d["City"], p["Type"], p["Index"])).lower()))
        before, d0, _, _ = read_housing(owner, d["City"], indices)
        for p in homes:
            built.append("%s=%s" % (p["Type"], str(build_normal(owner, d["City"], p["Type"], p["Index"])).lower()))
        after, d1, i1, game_appeal = read_housing(owner, d["City"], indices)
        built = ",".join(built)
        from_districts, from_improvements = d1 - d0, i1 - i0
        predicted = sum(h["Housing"] for h in housing.values())
        # The districts' own housing is what the plan predicts; housing an
        # improvement on the plot gave is lost when the district is built.
        entry = {"City": d["City"], "Built": built, "HousingPredicted": predicted, "HousingGame": after - before,
                 "HousingDistricts": from_districts, "HousingImprovements": from_improvements,
                 "ImprovementsPredicted": d.get("ImprovementHousing"), "Districts": []}
        if "=false" in built:
            entry["Skipped"] = "the game did not build the whole plan"
        else:
            ok = abs((from_districts if from_districts is not None else after - before) - predicted) < 1e-6
            if d.get("ImprovementHousing") is not None and from_improvements is not None:
                ok = ok and abs(from_improvements - d["ImprovementHousing"]) < 1e-6
            for p in homes:
                h = housing[(p["X"], p["Y"])]
                got = game_appeal.get(p["Index"])
                entry["Districts"].append({"Type": p["Type"], "X": p["X"], "Y": p["Y"], "AppealPredicted": h["Appeal"],
                                           "AppealGame": got, "Housing": h["Housing"]})
                ok = ok and got == h["Appeal"]
            entry["Ok"] = ok
            problems += 0 if ok else 1
        checks.append(entry)
        print("  city %d: built %s; housing predicted +%g game %+g (districts %+g, improvements %+g predicted %+g); appeal %s%s" % (
            d["City"], built, predicted, after - before, from_districts or 0, from_improvements or 0,
            d.get("ImprovementHousing") or 0,
            ", ".join("%s %s/%s" % (x["Type"][9:], x["AppealPredicted"], x["AppealGame"]) for x in entry["Districts"]),
            "" if entry.get("Ok", True) else "  MISMATCH"), flush=True)
    data["AppealCheck"] = checks
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=1)
    print("appeal check: %d plan(s), %d with a difference" % (len(checks), problems))
    return 0 if problems == 0 else 1


def cmd_all(args):
    status = 0
    for name in SCENARIOS:
        args.name = name
        if cmd_load(args) != 0:
            print("could not load", name)
            status = 2
            continue
        status = max(status, cmd_run(args))
    return status


def cmd_summary(_args):
    for name in sorted(os.listdir(RESULTS)) if os.path.isdir(RESULTS) else []:
        with open(os.path.join(RESULTS, name), encoding="utf-8") as fh:
            data = json.load(fh)
        c = data["Census"]
        print("%s: turn %s, %d cities, %d districts, %d pins" % (data["Scenario"], c["Turn"], len(c["Cities"]),
                                                                c["Districts"], c["Pins"]))
        for rec in data["Steps"]:
            d = rec["Data"] or {}
            print("  %-34s %7.2fs  ok=%s gain=%s placed=%s" % (rec["Label"], rec["Seconds"], d.get("Ok"), d.get("Gain"),
                                                              d.get("Placed")))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="In-game stress test on late-game saves")
    sub = ap.add_subparsers(dest="cmd", required=True)
    pp = sub.add_parser("prepare")
    pp.add_argument("name")
    for key in ("ruleset", "script", "size", "era", "leader"):
        pp.add_argument("--" + key)
    pp.add_argument("--seed", type=int)
    pp.add_argument("--turns", type=int)
    pp.add_argument("--timeout", type=float, default=4 * 3600)
    lp = sub.add_parser("load")
    lp.add_argument("name")
    rp = sub.add_parser("run")
    rp.add_argument("name")
    rp.add_argument("--cities", type=int, default=6, help="cities solved one by one (most populous first)")
    cp = sub.add_parser("check")
    cp.add_argument("name")
    ap_all = sub.add_parser("all")
    ap_all.add_argument("--cities", type=int, default=6)
    sub.add_parser("summary")
    args = ap.parse_args(argv)
    return {"prepare": cmd_prepare, "load": cmd_load, "run": cmd_run, "check": cmd_check, "all": cmd_all, "summary": cmd_summary}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
