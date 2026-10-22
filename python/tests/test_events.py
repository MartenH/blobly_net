"""The event loop's rules, without the library: EventLoop driven against fakes of its hooks —
synthetic time, scripted arrivals on two channels, a scripted controller ladder — over seeded
random scenarios (slow handlers, nested run(), recv inside a handler, health handlers registered
late, timers whose callbacks are slow or run() themselves). It asserts:
  A1 every frame taken off a channel is delivered exactly once, in arrival order per channel, and
     when no callback ran to the deadline, every frame that arrived by it was delivered;
  A2 run(d) started at t0 returns by t0 + d, or by the end of an event taken up by then — a frame
     (all its handlers), a timer, one health handler;
  A3 no wait runs past a timer that is due and not running, and run() never spins without time
     moving;
  A4 a health handler is told only known states, never the same one twice running, and each one
     the newest sample of its channel;
  A5 a timer is never fired inside its own callback;
  A6 a timer stays on its grid: its next due time is its first plus whole periods, and later than
     when it fired.
The same rules, and the same model, as the Lua run() (blobly/script/events_test.v)."""
import os
import random
import sys
import unittest

# the source tree, unless the run is of an installed wheel (BLOBLY_TEST_INSTALLED)
if not os.environ.get("BLOBLY_TEST_INSTALLED"):
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from blobly import _lib  # noqa: E402
from blobly.events import EventLoop, wait_on  # noqa: E402


class Arrival:
    def __init__(self, at, seq, ch):
        self.at, self.seq, self.ch = at, seq, ch


class Got:
    def __init__(self, seq):
        self.id = seq


STATES = ["", "ok", "error warning", "ERROR-PASSIVE", "BUS-OFF"]


class Model(EventLoop):
    """EventLoop over synthetic time; every hook records what it was asked."""

    def __init__(self, seed):
        super().__init__()
        self.r = random.Random(seed)
        self.t = 0
        self.arrivals = {"A": [], "B": []}
        self.all = []
        seq = 0
        for ch in ("A", "B"):
            at = self.r.randrange(20)
            while at < 300:
                seq += 1
                a = Arrival(at, seq, ch)
                self.arrivals[ch].append(a)
                self.all.append(a)
                at += 1 + self.r.randrange(25)
        self.rungs = {}
        for ch in ("A", "B"):
            at, steps = 0, []
            while at < 600:
                steps.append((at, STATES[self.r.randrange(len(STATES))]))
                at += 20 + self.r.randrange(120)
            self.rungs[ch] = steps
        self.polls, self.latest = [], {}
        self.delivered, self.last = set(), {"A": 0, "B": 0}
        self.popped = 0
        self.spins = 0

    def _now(self):
        return self.t

    def _listen(self, name):
        pass

    def _health(self, ch):
        cur = ""
        for at, s in self.rungs[ch]:
            if at <= self.t:
                cur = s
        self.polls.append((ch, cur))
        self.latest[ch] = len(self.polls) - 1
        return cur

    def _take(self, ch, upto):
        q = self.arrivals[ch]
        if q and q[0].at <= upto:
            a = q.pop(0)
            if a.at > self.t:
                self.t = a.at
            self.popped += 1
            return a
        return None

    def deliver(self, ch, seq):
        if seq in self.delivered:
            raise AssertionError(f"A1: frame {seq} delivered twice")
        if seq <= self.last[ch]:
            raise AssertionError(f"A1: frame {seq} out of order on {ch}")
        self.delivered.add(seq)
        self.last[ch] = seq

    def _wait_frame(self, names, ms):
        self.spins += 1
        if self.spins > 200000:
            raise AssertionError("A3: run() spins without time moving")
        for tm in self._timers:
            if not tm.active:
                room = max(0, tm.due - self.t)
                if ms > room:
                    raise AssertionError(f"A3: a wait of {ms} past a timer due in {room}")
        best = None
        for ch in names:
            q = self.arrivals[ch]
            if q and q[0].at <= self.t + ms and (best is None or q[0].at < self.arrivals[best][0].at):
                best = ch
        if best is None:
            self.t += ms
            return None
        a = self._take(best, self.t + ms)
        return best, Got(a.seq)

    def recv(self, ch, timeout):
        a = self._take(ch, self.t + timeout)
        if a is None:
            self.t += timeout
            return None
        return Got(a.seq)


