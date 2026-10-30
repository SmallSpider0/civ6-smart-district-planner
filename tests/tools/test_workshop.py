"""Offline tests of tools/workshop.py: the description's pictures (inline.txt,
[img] placeholders, the picture size) and that pack's gallery list leaves them out.

    python3 -I -m unittest discover -s tests/tools -v
"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "tools"))
import workshop as ws  # noqa: E402


class ImgTags(unittest.TestCase):
    def test_address_and_known_placeholder_pass(self):
        text = "a\n[img]https://example.invalid/x.jpg[/img]\n[img]STEAM_IMG_A_EN[/img]\n"
        errors, left = ws.img_problems("d", text, {"STEAM_IMG_A_EN"})
        self.assertEqual(errors, [])
        self.assertEqual(left, ["STEAM_IMG_A_EN"])

    def test_unknown_placeholder_is_an_error(self):
        errors, left = ws.img_problems("d", "[img]STEAM_IMG_TYPO[/img]", {"STEAM_IMG_A_EN"})
        self.assertEqual(left, [])
        self.assertEqual(len(errors), 1)
        self.assertIn("STEAM_IMG_TYPO", errors[0])


class InlineSize(unittest.TestCase):
    def test_width_fixed_height_follows_the_svg(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "p.svg")
            with open(path, "w", encoding="utf-8") as f:
                f.write('<svg xmlns="http://www.w3.org/2000/svg" width="770" height="436" viewBox="0 0 769.5 436.0">')
            self.assertEqual(ws.inline_size(path), (1260, 714))


class Repository(unittest.TestCase):
    def test_every_placeholder_in_the_descriptions_is_listed(self):
        listed = {ph for _, ph in ws.inline()}
        for name in ("description.bbcode", "description_zh.bbcode"):
            errors, _ = ws.img_problems(name, ws.read(os.path.join(ws.WS, name)), listed)
            self.assertEqual(errors, [], name)

    def test_gallery_list_leaves_out_the_inline_pictures(self):
        gallery = [src for src, _ in ws.images()]
        self.assertTrue(gallery)
        self.assertFalse([src for src in gallery if src.startswith("workshop/inline/")])
        for src, _ in ws.inline():
            self.assertTrue(src.startswith("workshop/inline/"), src)


if __name__ == "__main__":
    unittest.main()
