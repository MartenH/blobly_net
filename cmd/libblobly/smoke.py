"""smoke.py — a ctypes host of libblobly, the shape the Python package will take: the library
loaded into THIS interpreter, sim-demo brought up, its simulated ECUs heard on inproc:CAN1 from
the main thread and from a Python thread, a frame sent, CAN1's database (dbc/blobly_net.dbc)
encoded and decoded, the DoIP entity asked who it is, the run stopped and started again.

    python3 -I cmd/libblobly/smoke.py build/libblobly.so projects/sim-demo.blobnet

Exit 0 only when every step held."""
import ctypes
import sys
import threading


class Frame(ctypes.Structure):
    _fields_ = [("id", ctypes.c_uint32), ("len", ctypes.c_uint8), ("ext", ctypes.c_uint8),
                ("fd", ctypes.c_uint8), ("brs", ctypes.c_uint8), ("rtr", ctypes.c_uint8),
                ("esi", ctypes.c_uint8), ("data", ctypes.c_uint8 * 64)]


class Message(ctypes.Structure):
    _fields_ = [("id", ctypes.c_uint32), ("ext", ctypes.c_uint8), ("j1939", ctypes.c_uint8),
                ("dlc", ctypes.c_int32), ("signals", ctypes.c_int32)]


class Signal(ctypes.Structure):
    _fields_ = [("start_bit", ctypes.c_int32), ("length", ctypes.c_int32),
                ("big_endian", ctypes.c_uint8), ("is_signed", ctypes.c_uint8),
                ("multiplexor", ctypes.c_uint8), ("multiplexed", ctypes.c_uint8),
                ("mux_value", ctypes.c_int32), ("labels", ctypes.c_int32),
                ("factor", ctypes.c_double), ("offset", ctypes.c_double),
                ("minimum", ctypes.c_double), ("maximum", ctypes.c_double)]


class DoipAnnouncement(ctypes.Structure):
    _fields_ = [("vin", ctypes.c_char * 18), ("logical_address", ctypes.c_uint16),
                ("eid", ctypes.c_uint8 * 6), ("gid", ctypes.c_uint8 * 6), ("source", ctypes.c_char * 96)]


BB_ERR = -1
BB_ERR_HANDLE = -2
BB_ERR_STATE = -3
BB_HEALTH_UNKNOWN = 0
BB_KIND_CAN = 0
BB_KIND_DOIP = 1
BB_HEALTH_SOURCE_NONE = 0
BB_ERROR_MAX = 4095
BB_NONE = 1


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
    i, buf = ctypes.c_int, ctypes.c_char_p
    lib.bb_message_count.argtypes = [i]
    lib.bb_message_info.argtypes = [i, i, ctypes.POINTER(Message)]
    lib.bb_message_name.argtypes = [i, i, buf, i]
    lib.bb_signal_info.argtypes = [i, i, i, ctypes.POINTER(Signal)]
    lib.bb_signal_name.argtypes = [i, i, i, buf, i]
    lib.bb_signal_unit.argtypes = [i, i, i, buf, i]
    lib.bb_signal_label.argtypes = [i, i, i, i, ctypes.POINTER(ctypes.c_uint64),
                                    ctypes.POINTER(ctypes.c_double), buf, i]
    lib.bb_encode.argtypes = [i, i, i, ctypes.POINTER(ctypes.c_char_p), ctypes.POINTER(ctypes.c_double),
                              ctypes.POINTER(Frame)]
    lib.bb_doip_endpoint.argtypes = [i, buf, i, ctypes.POINTER(ctypes.c_int)]
    lib.bb_doip_discover.argtypes = [buf, i, i, ctypes.POINTER(DoipAnnouncement)]
    lib.bb_decode.argtypes = [i, ctypes.POINTER(Frame), ctypes.POINTER(ctypes.c_int),
                              ctypes.POINTER(ctypes.c_double), ctypes.POINTER(ctypes.c_uint8), i]


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


def name_of(get, *at):
    """A string through a caller's buffer: asked for its length, then read whole."""
    n = get(*at, None, 0)
    assert n >= 0
    b = ctypes.create_string_buffer(n + 1)
    assert get(*at, b, n + 1) == n
    return b.value.decode()


