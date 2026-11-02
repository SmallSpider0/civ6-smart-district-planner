"""Offline tests of tools/changelog.py (issue 217): the change-log fragments
in changelog.d/, what release.py prep makes of them and what validate.py checks.

    python3 -I -m unittest discover -s tests/tools -v
"""
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "tools"))
import changelog  # noqa: E402
import validate  # noqa: E402

HEAD = "# 更新记录\n\n只列要点。\n\n"
OLD = "## v1.7.0（2026-11-03）\n\n- 旧的一条（#199）。\n\n## v1.6.5（2026-10-31）\n\n- 更旧的（#188）。\n"


class FragmentTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.folder = os.path.join(self.dir, "changelog.d")
        os.mkdir(self.folder)
        self.log = os.path.join(self.dir, "CHANGELOG.md")
        self.write(self.log, HEAD + OLD)
        self.write(os.path.join(self.folder, "README.md"), "# changelog.d\n\nNot an entry.\n")

    def tearDown(self):
        shutil.rmtree(self.dir)

    def write(self, path, text):
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)

    def frag(self, name, text):
        self.write(os.path.join(self.folder, name), text)

    def read(self, path):
        with open(path, encoding="utf-8") as f:
            return f.read()

    def problems(self):
        return [(os.path.basename(p), n) for p, n, _ in changelog.problems(self.folder, self.log)]

    def test_collect_sorts_by_number_writes_section_and_deletes(self):
        self.frag("217.md", "- 第三（#217）。\n")
        self.frag("9.md", "- 第一（#9）。\n\n- 第二（#9）。\n")
        self.frag("217-ui.md", "- 第四（#217）。\n")
        lines = changelog.collect("1.7.1", "2026-11-04", self.folder, self.log)
        self.assertEqual(lines, ["- 第一（#9）。", "- 第二（#9）。", "- 第三（#217）。", "- 第四（#217）。"])
        self.assertEqual(self.read(self.log), HEAD + "## v1.7.1（2026-11-04）\n\n" + "\n".join(lines) + "\n\n" + OLD)
        self.assertEqual(sorted(os.listdir(self.folder)), ["README.md"])

    def test_number_order_is_numeric(self):
        self.frag("100.md", "- c\n")
        self.frag("20.md", "- b\n")
        self.frag("3.md", "- a\n")
        self.assertEqual(changelog.entries(self.folder), ["- a", "- b", "- c"])

    def test_refuses_without_fragments_and_changes_nothing(self):
        with self.assertRaises(SystemExit):
            changelog.collect("1.7.1", "2026-11-04", self.folder, self.log)
        self.assertEqual(self.read(self.log), HEAD + OLD)

    def test_refuses_existing_version_and_keeps_fragments(self):
        self.frag("5.md", "- x\n")
        with self.assertRaises(SystemExit):
            changelog.collect("1.7.0", "2026-11-04", self.folder, self.log)
        self.assertEqual(self.read(self.log), HEAD + OLD)
        self.assertIn("5.md", os.listdir(self.folder))

    def test_refuses_malformed_fragment_and_keeps_all(self):
        self.frag("5.md", "- x\n")
        self.frag("6.md", "## 标题\n- y\n")
        with self.assertRaises(SystemExit):
            changelog.collect("1.7.1", "2026-11-04", self.folder, self.log)
        self.assertEqual(self.read(self.log), HEAD + OLD)
        self.assertEqual(sorted(os.listdir(self.folder)), ["5.md", "6.md", "README.md"])

    def test_problems(self):
        self.frag("1.md", "- 好的\n")
        self.frag("2.md", "\n")                      # no entry
        self.frag("3.md", "- 一条\n  接着写\n")        # continuation line
        self.frag("4.md", "-没有空格\n")
        self.frag("fix.md", "- 名字不对\n")
        self.frag("5-two.md", "- 第二个文件\n")
        self.assertEqual(self.problems(), [("2.md", 0), ("3.md", 2), ("4.md", 1), ("4.md", 0), ("fix.md", 0)])

    def test_unreleased_section_is_a_problem(self):
        self.write(self.log, HEAD + "## 未发布\n\n- 旧写法\n\n" + OLD)
        self.assertEqual(self.problems(), [("CHANGELOG.md", 5)])

    def test_validate_reports_them(self):
        self.frag("x.md", "- bad name\n")
        old = changelog.problems
        changelog.problems = lambda: old(self.folder, self.log)
        try:
            report = validate.Report()
            validate.check_changelog(report)
        finally:
            changelog.problems = old
        self.assertEqual([(i[0], os.path.basename(i[1]), i[3]) for i in report.items], [("error", "x.md", "changelog")])

    def test_repository_is_clean(self):
        self.assertEqual(changelog.problems(), [])


if __name__ == "__main__":
    unittest.main()
