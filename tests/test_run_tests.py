"""scripts/run-tests.py: every module runs, a failed or broken one is reported in full,
and an unknown name stops before anything runs. Uses throwaway modules, not the suite."""
import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("run_tests", ROOT / "scripts/run-tests.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

PASSING = "import unittest\nclass T(unittest.TestCase):\n    def test_a(self): pass\n    def test_b(self): pass\n"
FAILING = "import unittest\nclass T(unittest.TestCase):\n    def test_wrong(self): self.assertEqual(1, 2, 'the failure text')\n"
BROKEN = "import not_a_module_anywhere\n"


class RunTestsTests(unittest.TestCase):
    def setUp(self):
        self.tests = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(self.tests))
        for name, text in (("test_pass", PASSING), ("test_fail", FAILING), ("test_broken", BROKEN)):
            (self.tests / f"{name}.py").write_text(text)

    def run_main(self, *names, jobs="2"):
        out = io.StringIO()
        with patch.object(runner, "TESTS", self.tests), patch.dict("os.environ", {"JOBS": jobs}), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            code = runner.main(list(names))
        return code, out.getvalue()

    def test_every_module_runs_and_failures_are_shown_in_full(self):
        code, out = self.run_main()
        self.assertEqual(1, code)
        self.assertIn("ok    test_pass  2 tests", out)
        self.assertIn("FAIL  test_fail  1 test,", out)
        self.assertIn("FAIL  test_broken", out)
        self.assertIn("the failure text", out)
        self.assertIn("not_a_module_anywhere", out)
        self.assertIn("Ran 4 tests in 3 modules", out)  # The import error counts as one.
        self.assertIn("FAILED: ", out)

    def test_named_modules_only_and_a_pass_returns_zero(self):
        code, out = self.run_main("tests/test_pass.py", jobs="1")
        self.assertEqual(0, code, out)
        self.assertIn("Running 1 test module, 1 at a time.", out)
        self.assertNotIn("test_fail", out)

    def test_unknown_module_stops_before_running_anything(self):
        code, out = self.run_main("test_pass", "test_missing")
        self.assertEqual(2, code)
        self.assertIn("no test module test_missing", out)
        self.assertNotIn("ok ", out)


if __name__ == "__main__":
    unittest.main()