def scenario(seed):
    m = Model(seed)
    r = m.r
    spans = []
    depth = [0]
    late = [0]
    event_start = {}

    def nested(k):
        depth[0] += 1
        try:
            m.run(k)
        finally:
            depth[0] -= 1

    def add_health(ch):
        rec = {"idx": -1, "s": None}

        def told(st):
            idx = m.latest[ch]
            if st == "":
                raise AssertionError("A4: told unknown")
            if st == rec["s"]:
                raise AssertionError(f"A4: told {st} twice running")
            if m.polls[idx][1] != st:
                raise AssertionError(f"A4: told {st} while the newest sample says {m.polls[idx][1]}")
            if idx <= rec["idx"]:
                raise AssertionError("A4: told an older sample")
            rec["idx"], rec["s"] = idx, st
            start = m.t
            if depth[0] == 0:
                k = r.randrange(4)
                if k == 0:
                    m.t += r.randrange(30)
                elif k == 1:
                    nested(1 + r.randrange(20))
            spans.append((start, m.t))
        m.on_health(ch, told)

    def behave():
        if depth[0] > 0:
            return
        k = r.randrange(10)
        if k == 0:
            m.t += 1 + r.randrange(40)
        elif k == 1:
            nested(1 + r.randrange(15))
        elif k == 2:
            ch = "AB"[r.randrange(2)]
            f = m.recv(ch, r.randrange(10))
            if f is not None:
                m.deliver(ch, f.id)
        elif k == 3 and late[0] < 2:
            late[0] += 1
            add_health("AB"[r.randrange(2)])

    for ch in ("A", "B"):
        def first(f, ch=ch):
            event_start[f.id] = m.t
            m.deliver(ch, f.id)
            behave()
            spans.append((event_start[f.id], m.t))
        m.on_message(ch, None, first)
        if r.randrange(2) == 0:
            seen = {"last": 0}

            def second(f, seen=seen, ch=ch):
                # every handler sees a channel's frames in arrival order, however the first one
                # nested run() between them
                if f.id <= seen["last"]:
                    raise AssertionError(f"A1: a second handler on {ch} saw frame {f.id} after {seen['last']}")
                seen["last"] = f.id
                if depth[0] == 0 and r.randrange(4) == 0:
                    m.t += r.randrange(30)
                spans.append((event_start[f.id], m.t))
            m.on_message(ch, None, second)
    if r.randrange(2) == 0:
        add_health("AB"[r.randrange(2)])
    if r.randrange(3) == 0:
        add_health("AB"[r.randrange(2)])
    for _ in range(r.randrange(3)):
        period = 5 + r.randrange(60)
        first_due = m.t + period
        rec = {"active": False, "fired": False}

        def tick(rec=rec, period=period, first_due=first_due):
            entry = rec["entry"]
            if rec["active"]:
                raise AssertionError("A5: a timer fired inside its own callback")
            if not rec["fired"] and m.t < first_due:
                raise AssertionError("A5: a timer fired before it was due")
            if (entry.due - first_due) % period != 0 or entry.due <= m.t:
                raise AssertionError(f"A6: next due {entry.due} off the grid {first_due}+{period}k or not after {m.t}")
            rec["fired"] = True
            rec["active"] = True
            st = m.t
            if depth[0] == 0:
                if r.randrange(3) == 0:
                    m.t += r.randrange(2 * period)
                elif r.randrange(3) == 0:
                    nested(r.randrange(period))
            spans.append((st, m.t))
            rec["active"] = False
        m.on_timer(period, tick)
        rec["entry"] = m._timers[-1]

    t0 = m.t
    d = 50 + r.randrange(200)
    m.run(d)
    bound, reached = t0 + d, False
    for a, b in spans:
        if a <= t0 + d and b > bound:
            bound = b
        if a <= t0 + d and b >= t0 + d:
            reached = True
    if m.t > bound:
        raise AssertionError(f"A2: run({d}) from {t0} returned at {m.t}, bound {bound}")
    if m.popped != len(m.delivered):
        raise AssertionError(f"A1: {m.popped} frames taken, {len(m.delivered)} delivered")
    if not reached:  # a callback that ran to the deadline leaves what arrived during it queued
        for a in m.all:
            if a.at <= t0 + d and a.seq not in m.delivered:
                raise AssertionError(f"A1: frame {a.seq} at {a.at} never delivered")


