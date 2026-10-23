"""someip — SOME/IP through libblobly, as the Lua someip.send, someip.call and someip.listen:
messages sent from a local port and what that port heard back, one request answered, and what a
port already carries. The rules are blobly/someip's; a message is a SomeipMessage, its payload raw
bytes (the layout belongs to the deployment, not to the tester).

    from blobly import someip, SomeipMessage
    answer = someip.call("127.0.0.1:30509", SomeipMessage(0x0100, 0x0001, b"ping"))
    print(answer.type, answer.payload)

Nothing needs a started project but listening on a channel's endpoint. Every wait is bounded by
its window or timeout, and Ctrl-C ends it within 100 ms (the exchange then finishes on its own)."""
import ctypes
from collections.abc import Iterable
from dataclasses import dataclass
from typing import NamedTuple

from . import _lib
from .doip import _ms, _started
from .events import _on_thread

__all__ = ["call", "listen", "send"]

# message types by name, as the Lua binding spells them; one the table does not know reads "type nn"
_TYPES = {"request": 0x00, "notification": 0x02, "response": 0x80, "error": 0x81}
_NAMES = {v: k for k, v in _TYPES.items()}


@dataclass(frozen=True)
class SomeipMessage:
    """A SOME/IP message: the header's fields and the payload. To send one, give `service`,
    `method` and the `payload`; a field left None takes the engine's default — `type`
    "notification" for an event id (bit 15 of `method`), "request" otherwise; `iface` (interface
    version) 1; `client` 0x1234 for a request (a blobly_emb node refuses client 0), 0 for a
    notification; `session` the run's next for a request, which goes out once per run (a late
    reply to one request can never complete another), 0 for a notification.

    A message heard has every field: `type` one of "request", "notification", "response",
    "error" (or "type nn" for another code), `return_code`, `at_ms` (ms into the window it was
    heard in; for a call's answer, ms after the send), `source`, the "host:port" it came from, and
    `protocol`, the protocol version (0x01 is the only one SOME/IP defines)."""
    service: int
    method: int
    payload: bytes = b""
    type: str | None = None
    iface: int | None = None
    client: int | None = None
    session: int | None = None
    return_code: int = 0
    at_ms: int | None = None
    source: str | None = None
    protocol: int | None = None

    @property
    def event(self) -> bool:
        """Whether `method` is an event id (bit 15 set)."""
        return bool(self.method & 0x8000)


class SomeipHeard(NamedTuple):
    """What a window heard (send, listen): the `messages` in the order heard, a datagram packing
    several giving each, and how many datagrams were `malformed` (not SOME/IP to their end) —
    reported, never hidden. Unpacks as `messages, malformed`."""
    messages: list[SomeipMessage]
    malformed: int


def _field(name: str, v, bits: int) -> int:
    """A header field to send: -1 for None (the default), else an int of `bits` bits."""
    if v is None:
        return -1
    if isinstance(v, bool) or not isinstance(v, int):
        raise TypeError(f"{name} must be an integer, not {v!r}")
    if not 0 <= v < 1 << bits:
        raise ValueError(f"{name} {v} does not fit {bits} bits")
    return v


def _out(m: SomeipMessage, keep: list) -> _lib.BbSomeipOut:
    """A bb_someip_out for `m`; its payload kept alive in `keep` for the call."""
    if not isinstance(m, SomeipMessage):
        raise TypeError(f"a SomeipMessage, not {m!r}")
    if m.service is None or m.method is None:
        raise TypeError(f"a message needs its service and method: {m!r}")
    if m.type is not None and m.type not in _TYPES:
        raise ValueError(f"type {m.type!r}: one of {', '.join(_TYPES)}")
    if isinstance(m.payload, (str, int)):
        raise TypeError(f"payload must be bytes, not {type(m.payload).__name__}")
    if m.return_code:
        raise ValueError(f"return_code {m.return_code}: a request or a notification is sent with 0")
    payload = bytes(m.payload)
    if len(payload) > 65507 - 16:
        raise ValueError(f"a payload of {len(payload)} bytes does not fit one UDP datagram")
    keep.append(payload)
    return _lib.BbSomeipOut(_field("service", m.service, 16), _field("method", m.method, 16),
                            -1 if m.type is None else _TYPES[m.type], _field("iface", m.iface, 8),
                            _field("client", m.client, 16), _field("session", m.session, 16),
                            payload, len(payload))


def _message(m: _lib.BbSomeipMsg, payload: bytes) -> SomeipMessage:
    return SomeipMessage(m.service, m.method, payload, _NAMES.get(m.msg_type, f"type {m.msg_type:02x}"),
                         m.iface, m.client, m.session, m.return_code, m.at_ms, _lib.text(m.source), m.protocol)


