#!/usr/bin/env python3
"""validate - static checks for the SmartDistrictPlanner mod and Lua tests.

Catches the Civ6 failures that are silent or only show up after a game
restart (AGENTS.md section 5):
  xml        every .xml/.modinfo is well formed (xmllint --noout)
  modinfo    mod id, DMT dependency, <Files> matches disk (exact case),
             every action file is listed, AddUserInterfaces has a Context
  text       text files use <LocalizedText><Replace Tag Language> (pitfall 2),
             en_US and zh_Hans_CN define the same keys, modinfo <LocalizedText>
             matches Text/*.xml
  loc        every LOC_SDP_* key used in Lua/UI XML exists in both languages;
             modinfo Name/Teaser/Description keys load in the front end (pitfall 1)
  ui         UI XML only uses controls and attributes that appear in the game's
             own UI XML (pitfall 8: an invalid attribute fails silently)
  lua        tools/luacheck.mjs: Lua 5.1 syntax, banned globals, determinism
  refscene   tests/compare/refscenes/*.txt read back the same and their scene
             files and index.json entries are current (tools/refscene.py)
  markdown   every **bold** in the repository's .md files opens and closes on
             GitHub: "**标题。**正文" shows the stars, "**标题**。正文" is bold

Usage: validate.py [--strict] [--mod DIR] [--tests DIR]
Exit codes: 0 clean, 1 errors (or warnings with --strict), 2 tool missing.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import unicodedata
from xml.parsers import expat

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(ROOT, "tools")
MOD_DIR = os.path.join(ROOT, "SmartDistrictPlanner")
TESTS_DIR = os.path.join(ROOT, "tests")
REFERENCE = os.path.join(ROOT, "reference")

MOD_ID = "d2b8b724-4174-42cb-943c-8036778c68ba"
DMT_ID = "4ecfcc62-5471-4435-b295-590df213e8d8"
LANGUAGES = ("en_US", "zh_Hans_CN")
LOC_REF = re.compile(r"\bLOC_SDP_[A-Z0-9_]+")

# Attributes the game accepts but its own UI XML never uses. Add an entry only
# after confirming in game that the control renders; note where it was checked.
UI_ATTRIBUTE_ALLOWLIST = {}
# Misspellings that occur in the game's own UI XML and so look like precedents.
UI_ATTRIBUTE_TYPOS = {"Achnor": "Anchor", "StachGrowth": "StackGrowth",
                      "AutoScollbar": "AutoScrollBar", "size": "Size", "Hide": "Hidden"}


class Node:
    __slots__ = ("tag", "attrib", "children", "text", "line")

    def __init__(self, tag, attrib, line):
        self.tag, self.attrib, self.line = tag, attrib, line
        self.children, self.text = [], ""

    def find(self, tag):
        return next((c for c in self.children if c.tag == tag), None)

    def findall(self, tag):
        return [c for c in self.children if c.tag == tag]

    def iter(self):
        yield self
        for c in self.children:
            yield from c.iter()


def parse_xml(path):
    """Parse into Node trees keeping line numbers (ElementTree drops them)."""
    parser = expat.ParserCreate()
    stack, root = [], []

    def start(tag, attrib):
        node = Node(tag, attrib, parser.CurrentLineNumber)
        (stack[-1].children if stack else root).append(node)
        stack.append(node)

    def end(_tag):
        stack.pop()

    def chars(data):
        if stack:
            stack[-1].text += data

    parser.StartElementHandler, parser.EndElementHandler = start, end
    parser.CharacterDataHandler = chars
    with open(path, "rb") as fh:
        parser.ParseFile(fh)
    return root[0]


class Report:
    def __init__(self):
        self.items = []

    def add(self, severity, path, line, rule, message):
        rel = os.path.relpath(path, ROOT) if os.path.isabs(path) else path
        self.items.append((severity, rel, line or 0, rule, message))

    def error(self, path, line, rule, message):
        self.add("error", path, line, rule, message)

    def warning(self, path, line, rule, message):
        self.add("warning", path, line, rule, message)

    def count(self, severity):
        return sum(1 for i in self.items if i[0] == severity)


def list_files(directory):
    """Relative POSIX paths of all files, skipping dotfiles (.gitkeep etc.)."""
    out = []
    for dirpath, dirnames, filenames in os.walk(directory):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
        for name in sorted(filenames):
            if not name.startswith("."):
                out.append(os.path.relpath(os.path.join(dirpath, name), directory).replace(os.sep, "/"))
    return out


# -- xml -------------------------------------------------------------------
def check_xml(report, paths):
    """Well-formedness via xmllint (as AGENTS.md specifies), expat as fallback.
    Returns {path: Node} for the files that parsed."""
    bad = set()
    if paths and shutil.which("xmllint"):
        proc = subprocess.run(["xmllint", "--noout"] + paths, capture_output=True, text=True)
        for line in proc.stderr.splitlines():
            m = re.match(r"(.+?):(\d+): (.*)", line)
            if m and m.group(1) in paths:
                report.error(m.group(1), int(m.group(2)), "xml", m.group(3).strip())
                bad.add(m.group(1))
    elif paths:
        report.warning("xmllint", 0, "xml", "xmllint not found; using the built-in parser only")
    trees = {}
    for path in paths:
        try:
            trees[path] = parse_xml(path)
        except expat.ExpatError as e:
            if path not in bad:
                report.error(path, e.lineno, "xml", str(e))
    return trees


# -- text ------------------------------------------------------------------
def text_entries(report, path, root):
    """{(language, tag): text} from a database text file."""
    entries = {}
    if root.tag != "GameData":
        report.error(path, root.line, "text", "text file root must be <GameData>, found <%s>" % root.tag)
    for node in root.iter():
        if node.tag == "Text" and "id" in node.attrib:
            report.error(path, node.line, "text",
                         "<Text id=...> with language children only works inside the modinfo; "
                         "use <LocalizedText><Replace Tag=\"...\" Language=\"...\"> (pitfall 2)")
    for container in root.children:
        if container.tag not in ("LocalizedText", "EnglishText"):
            continue
        for row in container.children:
            if row.tag not in ("Replace", "Row"):
                continue
            tag = row.attrib.get("Tag")
            lang = row.attrib.get("Language") or ("en_US" if container.tag == "EnglishText" else None)
            if not tag or not lang:
                report.error(path, row.line, "text", "<%s> needs Tag and Language attributes" % row.tag)
                continue
            text = row.find("Text")
            if text is None and "Text" not in row.attrib:
                report.error(path, row.line, "text", "%s (%s) has no <Text>" % (tag, lang))
            if (lang, tag) in entries:
                report.warning(path, row.line, "text", "%s (%s) defined twice in this file" % (tag, lang))
            entries[(lang, tag)] = (text.text if text is not None else row.attrib.get("Text", "")).strip()
    return entries


def compare_languages(report, label, entries, where):
    """Both languages must define the same SDP keys."""
    keys = {lang: {t for (l, t) in entries if l == lang} for lang in LANGUAGES}
    for lang in LANGUAGES:
        for other in LANGUAGES:
            for tag in sorted(keys[other] - keys[lang]):
                if tag.startswith("LOC_SDP_"):
                    report.error(where, 0, "text", "%s: %s has %s but %s lacks it" % (label, other, tag, lang))


def modinfo_text(root):
    """{(language, tag): (line, text)} from <LocalizedText><Text id><en_US>...
    in the modinfo."""
    entries = {}
    loc = root.find("LocalizedText")
    for text in loc.findall("Text") if loc is not None else []:
        for child in text.children:
            entries[(child.tag, text.attrib.get("id", ""))] = (child.line, child.text.strip())
    return entries


# -- modinfo ---------------------------------------------------------------
def check_mod(report, mod_dir, trees):
    files_on_disk = list_files(mod_dir)
    modinfos = [f for f in files_on_disk if f.endswith(".modinfo") and "/" not in f]
    if len(modinfos) != 1:
        report.error(mod_dir, 0, "modinfo", "expected exactly one .modinfo at the mod root, found %d" % len(modinfos))
        return
    mpath = os.path.join(mod_dir, modinfos[0])
    root = trees.get(mpath)
    if root is None:
        return
    if root.tag != "Mod" or root.attrib.get("id") != MOD_ID:
        report.error(mpath, root.line, "modinfo", "root must be <Mod id=\"%s\">" % MOD_ID)

    deps = root.find("Dependencies")
    if deps is None or DMT_ID not in [m.attrib.get("id") for m in deps.findall("Mod")]:
        report.error(mpath, root.line, "modinfo", "Detailed Map Tacks (%s) must be listed in <Dependencies>" % DMT_ID)

    files_node = root.find("Files")
    listed = [f.text.strip().replace("\\", "/") for f in files_node.findall("File")] if files_node is not None else []
    disk_exact, disk_lower = set(files_on_disk), {f.lower(): f for f in files_on_disk}
    for f in listed:
        if f not in disk_exact:
            hint = " (on disk as %s)" % disk_lower[f.lower()] if f.lower() in disk_lower else ""
            report.error(mpath, 0, "modinfo", "<Files> lists %s but it does not exist%s" % (f, hint))
    for f in files_on_disk:
        if f not in listed and f != modinfos[0]:
            report.error(mpath, 0, "modinfo", "%s is in the mod folder but not listed in <Files>" % f)

    text_sources = {"FrontEndActions": [], "InGameActions": []}
    used = set()
    for group in ("FrontEndActions", "InGameActions"):
        actions = root.find(group)
        for action in actions.children if actions is not None else []:
            if action.tag == "Properties":
                continue
            for f in action.findall("File"):
                path = f.text.strip().replace("\\", "/")
                used.add(path)
                if path not in listed:
                    report.error(mpath, f.line, "modinfo", "%s/%s uses %s which is not in <Files>" % (group, action.tag, path))
                if action.tag == "UpdateText":
                    text_sources[group].append(path)
            if action.tag == "AddUserInterfaces":
                props = action.find("Properties")
                if props is None or props.find("Context") is None:
                    report.error(mpath, action.line, "modinfo",
                                 "AddUserInterfaces needs <Properties><Context>InGame</Context> (pitfall 3)")

    for f in files_on_disk:
        tree = trees.get(os.path.join(mod_dir, f))
        if tree is not None and tree.tag in ("GameData", "Context") and f not in used:
            report.warning(mpath, 0, "modinfo", "%s is never loaded: no action in the modinfo uses it" % f)

    # Text: per load stage, both languages must agree.
    stage_entries = {}
    for group, paths in text_sources.items():
        merged = {}
        for path in paths:
            full = os.path.join(mod_dir, path)
            if full in trees:
                merged.update(text_entries(report, full, trees[full]))
        stage_entries[group] = merged
        compare_languages(report, group, merged, mpath)

    # The modinfo copy (mod list, disabled mod) must match the Text/ copy.
    in_modinfo = modinfo_text(root)
    for (lang, tag), (line, text) in sorted(in_modinfo.items()):
        for group in ("FrontEndActions", "InGameActions"):
            other = stage_entries[group].get((lang, tag))
            if other is not None and other != text:
                report.error(mpath, line, "text", "%s (%s) in <LocalizedText> differs from the %s text file"
                             % (tag, lang, group))

    # Mod name/description: shown in the front end (pitfall 1).
    fe_keys = set(stage_entries["FrontEndActions"]) | set(in_modinfo)
    props = root.find("Properties")
    for child in props.children if props is not None else []:
        for key in LOC_REF.findall(child.text):
            for lang in LANGUAGES:
                if (lang, key) not in fe_keys:
                    report.error(mpath, child.line, "loc",
                                 "%s uses %s but no %s text for it loads in the front end "
                                 "(FrontEndActions/UpdateText or modinfo <LocalizedText>; pitfall 1)"
                                 % (child.tag, key, lang))

    # LOC keys referenced from Lua and UI XML must load in game.
    ig_keys = set(stage_entries["InGameActions"])
    text_files = {os.path.join(mod_dir, p) for ps in text_sources.values() for p in ps}
    for f in files_on_disk:
        full = os.path.join(mod_dir, f)
        if not f.endswith((".lua", ".xml")) or full in text_files:
            continue
        with open(full, encoding="utf-8-sig", errors="replace") as fh:
            for lineno, line in enumerate(fh, 1):
                for key in LOC_REF.findall(line):
                    if key.endswith("_"):
                        continue  # prefix of a key built at runtime
                    for lang in LANGUAGES:
                        if (lang, key) not in ig_keys:
                            report.error(full, lineno, "loc", "%s has no %s text in InGameActions/UpdateText" % (key, lang))


# -- ui precedent ------------------------------------------------------------
def ui_precedents():
    """{control tag: {attribute: [count, example file]}} from the game's own
    UI XML, or None when reference/ is not set up."""
    roots = [os.path.join(REFERENCE, "base-ui"), os.path.join(REFERENCE, "dlc")]
    if not all(os.path.isdir(r) for r in roots):
        return None
    table = {}
    for base in roots:
        for dirpath, _dirs, files in os.walk(base, followlinks=True):
            if base.endswith("dlc") and "/UI" not in dirpath.replace(os.sep, "/"):
                continue
            for name in files:
                if not name.lower().endswith(".xml"):
                    continue
                try:
                    root = parse_xml(os.path.join(dirpath, name))
                except (expat.ExpatError, OSError):
                    continue
                if root.tag != "Context":
                    continue
                for node in root.iter():
                    attrs = table.setdefault(node.tag, {})
                    for attr in node.attrib:
                        attrs.setdefault(attr, [0, name])[0] += 1
    return table


def check_ui(report, trees, precedents):
    for path, root in sorted(trees.items()):
        if root.tag != "Context":
            continue
        if precedents is None:
            report.warning(path, 0, "ui", "reference/base-ui or reference/dlc missing; UI precedent check skipped")
            return
        for node in root.iter():
            known = precedents.get(node.tag)
            if known is None:
                report.error(path, node.line, "ui", "<%s> never appears in the game's UI XML (typo?)" % node.tag)
                continue
            for attr in node.attrib:
                if attr in UI_ATTRIBUTE_ALLOWLIST.get(node.tag, ()):
                    continue
                if attr in UI_ATTRIBUTE_TYPOS:
                    report.error(path, node.line, "ui", "<%s %s=...> is a misspelling of %s"
                                 % (node.tag, attr, UI_ATTRIBUTE_TYPOS[attr]))
                elif attr not in known:
                    report.error(path, node.line, "ui",
                                 "<%s %s=...> has no precedent in the game's UI XML; an invalid "
                                 "attribute makes the control fail silently (pitfall 8)" % (node.tag, attr))
                elif known[attr][0] == 1:
                    report.warning(path, node.line, "ui", "<%s %s=...> appears only once in the game's "
                                   "UI XML (%s); check that it works" % (node.tag, attr, known[attr][1]))


CLICKABLE = ("Button", "GridButton", "CheckBox")


def check_click_cover(report, trees):
    """In an instance whose root is a button, no other button may cover it.

    A GridButton of parent size inside a button (the game's tab look,
    TabButtonSelected) takes the mouse while it is shown: the district cells
    could not be clicked again once selected (2026-10-21, found by a tester;
    synthetic clicks cannot reach the game window, so no test saw it). The
    game's own tabs get away with it because a selected tab needs no click.
    Use a Grid or Image for such a look."""
    for path, root in sorted(trees.items()):
        if root.tag != "Context":
            continue
        for instance in root.iter():
            if instance.tag != "Instance" or not instance.children:
                continue
            top = instance.children[0]
            if top.tag not in CLICKABLE:
                continue
            for node in top.iter():
                if node is top or node.tag not in CLICKABLE:
                    continue
                if node.attrib.get("Size", "").replace(" ", "") == "parent,parent":
                    report.error(path, node.line, "ui",
                                 "<%s> covers the clickable root of instance %s and takes its clicks; "
                                 "use a Grid or Image" % (node.tag, instance.attrib.get("Name", "?")))


# -- lua -------------------------------------------------------------------
def check_controls(report, mod_dir, trees):
    """Every Controls.<ID> a mod script uses names a control of the UI XML.

    The game hands a script nil for an unknown ID; calling a method on it
    fails only when that line runs (2026-10-20: a scroll panel removed from
    the XML still had a CalculateSize call, found by the in-game tests)."""
    ids = set()
    for root in trees.values():
        if root.tag == "Context":
            for node in root.iter():
                if node.attrib.get("ID"):
                    ids.add(node.attrib.get("ID"))
    for rel in list_files(mod_dir):
        if not rel.endswith(".lua"):
            continue
        path = os.path.join(mod_dir, rel)
        with open(path, encoding="utf-8") as f:
            for lineno, line in enumerate(f, 1):
                for name in re.findall(r"\bControls\.([A-Za-z0-9_]+)", line):
                    if name not in ids:
                        report.error(path, lineno, "ui", "Controls.%s is not an ID in the UI XML" % name)


def check_version(report, mod_dir):
    """The release in the launch bar tooltip (VERSION in UI/SDP_Panel.lua) is
    the newest version in CHANGELOG.md, so a bug report can name the copy the
    game loaded (issue 27)."""
    panel = os.path.join(mod_dir, "UI", "SDP_Panel.lua")
    changelog = os.path.join(ROOT, "CHANGELOG.md")
    if not (os.path.isfile(panel) and os.path.isfile(changelog)):
        return
    with open(panel, encoding="utf-8") as f:
        found = re.search(r'^local VERSION = "(v[0-9.]+)"', f.read(), re.M)
    with open(changelog, encoding="utf-8") as f:
        newest = re.search(r"^## (v[0-9]+\.[0-9]+\.[0-9]+)", f.read(), re.M)
    if found is None:
        report.error(panel, 0, "version", 'no line local VERSION = "vX.Y.Z"')
    elif newest is not None and found.group(1) != newest.group(1):
        report.error(panel, 0, "version", "VERSION is %s, the newest version in CHANGELOG.md is %s"
                     % (found.group(1), newest.group(1)))


def check_workshop(report):
    """The Workshop texts and change notes go into item.vdf at release time
    (tools/workshop.py); what pack would refuse fails here first."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    try:
        import workshop
    except ImportError:
        return
    for problem in workshop.problems()[0]:
        label = problem.split(":")[0]
        path = label if os.path.exists(os.path.join(ROOT, label)) else os.path.join("workshop", label)
        report.error(os.path.join(ROOT, path), 0, "workshop", problem[len(label) + 1:].strip())


