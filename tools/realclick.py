"""Real mouse clicks on the planner panel, checked through the panel's state (macOS only).

The game window refuses the computer-use tool's clicks and exposes no
accessibility elements, so a small app posts system mouse events:
tools/click/sdp-click.swift built into ~/Applications/SDPClick.app
(`python3 -I tools/realclick.py build`) and allowed once under System Settings >
Privacy & Security > Accessibility. It has to be an app started with `open`:
macOS judges Accessibility by the app that starts a command-line tool, which
would be the host app, not the tool. It lives outside iCloud Drive because
codesign refuses the extended attributes iCloud adds.
A control's place comes from the game itself (Control:GetScreenOffset in UI
units, scaled to the window), so no screenshot coordinates are guessed.

    python3 -I tools/realclick.py suite      # the click checks below, in a game with a capital
    python3 -I tools/realclick.py at CODE    # click the control a Lua expression gives (SDP_Panel state)

The suite opens the panel and goes through what only a real click shows:
district cells round their states on both tabs (the 2026-10-21 bug: the
selected look took the mouse), the city chips and the clear all / default
buttons on the multi-city tab, the harbor / commercial hub switch, tabs, solve (the
camera goes to the city), a result row (the camera goes to its plot), a solution
row, place and undo, the close button. Each check reads the state back.
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script dir
import civ6tuner  # noqa: E402
import game  # noqa: E402
import sdplock  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.expanduser("~/Applications/SDPClick.app")
SOURCE = os.path.join(ROOT, "tools", "click", "sdp-click.swift")
# A self-signed code-signing certificate in the login keychain (tools/README.md "realclick.py");
# without it the app is signed ad hoc and loses its grants on every rebuild.
SIGNING_ID = os.environ.get("SDP_CODESIGN_ID", "SDPClick Local Signing")
OUT = os.path.join(ROOT, "logs", "sdp-click.out")
INFO_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.sdp.click</string>
  <key>CFBundleName</key><string>SDPClick</string>
  <key>CFBundleExecutable</key><string>sdp-click</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
"""


def run_click(*args):
    """Run SDPClick.app with `args`; returns (ok, output)."""
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    if os.path.exists(OUT):
        os.remove(OUT)
    subprocess.run(["open", "-W", "-n", "-g", APP, "--args"] + list(args) + ["--out", OUT], capture_output=True)
    for _ in range(50):
        if os.path.exists(OUT):
            break
        time.sleep(0.1)
    text = open(OUT, encoding="utf-8").read().strip() if os.path.exists(OUT) else "ERROR no output"
    return not text.startswith("ERROR"), text


def lua(code, timeout=30):
    resp = civ6tuner.request({"op": "exec", "state": "SDP_Panel", "code": code, "timeout": timeout})
    if not resp.get("ok"):
        raise RuntimeError(resp.get("error"))
    return resp.get("output") or []


def value(code):
    """The printed value of a Lua expression."""
    lines = lua("print('VALUE', tostring(%s))" % code)
    for line in lines:
        if line.startswith("VALUE"):
            return line.split("\t", 1)[1] if "\t" in line else line[6:]
    return None


def window():
    ok, text = run_click("window")
    if not ok:
        raise RuntimeError(text)
    return [int(v) for v in text.split()]


def click_control(expr):
    """Click the center of the control `expr` (a Lua expression)."""
    lines = lua("""
local c = %s
if c == nil then print('AT nil') return end
local x, y = c:GetScreenOffset()
local w, h = UIManager:GetScreenSizeVal()
print('AT', x + c:GetSizeX() / 2, y + c:GetSizeY() / 2, w, h, tostring(c:IsHidden()))
""" % expr)
    at = next((l for l in lines if l.startswith("AT")), "AT nil").split()
    if at[1] == "nil":
        raise RuntimeError("no control: " + expr)
    cx, cy, uw, uh = (float(v) for v in at[1:5])
    _, _, ww, wh = window()
    scale = ww / uw
    title = wh - uh * scale  # the window's title bar
    x, y = cx * scale, title + cy * scale
    # The game's process is listed oddly (pid -1), so the click tool cannot
    # bring it forward itself; `open -b` can (as game.py does).
    if game.front_app() != game.CIV6_BUNDLE:
        subprocess.run(["open", "-b", game.CIV6_BUNDLE], capture_output=True)
        for _ in range(30):
            if game.front_app() == game.CIV6_BUNDLE:
                break
            time.sleep(0.1)
    ok, text = run_click("%.1f" % x, "%.1f" % y)
    if not ok:
        raise RuntimeError(text)
    # A frame or two for the callback, and enough that the next click on
    # the same control is not taken for a double click: with the Tuner
    # daemon the checks between clicks take milliseconds, and 0.6 s between
    # two clicks on one cell lost every other click (2026-10-23).
    time.sleep(1.0)


