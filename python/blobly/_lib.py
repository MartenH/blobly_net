"""_lib — libblobly loaded into this interpreter, every bb.h call declared once, and the two rules
bb.h states for a host: the library is loaded from the main thread, and a thread the host created
attaches before its first call and detaches before it ends. A thread that calls in is attached
on its first call and detached when it ends, so a user never has to."""
import collections
import ctypes
import os
import sys
import threading


class BloblyError(Exception):
    """A call into libblobly refused: the message is bb_last_error's, the code bb.h's."""

    def __init__(self, message, code=-1):
        super().__init__(message)
        self.code = code


BB_ERR = -1
BB_ERR_HANDLE = -2
BB_ERR_STATE = -3
# answers that are neither success nor an error (bb.h)
BB_NONE = 1        # bb_bus_recv: no frame in time; bb_decode: no message
BB_SPENT = 2       # bb_bus_recv(h, 0): no frame yet, records still queued behind the look's bound
BB_RELEASING = 3   # bb_stop / bb_wait_released: a loop is still letting go of its wires

# enum bb_kind and enum bb_health_source
KINDS = {0: "can", 1: "doip", 2: "someip"}
BB_HEALTH_SOURCE_NEEDS_READER = 2

# bb_health, as transport.health_name spells it (the Lua prelude's bus.health strings)
HEALTH_NAMES = {0: "", 1: "ok", 2: "error warning", 3: "ERROR-PASSIVE", 4: "BUS-OFF"}


class BbFrame(ctypes.Structure):
    """bb_frame, field for field."""
    _fields_ = [("id", ctypes.c_uint32), ("len", ctypes.c_uint8), ("ext", ctypes.c_uint8),
                ("fd", ctypes.c_uint8), ("brs", ctypes.c_uint8), ("rtr", ctypes.c_uint8),
                ("esi", ctypes.c_uint8), ("data", ctypes.c_uint8 * 64)]


class BbMessage(ctypes.Structure):
    """bb_message, field for field."""
    _fields_ = [("id", ctypes.c_uint32), ("ext", ctypes.c_uint8), ("j1939", ctypes.c_uint8),
                ("dlc", ctypes.c_int32), ("signals", ctypes.c_int32)]


class BbSignal(ctypes.Structure):
    """bb_signal, field for field."""
    _fields_ = [("start_bit", ctypes.c_int32), ("length", ctypes.c_int32),
                ("big_endian", ctypes.c_uint8), ("is_signed", ctypes.c_uint8),
                ("multiplexor", ctypes.c_uint8), ("multiplexed", ctypes.c_uint8),
                ("mux_value", ctypes.c_int32), ("labels", ctypes.c_int32),
                ("factor", ctypes.c_double), ("offset", ctypes.c_double),
                ("minimum", ctypes.c_double), ("maximum", ctypes.c_double)]


def _declare(lib):
    """Every bb.h prototype, argtypes and restype. An int-returning call keeps ctypes' default."""
    c_int, c_char_p, P = ctypes.c_int, ctypes.c_char_p, ctypes.POINTER
    sigs = {
        "bb_version": ([], c_char_p),
        "bb_init": ([], c_int),
        "bb_last_error": ([], c_char_p),
        "bb_thread_attach": ([], c_int),
        "bb_thread_detach": ([], c_int),
        "bb_load": ([c_char_p], c_int),
        "bb_start": ([], c_int),
        "bb_stop": ([], c_int),
        "bb_wait_released": ([c_int], c_int),
        "bb_channel_count": ([], c_int),
        "bb_channel_name": ([c_int], c_char_p),
        "bb_channel_iface": ([c_int], c_char_p),
        "bb_channel_kind": ([c_int], c_int),
        "bb_channel_health_source": ([c_int], c_int),
        "bb_bus_open": ([c_char_p], c_int),
        "bb_bus_send": ([c_int, ctypes.POINTER(BbFrame)], c_int),
        "bb_bus_recv": ([c_int, c_int, ctypes.POINTER(BbFrame)], c_int),
        "bb_bus_health": ([c_int], c_int),
        "bb_bus_close": ([c_int], c_int),
        "bb_message_count": ([c_int], c_int),
        "bb_message_info": ([c_int, c_int, P(BbMessage)], c_int),
        "bb_message_name": ([c_int, c_int, c_char_p, c_int], c_int),
        "bb_signal_info": ([c_int, c_int, c_int, P(BbSignal)], c_int),
        "bb_signal_name": ([c_int, c_int, c_int, c_char_p, c_int], c_int),
        "bb_signal_unit": ([c_int, c_int, c_int, c_char_p, c_int], c_int),
        "bb_signal_label": ([c_int, c_int, c_int, c_int, P(ctypes.c_uint64), P(ctypes.c_double), c_char_p,
                             c_int], c_int),
        "bb_encode": ([c_int, c_int, c_int, P(c_char_p), P(ctypes.c_double), P(BbFrame)], c_int),
        "bb_decode": ([c_int, P(BbFrame), P(c_int), P(ctypes.c_double), P(ctypes.c_uint8), c_int], c_int),
        # faults and E2E (faults.py, e2e.py); a uint8_t * is declared c_char_p, its length beside it
        "bb_sim_fault": ([c_int, c_char_p, c_char_p, c_char_p, c_int, c_char_p], c_int),
        "bb_sim_clear_faults": ([], c_int),
        "bb_e2e_p01_crc": ([c_char_p, c_int, c_int, c_int, c_int, c_char_p], c_int),
        "bb_e2e_p01_protect": ([c_char_p, c_int, c_int, c_int, c_int, c_int, c_char_p], c_int),
    }
    for name, (args, res) in sigs.items():
        fn = getattr(lib, name)
        fn.argtypes = args
        fn.restype = res


