"""python/examples, run as a user runs them: each script as its own process, from a working
directory outside the repository (the default project is found beside the example, not in the
working directory), to a clean exit; and the pytest example under pytest. In a run of the
installed wheel the examples must import the installed package, not the source tree.

pytest is not a dependency of the package: its example is skipped where pytest is missing.
scripts/python_tests.py, which CI runs, installs pytest and checks that it imports first, so
there it runs."""
import os
import subprocess
import sys
import tempfile
import unittest
from importlib.util import find_spec

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
EXAMPLES = os.path.join(REPO, "python", "examples")
SIM_DEMO = os.path.join(REPO, "projects", "sim-demo.blobnet")
INSTALLED = bool(os.environ.get("BLOBLY_TEST_INSTALLED"))

# each script with arguments that keep it short; every script in the folder must be here
SCRIPTS = {
    "raw_can.py": [],
    "dbc_messages.py": [],
    "event_loop.py": ["--ms", "1000"],
    "signal_monitor.py": ["--seconds", "1.2"],
    "uds_diag.py": [],
    "fault_injection.py": [],
}


def run(*args, timeout=120):
    """`python <args>` as its own process, isolated as this one is, from a scratch directory."""
    env = dict(os.environ)
    if env.get("BLOBLY_LIB"):
        env["BLOBLY_LIB"] = os.path.abspath(env["BLOBLY_LIB"])  # the child's directory is not ours
    flags = ["-B"] + (["-I"] if sys.flags.isolated else [])
    with tempfile.TemporaryDirectory() as cwd:
        return subprocess.run([sys.executable, *flags, *args], cwd=cwd, env=env, capture_output=True,
                              text=True, encoding="utf-8", errors="replace", timeout=timeout)


class TestExamples(unittest.TestCase):
    def test_the_folder_and_its_index_name_the_same_examples(self):
        here = {f for f in os.listdir(EXAMPLES) if f.endswith(".py")}
        self.assertEqual(here - {"test_sim_demo.py", "conftest.py"}, set(SCRIPTS), "an example the test does not run")
        with open(os.path.join(EXAMPLES, "README.md"), encoding="utf-8") as f:
            index = f.read()
        for name in sorted(here):
            self.assertIn(f"]({name})", index, f"{name} is not linked from python/examples/README.md")

    def test_each_script_runs_clean(self):
        for name, args in SCRIPTS.items():
            with self.subTest(name):
                r = run(os.path.join(EXAMPLES, name), *args)
                self.assertEqual(r.returncode, 0, f"{name}:\n{r.stdout}\n{r.stderr}")
                self.assertIn("engine ", r.stdout)
                self.assert_package(r.stdout, name)

    def test_a_project_named_on_the_command_line_is_used(self):
        r = run(os.path.join(EXAMPLES, "raw_can.py"), SIM_DEMO, "--channel", "CAN2")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)  # CAN2 has no SUT to answer 0x101
        self.assertIn("receiving on CAN2", r.stdout)
        self.assertIn("FAIL: no 0x102 on CAN2", r.stderr)

    def test_the_repository_root_on_sys_path_is_no_package(self):
        # `python -m pytest` from the root puts it on sys.path, where its V blobly/ is a namespace
        script = os.path.join(EXAMPLES, "raw_can.py")
        boot = (f"import runpy, sys; sys.path.insert(0, {REPO!r}); sys.argv = [{script!r}]; "
                f"runpy.run_path({script!r}, run_name='__main__')")
        r = run("-c", boot)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assert_package(r.stdout, "raw_can.py")

    def test_a_missing_project_is_a_clear_failure(self):
        missing = os.path.join(REPO, "projects", "no-such.blobnet")
        r = run(os.path.join(EXAMPLES, "dbc_messages.py"), missing)
        self.assertEqual(r.returncode, 1)
        self.assertIn(f"FAIL: no project at {missing}", r.stderr)

    @unittest.skipIf(find_spec("pytest") is None, "pytest is not installed")
    def test_the_pytest_example_passes(self):
        # not -q: the plugin's header line says which blobly ran
        r = run("-m", "pytest", "-p", "no:cacheprovider", os.path.join(EXAMPLES, "test_sim_demo.py"))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("13 passed", r.stdout)
        self.assert_package(r.stdout, "test_sim_demo.py")

    def assert_package(self, out, name):
        """The example ran on the package this run tests: the installed wheel, or the checkout's
        (which an installed blobly would shadow, since the examples prefer one)."""
        if INSTALLED:
            self.assertNotIn("blobly 0+source", out, f"{name} imported the source tree")
        else:
            self.assertIn("blobly 0+source", out, f"{name} imported an installed blobly, not the checkout's")


if __name__ == "__main__":
    unittest.main()