class TestModel(unittest.TestCase):
    def test_model_of_run(self):
        for seed in range(1, 400):
            try:
                scenario(seed)
            except AssertionError as e:
                self.fail(f"seed {seed}: {e}")


class FakeChannel:
    """A channel whose frames are queued, and whose recv(0) is a look."""

    def __init__(self, name, frames=(), fail=False):
        self.name, self.frames, self.fail, self.calls = name, list(frames), fail, 0

    def recv(self, timeout_ms):
        self.calls += 1
        if self.fail:
            raise RuntimeError("bus is closed")
        return self.frames.pop(0) if self.frames else None


class Clock:
    def __init__(self):
        self.t = 0.0

    def now(self):
        return self.t

    def sleep(self, ms):
        self.t += ms


class TestWaitOn(unittest.TestCase):
    def test_takes_turns_between_flooded_channels(self):
        a, b = FakeChannel("A", range(10)), FakeChannel("B", range(10))
        c, rr, order = Clock(), 0, []
        for _ in range(8):
            got, rr = wait_on([a, b], 0, rr, c.now, c.sleep)
            order.append(got[0].name)
        self.assertEqual(order, ["A", "B"] * 4)

    def test_reads_the_second_channel(self):
        a, b = FakeChannel("A"), FakeChannel("B", [7])
        got, _ = wait_on([a, b], 50, 0, Clock().now, Clock().sleep)
        self.assertIs(got[0], b)
        self.assertEqual(got[1], 7)

    def test_a_fraction_of_a_millisecond_is_slept_not_read(self):
        clock = Clock()

        class Late(FakeChannel):
            def recv(self, timeout_ms):  # readable from t = 0.3, inside the 0.5 ms budget's fraction
                self.calls += 1
                clock.t += timeout_ms
                return "late" if clock.t >= 0.3 else None
        late = Late("A")
        got, _ = wait_on([late], 0.5, 0, clock.now, clock.sleep)
        self.assertIsNone(got)
        self.assertEqual(late.calls, 1, "looked again after the driver's whole-millisecond wait")
        self.assertEqual(clock.t, 0.5)

    def test_the_last_sleep_is_capped_at_the_deadline(self):
        clock = Clock()
        got, _ = wait_on([FakeChannel("A"), FakeChannel("B")], 0.05, 0, clock.now, clock.sleep)
        self.assertIsNone(got)
        self.assertAlmostEqual(clock.t, 0.05, msg="slept a whole slice past the deadline")

    def test_a_wait_longer_than_a_c_int_is_asked_in_pieces(self):
        asked = []

        class Spy(FakeChannel):
            def recv(self, timeout_ms):
                asked.append(timeout_ms)
                return None
        clock = Clock()
        wait_on([Spy("A")], 2**40, 0, clock.now, clock.sleep)
        self.assertLessEqual(asked[0], 2**31 - 1)
        self.assertEqual(clock.t, 0, "slept the rest of the budget instead of returning to wait again")

    def test_a_slow_look_ends_the_scan(self):
        clock = Clock()

        class Slow(FakeChannel):
            def recv(self, timeout_ms):
                clock.t += 10
                return None
        b = FakeChannel("B", [7])
        got, _ = wait_on([Slow("A"), b], 5, 0, clock.now, clock.sleep)
        self.assertIsNone(got)
        self.assertEqual(b.frames, [7], "a frame was taken after the deadline")

    def test_times_out_without_looking_after_the_deadline(self):
        class Late(FakeChannel):
            def recv(self, timeout_ms):  # readable from t = 20, the deadline
                self.calls += 1
                return "late" if clock.t >= 20 else None
        clock = Clock()
        late = Late("A")
        got, _ = wait_on([late, FakeChannel("B")], 20, 0, clock.now, lambda ms: setattr(clock, "t", clock.t + 7))
        self.assertIsNone(got, "a frame was taken after the deadline")

    def test_a_failing_single_channel_rests_and_does_not_spin(self):
        bad, clock = FakeChannel("A", fail=True), Clock()
        got, _ = wait_on([bad], 1000, 0, clock.now, clock.sleep)
        self.assertIsNone(got)
        self.assertEqual(bad.calls, 1)
        self.assertEqual(clock.t, 20, "rested neither a spin nor the whole wait")


