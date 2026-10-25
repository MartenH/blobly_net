"""_lib — libblobly loaded into this interpreter, every bb.h call declared once, and the two rules
bb.h states for a host: the library is loaded from the main thread, and a thread the host created
attaches before its first call and detaches before it ends. A thread that calls in is attached
on its first call and detached when it ends, so a user never has to."""
import collections
import ctypes
import numbers
import os
import sys
import threading
from collections.abc import Iterable
from typing import TYPE_CHECKING, TypeAlias

if TYPE_CHECKING:
    from .uds import Exchange

# what a parameter that takes bytes accepts, as bytes() reads it: bytes, bytearray, memoryview, or
# a sequence of byte values
ByteData: TypeAlias = bytes | Iterable[int]


class BloblyError(Exception):
    """A call into libblobly failed: the message is bb_last_error's, the code bb.h's. The kinds a
    caller acts on differently are subclasses: Refused, and the ways a UDS call fails."""
    code: int

    def __init__(self, message: str, code: int = -1) -> None:
        super().__init__(message)
        self.code = code


class Refused(BloblyError):
    """The library refused the call (BB_ERR): an argument out of range, a request it cannot carry,
    or another reason the message gives. A UDS request refused did not go out whole: the ECU was
    not asked."""


class NegativeResponse(BloblyError):
    """The ECU answered a UDS request with a negative response: `nrc` is its code, `nrc_name`
    ISO 14229-1's name for it, `exchange` the exchange it ended (UdsClient.last)."""
    nrc: int
    nrc_name: str
    exchange: "Exchange | None"

    def __init__(self, message: str, code: int = -4, nrc: int = 0, nrc_name: str = "",
                 exchange: "Exchange | None" = None) -> None:
        super().__init__(message, code)
        self.nrc, self.nrc_name, self.exchange = nrc, nrc_name, exchange


class Timeout(BloblyError):
    """Nothing came within the wait: no answer to a UDS request, or not the frame or signal value
    an expect waited for."""

    def __init__(self, message: str, code: int = -5) -> None:  # BB_ERR_TIMEOUT
        super().__init__(message, code)


class PendingExpired(BloblyError):
    """The ECU said responsePending (0x78), then nothing more within its P2*."""


class UndecodableAnswer(BloblyError):
    """An answer arrived that cannot be read as the answer to the request: the ECU answered, and
    the connection is not at fault."""


class CarrierFailed(BloblyError):
    """The carrier failed under the UDS request: the bus, or the ISO-TP channel (a frame lost
    mid-transfer); on DoIP a negative acknowledgement, or a connection that could not be opened
    (refused, or no routing activation answer)."""


class ConnectionLost(CarrierFailed):
    """The DoIP connection is gone (closed by the entity, reset, stalled inside a message, or
    taking nothing written for 2 s): the client's next call opens a new one — routing activation
    again, the session and security state the ECU had for the old one gone with it. `exchange` is
    the exchange it ended (UdsClient.last), whose `sent` says whether the request went out whole."""
    exchange: "Exchange | None"

    def __init__(self, message: str, code: int = -10, exchange: "Exchange | None" = None) -> None:
        super().__init__(message, code)
        self.exchange = exchange


class RoutingDenied(BloblyError):
    """A DoIP entity denied the routing activation of a UdsClient's connection: `routing_code` is
    the response code, `routing_name` ISO 13400-2's meaning of it, `hint` what to do about it (""
    where there is nothing to add), `tester` the tester address it was asked for."""
    routing_code: int
    routing_name: str
    hint: str
    tester: int

    def __init__(self, message: str, code: int = -9, routing_code: int = 0, routing_name: str = "",
                 hint: str = "", tester: int = 0) -> None:
        super().__init__(message, code)
        self.routing_code, self.routing_name, self.hint, self.tester = routing_code, routing_name, hint, tester


class FlashFailed(BloblyError):
    """A flash ran and the bootloader's own answers say it did not happen: an erase or check
    routine's result (the image is not marked valid), a malformed download answer, or a transfer
    stopped (a progress callback that raised, Ctrl-C). A step the bootloader refused raises
    NegativeResponse instead, and one it did not answer Timeout."""


class WriteGated(Refused):
    """A described write (NodeClient.write) not sent, since the client's connection has not
    established what the DID's write gate needs: `session` the session to switch to first (0: the
    one it is in will do), `level` the security level to unlock (0: none), whose seed request is
    security_access(2 * level - 1). The message says what the connection has and what it needs;
    session() and security_access() establish it, and this client's own exchanges are what tell."""
    session: int
    level: int

    def __init__(self, message: str, code: int = -13, session: int = 0, level: int = 0) -> None:
        super().__init__(message, code)
        self.session, self.level = session, level