def check_refscenes(report):
    """Reference scenes (tools/refscene.py): every source parses, survives
    the round trip, and its scene file and index.json entry are current."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    try:
        import refscene
    except ImportError:
        return
    for path, message in refscene.problems():
        report.error(os.path.join(ROOT, path), 0, "refscene", message)


def _punct(ch):
    return ch in "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~" or unicodedata.category(ch).startswith("P")


def bold_problems(text):
    """(line, snippet) for each ** that GitHub will not render as bold.

    CommonMark lets ** open only when it is left-flanking and close only when
    it is right-flanking. A ** after a full stop or colon and before text, as
    in "**标题。**正文", is neither, so the stars show. Fenced code and code
    spans are skipped; a bold may not span lines."""
    problems, fence = [], None
    for lineno, line in enumerate(text.split("\n"), 1):
        # A fence closes only with the same character, at least as long, and
        # nothing else on the line: ```` may hold an example with ```.
        m = re.match(r" {0,3}(`{3,}|~{3,})(.*)$", line)
        if m and fence is None:
            fence = m.group(1)
            continue
        if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence) and not m.group(2).strip():
            fence = None
            continue
        if fence is not None or "**" not in line:
            continue
        line = re.sub(r"`[^`]*`", "``", line.replace("\\*", ""))
        stack = []
        # Each run of two or more stars counts as one bold delimiter: in
        # "**bold *italic***" the final *** closes both.
        for m in re.finditer(r"\*{2,}", line):
            i, j = m.start(), m.end()
            before = line[i - 1] if i else " "
            after = line[j] if j < len(line) else " "
            opens = not after.isspace() and (not _punct(after) or before.isspace() or _punct(before))
            closes = not before.isspace() and (not _punct(before) or after.isspace() or _punct(after))
            if stack and closes:
                stack.pop()
            elif opens:
                stack.append(i)
            elif j - i > 2:
                continue  # a rule (***) or literal stars, not a bold
            else:
                stack.append(i)
                break
        if stack:
            i = stack[-1]
            problems.append((lineno, line[max(0, i - 12):i + 14]))
    return problems


def check_markdown(report):
    """Bold text in the repository's Markdown renders on GitHub (PR 174)."""
    try:
        names = subprocess.run(["git", "ls-files", "*.md"], cwd=ROOT, capture_output=True,
                               text=True, check=True).stdout.split()
    except (OSError, subprocess.CalledProcessError):
        return
    for name in names:
        path = os.path.join(ROOT, name)
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8") as f:
            for lineno, snippet in bold_problems(f.read()):
                report.error(path, lineno, "markdown",
                             "** does not open or close here, GitHub shows the stars; "
                             "put punctuation outside the bold: ...%s..." % snippet)