class Suite:
    def __init__(self):
        self.passed, self.failed = 0, []

    def check(self, label, got, want):
        ok = got == want
        print("  %s  %s: %s%s" % ("PASS" if ok else "FAIL", label, got, "" if ok else " (want %s)" % want), flush=True)
        if ok:
            self.passed += 1
        else:
            self.failed.append(label)


ROWS = {"SINGLE": "SDP_Panel.State().DistrictRows", "MULTI": "SDP_Panel.Multi.State().View.Districts",
        "SITES": "SDP_Panel.Sites.State().View.Districts"}


def cell_state(tab, district):
    rows = ROWS[tab]
    return value("(function() for _, r in ipairs(%s) do if r.Type == '%s' then return r.State end end end)()"
                 % (rows, district))


def cell(tab, district):
    rows = ROWS[tab]
    return "(function() for _, r in ipairs(%s) do if r.Type == '%s' then return r.Cell end end end)()" % (rows, district)


def own(base):
    return value("(function() for _, d in ipairs(SDP_Rules.PlannableDistricts(Game.GetLocalPlayer())) do "
                 "if SDP_Rules.BaseDistrict(d.Type) == '%s' then return d.Type end end end)()" % base)


def suite(args):
    back_to = game.front_app()
    try:
        return run_suite(args)
    finally:
        if back_to and back_to != game.CIV6_BUNDLE:
            subprocess.run(["open", "-b", back_to], capture_output=True)