BB_ERR = -1
BB_ERR_HANDLE = -2
BB_ERR_STATE = -3
BB_ERR_NEGATIVE = -4
BB_ERR_TIMEOUT = -5
BB_ERR_PENDING = -6
BB_ERR_UNDECODABLE = -7
BB_ERR_CARRIER = -8
BB_ERR_ROUTING = -9
BB_ERR_LOST = -10
BB_ERR_FLASH = -11
BB_ERR_E2E = -12  # returned by no call: E2eError's code
BB_ERR_GATED = -13
BB_ERR_CANCELLED = -14  # a UDS call bb_uds_cancel ended: what Ctrl-C asks, then raising KeyboardInterrupt
# the exception each code raises; a code not here (BB_ERR_HANDLE, BB_ERR_STATE, a newer library's)
# raises BloblyError itself
ERRORS = {BB_ERR: Refused, BB_ERR_NEGATIVE: NegativeResponse, BB_ERR_TIMEOUT: Timeout,
          BB_ERR_PENDING: PendingExpired, BB_ERR_UNDECODABLE: UndecodableAnswer,
          BB_ERR_CARRIER: CarrierFailed, BB_ERR_ROUTING: RoutingDenied, BB_ERR_LOST: ConnectionLost,
          BB_ERR_FLASH: FlashFailed, BB_ERR_GATED: WriteGated}
# answers that are neither success nor an error (bb.h)
BB_NONE = 1        # bb_bus_recv: no frame in time; bb_decode: no message
BB_SPENT = 2       # bb_bus_recv(h, 0): no frame yet, records still queued behind the look's bound
BB_RELEASING = 3   # bb_stop / bb_wait_released: a loop is still letting go of its wires
BB_ANSWERED = 4    # bb_uds_raw_suppressed: a positive answer came although none was asked for

# enum bb_kind and enum bb_health_source
KINDS = {0: "can", 1: "doip", 2: "someip"}
BB_HEALTH_SOURCE_NEEDS_READER = 2

# bb_health, as transport.health_name spells it (the Lua prelude's bus.health strings)
HEALTH_NAMES = {0: "", 1: "ok", 2: "error warning", 3: "ERROR-PASSIVE", 4: "BUS-OFF"}


class BbFrame(ctypes.Structure):
    """bb_frame, field for field."""
    _fields_ = [("id", ctypes.c_uint32), ("len", ctypes.c_uint8), ("ext", ctypes.c_uint8),
                ("fd", ctypes.c_uint8), ("brs", ctypes.c_uint8), ("rtr", ctypes.c_uint8),
                ("esi", ctypes.c_uint8), ("data", ctypes.c_uint8 * 64), ("e2e", ctypes.c_uint8),
                ("t_ns", ctypes.c_int64)]


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


class BbUdsTarget(ctypes.Structure):
    """bb_uds_target, field for field."""
    _fields_ = [("tx", ctypes.c_uint32), ("rx", ctypes.c_uint32), ("ext", ctypes.c_uint8)]


class BbUdsExchange(ctypes.Structure):
    """bb_uds_exchange, field for field."""
    _fields_ = [("sent", ctypes.c_uint8), ("negative", ctypes.c_uint8), ("nrc", ctypes.c_uint8),
                ("pending", ctypes.c_int32), ("rtt_us", ctypes.c_int64), ("pending_us", ctypes.c_int64),
                ("request_len", ctypes.c_int32), ("answer_len", ctypes.c_int32)]


class BbDtc(ctypes.Structure):
    """bb_dtc, field for field."""
    _fields_ = [("code", ctypes.c_uint32), ("status", ctypes.c_uint8), ("availability", ctypes.c_uint8)]


class BbCounters(ctypes.Structure):
    """bb_counters, field for field."""
    _fields_ = [("occurrences", ctypes.c_uint64), ("aging", ctypes.c_uint64),
                ("failed_cycles", ctypes.c_uint64), ("has", ctypes.c_uint8)]


class BbFunctionalReply(ctypes.Structure):
    """bb_functional_reply, field for field."""
    _fields_ = [("outcome", ctypes.c_int32), ("nrc", ctypes.c_uint8), ("pended", ctypes.c_uint8),
                ("answer_len", ctypes.c_int32)]


BB_DOIP_SOURCE_MAX = 96


class BbDoipAnnouncement(ctypes.Structure):
    """bb_doip_announcement, field for field."""
    _fields_ = [("vin", ctypes.c_char * 18), ("logical_address", ctypes.c_uint16),
                ("eid", ctypes.c_uint8 * 6), ("gid", ctypes.c_uint8 * 6),
                ("source", ctypes.c_char * BB_DOIP_SOURCE_MAX)]


class BbSomeipOut(ctypes.Structure):
    """bb_someip_out, field for field."""
    _fields_ = [("service", ctypes.c_uint16), ("method", ctypes.c_uint16), ("msg_type", ctypes.c_int32),
                ("iface", ctypes.c_int32), ("client", ctypes.c_int32), ("session", ctypes.c_int32),
                ("payload", ctypes.c_char_p), ("payload_len", ctypes.c_int32)]


BB_SOMEIP_FROM_MAX = 64


class BbSomeipMsg(ctypes.Structure):
    """bb_someip_msg, field for field."""
    _fields_ = [("service", ctypes.c_uint16), ("method", ctypes.c_uint16), ("client", ctypes.c_uint16),
                ("session", ctypes.c_uint16), ("iface", ctypes.c_uint8), ("msg_type", ctypes.c_uint8),
                ("return_code", ctypes.c_uint8), ("protocol", ctypes.c_uint8), ("payload_len", ctypes.c_int32),
                ("at_ms", ctypes.c_int64),
                ("source", ctypes.c_char * BB_SOMEIP_FROM_MAX)]