def check_lua(report, paths):
    if not paths:
        return True
    if not shutil.which("node"):
        report.error("node", 0, "lua", "node not found; Lua files were not checked")
        return False
    if not os.path.isdir(os.path.join(TOOLS, "node_modules", "luaparse")):
        report.error("tools/node_modules", 0, "lua", "luaparse missing; run: cd tools && npm install")
        return False
    proc = subprocess.run(["node", os.path.join(TOOLS, "luacheck.mjs"), "--json"] + paths,
                          capture_output=True, text=True)
    try:
        diags = json.loads(proc.stdout)
    except ValueError:
        report.error("tools/luacheck.mjs", 0, "lua", "checker failed: %s" % (proc.stderr.strip() or proc.stdout.strip()))
        return False
    for d in diags:
        report.add(d["severity"], d["file"], d["line"], d["rule"], d["message"])
    return True


def run(mod_dir=MOD_DIR, tests_dir=TESTS_DIR, strict=False, quiet=False):
    """Run all checks; returns (exit code, Report)."""
    report = Report()
    mod_files = [os.path.join(mod_dir, f) for f in list_files(mod_dir)] if os.path.isdir(mod_dir) else []
    if not os.path.isdir(mod_dir):
        report.error(mod_dir, 0, "modinfo", "mod folder not found")
    # tests/compare/ is the offline comparison harness: it runs in node
    # (tools/compare.mjs), never in the game, so the game's rules do not apply.
    test_files = [os.path.join(tests_dir, f) for f in list_files(tests_dir)
                  if not f.startswith("compare/")] if os.path.isdir(tests_dir) else []

    xml_paths = [p for p in mod_files if p.endswith((".xml", ".modinfo"))]
    trees = check_xml(report, xml_paths)
    if os.path.isdir(mod_dir):
        check_mod(report, mod_dir, trees)
        check_version(report, mod_dir)
    if any(root.tag == "Context" for root in trees.values()):
        check_ui(report, trees, ui_precedents())
        check_click_cover(report, trees)
        check_controls(report, mod_dir, trees)
    if os.path.isdir(os.path.join(ROOT, "workshop")):
        check_workshop(report)
    check_refscenes(report)
    check_markdown(report)
    tool_ok = check_lua(report, [p for p in mod_files + test_files if p.endswith(".lua")])

    if not quiet:
        for severity, path, line, rule, message in sorted(report.items, key=lambda i: (i[1], i[2], i[3])):
            print("%s %s:%d [%s] %s" % (severity.upper(), path, line, rule, message))
        print("validate: %d file(s), %d error(s), %d warning(s)"
              % (len(mod_files) + len(test_files), report.count("error"), report.count("warning")))
    if not tool_ok:
        return 2, report
    failed = report.count("error") or (strict and report.count("warning"))
    return (1 if failed else 0), report


def main(argv=None):
    ap = argparse.ArgumentParser(description="Static checks for the SmartDistrictPlanner mod")
    ap.add_argument("--strict", action="store_true", help="treat warnings as errors")
    ap.add_argument("--mod", default=MOD_DIR, help="mod folder (default SmartDistrictPlanner/)")
    ap.add_argument("--tests", default=TESTS_DIR, help="Lua test folder (default tests/)")
    args = ap.parse_args(argv)
    return run(os.path.abspath(args.mod), os.path.abspath(args.tests), args.strict)[0]


if __name__ == "__main__":
    sys.exit(main())