def run_suite(_args):
    s = Suite()
    # A queued popup (historic moment, boost) covers the panel and takes the clicks.
    game.close_popups()
    lua("""
SDP_Panel.Open()
SDP_Panel.SelectTab("SINGLE")
local cap = Players[Game.GetLocalPlayer()]:GetCities():GetCapitalCity()
SDP_Panel.SelectCity(cap:GetID())
for _, d in ipairs(SDP_Rules.PlannableDistricts(Game.GetLocalPlayer())) do SDP_Panel.SetState(d.Type, SDP_UI.DefaultState(d)) end
""")
    campus = own("DISTRICT_CAMPUS")
    # A candidate and an automatic district the capital can still plan.
    pick = ("(function() for _, r in ipairs(SDP_Panel.State().DistrictRows) do "
            "if r.State == '%s' and r.Status == nil and r.Type ~= '%s' then return r.Type end end end)()")
    theater, aqueduct = value(pick % ("POOL", campus)), value(pick % ("AUTO", ""))
    print("cells: %s (candidate), %s (automatic)" % (theater, aqueduct))
    # District cells, single-city tab: round the states.
    for district, states in ((theater, ["POOL", "MUST", "OFF", "POOL"]), (aqueduct, ["AUTO", "MUST", "OFF", "AUTO"])):
        s.check("single %s starts" % district, cell_state("SINGLE", district), states[0])
        for want in states[1:]:
            click_control(cell("SINGLE", district))
            s.check("single %s after a click" % district, cell_state("SINGLE", district), want)
    # Tabs by click.
    click_control("Controls.MultiTab")
    s.check("multi tab by click", value("SDP_Panel.Tab()"), "MULTI")
    lua("SDP_Panel.Multi.Refresh()")
    for district, states in ((theater, ["POOL", "MUST", "OFF", "POOL"]), (aqueduct, ["AUTO", "MUST", "OFF", "AUTO"])):
        s.check("multi %s starts" % district, cell_state("MULTI", district), states[0])
        for want in states[1:]:
            click_control(cell("MULTI", district))
            s.check("multi %s after a click" % district, cell_state("MULTI", district), want)
    # A city-center pin's check box: off and on again.
    lua("""
local pid = Game.GetLocalPlayer()
local city = Players[pid]:GetCities():GetCapitalCity()
SDP_RealClickSite = nil
for _, entry in ipairs(SDP_City.PlotsInRange(city:GetX(), city:GetY(), 7)) do
  local plot = Map.GetPlotByIndex(entry.Index)
  if SDP_RealClickSite == nil and Map.GetPlotDistance(city:GetX(), city:GetY(), entry.X, entry.Y) == 6 and not plot:IsWater()
      and not plot:IsMountain() and plot:GetOwner() == -1 and PlayersVisibility[pid]:IsRevealed(entry.Index) then
    SDP_RealClickSite = entry
  end
end
local _, count = SDP_City.CityNumbers(pid)
SDP_Pins.Place(pid, { { Type = "DISTRICT_CITY_CENTER", X = SDP_RealClickSite.X, Y = SDP_RealClickSite.Y, Name = tostring(count + 1) } })
SDP_Panel.Multi.Refresh()
""")
    lua("SDP_Panel.Multi.SetCenter(nil); SDP_Panel.Multi.DefaultCities()")
    site = "(function() for _, c in ipairs(SDP_Panel.Multi.State().View.Cities) do if c.Kind == 'SITE' then return c end end end)()"
    s.check("site pin listed, on", value(site + ".Included"), "true")
    click_control(site + ".Chip")
    s.check("site chip off by click", value(site + ".Included"), "false")
    click_control(site + ".Chip")
    s.check("site chip on again by click", value(site + ".Included"), "true")
    # The two buttons over the chips (issue 63).
    click_control("Controls.MultiCityClear")
    s.check("clear all by click", value("#SDP_Panel.Multi.Participants()"), "0")
    click_control("Controls.MultiCityDefault")
    s.check("default by click", value(site + ".Included"), "true")
    # The settings line (issue 71): the switches sit under it; unfold by click.
    lua("SDP_Panel.Multi.SetFold(true)")
    click_control("Controls.MultiFoldButton")
    s.check("multi settings unfolded by click", value("SDP_Panel.Multi.State().Fold"), "false")
    # The swap switch (issue 54), on by default (issue 162).
    s.check("multi swap switch on by default", value("SDP_Panel.Multi.State().Swap"), "true")
    click_control("Controls.MultiSwapCheck")
    s.check("multi swap switch off by click", value("SDP_Panel.Multi.State().Swap"), "false")
    click_control("Controls.MultiSwapCheck")
    s.check("multi swap switch on again", value("SDP_Panel.Multi.State().Swap"), "true")
    # Back to the single-city tab: solve, a solution row, place, undo.
    click_control("Controls.SingleTab")
    s.check("single tab by click", value("SDP_Panel.Tab()"), "SINGLE")
    lua("SDP_Panel.SetFold(true)")
    click_control("Controls.FoldButton")
    s.check("single settings unfolded by click", value("SDP_Panel.State().Fold"), "false")
    s.check("single swap switch on by default", value("SDP_Panel.State().Swap"), "true")
    click_control("Controls.SwapCheck")
    s.check("single swap switch off by click", value("SDP_Panel.State().Swap"), "false")
    click_control("Controls.SwapCheck")
    s.check("single swap switch on again", value("SDP_Panel.State().Swap"), "true")
    # The coverage column, the last of the weight row (issue 61): its arrows,
    # 0.5 a click (issue 53).
    s.check("single coverage column last", value("SDP_Panel.State().WeightCells[9].Key"), "COVERAGE")
    click_control("SDP_Panel.State().WeightCells[9].More")
    s.check("single coverage up by click", value("SDP_Panel.State().Weights.COVERAGE == 0.5"), "true")
    click_control("SDP_Panel.State().WeightCells[9].Less")
    s.check("single coverage down by click", value("SDP_Panel.State().Weights.COVERAGE == 0"), "true")
    # The Tiles column (issue 53), in place of the land switch.
    s.check("single tiles column", value("SDP_Panel.State().WeightCells[6].Key"), "LAND")
    click_control("SDP_Panel.State().WeightCells[6].Less")
    s.check("single tiles down by click", value("SDP_Panel.State().Weights.LAND == 0.5"), "true")
    click_control("SDP_Panel.State().WeightCells[6].More")
    s.check("single tiles up by click", value("SDP_Panel.State().Weights.LAND == 1"), "true")
    lua("SDP_Panel.SetState('%s', 'MUST'); SDP_Panel.SetCount(3)" % campus)
    # Camera moves (issue 67): the panel records the last one (the game's UI table is read-only).
    lua("SDP_UI.LastLook = nil")
    click_control("Controls.SolveButton")
    for _ in range(60):
        if value("SDP_Panel.State().Running") == "false" and value("SDP_Panel.State().Result ~= nil") == "true":
            break
        time.sleep(0.5)
    s.check("solve by click", value("SDP_Panel.State().Result and SDP_Panel.State().Result.Ok"), "true")
    s.check("settings folded by the solve", value("SDP_Panel.State().Fold"), "true")
    capital = value("(function() local c = Players[Game.GetLocalPlayer()]:GetCities():GetCapitalCity() "
                    "return c:GetX() .. ',' .. c:GetY() end)()")
    s.check("the camera goes to the city", value("SDP_UI.LastLook"), capital)
    # A result row with a plot (issue 67): a click moves the camera there.
    row = "(function() for _, r in ipairs(SDP_Panel.State().ResultRows) do if r.X ~= nil then return r end end end)()"
    lua("SDP_UI.LastLook = nil")
    click_control(row + ".Row")
    s.check("result row by click", value("SDP_UI.LastLook"), value(row + ".X .. ',' .. " + row + ".Y"))
    rows = int(value("#(SDP_Panel.State().Result.Solutions or {})") or 0)
    if rows > 1:
        click_control("SDP_Panel.State().SolutionCells[2]")
        s.check("second solution by click", value("SDP_Panel.State().Solution"), "2")
    # Peek (issue 71): the window hidden, the way back by click.
    click_control("Controls.PeekButton")
    s.check("peek by click", value("SDP_Panel.State().Peek"), "true")
    click_control("Controls.PeekReturn")
    s.check("back from peek by click", value("SDP_Panel.State().Peek"), "false")
    click_control("Controls.PlaceButton")
    s.check("place by click", value("SDP_Panel.State().Result.Placed"), "true")
    click_control("Controls.UndoButton")
    s.check("undo by click", value("SDP_Panel.State().Result.Placed"), "false")
    # City sites (issue 75): the selected plan again, and Next site while
    # peeking, go through its sites.
    click_control("Controls.SitesTab")
    s.check("sites tab by click", value("SDP_Panel.Tab()"), "SITES")
    # The district grid and count (issue 90): a candidate and an other
    # district round their states, the count's arrows.
    candidate = value("(function() for _, r in ipairs(SDP_Panel.Sites.State().View.Districts) do "
                      "if r.State == 'POOL' and r.Status == nil then return r.Type end end end)()")
    for district, states in ((candidate, ["POOL", "MUST", "OFF", "POOL"]), (aqueduct, ["OFF", "MUST", "OFF"])):
        s.check("sites %s starts" % district, cell_state("SITES", district), states[0])
        for want in states[1:]:
            click_control(cell("SITES", district))
            s.check("sites %s after a click" % district, cell_state("SITES", district), want)
    s.check("sites district count", value("SDP_Panel.Sites.State().DistrictCount"), "3")
    click_control("Controls.SitesPlanMore")
    s.check("sites district count up by click", value("SDP_Panel.Sites.State().DistrictCount"), "4")
    click_control("Controls.SitesPlanLess")
    s.check("sites district count down by click", value("SDP_Panel.Sites.State().DistrictCount"), "3")
    lua("SDP_Panel.Sites.SetCount(2); SDP_Panel.Sites.SetTier('FAST'); SDP_Panel.Sites.SetSelected('%s', true); "
        "SDP_Panel.Sites.SetDistrictCount(1)" % campus)
    click_control("Controls.SitesSolveButton")
    for _ in range(120):
        if value("SDP_Panel.State().Running") == "false" and value("SDP_Panel.Sites.State().Result ~= nil") == "true":
            break
        time.sleep(0.5)
    sol = "SDP_Panel.Sites.State().Result.Solutions[SDP_Panel.Sites.State().Solution]"
    if value("SDP_Panel.Sites.State().Result.Ok and #%s.Sites == 2" % sol) == "true":
        at = ["%s.Sites[%d].X .. ',' .. %s.Sites[%d].Y" % (sol, n, sol, n) for n in (1, 2)]
        s.check("sites: the camera at the first site", value("SDP_UI.LastLook"), value(at[0]))
        click_control("SDP_Panel.Sites.State().View.Solutions[SDP_Panel.Sites.State().Solution].Cell")
        s.check("sites: the plan again by click, the second site", value("SDP_UI.LastLook"), value(at[1]))
        click_control("Controls.PeekButton")
        s.check("sites: next site shown while peeking", value("Controls.PeekNextSite:IsHidden()"), "false")
        click_control("Controls.PeekNextSite")
        s.check("sites: next site by click, round to the first", value("SDP_UI.LastLook"), value(at[0]))
        click_control("Controls.PeekReturn")
        s.check("sites: next site gone with the peek", value("Controls.PeekNextSite:IsHidden()"), "true")
    else:
        s.check("sites: a plan with two sites", value("SDP_Panel.Sites.State().Result.Ok and #%s.Sites" % sol), "2")
    lua("SDP_Panel.Sites.SetSelected('%s', false); SDP_Panel.Sites.SetDistrictCount(3); "
        "SDP_Panel.Sites.SetTier('STANDARD')" % campus)
    click_control("Controls.CloseButton")
    s.check("close by click", value("SDP_Panel.IsOpen()"), "false")
    # Issue 76: a city selected on the map since the panel last opened: it
    # opens on the single-city tab; the same one still selected: the tab it
    # was closed on. (Closed on the city sites tab just above.)
    lua("UI.DeselectAllCities(); SDP_Panel.Open(); SDP_Panel.SelectTab('SITES'); SDP_Panel.Close()")
    lua("UI.SelectCity(Players[Game.GetLocalPlayer()]:GetCities():GetCapitalCity())")
    time.sleep(0.5)
    lua("SDP_Panel.Open()")
    s.check("a city selected: opens on the single-city tab", value("SDP_Panel.Tab()"), "SINGLE")
    click_control("Controls.MultiTab")
    click_control("Controls.CloseButton")
    lua("SDP_Panel.Open()")
    s.check("the same city still selected: the tab it was closed on", value("SDP_Panel.Tab()"), "MULTI")
    lua("SDP_Panel.SelectTab('SINGLE'); SDP_Panel.Close(); UI.DeselectAllCities()")
    # Clean up the site pin.
    lua("while SDP_Pins.CanUndo() do SDP_Pins.UndoLast() end")
    print("realclick: %d passed, %d failed%s" % (s.passed, len(s.failed),
                                                  (": " + ", ".join(s.failed)) if s.failed else ""))
    return 0 if not s.failed else 1


