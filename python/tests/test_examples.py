"""python/examples, run as a user runs them: each script as its own process, from a working
directory outside the repository (the default project is found beside the example, not in the
working directory), to a clean exit; and the pytest example under pytest. In a run of the
installed wheel the examples must import the installed package, not the source tree.

The suite runs under pytest, which scripts/python_tests.py (what CI runs) installs."""
import os
import socket
import struct
import threading

from conftest import INSTALLED, REPO, SIM_DEMO, run_python as run

EXAMPLES = os.path.join(REPO, "python", "examples")

# each script with arguments that keep it short; every script in the folder must be here
SCRIPTS = {
    "raw_can.py": [],
    "dbc_messages.py": [],
    "event_loop.py": ["--ms", "1000"],
    "signal_monitor.py": ["--seconds", "1.2"],
    "uds_diag.py": [],
    "doip_diag.py": [],
    "fault_injection.py": [],
    "flash_ecu.py": [],
    "someip_node.py": None,  # against a node: SomeipNode's
}


class SomeipNode:
    """A static-peer SOME/IP node on loopback for someip_node.py: each request answered from its
    own port with the RESPONSE mirroring it, preceded by an event."""

    def __init__(self):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.settimeout(0.05)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]  # the peer port the example sends from, free now
        self.args = ["--to", f"127.0.0.1:{self.sock.getsockname()[1]}", "--port", str(port)]
        self.done = threading.Event()
        self.t = threading.Thread(target=self.serve, daemon=True)
        self.t.start()

    def serve(self):
        while not self.done.is_set():
            try:
                data, src = self.sock.recvfrom(2048)
            except socket.timeout:
                continue
            svc, mth, _, client, session, _, iface, mtype, _ = struct.unpack(">HHIHHBBBB", data[:16])
            if mtype == 0x00:
                self.sock.sendto(struct.pack(">HHIHHBBBB", svc, 0x8001, 8, 0, 0, 1, iface, 0x02, 0), src)
                payload = data[16:][::-1]
                self.sock.sendto(struct.pack(">HHIHHBBBB", svc, mth, 8 + len(payload), client, session, 1, iface,
                                             0x80, 0) + payload, src)

    def close(self):
        self.done.set()
        self.t.join()
        self.sock.close()


def assert_package(out, name):
    """The example ran on the package this run tests: the installed wheel, or the checkout's
    (which an installed blobly would shadow, since the examples prefer one)."""
    if INSTALLED:
        assert "blobly 0+source" not in out, f"{name} imported the source tree"
    else:
        assert "blobly 0+source" in out, f"{name} imported an installed blobly, not the checkout's"


class TestExamples:
    def test_the_folder_and_its_index_name_the_same_examples(self):
        here = {f for f in os.listdir(EXAMPLES) if f.endswith(".py")}
        assert here - {"test_sim_demo.py", "conftest.py"} == set(SCRIPTS), "an example the test does not run"
        with open(os.path.join(EXAMPLES, "README.md"), encoding="utf-8") as f:
            index = f.read()
        for name in sorted(here):
            assert f"]({name})" in index, f"{name} is not linked from python/examples/README.md"

    def test_each_script_runs_clean(self):
        for name, args in SCRIPTS.items():
            node = SomeipNode() if args is None else None
            try:
                r = run(os.path.join(EXAMPLES, name), *(node.args if node else args))
            finally:
                if node:
                    node.close()
            assert r.returncode == 0, f"{name}:\n{r.stdout}\n{r.stderr}"
            assert "engine " in r.stdout, name
            assert_package(r.stdout, name)

    def test_a_project_named_on_the_command_line_is_used(self):
        r = run(os.path.join(EXAMPLES, "raw_can.py"), SIM_DEMO, "--channel", "CAN2")
        assert r.returncode == 1, r.stdout + r.stderr  # CAN2 has no SUT to answer 0x101
        assert "receiving on CAN2" in r.stdout
        assert "FAIL: no 0x102 on CAN2" in r.stderr

    def test_the_repository_root_on_sys_path_is_no_package(self):
        # `python -m pytest` from the root puts it on sys.path, where its V blobly/ is a namespace
        script = os.path.join(EXAMPLES, "raw_can.py")
        boot = (f"import runpy, sys; sys.path.insert(0, {REPO!r}); sys.argv = [{script!r}]; "
                f"runpy.run_path({script!r}, run_name='__main__')")
        r = run("-c", boot)
        assert r.returncode == 0, r.stdout + r.stderr
        assert_package(r.stdout, "raw_can.py")

    def test_a_missing_project_is_a_clear_failure(self):
        missing = os.path.join(REPO, "projects", "no-such.blobnet")
        r = run(os.path.join(EXAMPLES, "dbc_messages.py"), missing)
        assert r.returncode == 1
        assert f"FAIL: no project at {missing}" in r.stderr

    def test_the_pytest_example_passes(self):
        # not -q: the plugin's header line says which blobly ran
        r = run("-m", "pytest", "-p", "no:cacheprovider", os.path.join(EXAMPLES, "test_sim_demo.py"))
        assert r.returncode == 0, r.stdout + r.stderr
        assert "15 passed" in r.stdout
        assert_package(r.stdout, "test_sim_demo.py")
