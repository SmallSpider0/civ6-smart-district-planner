#!/usr/bin/env python3
"""shots - panel screenshots for docs/images/ (macOS).

    python3 -I tools/shots.py stage NAME     # tests/shots/NAME.lua in the SDP_Panel state (single, sites, multi)
    python3 -I tools/shots.py capture NAME   # the panel as it is now -> docs/images/NAME.jpg
    python3 -I tools/shots.py region         # where the panel is on screen (for computer-use instead)
    python3 -I tools/shots.py save SRC NAME  # crop SRC and write docs/images/NAME.jpg
    python3 -I tools/shots.py lang en|zh     # game closed: set the display language (backs up AppOptions.txt)
    python3 -I tools/shots.py lang restore   # put the backed-up AppOptions.txt back, byte for byte

`capture` asks SDPClick.app (tools/realclick.py build) for a PNG of the
panel's window, placed as the game itself reports it, the same way the real
clicks find controls; SDPClick brings the game forward and gives the front
back. It needs SDPClick allowed once under System Settings > Privacy &
Security > Screen & System Audio Recording (the first capture asks). Without
that, capture with computer-use's full-screen zoom of the rectangle `region`
prints (screen points; multiply by the screenshot frame's width / the
screen's width) and pass the file to `save`, which cuts 5 px off the sides
(the zoom catches the map beside the frame). Both write a JPEG of quality 90. Names follow CONTRIBUTING: v<round>-panel-
single.jpg, v<round>-en-panel-multi.jpg.

English shots: quit the game, `lang en`, launch, new game, stage, capture,
quit, `lang restore` (prints whether the file is identical to the backup).
The backup is logs/AppOptions.backup.txt; `lang en` refuses to overwrite an
existing backup, so a forgotten restore is not lost.
"""
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script dir
import civ6tuner  # noqa: E402
import game  # noqa: E402
import paths  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STAGES = os.path.join(ROOT, "tests", "shots")
IMAGES = os.path.join(ROOT, "docs", "images")
BACKUP = os.path.join(ROOT, "logs", "AppOptions.backup.txt")
LANGUAGES = {"en": "en_US", "zh": "zh_Hans_CN"}


def run(code, timeout=300):
    resp = civ6tuner.request({"op": "exec", "state": "SDP_Panel", "code": code, "timeout": timeout})
    if not resp.get("ok"):
        raise SystemExit("SDP_Panel: %s" % resp.get("error"))
    return resp.get("output") or []


def stage(args):
    path = os.path.join(STAGES, args.name + ".lua")
    if not os.path.exists(path):
        raise SystemExit("no stage %s (have: %s)" % (path, ", ".join(sorted(f[:-4] for f in os.listdir(STAGES)))))
    with open(path, encoding="utf-8") as fh:
        for line in run(fh.read()):
            print(line)
    return 0


def screen_size():
    out = subprocess.run(["osascript", "-e", 'tell application "Finder" to get bounds of window of desktop'],
                         capture_output=True, text=True).stdout
    nums = [int(n) for n in re.findall(r"-?\d+", out)]
    return (nums[2], nums[3]) if len(nums) == 4 else (None, None)


def panel_rect():
    """The panel window's rectangle relative to the game window, in points."""
    import realclick  # noqa: E402 (macOS only)
    lines = run("""
local c = Controls.Window
local x, y = c:GetScreenOffset()
local w, h = UIManager:GetScreenSizeVal()
print('AT', x, y, c:GetSizeX(), c:GetSizeY(), w, h)
""")
    at = next((l for l in lines if l.startswith("AT")), None)
    if at is None:
        raise SystemExit("panel window not found")
    cx, cy, cw, ch, uw, uh = (float(v) for v in at.split()[1:7])
    wx, wy, ww, wh = realclick.window()
    scale = ww / uw
    title = wh - uh * scale  # the window's title bar
    return (wx, wy), (cx * scale, title + cy * scale, cw * scale, ch * scale)


def region(_args):
    if game.front_app() != game.CIV6_BUNDLE:
        subprocess.run(["open", "-b", game.CIV6_BUNDLE], capture_output=True)
    (wx, wy), (x, y, w, h) = panel_rect()
    x0, y0, x1, y1 = wx + x, wy + y, wx + x + w, wy + y + h
    sw, sh = screen_size()
    print("panel in screen points: %d %d %d %d (screen %sx%s)" % (x0, y0, x1, y1, sw, sh))
    if sw:
        print("for a computer-use frame of width F: multiply by F/%d" % sw)
    return 0


