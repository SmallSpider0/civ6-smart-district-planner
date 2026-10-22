#!/usr/bin/env python3
"""paths - where Steam, the game and the game's own folders are (macOS, Windows).

Every tool takes its default locations from here. When something is not
where the default says (a second Steam library is found through
libraryfolders.vdf; a Documents folder moved elsewhere is not), set the
environment variable below or pass the tool's own option.

                macOS (Aspyr)                                 Windows
  SDP_STEAM     ~/Library/Application Support/Steam           registry SteamPath, else
                                                              C:\\Program Files (x86)\\Steam
  game data     <library>/common/Sid Meier's Civilization VI  same folder (Base\\, DLC\\)
                /Civ6.app/Contents/Assets (Base/, DLC/)
  SDP_GAME_DOCS ~/Library/Application Support/Sid Meier's     Documents\\My Games\\
                Civilization VI/Sid Meier's Civilization VI   Sid Meier's Civilization VI
                (Mods, Saves)
  SDP_GAME_DATA ~/Library/Application Support/Sid Meier's     %LOCALAPPDATA%\\Firaxis Games\\
                Civilization VI/Firaxis Games/Sid Meier's     Sid Meier's Civilization VI
                Civilization VI (Logs, Cache, Mods.sqlite)

The Windows column is the game's documented layout; it has not been checked
on a Windows machine by these tools yet. `python3 -I tools/paths.py` prints
what was found.
"""
import os
import re
import sys

GAME_FOLDER = "Sid Meier's Civilization VI"
WORKSHOP_GAME = "289070"
# Workshop items the tools read (reference/, tools/compare.mjs).
DMT = "2428969051"  # Detailed Map Tacks, the mod's dependency
AMT = "3771382002"  # Auto Map Tacks Planner r49, compared against
EP = "3793348626"   # Empire Planner, compared against

MAC_SUPPORT = os.path.expanduser("~/Library/Application Support")


def _registry(root, key, name):
    try:
        import winreg
        with winreg.OpenKey(getattr(winreg, root), key) as handle:
            return winreg.QueryValueEx(handle, name)[0]
    except OSError:
        return None


def steam_root():
    if os.environ.get("SDP_STEAM"):
        return os.environ["SDP_STEAM"]
    if sys.platform == "darwin":
        return os.path.join(MAC_SUPPORT, "Steam")
    if sys.platform == "win32":
        found = _registry("HKEY_CURRENT_USER", r"Software\Valve\Steam", "SteamPath")
        if found:
            return os.path.normpath(found)
        return os.path.join(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"), "Steam")
    return None


def steam_libraries():
    """Every steamapps folder: the Steam folder's own, then libraryfolders.vdf's."""
    root = steam_root()
    if root is None:
        return []
    found = [os.path.join(root, "steamapps")]
    try:
        with open(os.path.join(root, "steamapps", "libraryfolders.vdf"), encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        text = ""
    for path in re.findall(r'"path"\s+"([^"]+)"', text):
        lib = os.path.join(os.path.normpath(path.replace("\\\\", "\\")), "steamapps")
        if all(os.path.normcase(lib) != os.path.normcase(f) for f in found):
            found.append(lib)
    return found


def _in_libraries(*parts):
    for lib in steam_libraries():
        path = os.path.join(lib, *parts)
        if os.path.isdir(path):
            return path
    return None


def game_assets():
    """The folder holding Base/ and DLC/ (inside Civ6.app on macOS)."""
    install = _in_libraries("common", GAME_FOLDER)
    if install is None:
        return None
    if sys.platform == "darwin":
        return os.path.join(install, "Civ6.app", "Contents", "Assets")
    return install


def workshop_item(item):
    return _in_libraries("workshop", "content", WORKSHOP_GAME, item)


def game_docs():
    """The game's user folder: Mods, Saves."""
    if os.environ.get("SDP_GAME_DOCS"):
        return os.environ["SDP_GAME_DOCS"]
    if sys.platform == "darwin":
        return os.path.join(MAC_SUPPORT, GAME_FOLDER, GAME_FOLDER)
    if sys.platform == "win32":
        # Documents may be moved (OneDrive does): the shell folder says where.
        docs = _registry("HKEY_CURRENT_USER", r"Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders",
                         "Personal")
        docs = os.path.expandvars(docs) if docs else os.path.join(os.path.expanduser("~"), "Documents")
        return os.path.join(docs, "My Games", GAME_FOLDER)
    return None


def game_data():
    """The game's data folder: Logs, Cache, Mods.sqlite."""
    if os.environ.get("SDP_GAME_DATA"):
        return os.environ["SDP_GAME_DATA"]
    if sys.platform == "darwin":
        return os.path.join(MAC_SUPPORT, GAME_FOLDER, "Firaxis Games", GAME_FOLDER)
    if sys.platform == "win32":
        local = os.environ.get("LOCALAPPDATA") or os.path.join(os.path.expanduser("~"), "AppData", "Local")
        return os.path.join(local, "Firaxis Games", GAME_FOLDER)
    return None


def _first_existing(*candidates):
    candidates = [c for c in candidates if c]
    for path in candidates:
        if os.path.exists(path):
            return path
    return candidates[0] if candidates else None


def mods_dir():
    docs = game_docs()
    return os.path.join(docs, "Mods") if docs else None


def saves_dir():
    docs = game_docs()
    return os.path.join(docs, "Saves", "Single") if docs else None


def logs_dir():
    data = game_data()
    return os.path.join(data, "Logs") if data else None


def gameplay_db():
    """Cache/DebugGameplay.sqlite, written when a game loads (either folder on Windows)."""
    data, docs = game_data(), game_docs()
    return _first_existing(data and os.path.join(data, "Cache", "DebugGameplay.sqlite"),
                           docs and os.path.join(docs, "Cache", "DebugGameplay.sqlite"))


def main():
    rows = [
        ("Steam", steam_root()),
        ("Steam libraries", ", ".join(steam_libraries()) or None),
        ("game data (Base, DLC)", game_assets()),
        ("DMT", workshop_item(DMT)),
        ("AMT", workshop_item(AMT)),
        ("Empire Planner", workshop_item(EP)),
        ("Mods", mods_dir()),
        ("Saves", saves_dir()),
        ("Logs", logs_dir()),
        ("DebugGameplay.sqlite", gameplay_db()),
    ]
    for label, path in rows:
        state = "missing" if path is None or not os.path.exists(path.split(", ")[0]) else "ok"
        print("%-22s %-7s %s" % (label, state, path or "-"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
