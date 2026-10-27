"""Offline tests of tools/deploy.py's version guard (pitfall 45).

    python3 -I -m unittest discover -s tests/tools -v
"""
import contextlib
import io
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "tools"))
import deploy  # noqa: E402

MODINFO = '<?xml version="1.0" encoding="utf-8"?>\n<Mod id="d2b8b724-4174-42cb-943c-8036778c68ba" version="%d">\n</Mod>\n'


class DeployVersionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.source = os.path.join(self.tmp.name, "src", deploy.MOD_NAME)
        self.mods = os.path.join(self.tmp.name, "Mods")
        os.makedirs(self.source)
        os.makedirs(os.path.join(self.mods, deploy.MOD_NAME))

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, mod_dir, version):
        with open(os.path.join(mod_dir, deploy.MOD_NAME + ".modinfo"), "w", encoding="utf-8") as fh:
            fh.write(MODINFO % version)

    def run_deploy(self, *extra):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = deploy.main(["--dry-run", "--skip-validate", "--mods-dir", self.mods, "--source", self.source, *extra])
        return code, out.getvalue()

    def test_reads_the_version(self):
        self.write(self.source, 13)
        self.assertEqual(deploy.modinfo_version(self.source), 13)
        self.assertIsNone(deploy.modinfo_version(self.mods))

    def test_lower_version_is_refused(self):
        self.write(self.source, 12)
        self.write(os.path.join(self.mods, deploy.MOD_NAME), 13)
        code, out = self.run_deploy()
        self.assertEqual(code, 5)
        self.assertIn("from 13 to 12", out)

    def test_lower_version_with_override(self):
        self.write(self.source, 12)
        self.write(os.path.join(self.mods, deploy.MOD_NAME), 13)
        self.assertEqual(self.run_deploy("--allow-downgrade")[0], 0)

    def test_same_or_higher_version_and_first_deploy(self):
        self.write(self.source, 13)
        self.assertEqual(self.run_deploy()[0], 0)  # nothing deployed yet
        for deployed in (13, 12):
            self.write(os.path.join(self.mods, deploy.MOD_NAME), deployed)
            self.assertEqual(self.run_deploy()[0], 0)


if __name__ == "__main__":
    unittest.main()