class BbIface(ctypes.Structure):
    """bb_iface, field for field."""
    _fields_ = [("fd", ctypes.c_int32), ("bitrate", ctypes.c_int32), ("is_virtual", ctypes.c_uint8)]


class BbVectorHw(ctypes.Structure):
    """bb_vector_hw, field for field."""
    _fields_ = [("hw_type", ctypes.c_int32), ("hw_index", ctypes.c_int32), ("hw_channel", ctypes.c_int32),
                ("serial", ctypes.c_uint32), ("bitrate", ctypes.c_uint32), ("app", ctypes.c_int32),
                ("owner_known", ctypes.c_uint8), ("can", ctypes.c_uint8), ("fd_iso", ctypes.c_uint8),
                ("fd_bosch", ctypes.c_uint8), ("on_bus", ctypes.c_uint8)]


FLASH_NOTE = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_char_p)
FLASH_PROGRESS = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_int32, ctypes.c_int32)


class BbFlashOpts(ctypes.Structure):
    """bb_flash_opts, field for field."""
    _fields_ = [("base", ctypes.c_uint32), ("sw_version", ctypes.c_uint32), ("auth", ctypes.c_int32),
                ("seed", ctypes.c_char_p), ("seed_file", ctypes.c_char_p), ("quiet", ctypes.c_int32),
                ("note", FLASH_NOTE), ("progress", FLASH_PROGRESS), ("ctx", ctypes.c_void_p)]


class BbFlashReport(ctypes.Structure):
    """bb_flash_report, field for field."""
    _fields_ = [("bytes", ctypes.c_int32), ("blocks", ctypes.c_int32), ("wrapped", ctypes.c_uint8),
                ("reset_acknowledged", ctypes.c_uint8), ("auth", ctypes.c_int32)]


class BbBootReport(ctypes.Structure):
    """bb_boot_report, field for field."""
    _fields_ = [("authenticated", ctypes.c_uint8), ("verified", ctypes.c_uint8), ("erases", ctypes.c_int32),
                ("blocks", ctypes.c_int32), ("bytes", ctypes.c_int32), ("checks", ctypes.c_int32),
                ("resets", ctypes.c_int32)]


# bus metrics (project.py's Channel.load / Channel.diagnostics)
class BbBusload(ctypes.Structure):
    """bb_busload, field for field."""
    _fields_ = [("percent", ctypes.c_double), ("average", ctypes.c_double), ("bits", ctypes.c_double),
                ("frames", ctypes.c_uint64), ("nominal", ctypes.c_int32)]


class BbDiagnostics(ctypes.Structure):
    """bb_diagnostics, field for field."""
    _fields_ = [("dropped", ctypes.c_uint64), ("bus_errors", ctypes.c_uint64), ("decode_errors", ctypes.c_uint64)]


class BbReplayOpts(ctypes.Structure):
    """bb_replay_opts, field for field."""
    _fields_ = [("source", ctypes.c_char_p), ("speed", ctypes.c_double), ("loop", ctypes.c_int32),
                ("paused", ctypes.c_int32), ("exclude", ctypes.c_char_p), ("bus", ctypes.c_char_p)]


class BbReplayInfo(ctypes.Structure):
    """bb_replay_info, field for field."""
    _fields_ = [("state", ctypes.c_int32), ("loop", ctypes.c_uint8), ("ended", ctypes.c_uint8),
                ("passes", ctypes.c_int32), ("position_s", ctypes.c_double), ("duration_s", ctypes.c_double),
                ("speed", ctypes.c_double), ("sent", ctypes.c_int64), ("failed", ctypes.c_int64)]


class BbRecordReport(ctypes.Structure):
    """bb_record_report, field for field."""
    _fields_ = [("frames", ctypes.c_int64), ("ours", ctypes.c_int64), ("theirs", ctypes.c_int64),
                ("missed", ctypes.c_int64), ("dropped", ctypes.c_int64)]


# enum bb_replay_state, as the Lua replay status names it
REPLAY_STATES = {0: "stopped", 1: "playing", 2: "paused", 3: "finished"}


# enum bb_flash_auth, as the Lua flash.program's report names it
FLASH_AUTH = {0: "skipped", 1: "authenticated", 2: "not required"}

class BbGenerator(ctypes.Structure):
    """bb_generator, field for field."""
    _fields_ = [("id", ctypes.c_uint32), ("ext", ctypes.c_uint8), ("running", ctypes.c_uint8),
                ("sendable", ctypes.c_uint8), ("cycle_ms", ctypes.c_int32), ("sent", ctypes.c_int64)]


# bb_wave's parameters after its kind, in its order
WAVE_PARAMS = ("value", "offset", "amplitude", "freq", "phase", "min", "max", "period", "start", "step",
               "modulo", "count", "base")


