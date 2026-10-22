"""events — the event loop, the shape of the Lua prelude's run() (blobly/script): one thread, no
reader threads, no background senders. run() reads every channel a handler names from the same
channel objects send and recv use, so a frame is consumed once by whoever reads it and the
script's own sends are never heard back.

The deadline rule is per event — a frame, a timer, one health handler: none is taken up once the
deadline has passed, and a frame taken up reaches every handler it matches (it cannot be re-read).
Timers keep their grid (a late fire does not move the next; missed periods are skipped) and are
not fired inside their own callback. Health is sampled every 100 ms, per handler, and each
handler is told a known state it has not been told yet — so one registered late hears the current
state, and "" (unknown) is never said.

EventLoop is pure: it reaches time, frames and health only through _resolve, _listen, _now,
_wait_frame and _health, which Project implements over libblobly and the model test
(tests/test_events.py) replaces. Handlers are keyed by what _resolve returns — a Channel object
for a Project, so two rows that share a name stay two rows."""
import collections
import math
import sys
import time

HEALTH_POLL_MS = 100
# how long a wait on several channels sleeps between looks: Windows' default timer granularity
# cannot sleep 0.1 ms
WAIT_SLICE_MS = 1.0 if sys.platform == "win32" else 0.1
# how long a wait rests on a channel that answered an error at once (closed, failing): long
# enough not to spin, short enough that a link that comes back is read again
ERROR_REST_MS = 20
# the longest wait one driver call can be asked for: bb.h's timeouts are C ints
MAX_WAIT_MS = 2**31 - 1
# the longest one wait inside run() is, as the Lua run(): the loop goes on, a long run() is many
LONGEST_WAIT_MS = 1000


def _finite(x):
    """A real number of milliseconds: not a bool, not NaN, not infinite."""
    return not isinstance(x, bool) and isinstance(x, (int, float)) and math.isfinite(x)


class _Timer:
    __slots__ = ("due", "period", "fn", "active")

    def __init__(self, due, period, fn):
        self.due, self.period, self.fn, self.active = due, period, fn, False


class _Health:
    __slots__ = ("channel", "fn", "said")

    def __init__(self, channel, fn):
        self.channel, self.fn, self.said = channel, fn, None


class EventLoop:
    """on_message / on_health / on_timer, and run(). Subclasses supply _resolve(channel) -> key,
    _listen(key) (open and validate a channel where a handler names it), _now (ms, monotonic),
    _wait_frame(keys, timeout_ms) -> (key, frame) | None and _health(key) -> str."""

    def __init__(self):
        self._on_msg = []      # (channel key, id or None, fn)
        self._on_health = []   # _Health
        self._timers = []      # _Timer
        self._listened = []    # channel keys, in the order handlers named them
        # frames taken up whose handlers have not all run, oldest first: [frame, handlers, next].
        # Any run(), nested or not, finishes these before it takes up another frame, so no
        # handler sees a later frame before an earlier one
        self._pending = collections.deque()

    def _resolve(self, channel):
        return channel

    def _listen_key(self, channel):
        key = self._resolve(channel)
        self._listen(key)
        self._read(key)
        return key

    def _read(self, key):
        """run() reads this channel from now on."""
        if not any(k is key or k == key for k in self._listened):
            self._listened.append(key)

    def _health_needs_reader(self, key):
        """Whether a channel's ladder moves only while it is read. Unknown here: read it."""
        return True

    def _to_read(self, needs):
        """What one wait reads, built at each wait so a handler registered inside a callback is
        read in this run(): every channel an on_message names, and a health handler's where its
        ladder needs a reader (`needs` holds this run()'s answers)."""
        read = list(self._listened)
        for h in self._on_health:
            if any(k is h.channel or k == h.channel for k in read):
                continue
            answer = next((a for c, a in needs if c is h.channel or c == h.channel), None)
            if answer is None:
                answer = self._health_needs_reader(h.channel)
                needs.append((h.channel, answer))
            if answer:
                read.append(h.channel)
        return read

    def on_message(self, channel, id, fn):
        """fn(frame) for each frame on `channel` whose id is `id` (None: every frame) received
        during run() — what other nodes sent."""
        self._on_msg.append((self._listen_key(channel), id, fn))

    def on_health(self, channel, fn):
        """fn(state) during run() when the controller's ladder has moved — "ok", "error warning",
        "ERROR-PASSIVE", "BUS-OFF" — and at its first sample with the state then. Sampled every
        100 ms: a state held for less than that can be missed. A software bus never fires."""
        key = self._resolve(channel)
        self._listen(key)
        self._on_health.append(_Health(key, fn))

    def on_timer(self, period_ms, fn):
        """fn() every period_ms during run(), on its own grid. The period must be a positive,
        finite number of milliseconds."""
        if not _finite(period_ms) or not period_ms >= 1:
            raise ValueError("on_timer: the period must be a finite number of milliseconds, at least 1")
        self._timers.append(_Timer(self._now() + period_ms, period_ms, fn))

    def _poll_health(self, deadline):
        for h in list(self._on_health):
            if self._now() >= deadline:
                return
            s = self._health(h.channel)  # sampled per handler: a nested run() cannot leave it stale
            if s != "" and s != h.said:
                h.said = s
                h.fn(s)

    def _dispatch_pending(self):
        """Runs the remaining handlers of the frames taken up, oldest first. Each handler is
        passed BEFORE it is called, so a run() inside it continues with the next one rather than
        calling it again; a handler that raises ends its frame's dispatch."""
        while self._pending:
            entry = self._pending[0]
            frame, handlers, i = entry
            if i >= len(handlers):
                self._pending.popleft()
                continue
            entry[2] = i + 1
            try:
                handlers[i](frame)
            except BaseException:
                if self._pending and self._pending[0] is entry:
                    self._pending.popleft()
                raise

    @staticmethod
    def _past_grid(t, at):
        """Moves a timer to the first point on its grid after `at`, in one step."""
        if t.due <= at:
            t.due += (math.floor((at - t.due) / t.period) + 1) * t.period
            while t.due <= at:  # what floating-point rounding left behind
                t.due += t.period

    def _fire(self, t):
        # on its grid BEFORE the call, so a run() inside it neither fires it again nor waits on
        # it; and again when the call ends, so points a long callback ran over are skipped, not
        # fired back to back
        self._past_grid(t, self._now())
        t.active = True
        try:
            t.fn()
        finally:
            t.active = False
            self._past_grid(t, self._now())

    def run(self, duration_ms=1000):
        """The event loop for duration_ms (a finite number, zero or more). It reads every channel a
        handler names; a frame it reads is consumed, whether or not a handler matched it."""
        if not _finite(duration_ms) or duration_ms < 0:
            # NaN would make every deadline comparison false: a loop that never ends
            raise ValueError("run: the duration must be a finite number of milliseconds, zero or more")
        deadline = self._now() + duration_ms
        next_health = self._now()
        # whether a health handler's channel needs reading, asked once per run() and channel — not
        # at registration, since a reload can keep a channel while its row's interface changes
        needs = []  # (channel, answer)
        while True:
            now = self._now()
            for t in list(self._timers):
                if self._now() >= deadline:
                    break
                if not t.active and now >= t.due:
                    self._fire(t)
            if self._on_health and self._now() >= next_health and self._now() < deadline:
                next_health = self._now() + HEALTH_POLL_MS
                self._poll_health(deadline)
            now = self._now()  # after the callbacks: the time they took is not waited again
            if now >= deadline:
                break
            self._dispatch_pending()  # an outer run()'s frame, before any frame of this one
            now = self._now()
            if now >= deadline:
                break
            wake = deadline
            for t in self._timers:
                if not t.active and t.due < wake:
                    wake = t.due
            if self._on_health and next_health < wake:
                wake = next_health
            # the exact budget, fractions included: the wait never reads past the deadline; and at
            # most a second, so a long run() is many waits
            got = self._wait_frame(self._to_read(needs), min(max(0, wake - now), LONGEST_WAIT_MS))
            if got is not None:
                key, frame = got
                handlers = [fn for ch, want, fn in self._on_msg
                            if (ch is key or ch == key) and (want is None or want == frame.id)]
                self._pending.append([frame, handlers, 0])
                self._dispatch_pending()
            if self._now() >= deadline:
                break