def capture(args):
    import time
    import realclick  # noqa: E402 (macOS only)
    _, (x, y, w, h) = panel_rect()
    src = os.path.join(ROOT, "logs", "shot.png")
    if os.path.exists(src):
        os.remove(src)
    # SDPClick cannot find the game's process to activate it (pid -1, as in
    # realclick.click_control): bring it forward here, give the front back after.
    previous = game.front_app()
    subprocess.run(["open", "-b", game.CIV6_BUNDLE], capture_output=True)
    for _ in range(30):
        if game.front_app() == game.CIV6_BUNDLE:
            break
        time.sleep(0.1)
    time.sleep(0.5)  # a frame or two after the switch
    try:
        ok, text = realclick.run_click("capture", "%d" % x, "%d" % y, "%d" % w, "%d" % h, src)
    finally:
        if previous and previous != game.CIV6_BUNDLE:
            subprocess.run(["open", "-b", previous], capture_output=True)
    if not ok:
        raise SystemExit(text)
    return write_jpeg(src, args.name, cut=0)


def save(args):
    if not os.path.exists(args.src):
        raise SystemExit("no file " + args.src)
    return write_jpeg(args.src, args.name)


def write_jpeg(src, name, cut=5):
    out = os.path.join(IMAGES, name if name.endswith(".jpg") else name + ".jpg")
    tmp = out + ".tmp.png"
    shutil.copyfile(src, tmp)
    size = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", tmp], capture_output=True, text=True).stdout
    w = int(re.search(r"pixelWidth: (\d+)", size).group(1))
    h = int(re.search(r"pixelHeight: (\d+)", size).group(1))
    if cut:
        subprocess.run(["sips", "-c", str(h), str(w - 2 * cut), "--cropOffset", "0", str(cut), tmp], check=True,
                       capture_output=True)
    subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "90", tmp, "--out", out], check=True,
                   capture_output=True)
    os.remove(tmp)
    print("wrote %s (%dx%d)" % (os.path.relpath(out, ROOT), w - 2 * cut, h))
    return 0


def app_options():
    data, docs = paths.game_data(), paths.game_docs()
    for base in (data, docs):
        if base and os.path.exists(os.path.join(base, "AppOptions.txt")):
            return os.path.join(base, "AppOptions.txt")
    raise SystemExit("AppOptions.txt not found under %s or %s" % (data, docs))


def lang(args):
    if game.game_running():
        raise SystemExit("quit the game first (python3 -I tools/game.py quit): it rewrites AppOptions.txt on exit")
    path = app_options()
    if args.which == "restore":
        if not os.path.exists(BACKUP):
            raise SystemExit("no backup at " + BACKUP)
        shutil.copyfile(BACKUP, path)
        same = open(BACKUP, "rb").read() == open(path, "rb").read()
        print("restored %s: %s" % (path, "identical to the backup" if same else "DIFFERS"))
        if same:
            os.remove(BACKUP)
        return 0 if same else 1
    if os.path.exists(BACKUP):
        raise SystemExit("a backup is already there (%s): run `lang restore` first" % BACKUP)
    raw = open(path, "rb").read()
    new, n = re.subn(rb"^(DisplayLanguage )\S+(\r?)$", b"\\1" + LANGUAGES[args.which].encode() + b"\\2", raw,
                     flags=re.M)
    if n != 1:
        raise SystemExit("DisplayLanguage line not found once in " + path)
    os.makedirs(os.path.dirname(BACKUP), exist_ok=True)
    shutil.copyfile(path, BACKUP)
    open(path, "wb").write(new)  # keeps the CRLF line ends
    print("DisplayLanguage %s in %s (backup %s)" % (LANGUAGES[args.which], path, os.path.relpath(BACKUP, ROOT)))
    return 0


def main():
    import argparse
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("stage")
    s.add_argument("name")
    c = sub.add_parser("capture")
    c.add_argument("name")
    sub.add_parser("region")
    v = sub.add_parser("save")
    v.add_argument("src")
    v.add_argument("name")
    g = sub.add_parser("lang")
    g.add_argument("which", choices=["en", "zh", "restore"])
    args = ap.parse_args()
    if sys.platform != "darwin" and args.cmd in ("capture", "region", "save"):
        raise SystemExit("macOS only")
    return {"stage": stage, "capture": capture, "region": region, "save": save, "lang": lang}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
