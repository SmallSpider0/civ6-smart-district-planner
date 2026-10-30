"""Offline tests of tools/validate.py's Markdown bold check (PR 174).

Each case was rendered with GitHub's own Markdown API (gh api markdown) on
2026-10-30: the check flags exactly the lines where GitHub shows the stars.

    python3 -I -m unittest discover -s tests/tools -v
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "tools"))
import validate  # noqa: E402

SHOWS_STARS = [
    "- **标题。**正文",
    '**"引号"**后文',
    "a **b** c **d.**e",
    "**粗**和**粗。**尾",
]
RENDERS = [
    "- **标题**。正文",
    "- **标题。** 正文",
    "中文**加粗**中文",
    "（**X**）后面",
    "**状态：已确认（2026）**。第 8 节",
    "点 **打钉**：钉名",
    "默认都不勾，**全选** 一次",
    "**Requires X.** It decides",
    "`**x。**y` 代码",
]


class BoldTest(unittest.TestCase):
    def test_flags_what_github_does_not_render(self):
        for line in SHOWS_STARS:
            with self.subTest(line=line):
                self.assertEqual([p[0] for p in validate.bold_problems(line)], [1])

    def test_passes_what_github_renders(self):
        for line in RENDERS:
            with self.subTest(line=line):
                self.assertEqual(validate.bold_problems(line), [])

    def test_skips_fenced_code_and_reports_line_numbers(self):
        text = "ok **a**\n```\n**b。**c\n```\n\n- **d。**e\n"
        self.assertEqual([p[0] for p in validate.bold_problems(text)], [6])


if __name__ == "__main__":
    unittest.main()
