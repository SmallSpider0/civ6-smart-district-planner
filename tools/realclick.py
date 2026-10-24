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
selected look took the mouse), the city-center pin check box on the
multi-city tab, the harbor / commercial hub switch, tabs, solve, a solution
row, place and undo, the close button. Each check reads the state back.
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script dir
import civ6tuner  # noqa: E402
import game  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.expanduser("~/Applications/SDPClick.app")
SOURCE = os.path.join(ROOT, "tools", "click", "sdp-click.swift")
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


def cell_state(tab, district):
    rows = "SDP_Panel.State().DistrictRows" if tab == "SINGLE" else "SDP_Panel.Multi.State().View.Districts"
    return value("(function() for _, r in ipairs(%s) do if r.Type == '%s' then return r.State end end end)()"
                 % (rows, district))


def cell(tab, district):
    rows = "SDP_Panel.State().DistrictRows" if tab == "SINGLE" else "SDP_Panel.Multi.State().View.Districts"
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
    site = "(function() for _, c in ipairs(SDP_Panel.Multi.State().View.Cities) do if c.Kind == 'SITE' then return c end end end)()"
    s.check("site pin listed, on", value(site + ".Included"), "true")
    click_control(site + ".Check")
    s.check("site pin unticked by click", value(site + ".Included"), "false")
    click_control(site + ".Check")
    s.check("site pin ticked again", value(site + ".Included"), "true")
    # The harbor / commercial hub switch.
    click_control("Controls.MultiApartCheck")
    s.check("multi apart switch off by click", value("SDP_Panel.Multi.State().Apart"), "false")
    click_control("Controls.MultiApartCheck")
    s.check("multi apart switch on again", value("SDP_Panel.Multi.State().Apart"), "true")
    # The swap switch (issue 54), off by default.
    click_control("Controls.MultiSwapCheck")
    s.check("multi swap switch on by click", value("SDP_Panel.Multi.State().Swap"), "true")
    click_control("Controls.MultiSwapCheck")
    s.check("multi swap switch off again", value("SDP_Panel.Multi.State().Swap"), "false")
    # Back to the single-city tab: solve, a solution row, place, undo.
    click_control("Controls.SingleTab")
    s.check("single tab by click", value("SDP_Panel.Tab()"), "SINGLE")
    click_control("Controls.ApartCheck")
    s.check("single apart switch off by click", value("SDP_Panel.State().Apart"), "false")
    click_control("Controls.ApartCheck")
    s.check("single apart switch on again", value("SDP_Panel.State().Apart"), "true")
    click_control("Controls.SwapCheck")
    s.check("single swap switch on by click", value("SDP_Panel.State().Swap"), "true")
    click_control("Controls.SwapCheck")
    s.check("single swap switch off again", value("SDP_Panel.State().Swap"), "false")
    # The coverage column, the last of the weight row (issue 61): its arrows.
    s.check("single coverage column last", value("SDP_Panel.State().WeightCells[10].Key"), "COVERAGE")
    click_control("SDP_Panel.State().WeightCells[10].More")
    s.check("single coverage up by click", value("SDP_Panel.State().Weights.COVERAGE == 1"), "true")
    click_control("SDP_Panel.State().WeightCells[10].Less")
    s.check("single coverage down by click", value("SDP_Panel.State().Weights.COVERAGE == 0"), "true")
    lua("SDP_Panel.SetState('%s', 'MUST'); SDP_Panel.SetCount(3)" % campus)
    click_control("Controls.SolveButton")
    for _ in range(60):
        if value("SDP_Panel.State().Running") == "false" and value("SDP_Panel.State().Result ~= nil") == "true":
            break
        time.sleep(0.5)
    s.check("solve by click", value("SDP_Panel.State().Result and SDP_Panel.State().Result.Ok"), "true")
    rows = int(value("#(SDP_Panel.State().Result.Solutions or {})") or 0)
    if rows > 1:
        click_control("SDP_Panel.State().SolutionCells[2]")
        s.check("second solution by click", value("SDP_Panel.State().Solution"), "2")
    click_control("Controls.PlaceButton")
    s.check("place by click", value("SDP_Panel.State().Result.Placed"), "true")
    click_control("Controls.UndoButton")
    s.check("undo by click", value("SDP_Panel.State().Result.Placed"), "false")
    click_control("Controls.CloseButton")
    s.check("close by click", value("SDP_Panel.IsOpen()"), "false")
    # Clean up the site pin.
    lua("while SDP_Pins.CanUndo() do SDP_Pins.UndoLast() end")
    print("realclick: %d passed, %d failed%s" % (s.passed, len(s.failed),
                                                  (": " + ", ".join(s.failed)) if s.failed else ""))
    return 0 if not s.failed else 1


def at(args):
    click_control(args.code)
    return 0


def build(_args):
    """Build ~/Applications/SDPClick.app (a rebuild may need the Accessibility grant again)."""
    macos = os.path.join(APP, "Contents", "MacOS")
    os.makedirs(macos, exist_ok=True)
    with open(os.path.join(APP, "Contents", "Info.plist"), "w", encoding="utf-8") as fh:
        fh.write(INFO_PLIST)
    subprocess.run(["swiftc", "-O", SOURCE, "-o", os.path.join(macos, "sdp-click")], check=True)
    subprocess.run(["xattr", "-cr", APP], check=True)
    subprocess.run(["codesign", "-s", "-", "--force", "--deep", APP], check=True)
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
    sub.add_parser("build")
    sub.add_parser("trusted")
    ap_at = sub.add_parser("at")
    ap_at.add_argument("code")
    args = ap.parse_args(argv)
    if sys.platform != "darwin":
        print("realclick.py posts macOS mouse events (SDPClick.app); on other systems click by hand")
        return 2
    return {"suite": suite, "at": at, "build": build, "trusted": trusted}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