def at(args):
    click_control(args.code)
    return 0


def build(args):
    """Build ~/Applications/SDPClick.app. Every rebuild changes the ad hoc signature, and macOS then
    drops the app's Accessibility and Screen Recording grants (they must be given again), so it
    only rebuilds when the Swift source changed (or with --force)."""
    import hashlib
    macos = os.path.join(APP, "Contents", "MacOS")
    stamp = os.path.join(APP, "Contents", "source.sha256")
    digest = hashlib.sha256(open(SOURCE, "rb").read()).hexdigest()
    if not getattr(args, "force", False) and os.path.exists(os.path.join(macos, "sdp-click")) \
            and os.path.exists(stamp) and open(stamp).read().strip() == digest:
        print("SDPClick.app is up to date (source unchanged); --force rebuilds (and needs the grants again)")
        print(run_click("trusted")[1])
        return 0
    os.makedirs(macos, exist_ok=True)
    with open(os.path.join(APP, "Contents", "Info.plist"), "w", encoding="utf-8") as fh:
        fh.write(INFO_PLIST)
    subprocess.run(["swiftc", "-O", SOURCE, "-o", os.path.join(macos, "sdp-click")], check=True)
    subprocess.run(["xattr", "-cr", APP], check=True)
    with open(stamp, "w") as fh:
        fh.write(digest + "\n")
    # A signing identity of its own keeps the app's Accessibility and Screen Recording grants across
    # rebuilds (an ad hoc signature changes with every build and macOS drops the grants).
    ids = subprocess.run(["security", "find-identity", "-p", "codesigning"], capture_output=True, text=True).stdout
    identity = SIGNING_ID if SIGNING_ID in ids else "-"
    subprocess.run(["codesign", "-s", identity, "--force", "--deep", APP], check=True)
    print("signed with %s" % ("the " + SIGNING_ID + " certificate" if identity != "-" else "an ad hoc signature"))
    if identity == "-":
        print("rebuilt: allow SDPClick again under Privacy & Security > Accessibility and > Screen & System Audio Recording")
    print(run_click("trusted")[1])
    return 0


def trusted(_args):
    text = run_click("trusted")[1]
    print(text)
    return 0 if text == "trusted" else 1


def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser(description="Real clicks on the planner panel")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("suite")
    b = sub.add_parser("build")
    b.add_argument("--force", action="store_true")
    sub.add_parser("trusted")
    ap_at = sub.add_parser("at")
    ap_at.add_argument("code")
    args = ap.parse_args(argv)
    if sys.platform != "darwin":
        print("realclick.py posts macOS mouse events (SDPClick.app); on other systems click by hand")
        return 2
    if args.cmd in ("suite", "at"):
        sdplock.claim_or_exit(ROOT, "realclick " + args.cmd)
    return {"suite": suite, "at": at, "build": build, "trusted": trusted}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
