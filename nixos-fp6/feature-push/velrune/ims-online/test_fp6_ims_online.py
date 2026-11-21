"""Tests for fp6_ims_online with a fake oFono, a fake systemd and a fake clock.

    python3 -m unittest -v test_fp6_ims_online
"""
import os
import tempfile
import unittest

import fp6_ims_online as m


class FakeClock:
    def __init__(self):
        self.t = 1000.0
        self.slept = []

    def now(self):
        return self.t

    def sleep(self, s):
        self.slept.append(s)
        self.t += s


class FakeOfono:
    """Online plus registration/attach, optionally scripted over time."""

    def __init__(self, clock, online=True, attach_after=0, offline_after=None):
        self.clock = clock
        self._online = online
        self.attach_at = clock.t + attach_after if attach_after is not None else None
        self.offline_at = clock.t + offline_after if offline_after is not None else None

    def online(self):
        if self.offline_at is not None and self.clock.t >= self.offline_at:
            return False
        return self._online

    def registered(self):
        return self.online() is True and self.attach_at is not None and self.clock.t >= self.attach_at

    def attached(self):
        return self.registered()


class FakeSystemd:
    """Records calls. The PDN comes up on start number `pdn_ok_on` (None: never)."""

    def __init__(self, clock, pdn_ok_on=1, imsd_ok=True, active=()):
        self.clock = clock
        self.calls = []
        self.active = set(active)
        self.pdn_starts = 0
        self.pdn_ok_on = pdn_ok_on
        self.imsd_ok = imsd_ok

    def run(self, *args, timeout=None):
        self.calls.append(" ".join(args))
        if args[0] == "start" and args[1] == m.PDN:
            self.pdn_starts += 1
            if self.pdn_ok_on is not None and self.pdn_starts >= self.pdn_ok_on:
                self.active.add(m.PDN)
                return True
            return False
        if args[0] == "start" and args[1] == m.IMSD:
            if self.imsd_ok:
                self.active.add(m.IMSD)
            return self.imsd_ok
        if args[0] == "stop":
            self.active.difference_update(args[1:])
        return True

    def is_active(self, unit):
        return unit in self.active

    def index(self, prefix):
        for i, c in enumerate(self.calls):
            if c.startswith(prefix):
                return i
        return -1


class WatcherTests(unittest.TestCase):
    def test_boot_offline_then_online_does_nothing(self):
        # fp6-ofono-online brings the modem online at boot; the boot path owns the chain.
        w = m.Watcher()
        self.assertEqual(w.observe(None, 0), [])
        self.assertEqual(w.observe(False, 1), [])
        self.assertEqual(w.observe(False, 30), [])
        self.assertEqual(w.observe(True, 31), [])

    def test_flight_mode_stops_after_debounce_then_recovers(self):
        w = m.Watcher(debounce=4)
        w.observe(True, 0)
        self.assertEqual(w.observe(False, 10), [])
        self.assertTrue(w.pending)
        self.assertEqual(w.observe(False, 12), [])
        self.assertEqual(w.observe(False, 14), ["stop-chain"])
        self.assertEqual(w.observe(False, 50), [])           # idempotent while offline
        self.assertEqual(w.observe(True, 60), ["start-recovery"])
        self.assertEqual(w.observe(True, 90), [])            # once per offline period

    def test_offline_blip_is_ignored(self):
        w = m.Watcher(debounce=4)
        w.observe(True, 0)
        self.assertEqual(w.observe(False, 1), [])
        self.assertEqual(w.observe(True, 3), [])
        self.assertEqual(w.observe(False, 100), [])
        self.assertFalse(w.observe(False, 103))
        self.assertFalse(w.stopped)

    def test_ofono_restart_is_left_to_fp6_ims_recover(self):
        # The modem vanishes and comes back offline, then online (fp6-ofono-online).
        w = m.Watcher(debounce=4)
        w.observe(True, 0)
        self.assertEqual(w.observe(None, 1), [])
        self.assertEqual(w.observe(False, 2), [])
        self.assertEqual(w.observe(False, 20), [])
        self.assertEqual(w.observe(True, 21), [])

    def test_vanishing_modem_cancels_a_pending_stop(self):
        w = m.Watcher(debounce=4)
        w.observe(True, 0)
        w.observe(False, 1)
        w.observe(None, 2)
        self.assertEqual(w.observe(False, 10), [])

    def test_restarted_watcher_still_restores_what_it_stopped(self):
        w = m.Watcher(stopped=True)
        self.assertEqual(w.observe(False, 0), [])
        self.assertEqual(w.observe(True, 5), ["start-recovery"])

    def test_oFono_restart_during_flight_mode_still_restores(self):
        # Something restarted oFono while the chain was stopped; it came back online.
        w = m.Watcher(debounce=4)
        w.observe(True, 0)
        w.observe(False, 1)
        w.observe(False, 5)
        self.assertTrue(w.stopped)
        w.observe(None, 6)
        w.observe(False, 7)
        self.assertEqual(w.observe(True, 8), ["start-recovery"])

    def test_rate_limited_per_hour_then_resumes(self):
        w = m.Watcher(debounce=0, max_per_hour=2)
        t = 0
        for _ in range(2):
            w.observe(True, t)
            w.observe(False, t + 1)
            self.assertEqual(w.observe(True, t + 2), ["start-recovery"])
            t += 10
        w.observe(False, t + 1)
        self.assertEqual(w.observe(True, t + 2), ["rate-limited"])
        self.assertEqual(w.observe(True, t + 3), [])          # logged once
        self.assertTrue(w.stopped)
        self.assertEqual(w.observe(True, 3603), ["start-recovery"])


class StepTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.state = m.StateFile(self.dir.name)
        self.clock = FakeClock()

    def tearDown(self):
        self.dir.cleanup()

    def test_stop_chain_order_and_state(self):
        sd = FakeSystemd(self.clock, active={m.PDN, m.IMSD})
        of = FakeOfono(self.clock)
        w = m.Watcher(debounce=4)
        m.step(w, of, sd, self.state, self.clock)
        of._online = False
        m.step(w, of, sd, self.state, self.clock)
        self.clock.t += 5
        self.assertEqual(m.step(w, of, sd, self.state, self.clock), ["stop-chain"])
        self.assertTrue(self.state.get())
        self.assertFalse(sd.is_active(m.PDN) or sd.is_active(m.IMSD))
        # The recovery unit first, then fp6-ims-recover's runs and retries (they would
        # restart oFono and undo flight mode), then imsd and the PDN, then reset-failed.
        order = [sd.index("stop " + m.RECOVER), sd.index("stop fp6-ims-recover-run-*"),
                 sd.index("stop imsd.service fp6-ims-pdn.service"),
                 sd.index("reset-failed fp6-ims-pdn.service imsd.service")]
        self.assertEqual(order, sorted(order))
        self.assertNotIn(-1, order)
        self.assertIn("fp6-ims-recover-retry-*.timer", sd.calls[order[1]])
        self.assertFalse(any("msm-modem-uim-selection" in c or "ofono" in c.split(".")[0] for c in sd.calls))
        # Back online: the recovery unit starts, without blocking, and the state clears.
        of._online = True
        self.assertEqual(m.step(w, of, sd, self.state, self.clock), ["start-recovery"])
        self.assertIn("start --no-block " + m.RECOVER, sd.calls)
        self.assertFalse(self.state.get())


class RecoverTests(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()
        os.environ.update({"ATTACH_TIMEOUT": "300", "DEADLINE": "600", "RETRY": "10"})

    def test_waits_for_attach_then_retries_pdn_every_10s_then_imsd(self):
        of = FakeOfono(self.clock, attach_after=40)
        sd = FakeSystemd(self.clock, pdn_ok_on=4)       # internal/211, cm/1110 ... then up
        self.assertEqual(m.recover(of, sd, self.clock), 0)
        self.assertEqual(sd.pdn_starts, 4)
        self.assertEqual(self.clock.slept[:8], [5] * 8)  # attach wait
        self.assertEqual(self.clock.slept[8:], [10, 10, 10])
        # Every try: reset-failed first, then start (the runbook's loop).
        tries = [i for i, c in enumerate(sd.calls) if c == "start " + m.PDN]
        for i in tries:
            self.assertEqual(sd.calls[i - 1], "reset-failed fp6-ims-pdn.service imsd.service")
        self.assertGreater(sd.index("start " + m.IMSD), tries[-1])
        self.assertTrue(sd.is_active(m.IMSD))
        self.assertEqual(sd.index("start --no-block " + m.ESCALATE), -1)

    def test_nothing_when_imsd_and_pdn_active(self):
        sd = FakeSystemd(self.clock, active={m.PDN, m.IMSD})
        self.assertEqual(m.recover(FakeOfono(self.clock), sd, self.clock), 0)
        self.assertEqual([c for c in sd.calls if not c.startswith("is-active")], [])

    def test_pdn_never_up_escalates_after_deadline(self):
        of = FakeOfono(self.clock)
        sd = FakeSystemd(self.clock, pdn_ok_on=None)
        self.assertEqual(m.recover(of, sd, self.clock), 1)
        self.assertIn("start --no-block " + m.ESCALATE, sd.calls)
        self.assertEqual(sd.index("start " + m.IMSD), -1)
        self.assertGreaterEqual(sd.pdn_starts, 60)
        self.assertLessEqual(sd.pdn_starts, 62)

    def test_no_attach_escalates(self):
        of = FakeOfono(self.clock, attach_after=None)
        sd = FakeSystemd(self.clock)
        self.assertEqual(m.recover(of, sd, self.clock), 1)
        self.assertEqual(sd.pdn_starts, 0)
        self.assertIn("start --no-block " + m.ESCALATE, sd.calls)

    def test_offline_again_stops_quietly(self):
        of = FakeOfono(self.clock, offline_after=25)
        sd = FakeSystemd(self.clock, pdn_ok_on=None)
        self.assertEqual(m.recover(of, sd, self.clock), 0)
        self.assertNotIn("start --no-block " + m.ESCALATE, sd.calls)
        self.assertLessEqual(sd.pdn_starts, 3)

    def test_imsd_failure_is_left_to_its_onfailure(self):
        of = FakeOfono(self.clock)
        sd = FakeSystemd(self.clock, imsd_ok=False)
        self.assertEqual(m.recover(of, sd, self.clock), 1)
        self.assertNotIn("start --no-block " + m.ESCALATE, sd.calls)


class ParseTests(unittest.TestCase):
    MODEMS = ('{"type":"a(oa{sv})","data":[[["/qrtrsoc_0",{"Powered":{"type":"b","data":true},'
              '"Online":{"type":"b","data":false},"Type":{"type":"s","data":"hardware"}}]]]}')

    def test_get_modems(self):
        self.assertEqual(m.parse_modems(self.MODEMS),
                         [("/qrtrsoc_0", {"Powered": True, "Online": False, "Type": "hardware"})])
        self.assertEqual(m.parse_modems('{"type":"a(oa{sv})","data":[[]]}'), [])

    def test_get_properties(self):
        self.assertEqual(m.parse_props('{"type":"a{sv}","data":[{"Attached":{"type":"b","data":true},'
                                       '"Status":{"type":"s","data":"registered"}}]}'),
                         {"Attached": True, "Status": "registered"})


if __name__ == "__main__":
    unittest.main()
