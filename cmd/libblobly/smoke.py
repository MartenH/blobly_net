"""smoke.py — a ctypes host of libblobly, the shape the Python package will take: the library
loaded into THIS interpreter, sim-demo brought up, its simulated ECUs heard on inproc:CAN1 from
the main thread and from a Python thread, a frame sent, the run stopped and started again.

    python3 -I cmd/libblobly/smoke.py build/libblobly.so projects/sim-demo.blobnet

Exit 0 only when every step held."""
import ctypes
import sys
import threading


class Frame(ctypes.Structure):
    _fields_ = [("id", ctypes.c_uint32), ("len", ctypes.c_uint8), ("ext", ctypes.c_uint8),
                ("fd", ctypes.c_uint8), ("brs", ctypes.c_uint8), ("rtr", ctypes.c_uint8),
                ("esi", ctypes.c_uint8), ("data", ctypes.c_uint8 * 64)]


BB_ERR = -1
BB_ERR_HANDLE = -2
BB_ERR_STATE = -3
BB_HEALTH_UNKNOWN = 0
BB_KIND_CAN = 0
BB_KIND_DOIP = 1
BB_HEALTH_SOURCE_NONE = 0
BB_ERROR_MAX = 4095


def bind(lib):
    lib.bb_version.restype = ctypes.c_char_p
    lib.bb_last_error.restype = ctypes.c_char_p
    lib.bb_load.argtypes = [ctypes.c_char_p]
    lib.bb_channel_name.argtypes = [ctypes.c_int]
    lib.bb_channel_name.restype = ctypes.c_char_p
    lib.bb_channel_iface.argtypes = [ctypes.c_int]
    lib.bb_channel_iface.restype = ctypes.c_char_p
    lib.bb_bus_open.argtypes = [ctypes.c_char_p]
    lib.bb_bus_send.argtypes = [ctypes.c_int, ctypes.POINTER(Frame)]
    lib.bb_bus_recv.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.POINTER(Frame)]
    lib.bb_bus_health.argtypes = [ctypes.c_int]
    lib.bb_bus_close.argtypes = [ctypes.c_int]
    lib.bb_channel_kind.argtypes = [ctypes.c_int]
    lib.bb_channel_health_source.argtypes = [ctypes.c_int]
    lib.bb_wait_released.argtypes = [ctypes.c_int]


def err(lib):
    return lib.bb_last_error().decode()


def exchange(lib, who, n):
    h = lib.bb_bus_open(b"inproc:CAN1")
    assert h >= 0, f"{who} open: {err(lib)}"
    f = Frame()
    for i in range(n):
        rc = lib.bb_bus_recv(h, 1000, ctypes.byref(f))
        assert rc == 0, f"{who} recv {i}: rc={rc} {err(lib)}"
        assert 0 < f.len <= 8
    f = Frame(id=0x123, len=3)
    f.data[0], f.data[1], f.data[2] = 1, 2, 3
    assert lib.bb_bus_send(h, ctypes.byref(f)) == 0, f"{who} send: {err(lib)}"
    assert lib.bb_bus_health(h) == BB_HEALTH_UNKNOWN, f"{who}: a software bus has no ladder"
    assert lib.bb_bus_close(h) == 0, f"{who} close: {err(lib)}"
    assert lib.bb_bus_recv(h, 0, ctypes.byref(f)) == BB_ERR_HANDLE, f"{who}: a closed handle must refuse"
    print(f"ok   {who}: {n} frames heard, one sent")


def main(path, project):
    lib = ctypes.CDLL(path)
    bind(lib)
    assert lib.bb_init() == 0, err(lib)
    assert lib.bb_thread_attach() == 0, "attach on the loading thread must be harmless"
    print("libblobly", lib.bb_version().decode())
    assert lib.bb_start() == BB_ERR_STATE, "start before load must refuse"
    # an error past BB_ERROR_MAX is cut before a whole character: strict decoding must hold
    assert lib.bb_load(("\u00e9" * 3000).encode()) == BB_ERR
    raw = lib.bb_last_error()
    assert 0 < len(raw) <= BB_ERROR_MAX, len(raw)
    raw.decode("utf-8")  # strict: a cut inside a character raises here
    print(f"ok   a {len(raw)}-byte error, cut at a character boundary")
    assert lib.bb_load(project.encode()) == 0, f"load: {err(lib)}"
    n = lib.bb_channel_count()
    assert n >= 2, f"channels: {n}"
    doip = None
    for i in range(n):
        kind, src = lib.bb_channel_kind(i), lib.bb_channel_health_source(i)
        iface = lib.bb_channel_iface(i).decode()
        print(f"     channel {lib.bb_channel_name(i).decode()} ({iface}) kind {kind} health source {src}")
        assert kind >= 0 and src >= 0, err(lib)
        if kind == BB_KIND_DOIP:
            doip = (i, iface)
        if kind == BB_KIND_CAN and iface.startswith("inproc:"):
            assert src == BB_HEALTH_SOURCE_NONE, f"inproc health source {src}"
    assert doip, "sim-demo has a DoIP row"
    assert lib.bb_bus_open(doip[1].encode()) == BB_ERR and "DoIP or SOME/IP" in err(lib), err(lib)
    print("ok   kinds and health sources; a DoIP row refused by name")
    assert lib.bb_start() == 0, f"start: {err(lib)}"
    moved = lib.bb_channel_iface(doip[0]).decode()
    assert moved != doip[1], f"the run did not move {doip[1]}"
    assert lib.bb_start() == BB_ERR_STATE, "a second start must refuse"
    exchange(lib, "main thread", 20)
    failures = []

    def from_thread():
        # a Python thread: the collector did not see it born. Churn handles first so a
        # collection happens on it, then the exchange.
        try:
            assert lib.bb_thread_attach() == 0, f"attach: {err(lib)}"
            for i in range(200):  # an unattached thread aborts by 10 (measured); 20x that
                h = lib.bb_bus_open(b"inproc:CAN1")
                assert h >= 0 and lib.bb_bus_close(h) == 0, f"churn {i}: {err(lib)}"
            exchange(lib, "python thread", 20)
            assert lib.bb_thread_detach() == 0, f"detach: {err(lib)}"
        except Exception as e:  # any failure on the thread fails the smoke, not only an assert
            failures.append(repr(e))

    t = threading.Thread(target=from_thread)
    t.start()
    t.join()
    assert not failures, failures[0]
    assert lib.bb_stop() == 0, f"stop: {err(lib)}"
    assert lib.bb_channel_iface(doip[0]).decode() == doip[1], "stop restores the project's interfaces"
    assert lib.bb_wait_released(0) == 0, "a clean stop leaves the process released"
    assert lib.bb_stop() == BB_ERR_STATE, "a second stop must refuse"
    assert lib.bb_start() == 0, f"start again: {err(lib)}"
    exchange(lib, "second run", 5)
    assert lib.bb_stop() == 0, f"stop again: {err(lib)}"
    print("ok   libblobly smoke (python)")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("usage: smoke.py <libblobly.so|blobly.dll> <project.blobnet>", file=sys.stderr)
        sys.exit(2)
    main(sys.argv[1], sys.argv[2])