class BbWave(ctypes.Structure):
    """bb_wave, field for field."""
    _fields_ = [("kind", ctypes.c_char_p)] + [(p, ctypes.c_double) for p in WAVE_PARAMS]


# enum bb_gen_text
GEN_NAME, GEN_CHANNEL, GEN_MESSAGE, GEN_TRIGGER, GEN_TARGET, GEN_NOTE = range(6)


# the system model (nodes.py)
class BbNode(ctypes.Structure):
    """bb_node, field for field."""
    _fields_ = [("dids", ctypes.c_int32), ("faults", ctypes.c_int32), ("targets", ctypes.c_int32),
                ("described", ctypes.c_uint8), ("server", ctypes.c_uint8), ("reference_key", ctypes.c_uint8)]


class BbReach(ctypes.Structure):
    """bb_reach, field for field."""
    _fields_ = [("row", ctypes.c_int32), ("doip", ctypes.c_uint8), ("ext", ctypes.c_uint8),
                ("tx", ctypes.c_uint32), ("rx", ctypes.c_uint32)]


class BbDid(ctypes.Structure):
    """bb_did, field for field."""
    _fields_ = [("id", ctypes.c_uint16), ("kind", ctypes.c_int32), ("size", ctypes.c_int32),
                ("parts", ctypes.c_int32), ("by_label", ctypes.c_uint8), ("read_gated", ctypes.c_uint8), ("read_sessions", ctypes.c_int32),
                ("read_level", ctypes.c_int32), ("writable", ctypes.c_uint8), ("write_sessions", ctypes.c_int32),
                ("write_level", ctypes.c_int32)]


class BbWriteNeeds(ctypes.Structure):
    """bb_write_needs, field for field."""
    _fields_ = [("session", ctypes.c_uint8), ("level", ctypes.c_uint8)]


# enum bb_functional_outcome, as the Lua uds.functional names the outcomes
OUTCOMES = {0: "positive", 1: "negative", 2: "silent", 3: "pending", 4: "failed"}


# a UDS client's timing (uds.py)
class BbUdsTiming(ctypes.Structure):
    """bb_uds_timing, field for field."""
    _fields_ = [("timeout_ms", ctypes.c_int32), ("p2_star_ms", ctypes.c_int32), ("margin_ms", ctypes.c_int32),
                ("pending_budget_ms", ctypes.c_int32)]


# enum bb_uds_wait, by bb_uds_timing's field names
WAITS = {"timeout_ms": 0, "p2_star_ms": 1, "margin_ms": 2, "pending_budget_ms": 3}


# background senders and the keep-alive (cyclic.py, uds.py)
class BbCyclicInfo(ctypes.Structure):
    """bb_cyclic_info, field for field."""
    _fields_ = [("sent", ctypes.c_uint64), ("failed", ctypes.c_uint64), ("period_ms", ctypes.c_int32),
                ("running", ctypes.c_uint8)]


class BbKeepAlive(ctypes.Structure):
    """bb_keep_alive, field for field."""
    _fields_ = [("period_ms", ctypes.c_int32), ("sent", ctypes.c_uint64), ("failures", ctypes.c_uint64),
                ("running", ctypes.c_uint8)]
# J1939 on a row's frames (j1939.py)
BB_J1939_MAX = 1785
BB_J1939_TEXT = 256


class BbJ1939Message(ctypes.Structure):
    """bb_j1939_message, field for field."""
    _fields_ = [("pgn", ctypes.c_uint32), ("sa", ctypes.c_uint8), ("da", ctypes.c_uint8),
                ("priority", ctypes.c_uint8), ("bam", ctypes.c_uint8), ("len", ctypes.c_int32),
                ("message", ctypes.c_int32), ("t_start_ns", ctypes.c_int64), ("t_end_ns", ctypes.c_int64),
                ("data", ctypes.c_uint8 * BB_J1939_MAX), ("note", ctypes.c_char * BB_J1939_TEXT)]


class BbJ1939Fault(ctypes.Structure):
    """bb_j1939_fault, field for field."""
    _fields_ = [("kind", ctypes.c_int32), ("sa", ctypes.c_uint8), ("da", ctypes.c_uint8),
                ("announced", ctypes.c_uint8), ("pgn", ctypes.c_uint32),
                ("detail", ctypes.c_char * BB_J1939_TEXT), ("text", ctypes.c_char * BB_J1939_TEXT)]


class BbJ1939Address(ctypes.Structure):
    """bb_j1939_address, field for field."""
    _fields_ = [("sa", ctypes.c_uint8), ("name", ctypes.c_uint64), ("identity", ctypes.c_uint32),
                ("manufacturer", ctypes.c_uint16), ("ecu_instance", ctypes.c_uint8),
                ("function_instance", ctypes.c_uint8), ("function", ctypes.c_uint8),
                ("vehicle_system", ctypes.c_uint8), ("vehicle_system_instance", ctypes.c_uint8),
                ("industry_group", ctypes.c_uint8), ("arbitrary_address_capable", ctypes.c_uint8),
                ("t_ns", ctypes.c_int64)]