def _candidates():
    """Where the library may be: BLOBLY_LIB, else the copy an installed wheel carries (_native/),
    else beside this package, else the repository's build/ (a source checkout)."""
    names = ["blobly.dll"] if sys.platform == "win32" else ["libblobly.so"]
    env = os.environ.get("BLOBLY_LIB")
    if env:
        return [os.path.abspath(env)]
    here = os.path.dirname(os.path.abspath(__file__))
    repo_build = os.path.join(os.path.dirname(os.path.dirname(here)), "build")
    return [os.path.join(d, n) for d in (os.path.join(here, "_native"), here, repo_build) for n in names]


_lock = threading.Lock()
_lib = None
loaded_path = None  # which file lib() loaded
_tls = threading.local()
# the last detaches the finalizer did, as (thread ident, bb_thread_detach's answer): what a test
# reads to see that a thread was let go on itself; bounded, so a thread-per-job host keeps nothing
detached = collections.deque(maxlen=64)
# which Project's load the library holds now, and which load that was: a channel of another
# project, or of an earlier load of its own, would reach another row by its index; and which
# run, moved by each start and stop: a row's databases are the run's, so a message of an
# earlier run would reach another message by its index
state = {"owner": None, "gen": 0, "run": 0}
# bb.h: open, close, load, start and stop are not synchronised against each other, and ctypes
# releases the GIL inside a call, so every one of them (and the row-name reads a load replaces)
# runs under this lock, from whichever thread makes it
state_lock = threading.RLock()


class _Attachment:
    """Held in the thread's local storage: CPython clears that storage on the ending thread itself,
    so this finalizer runs there and detaches the thread it attached."""

    def __init__(self, lib):
        self.lib = lib

    def __del__(self):
        try:
            detached.append((threading.get_ident(), self.lib.bb_thread_detach()))
        except Exception:  # the interpreter may be shutting down; nothing to report to
            pass


def lib():
    """The loaded library, bb_init done; refused from any thread but the main one the first time."""
    global _lib, loaded_path
    with _lock:
        if _lib is None:
            # the thread rule below rests on CPython clearing a thread's local storage ON that
            # thread as it ends; a tracing collector (PyPy) may finalize later, or elsewhere
            if sys.implementation.name != "cpython":
                raise BloblyError("blobly needs CPython: it detaches a thread from the library "
                                  "as CPython ends it, which " + sys.implementation.name +
                                  " does not promise")
            if threading.current_thread() is not threading.main_thread():
                raise BloblyError("load blobly from the main thread first: bb.h requires the "
                                  "library be loaded there (its collector takes the loading thread "
                                  "for the main one)")
            tried = []
            for path in _candidates():
                if os.path.exists(path):
                    loaded = ctypes.CDLL(path)
                    _declare(loaded)
                    if loaded.bb_init() != 0:
                        raise BloblyError(text(loaded.bb_last_error()))
                    _lib = loaded
                    loaded_path = path
                    break
                tried.append(path)
            if _lib is None:
                raise BloblyError("libblobly not found (set BLOBLY_LIB, or build it with "
                                  "scripts/build_libblobly.sh); looked at: " + ", ".join(tried))
    attach()
    return _lib


def attach():
    """Attaches the calling thread on its first call in, unless it is the main thread."""
    if threading.current_thread() is threading.main_thread() or getattr(_tls, "held", None):
        return
    if _lib.bb_thread_attach() != 0:
        raise BloblyError(text(_lib.bb_last_error()))
    _tls.held = _Attachment(_lib)


def text(b):
    """A string from the library. Its messages are cut before a whole character past
    BB_ERROR_MAX bytes, but a project's own names need not be UTF-8: an undecodable byte must not
    hide an error behind a UnicodeDecodeError."""
    return b.decode("utf-8", errors="replace") if b is not None else ""


def string(get, *at):
    """A string a bb_* call copies into the caller's buffer (bb.h), read whole: the call answers
    the string's length, so one that did not fit is asked for again with room for it."""
    cap = 256
    while True:
        buf = ctypes.create_string_buffer(cap)
        n = check(get(*at, buf, cap))
        if n < cap:
            return text(buf.raw[:n])
        cap = n + 1


def check(rc):
    """A bb_* return value: itself when >= 0, a BloblyError with bb_last_error's message otherwise."""
    if rc < 0:
        raise BloblyError(text(_lib.bb_last_error()), rc)
    return rc