class TestSpentLook(unittest.TestCase):
    def test_a_spent_look_is_looked_again_at_once(self):
        class Busy(FakeChannel):
            spent = 5

            def look(self):
                if self.spent:
                    self.spent -= 1
                    return None, True
                return Got("0x42"), False

        clock = Clock()
        sleeps = []
        got, _ = wait_on([Busy("A"), FakeChannel("B")], 50, 0, clock.now, lambda ms: sleeps.append(ms))
        self.assertIsNotNone(got)
        self.assertEqual(sleeps, [], "slept on a queue that said it was not empty")


class Ladder(EventLoop):
    """A channel with no frames and a ladder that moves by sample count, over synthetic time."""

    def __init__(self, steps):
        super().__init__()
        self.t, self.steps, self.samples = 0, steps, 0

    def _now(self):
        return self.t

    def _listen(self, name):
        pass

    def _wait_frame(self, names, ms):
        self.t += ms
        return None

    def _health(self, name):
        self.samples += 1
        return self.steps[min(self.samples, len(self.steps)) - 1]


class TestSpentSingleLook(unittest.TestCase):
    def test_a_spent_single_look_is_not_slept_on(self):
        class Busy(FakeChannel):
            def look(self):
                return None, True

        clock, sleeps = Clock(), []
        got, _ = wait_on([Busy("A")], 0.5, 0, clock.now, lambda ms: sleeps.append(ms))
        self.assertIsNone(got)
        self.assertEqual(sleeps, [], "slept the fraction on a queue that said it was not empty")


class TestHealthReading(unittest.TestCase):
    def test_whether_a_health_channel_is_read_is_asked_at_each_run(self):
        class Asked(Ladder):
            needs = False
            waited_on = []

            def _health_needs_reader(self, name):
                return self.needs

            def _wait_frame(self, names, ms):
                self.waited_on.append(list(names))
                return super()._wait_frame(names, ms)

        loop = Asked(["ok"])
        loop.on_health("A", lambda s: None)
        loop.run(5)
        self.assertTrue(loop.waited_on and all("A" not in n for n in loop.waited_on))
        loop.needs, loop.waited_on = True, []  # a reload put the row on a wire that needs a reader
        loop.run(5)
        self.assertTrue(loop.waited_on and all("A" in n for n in loop.waited_on))


class TestMidRunRegistration(unittest.TestCase):
    def test_a_handler_registered_inside_a_callback_is_read_in_the_same_run(self):
        class Two(Ladder):
            sent = False

            def _wait_frame(self, names, ms):
                if "B" in names and self.t >= 2 and not self.sent:  # one frame, at its own time
                    self.sent = True
                    self.t += 1
                    return "B", Got("b")
                return super()._wait_frame(names, ms)

        loop, heard = Two(["ok"]), []

        def register():
            if not heard and not loop._listened:
                loop.on_message("B", None, lambda f: heard.append(f.id))

        loop.on_timer(1, register)
        loop.run(10)
        self.assertTrue(heard, "a handler registered in a timer callback was not read in that run()")


class TestHealth(unittest.TestCase):
    def test_every_transition_is_told_once(self):
        m, seen = Ladder(["ok", "ok", "", "BUS-OFF", "BUS-OFF", "ok"]), []
        m.on_health("A", seen.append)
        m.run(750)
        self.assertEqual(seen, ["ok", "BUS-OFF", "ok"])

    def test_a_handler_registered_late_hears_the_current_state(self):
        m, first, late = Ladder(["BUS-OFF"]), [], []
        m.on_health("A", first.append)
        m.run(150)
        m.on_health("A", late.append)
        m.run(150)
        self.assertEqual(first, ["BUS-OFF"])
        self.assertEqual(late, ["BUS-OFF"], "a handler registered after another was told nothing")

    def test_a_nested_run_does_not_leave_an_older_sample(self):
        m, a, b = Ladder(["ok", "BUS-OFF"]), [], []
        nested = []

        def first(s):
            a.append(s)
            if not nested:
                nested.append(True)
                m.run(150)
        m.on_health("A", first)
        m.on_health("A", b.append)
        m.run(350)
        self.assertEqual(b, ["BUS-OFF"], "a false recovery: an older sample after a newer one")

    def test_no_health_handler_starts_past_the_deadline(self):
        m, second = Ladder(["ok"]), []

        def slow(s):
            m.t += 60
        m.on_health("A", slow)
        m.on_health("A", second.append)
        m.run(20)
        self.assertEqual(second, [])