# enum bb_j1939_fault_kind, as j1939.FaultKind names the kinds
J1939_FAULTS = {0: "orphan", 1: "sequence", 2: "restarted", 3: "aborted", 4: "timeout", 5: "malformed",
                6: "overflow", 7: "padding", 8: "off_spec", 9: "truncated"}


# Network management on a row's frames (nm.py)
BB_NM_TEXT = 256


class BbNmView(ctypes.Structure):
    """bb_nm_view, field for field."""
    _fields_ = [("state", ctypes.c_int32), ("nodes", ctypes.c_int32), ("keepers", ctypes.c_int32),
                ("woke", ctypes.c_int32), ("woke_active", ctypes.c_uint8), ("heard", ctypes.c_uint8),
                ("timeout_default", ctypes.c_uint8), ("timeout_ms", ctypes.c_int32), ("source", ctypes.c_int32),
                ("t_ns", ctypes.c_int64), ("woke_ns", ctypes.c_int64), ("last_ns", ctypes.c_int64),
                ("frames", ctypes.c_uint64), ("malformed", ctypes.c_uint64), ("dropped", ctypes.c_uint64),
                ("origin", ctypes.c_char * BB_NM_TEXT), ("frames_text", ctypes.c_char * BB_NM_TEXT),
                ("last_error", ctypes.c_char * BB_NM_TEXT)]


class BbNmNode(ctypes.Structure):
    """bb_nm_node, field for field."""
    _fields_ = [("name", ctypes.c_char * BB_NM_TEXT), ("id", ctypes.c_uint32), ("ext", ctypes.c_uint8),
                ("has_id", ctypes.c_uint8), ("nid", ctypes.c_int32), ("missing", ctypes.c_uint8),
                ("unknown", ctypes.c_uint8), ("live", ctypes.c_uint8), ("keeper", ctypes.c_int32),
                ("repeater", ctypes.c_uint8), ("cbv", ctypes.c_uint8), ("has_pn", ctypes.c_uint8), ("pn", ctypes.c_uint64),
                ("count", ctypes.c_uint64), ("last_ns", ctypes.c_int64), ("cadence_ms", ctypes.c_double),
                ("last_interval_ms", ctypes.c_double)]


# enum bb_nm_state and enum bb_nm_source, as blobly/nm names them
NM_STATES = {0: "asleep", 1: "awake", 2: "releasing"}
NM_SOURCES = {0: "system.toml", 1: "ARXML", 2: "project", 3: "script"}