def _capture(lib, c: int) -> SomeipHeard:
    """The messages of capture `c`, read whole and the capture let go."""
    try:
        bad = ctypes.c_int()
        n = _lib.check(lib.bb_someip_count(c, ctypes.byref(bad)))
        out, m = [], _lib.BbSomeipMsg()
        for i in range(n):
            payload = _lib.bytes_of(lib.bb_someip_message, c, i, ctypes.byref(m))
            out.append(_message(m, payload))
        return SomeipHeard(out, bad.value)
    finally:
        lib.bb_someip_free(c)


def _port(name: str, port) -> int:
    if port is None:
        return 0
    if isinstance(port, bool) or not isinstance(port, int):
        raise TypeError(f"{name}: a port is an int, not {port!r}")
    if not 1 <= port <= 0xFFFF:
        raise ValueError(f"{name}: {port} is not a UDP port")
    return port


def _to(name: str, to) -> bytes:
    if not isinstance(to, str) or "\0" in to:
        raise TypeError(f"{name}: to is an IPv4 \"host:port\" string, not {to!r}")
    return to.encode()


def send(to: str, msgs: SomeipMessage | Iterable[SomeipMessage], *, port: int | None = None,
         window_ms: float = 1000) -> SomeipHeard:
    """Sends `msgs` (one SomeipMessage or several; only requests and notifications) to `to`, an
    IPv4 "host:port", FROM the local `port` (None: 30491), then hears that port for `window_ms`
    and returns what it heard — one socket both ways, since a node with a static peer endpoint (a
    blobly_emb SOME/IP node) accepts datagrams only from its configured peer and answers it.
    A port another listener of this process holds is refused (Refused)."""
    window = _ms("someip.send", window_ms)
    p = _port("someip.send", port)
    dest = _to("someip.send", to)
    items = [msgs] if isinstance(msgs, SomeipMessage) else list(msgs)
    keep: list = []
    arr = (_lib.BbSomeipOut * max(len(items), 1))(*[_out(m, keep) for m in items])
    lib = _lib.lib()
    return _on_thread(lambda: _capture(lib, _lib.check(lib.bb_someip_send(p, dest, arr, len(items), window))),
                      "blobly-someip")


def call(to: str, request: SomeipMessage, *, port: int | None = None, timeout_ms: float = 1000) -> SomeipMessage:
    """One request/response exchange: sends `request` to `to` (an IPv4 "host:port") from the local
    `port` (None: 30491) and returns the RESPONSE or ERROR mirroring its Request ID as soon as it
    arrives from `to` — an ERROR is an answer (`type` "error", its `return_code`). Events, other
    senders and stale replies to an earlier session are skipped. Raises Timeout when nothing
    answered within `timeout_ms` (at least 1), Refused for what is no request (an event id,
    client 0, another type) and for a session this run already sent."""
    wait = _ms("someip.call", timeout_ms)
    if wait < 1:
        raise ValueError(f"someip.call: a timeout of {timeout_ms} ms; a call waits at least 1 ms")
    p = _port("someip.call", port)
    dest = _to("someip.call", to)
    keep: list = []
    req = _out(request, keep)
    lib = _lib.lib()
    heard = _on_thread(lambda: _capture(lib, _lib.check(lib.bb_someip_call(p, dest, ctypes.byref(req), wait))),
                       "blobly-someip")
    return heard.messages[0]


def listen(window_ms: float = 1000, *, port: int | None = None, group: str | None = None,
           channel=None) -> SomeipHeard:
    """Hears for `window_ms` what the network already carries on `port` (None: 30490): a
    blobly_emb node's events to its peer (bind the peer port), a service's events on a multicast
    `group` (joined on the port), SD offers (join the SD group). Nothing is sent and nothing is
    subscribed to, so an event a service sends only to subscribers is not heard.

    `channel`, a SOME/IP Channel of the started project, listens on its bind host, port and group;
    a `port`, or a `group`, contradicting it is refused. A port another listener of this process
    holds is refused too: two sockets on one UDP port split its stream."""
    window = _ms("someip.listen", window_ms)
    p = 0 if port is None else _port("someip.listen", port)
    if group is not None and (not isinstance(group, str) or not group or "\0" in group):
        raise TypeError(f"someip.listen: group is a multicast address, not {group!r}")
    g = None if group is None else group.encode()
    lib = _lib.lib()
    host = None
    if channel is not None:
        from .project import Channel  # project imports this module
        if not isinstance(channel, Channel):
            raise TypeError(f"someip.listen: channel is a Channel, not {channel!r}")
        use_port, use_group = ctypes.c_int(), ctypes.create_string_buffer(256)
        with _lib.state_lock:  # the row's endpoint in this run, read once; the wait holds no lock
            _started("someip.listen", channel)
            host = _lib.string(lambda buf, cap: lib.bb_someip_listener(channel._index, p, g, buf, cap,
                                                                       ctypes.byref(use_port), use_group, 256))
        host, p, g = host.encode(), use_port.value, use_group.value
    return _on_thread(lambda: _capture(lib, _lib.check(lib.bb_someip_listen(host, p, g, window))), "blobly-someip")