class TestTimers(unittest.TestCase):
    def test_a_day_of_missed_periods_is_skipped_in_one_step(self):
        import time as _time
        m, fired = Ladder([""]), []
        m.on_timer(1, lambda: fired.append(m.t))
        m.t = 86_400_000.0  # a day idle in a REPL
        t0 = _time.monotonic()
        m.run(5)
        self.assertLess(_time.monotonic() - t0, 0.5, "the missed periods were walked one by one")
        self.assertTrue(fired)
        self.assertEqual((m._timers[0].due - 1) % 1, 0)
        self.assertGreater(m._timers[0].due, fired[0])

    def test_a_long_callback_skips_the_points_it_ran_over(self):
        m, fired = Ladder([""]), []

        def slow():
            fired.append(m.t)
            if len(fired) == 1:
                m.t += 35  # ran over three more points of a 10 ms grid
        m.on_timer(10, slow)
        m.run(60)
        self.assertEqual(fired[:2], [10, 50], "the points the callback ran over were fired back to back")

    def test_one_wait_is_at_most_a_second(self):
        m, asked = Ladder([""]), []
        real = m._wait_frame
        m._wait_frame = lambda names, ms: (asked.append(ms), real(names, ms))[1]
        m.run(5000)
        self.assertLessEqual(max(asked), 1000)

    def test_a_duration_that_is_not_a_finite_number_is_refused(self):
        m = Ladder([""])
        for bad in (float("nan"), float("inf"), -1, "10", True, None):
            with self.assertRaises(ValueError, msg=repr(bad)):
                m.run(bad)
        m.run(0)  # zero is a look at nothing, not an error

    def test_a_period_that_is_not_positive_is_refused(self):
        m = Model(1)
        for bad in (0, 0.5, -5, "10", True, None, float("nan"), float("inf")):
            with self.assertRaises(ValueError, msg=repr(bad)):
                m.on_timer(bad, lambda: None)


class TestFrame(unittest.TestCase):
    def test_a_remote_frame_keeps_the_length_it_asks_for(self):
        from blobly.project import frame_of
        f = frame_of(_lib.BbFrame(id=0x123, len=8, rtr=1))
        self.assertTrue(f.rtr)
        self.assertEqual(f.data, b"")
        self.assertEqual(f.length, 8)
        self.assertNotEqual(f, frame_of(_lib.BbFrame(id=0x123, len=0, rtr=1)))


class Queued(EventLoop):
    """Frames already queued on one channel, no clock to speak of."""

    def __init__(self, frames):
        super().__init__()
        self.t, self.frames = 0, list(frames)

    def _now(self):
        return self.t

    def _listen(self, name):
        pass

    def _wait_frame(self, names, ms):
        if self.frames:
            return "A", Got(self.frames.pop(0))
        self.t += ms
        return None

    def _health(self, name):
        return ""


class TestOrder(unittest.TestCase):
    def test_a_nested_run_does_not_overtake_the_frame_being_dispatched(self):
        m, first, second = Queued([1, 2]), [], []

        def outer(f):
            first.append(f.id)
            if f.id == 1:
                m.run(5)  # takes frame 2 up while frame 1 still has a handler to reach
        m.on_message("A", None, outer)
        m.on_message("A", None, lambda f: second.append(f.id))
        m.run(20)
        self.assertEqual(second, [1, 2], "the second handler saw frame 2 before frame 1")
        self.assertEqual(first, [1, 2])


class TestTimeout(unittest.TestCase):
    def test_a_receive_waits_at_most_what_was_asked(self):
        from blobly.project import _ms
        self.assertEqual(_ms(0.01), 0)
        self.assertEqual(_ms(1.99), 1)
        self.assertEqual(_ms(None), -1)
        for bad in (float("nan"), float("inf"), True, "5"):
            with self.assertRaises(TypeError, msg=repr(bad)):
                _ms(bad)


class TestText(unittest.TestCase):
    def test_a_message_cut_inside_a_utf8_sequence_still_reads(self):
        # the library truncates its error buffer at 512 bytes, possibly inside a character
        self.assertEqual(_lib.text(b"cannot load /home/M\xc3"), "cannot load /home/M\ufffd")
        self.assertEqual(_lib.text(None), "")


if __name__ == "__main__":
    unittest.main()