def dbc_steps(lib, row):
    """CAN1's Powertrain (0x100): listed with its signals, encoded as bus.send_message does,
    decoded back, and a frame the simulation sent decoded."""
    names = [name_of(lib.bb_message_name, row, m) for m in range(lib.bb_message_count(row))]
    pt = names.index("Powertrain")
    mi = Message()
    assert lib.bb_message_info(row, pt, ctypes.byref(mi)) == 0, err(lib)
    assert (mi.id, mi.ext, mi.dlc, mi.signals) == (0x100, 0, 8, 6), (mi.id, mi.dlc, mi.signals)
    sigs = {}
    for s in range(mi.signals):
        si = Signal()
        assert lib.bb_signal_info(row, pt, s, ctypes.byref(si)) == 0, err(lib)
        sigs[name_of(lib.bb_signal_name, row, pt, s)] = (s, si)
    s, es = sigs["EngineSpeed"]
    assert (es.start_bit, es.length, es.factor, es.maximum) == (0, 16, 0.25, 16383.75)
    assert name_of(lib.bb_signal_unit, row, pt, s) == "rpm"
    g, gear = sigs["Gear"]
    raw, value = ctypes.c_uint64(), ctypes.c_double()
    labels = {}
    for k in range(gear.labels):
        n = lib.bb_signal_label(row, pt, g, k, None, None, None, 0)
        b = ctypes.create_string_buffer(n + 1)
        assert lib.bb_signal_label(row, pt, g, k, ctypes.byref(raw), ctypes.byref(value), b, n + 1) == n
        labels[raw.value] = (value.value, b.value.decode())
    assert labels[3] == (3.0, "Third"), labels
    f = Frame()
    keys = (ctypes.c_char_p * 2)(b"EngineSpeed", b"Gear")
    vals = (ctypes.c_double * 2)(1500, 3)
    assert lib.bb_encode(row, pt, 2, keys, vals, ctypes.byref(f)) == 0, err(lib)
    assert (f.id, f.len) == (0x100, 8) and bytes(f.data[:8]) == bytes([0x70, 0x17, 0, 0, 0, 0x18, 0, 0])
    m = ctypes.c_int(-1)
    got = (ctypes.c_double * 16)()
    on = (ctypes.c_uint8 * 16)()
    assert lib.bb_decode(row, ctypes.byref(f), ctypes.byref(m), got, on, 16) == 0, err(lib)
    assert m.value == pt and got[s] == 1500 and got[g] == 3 and on[s] and on[g]
    assert lib.bb_decode(row, ctypes.byref(Frame(id=0x7FF, len=1)), ctypes.byref(m), got, on, 16) == BB_NONE
    h = lib.bb_bus_open(b"inproc:CAN1")
    decoded = False
    for _ in range(20):
        assert lib.bb_bus_recv(h, 1000, ctypes.byref(f)) == 0, err(lib)
        if lib.bb_decode(row, ctypes.byref(f), ctypes.byref(m), got, on, 16) == 0:
            decoded = True
            break
    lib.bb_bus_close(h)
    assert decoded, "nothing the simulation sent decoded"
    print(f"ok   CAN1's database: {len(names)} messages; Powertrain encoded and decoded; "
          f"{names[m.value]} heard and decoded")


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
    can1 = next(i for i in range(n) if lib.bb_channel_name(i) == b"CAN1")
    assert lib.bb_message_count(can1) == BB_ERR_STATE, "a row's databases are the run's: none before start"
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
    dbc_steps(lib, can1)
    a, host, port = DoipAnnouncement(), ctypes.create_string_buffer(64), ctypes.c_int()
    assert lib.bb_doip_endpoint(doip[0], host, 64, ctypes.byref(port)) > 0, f"endpoint: {err(lib)}"
    assert lib.bb_doip_discover(host.value, port.value, 1200, ctypes.byref(a)) == 0, f"discover: {err(lib)}"
    assert (a.vin, a.logical_address) == (b"BLOBLYNETV0SUT001", 0x1000), (a.vin, a.logical_address)
    assert moved.endswith(a.source.decode()), f"discovered at {a.source} while the row is {moved}"
    print(f"ok   DoIP1 discovered: {a.vin.decode()} at 0x{a.logical_address:04X} from {a.source.decode()}")
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
    assert lib.bb_message_count(can1) == BB_ERR_STATE, "the databases outlived the run"
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