def wait_on(channels, timeout_ms, rr, now, sleep_ms):
    """The next frame on any of `channels` (objects with .recv(timeout_ms) in whole ms), waiting
    at most timeout_ms (a fraction allowed); with several, a look at each in turn from `rr` and one
    slice of sleep between looks. Nothing is taken off a channel after the deadline: a wait the
    driver cannot express (a fraction of a millisecond) is slept, not read. Returns
    ((channel, frame) | None, rr)."""
    if not channels:
        if timeout_ms > 0:
            sleep_ms(timeout_ms)
        return None, rr
    deadline = now() + timeout_ms
    if len(channels) == 1:
        try:
            # the floor, so the driver never waits past the deadline; a longer wait than one call can
            # be asked for returns when that call does, and run() waits again
            capped = int(timeout_ms) > MAX_WAIT_MS
            look = getattr(channels[0], "look", None)
            if int(timeout_ms) == 0 and look:
                f, spent = look()
                if f is None and spent:  # records still queued: run() asks again at once
                    return None, rr
            else:
                f = channels[0].recv(min(int(timeout_ms), MAX_WAIT_MS))
        except Exception:
            rest = min(deadline - now(), ERROR_REST_MS)
            if rest > 0:
                sleep_ms(rest)
            return None, rr
        if f is not None:
            return (channels[0], f), rr
        if not capped:  # only the fraction of a millisecond the driver could not be asked for
            rest = deadline - now()
            if rest > 0:
                sleep_ms(rest)
        return None, rr
    n = len(channels)
    while True:
        spent = False
        for k in range(n):
            if k > 0 and timeout_ms > 0 and now() >= deadline:  # a slow look spent the budget
                return None, rr
            i = (rr + k) % n
            try:
                look = getattr(channels[i], "look", None)
                f, s = look() if look else (channels[i].recv(0), False)
                spent = spent or s
            except Exception:  # an error is a look with nothing in it
                f = None
            if f is not None:
                return (channels[i], f), i + 1
        if now() >= deadline:
            return None, rr
        if spent:
            continue  # records still queued behind a look's bound: look again at once
        sleep_ms(min(WAIT_SLICE_MS, deadline - now()))  # never a slice past the deadline
        if now() >= deadline:  # what came in the last slice stays for the next reader
            return None, rr


def monotonic_ms():
    return time.monotonic() * 1000.0


def sleep_ms(ms):
    time.sleep(ms / 1000.0)