def _declare(lib):
    """Every bb.h prototype, argtypes and restype. An int-returning call keeps ctypes' default."""
    c_int, c_char_p, P = ctypes.c_int, ctypes.c_char_p, ctypes.POINTER
    sigs = {
        "bb_version": ([], c_char_p),
        "bb_init": ([], c_int),
        "bb_last_error": ([], c_char_p),
        "bb_thread_attach": ([], c_int),
        "bb_thread_detach": ([], c_int),
        "bb_now_ns": ([], ctypes.c_int64),
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
        # a const uint8_t * is declared c_char_p: bytes pass as they are, their length beside them
        "bb_uds_open": ([c_int, P(ctypes.c_int64), P(ctypes.c_int64), P(BbUdsTarget)], c_int),
        "bb_uds_close": ([c_int], c_int),
        "bb_uds_cancel": ([c_int], c_int),
        "bb_uds_replaces": ([c_int], c_int),
        "bb_uds_last": ([c_int, P(BbUdsExchange), c_char_p, c_int, c_char_p, c_int], c_int),
        "bb_uds_data": ([c_int, c_char_p, c_int], c_int),
        "bb_uds_raw": ([c_int, c_char_p, c_int, c_char_p, c_int], c_int),
        "bb_uds_raw_suppressed": ([c_int, c_char_p, c_int], c_int),
        "bb_uds_session": ([c_int, c_int, c_char_p, c_int], c_int),
        "bb_uds_tester_present": ([c_int], c_int),
        "bb_uds_read_did": ([c_int, c_int, c_char_p, c_int], c_int),
        "bb_uds_write_did": ([c_int, c_int, c_char_p, c_int], c_int),
        "bb_uds_reset": ([c_int, c_int, c_char_p, c_int], c_int),
        "bb_uds_comm_control": ([c_int, c_int, c_int], c_int),
        "bb_uds_dtc_setting": ([c_int, c_int], c_int),
        "bb_uds_clear_dtcs": ([c_int, c_int], c_int),
        "bb_uds_security_seed": ([c_int, c_int, P(ctypes.c_uint8), c_char_p, c_int], c_int),
        "bb_uds_security_key": ([c_int, c_int, c_char_p, c_int], c_int),
        "bb_reference_key": ([c_char_p, c_int, c_char_p, c_int], c_int),
        "bb_nrc_name": ([c_int, c_char_p, c_int], c_int),
        "bb_last_nrc": ([P(ctypes.c_uint8)], c_int),
        # faults and E2E (faults.py, e2e.py); a uint8_t * is declared c_char_p, its length beside it
        "bb_sim_fault": ([c_int, c_char_p, c_char_p, c_char_p, c_int, c_char_p], c_int),
        "bb_sim_clear_faults": ([], c_int),
        "bb_e2e_p01_crc": ([c_char_p, c_int, c_int, c_int, c_int, c_char_p], c_int),
        "bb_e2e_p01_protect": ([c_char_p, c_int, c_int, c_int, c_int, c_int, c_char_p], c_int),
        "bb_uds_dtcs": ([c_int, c_int], c_int),
        "bb_uds_supported_dtcs": ([c_int], c_int),
        "bb_uds_dtc": ([c_int, c_int, P(BbDtc)], c_int),
        "bb_uds_dtc_count": ([c_int, c_int, P(ctypes.c_uint8)], c_int),
        "bb_uds_snapshot_ids": ([c_int], c_int),
        "bb_uds_snapshot_id": ([c_int, c_int, P(ctypes.c_uint32), P(ctypes.c_uint8)], c_int),
        "bb_uds_snapshot": ([c_int, c_int, c_int, P(BbDtc)], c_int),
        "bb_uds_snapshot_record": ([c_int, c_int, P(ctypes.c_uint8)], c_int),
        "bb_uds_snapshot_did": ([c_int, c_int, c_int, P(ctypes.c_uint16), c_char_p, c_int], c_int),
        "bb_uds_extended": ([c_int, c_int, c_int, P(BbDtc), P(BbCounters)], c_int),
        "bb_uds_extended_record": ([c_int, c_int, P(ctypes.c_uint8), c_char_p, c_int], c_int),
        "bb_uds_did_size": ([c_int, c_int, c_int], c_int),
        "bb_uds_ext_record_size": ([c_int, c_int, c_int], c_int),
        "bb_dtc_name": ([c_int, c_char_p, c_int], c_int),
        "bb_dtc_code": ([c_char_p, P(c_int)], c_int),
        "bb_dtc_status_bit": ([c_int, P(ctypes.c_uint8), c_char_p, c_int], c_int),
        "bb_uds_functional": ([c_int, ctypes.c_int64, P(c_int), c_int, c_char_p, c_int, c_int,
                               P(BbFunctionalReply)], c_int),
        "bb_uds_reply_error": ([c_int, c_char_p, c_int], c_int),
        "bb_uds_functional_doip": ([c_int, P(ctypes.c_int64), c_char_p, c_int, c_int, P(BbFunctionalReply)],
                                   c_int),
        # DoIP (doip.py)
        "bb_last_routing": ([P(ctypes.c_uint8), P(ctypes.c_uint16)], c_int),
        "bb_doip_routing_name": ([c_int, c_char_p, c_int], c_int),
        "bb_doip_routing_hint": ([c_int, c_int, c_char_p, c_int], c_int),
        "bb_doip_endpoint": ([c_int, c_char_p, c_int, P(c_int)], c_int),
        "bb_doip_listener": ([c_int, c_int, c_int, P(c_int), P(c_int)], c_int),
        "bb_doip_discover": ([c_char_p, c_int, c_int, P(BbDoipAnnouncement)], c_int),
        "bb_doip_listen": ([c_int, c_int, c_int, P(BbDoipAnnouncement), c_int], c_int),
        # SOME/IP (someip.py)
        "bb_someip_send": ([c_int, c_char_p, P(BbSomeipOut), c_int, c_int], c_int),
        "bb_someip_call": ([c_int, c_char_p, P(BbSomeipOut), c_int], c_int),
        "bb_someip_listener": ([c_int, c_int, c_char_p, c_char_p, c_int, P(c_int), c_char_p, c_int], c_int),
        "bb_someip_listen": ([c_char_p, c_int, c_char_p, c_int], c_int),
        "bb_someip_count": ([c_int, P(c_int)], c_int),
        "bb_someip_message": ([c_int, c_int, P(BbSomeipMsg), c_char_p, c_int], c_int),
        "bb_someip_free": ([c_int], c_int),
        # flashing (flash.py)
        "bb_flash_defaults": ([P(BbFlashOpts)], c_int),
        "bb_flash_open": ([c_int, P(ctypes.c_int64), P(ctypes.c_int64), P(BbUdsTarget)], c_int),
        "bb_flash_program": ([c_int, c_char_p, c_int, P(BbFlashOpts), P(BbFlashReport)], c_int),
        "bb_flash_cancel": ([c_int], c_int),
        "bb_boot_sim": ([c_int, P(ctypes.c_int64), P(ctypes.c_int64)], c_int),
        "bb_boot_sim_stop": ([c_int, P(BbBootReport)], c_int),
        # replay and recording (replay.py)
        "bb_replay_defaults": ([P(BbReplayOpts)], c_int),
        "bb_replay_start": ([P(c_int), c_int, P(BbReplayOpts)], c_int),
        "bb_replay_notes": ([c_int, c_char_p, c_int], c_int),
        "bb_replay_pause": ([c_int, c_int], c_int),
        "bb_replay_seek": ([c_int, ctypes.c_double], c_int),
        "bb_replay_speed": ([c_int, ctypes.c_double], c_int),
        "bb_replay_loop": ([c_int, c_int], c_int),
        "bb_replay_status": ([c_int, P(BbReplayInfo)], c_int),
        "bb_replay_error": ([c_int, c_char_p, c_int], c_int),
        "bb_replay_wait": ([c_int, c_int], c_int),
        "bb_replay_stop": ([c_int, P(BbReplayInfo)], c_int),
        "bb_record_start": ([P(c_int), c_int, c_char_p], c_int),
        "bb_record_counts": ([c_int, P(BbRecordReport)], c_int),
        "bb_record_stop": ([c_int, P(BbRecordReport)], c_int),
        # the CAN bridge into WSL (bridge.py)
        "bb_wsl_distros": ([c_char_p, c_int], c_int),
        "bb_bridge_program": ([c_char_p, c_int], c_int),
        "bb_bridge_start": ([c_char_p], c_int),
        "bb_bridge_state": ([c_char_p, P(c_int), c_char_p, c_int], c_int),
        "bb_bridge_rows": ([c_char_p, c_char_p, c_int], c_int),
        "bb_bridge_stop": ([c_char_p], c_int),
        # bus metrics (project.py)
        "bb_bus_load": ([c_int, P(BbBusload)], c_int),
        "bb_bus_diagnostics": ([c_int, P(BbDiagnostics)], c_int),
        # generators (generators.py)
        "bb_gen_count": ([], c_int),
        "bb_gen_find": ([c_char_p], c_int),
        "bb_gen_info": ([c_int, P(BbGenerator)], c_int),
        "bb_gen_text": ([c_int, c_int, c_char_p, c_int], c_int),
        "bb_gen_run": ([P(ctypes.c_int64)], c_int),
        "bb_gen_fire": ([c_int, ctypes.c_int64, ctypes.c_int64], c_int),
        "bb_gen_start": ([c_int, c_int], c_int),
        "bb_gen_stop": ([c_int], c_int),
        "bb_gen_cycle": ([c_int, c_int], c_int),
        "bb_gen_set": ([c_int, c_char_p, ctypes.c_double], c_int),
        "bb_gen_source": ([c_int, c_char_p, P(BbWave)], c_int),
        # the system model (nodes.py); a const uint8_t * is declared c_char_p, its length beside it
        "bb_system_path": ([c_char_p, c_int], c_int),
        "bb_node_count": ([], c_int),
        "bb_node_info": ([c_int, P(BbNode)], c_int),
        "bb_node_name": ([c_int, c_char_p, c_int], c_int),
        "bb_node_problem": ([c_int, c_char_p, c_int], c_int),
        "bb_node_target": ([c_int, c_int, P(BbReach)], c_int),
        "bb_node_reach": ([c_int, c_int, P(BbReach)], c_int),
        "bb_node_fault": ([c_int, c_int, P(ctypes.c_uint32), c_char_p, c_int], c_int),
        "bb_did_info": ([c_int, c_int, P(BbDid)], c_int),
        "bb_did_name": ([c_int, c_int, c_char_p, c_int], c_int),
        "bb_did_session": ([c_int, c_int, c_int, c_int, c_char_p, c_int], c_int),
        "bb_did_part": ([c_int, c_int, c_int, P(c_int), c_char_p, c_int], c_int),
        "bb_did_hint": ([c_int, c_int, c_int, c_char_p, c_int], c_int),
        "bb_did_text": ([c_int, c_int, c_char_p, c_int, c_int, c_char_p, c_int], c_int),
        "bb_uds_write_described": ([c_int, c_int, c_int, P(c_char_p), c_int, P(BbWriteNeeds)], c_int),
        # raw ISO-TP (isotp.py), UDS timing and the DoIP retarget (uds.py)
        "bb_isotp_open": ([c_int, ctypes.c_int64, ctypes.c_int64, P(BbUdsTarget)], c_int),
        "bb_isotp_send": ([c_int, c_char_p, c_int], c_int),
        "bb_isotp_recv": ([c_int, c_int, c_char_p, c_int], c_int),
        "bb_isotp_data": ([c_int, c_char_p, c_int], c_int),
        "bb_isotp_close": ([c_int], c_int),
        "bb_uds_get_timing": ([c_int, P(BbUdsTiming)], c_int),
        "bb_uds_set_wait": ([c_int, c_int, c_int], c_int),
        "bb_uds_check_wait": ([c_int, c_int], c_int),
        "bb_uds_retarget": ([c_int, P(ctypes.c_int64)], c_int),
        # interfaces present and Vector assignment (discovery.py, vector.py)
        "bb_ifaces": ([], c_int),
        "bb_ifaces_cansub": ([c_int], c_int),
        "bb_vector_hardware": ([], c_int),
        "bb_listing_count": ([c_int], c_int),
        "bb_listing_note": ([c_int, c_char_p, c_int], c_int),
        "bb_iface_info": ([c_int, c_int, P(BbIface)], c_int),
        "bb_iface_text": ([c_int, c_int, c_int, c_char_p, c_int], c_int),
        "bb_vector_info": ([c_int, c_int, P(BbVectorHw)], c_int),
        "bb_vector_text": ([c_int, c_int, c_int, c_char_p, c_int], c_int),
        "bb_listing_free": ([c_int], c_int),
        "bb_vector_driver": ([c_char_p, c_int], c_int),
        "bb_vector_slot": ([c_int], c_int),
        "bb_vector_assign": ([c_int, c_int, c_int, c_int, c_int], c_int),
        # E2E on a row's frames (project.py, e2e.py)
        "bb_e2e_attach": ([c_int, c_int], c_int),
        "bb_e2e_stamp": ([c_int, c_int, P(BbFrame)], c_int),
        # background senders (cyclic.py) and the keep-alive (uds.py)
        "bb_cyclic_start": ([c_int, P(BbFrame), c_int], c_int),
        "bb_cyclic_start_message": ([c_int, c_int, c_int, P(c_char_p), P(ctypes.c_double), c_int, c_int], c_int),
        "bb_cyclic_data": ([c_int, c_char_p, c_int], c_int),
        "bb_cyclic_signals": ([c_int, c_int, P(c_char_p), P(ctypes.c_double)], c_int),
        "bb_cyclic_period": ([c_int, c_int], c_int),
        "bb_cyclic_status": ([c_int, P(BbCyclicInfo)], c_int),
        "bb_cyclic_error": ([c_int, c_char_p, c_int], c_int),
        "bb_cyclic_stop": ([c_int], c_int),
        "bb_cyclic_free": ([c_int], c_int),
        "bb_uds_keep_alive": ([c_int, c_int], c_int),
        "bb_uds_keep_alive_status": ([c_int, P(BbKeepAlive)], c_int),
        "bb_uds_keep_alive_failure": ([c_int, c_char_p, c_int], c_int),
        # J1939 on a row's frames (j1939.py)
        "bb_j1939_attach": ([c_int, c_int, c_int], c_int),
        "bb_j1939_take_message": ([c_int, P(BbJ1939Message), P(ctypes.c_double), P(ctypes.c_uint8), c_int],
                                  c_int),
        "bb_j1939_take_fault": ([c_int, P(BbJ1939Fault)], c_int),
        "bb_j1939_dropped": ([c_int], c_int),
        "bb_j1939_address_count": ([c_int], c_int),
        "bb_j1939_address_info": ([c_int, c_int, P(BbJ1939Address)], c_int),
        "bb_j1939_function_name": ([c_int, c_char_p, c_int], c_int),
        # network management on a row's frames (nm.py)
        "bb_nm_attach": ([c_int, c_int], c_int),
        "bb_nm_attach_range": ([c_int, c_int, ctypes.c_int64, ctypes.c_int64, c_int, c_int], c_int),
        "bb_nm_read_view": ([c_int, P(BbNmView)], c_int),
        "bb_nm_node_info": ([c_int, c_int, P(BbNmNode)], c_int),
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


def in_progress(on: bool) -> None:
    """Marks the calling thread as inside a flash's progress callback, where lib() refuses it: the
    flash holds the engine until it ends, and a call waiting for it there would wait for ever."""
    _tls.in_progress = on


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
    if getattr(_tls, "in_progress", False):
        raise BloblyError("a call into blobly from a flash's progress callback: the flash holds the "
                          "engine until it ends", BB_ERR_STATE)
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


def byte_data(name, v):
    """A byte-string argument: bytes, bytearray, memoryview, or a sequence of byte values. An integer
    is refused, where bytes() would read it as a count of zero bytes."""
    if isinstance(v, (str, numbers.Integral)):
        raise TypeError(f"{name} must be bytes, not {type(v).__name__}")
    try:
        return bytes(v)
    except (TypeError, ValueError) as e:
        raise TypeError(f"{name} must be bytes: {e}") from None


def ms_of(ns):
    """A host monotonic time in ns as the ms a script sees: the division the Lua binding makes."""
    return ns / 1_000_000.0


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


def bytes_of(get, *at):
    """Bytes a bb_* call copies into the caller's buffer from what the library holds, read whole:
    the call answers their length, so a cut one is asked for again with room for it."""
    cap = 256
    while True:
        buf = ctypes.create_string_buffer(cap)
        n = check(get(*at, buf, cap))
        if n <= cap:
            return buf.raw[:n]
        cap = n


def check(rc):
    """A bb_* return value: itself when >= 0, otherwise the error its code names (error())."""
    if rc < 0:
        raise error(rc)
    return rc


def error(rc):
    """The exception for a failed call's code, with bb_last_error's message: read it before the
    thread's next call, which replaces it. A denied routing activation carries its code, read with
    it (bb_last_routing is the thread's too)."""
    e = ERRORS.get(rc, BloblyError)(text(_lib.bb_last_error()), rc)
    if isinstance(e, RoutingDenied):
        code, tester = ctypes.c_uint8(), ctypes.c_uint16()
        if _lib.bb_last_routing(ctypes.byref(code), ctypes.byref(tester)) == 0:
            e.routing_code, e.tester = code.value, tester.value
            e.routing_name = string(_lib.bb_doip_routing_name, code.value)
            e.hint = string(_lib.bb_doip_routing_hint, code.value, tester.value)
    return e
