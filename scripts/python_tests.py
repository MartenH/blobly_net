"""python_tests.py — the Python package's tests (python/tests: the package, its examples, the pytest
example and its docs) under one or more interpreters, each in a fresh virtual environment with
pytest: from the source tree against a built engine, then from the installed wheel.

    python3 scripts/python_tests.py [--lib build/libblobly.so] [--wheel build/wheels/blobly-*.whl]
                                    python3 [/path/to/python3.11 ...]

--lib    the engine the source-tree run loads (BLOBLY_LIB); without it, no source-tree run.
--wheel  the wheel to install and test (py3-none: one wheel serves every version); without it,
         no installed run. The installed run sets BLOBLY_TEST_INSTALLED and keeps the source tree
         off sys.path, so the package and the engine it loads are the wheel's.

The suite runs under pytest (pinned below), which is not a dependency of the package: each
environment installs it and checks that it imports. A virtual environment
because a system Python may refuse a pip install (PEP 668). Exits 1 if any run failed, after
reporting all of them."""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PYTEST = "pytest==9.1.1"
# the suite under pytest, which runs its unittest classes and its pytest tests alike: importlib
# mode puts nothing on sys.path, so in the installed run the package is the wheel's, and no
# cache directory is written into the tree
PYTEST_ARGS = ["-v", "-p", "no:cacheprovider", "--import-mode=importlib"]
STEP_TIMEOUT_S = 900


def venv_python(env_dir):
    sub = ("Scripts", "python.exe") if sys.platform == "win32" else ("bin", "python")
    return os.path.join(env_dir, *sub)


def run(interpreter, lib, wheel):
    """One interpreter's runs, its output printed as each step ends; True when all passed."""
    exe = shutil.which(interpreter) or interpreter

    def step(title, cmd, env):
        print(f"--- {title}\n$ {' '.join(cmd)}", flush=True)
        t0 = time.monotonic()
        try:
            r = subprocess.run(cmd, cwd=ROOT, env=env, timeout=STEP_TIMEOUT_S)
        except subprocess.TimeoutExpired:
            print(f"[{title}: no exit within {STEP_TIMEOUT_S} s]", flush=True)
            return False
        except OSError as e:  # the interpreter would not start
            print(f"[{title}: {e}]", flush=True)
            return False
        print(f"[{title}: exit {r.returncode}, {time.monotonic() - t0:.1f} s]", flush=True)
        return r.returncode == 0

    # what the runs are told comes from these arguments alone; PYTHONPATH would put packages in
    # front of pip that the isolated (-I) runs cannot see
    base = {k: v for k, v in os.environ.items()
            if k not in ("BLOBLY_LIB", "BLOBLY_TEST_INSTALLED", "PYTHONPATH", "PYTHONHOME")}
    print(f"=== {exe}", flush=True)
    with tempfile.TemporaryDirectory(prefix="blobly-tests-", ignore_cleanup_errors=True) as env_dir:
        py = venv_python(env_dir)
        pip = [py, "-I", "-m", "pip", "install", "-q", "--disable-pip-version-check"]
        if not (step("venv", [exe, "-I", "-m", "venv", env_dir], base)
                and step("version", [py, "-I", "-c", "import sys; print(sys.version)"], base)
                and step("pytest", pip + [PYTEST], base)
                and step("pytest imports", [py, "-I", "-c", "import pytest"], base)):
            return False
        ok = True
        if lib:
            env = dict(base, BLOBLY_LIB=os.path.abspath(lib))
            ok &= step("source tree", [py, "-I", "-m", "pytest", *PYTEST_ARGS, "python/tests"], env)
        if wheel:
            if not step("install the wheel", pip + [os.path.abspath(wheel)], base):
                return False
            env = dict(base, BLOBLY_TEST_INSTALLED="1")
            ok &= step("installed wheel", [py, "-I", "-m", "pytest", *PYTEST_ARGS, "python/tests"], env)
    return ok


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("interpreters", nargs="+")
    ap.add_argument("--lib")
    ap.add_argument("--wheel")
    args = ap.parse_args()
    if not args.lib and not args.wheel:
        ap.error("nothing to test: give --lib, --wheel or both")
    wheels = [i for i in args.interpreters if i.endswith(".whl")]
    if wheels:
        ap.error(f"{', '.join(wheels)}: a wheel where an interpreter goes (one --wheel at a time)")
    results = [(i, run(i, args.lib, args.wheel)) for i in args.interpreters]
    print(", ".join(f"{i}: {'ok' if ok else 'FAILED'}" for i, ok in results))
    return 0 if all(ok for _, ok in results) else 1


if __name__ == "__main__":
    sys.exit(main())
