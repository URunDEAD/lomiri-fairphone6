#!/usr/bin/env python3
"""Tests for velrune-lock-check, run against its test build with a private PAM stack.

usage: [TEST_SHELL=/path/to/sh] test_lock_check.py HELPER PAM_MODULE_DIR

HELPER is the -DVELRUNE_LOCK_TESTING build (it takes --confdir and --active-uid in place
of /etc/pam.d and logind). The stack is velrune-lock's own shape (faillock preauth, the
password check, authfail, authsucc, deny) with pam_exec and pam_deny in place of pam_unix:
the right PIN is 2468, a wrong one gives PAM_AUTH_ERR as pam_unix does. The tally folder is a temporary one the test
user owns, as the root-owned one is for the real helper.
"""
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HELPER, MODULES = sys.argv[1], sys.argv[2]
SH = os.environ.get("TEST_SHELL", "/bin/sh")
UID = os.getuid()


class LockCheck(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = self.tmp.name
        self.tally = os.path.join(t, "tally")
        os.mkdir(self.tally, 0o700)
        conf = os.path.join(t, "pam.d")
        os.mkdir(conf)
        check = os.path.join(t, "check-pin")
        with open(check, "w") as f:
            # Builtins only: pam_exec gives the script no PATH. The token has no newline.
            f.write(f"#!{SH}\nIFS= read -r pw || true\n[ \"$pw\" = 2468 ]\n")
        os.chmod(check, 0o755)
        fl = f"{MODULES}/pam_faillock.so dir={self.tally} deny=10 unlock_time=900"
        # The password check behaves as pam_unix's "[success=1 default=bad]" line does: a
        # right PIN skips authfail, a wrong one is PAM_AUTH_ERR (pam_deny), not the
        # PAM_SYSTEM_ERR pam_exec itself reports for a failed command.
        with open(os.path.join(conf, "velrune-lock"), "w") as f:
            f.write(f"auth required {fl} preauth\n"
                    f"auth [success=2 default=ignore] {MODULES}/pam_exec.so quiet expose_authtok {check}\n"
                    f"auth [default=bad] {MODULES}/pam_deny.so\n"
                    f"auth [default=die] {fl} authfail\n"
                    f"auth sufficient {fl} authsucc\n"
                    f"auth required {MODULES}/pam_deny.so\n")
        self.conf = conf
        self.args = ["--dir", self.tally, "--lock-file", os.path.join(t, "attempt.lock"),
                     "--deny", "10", "--unlock-time", "900", "--confdir", conf]

    def tearDown(self):
        self.tmp.cleanup()

    def stack(self, text):
        """Replace the PAM stack of the service."""
        with open(os.path.join(self.conf, "velrune-lock"), "w") as f:
            f.write(text)

    def ask(self, payload, active_uid=UID, min_fail_ms=2000, shutdown=False):
        """One connection: the helper gets the socket as stdin/stdout, like Accept=yes."""
        ours, theirs = socket.socketpair()
        proc = subprocess.Popen([HELPER, *self.args, "--active-uid", str(active_uid),
                                 "--min-fail-ms", str(min_fail_ms)],
                                stdin=theirs, stdout=theirs, stderr=subprocess.DEVNULL)
        theirs.close()
        if payload:
            try:
                ours.sendall(payload)
            except (BrokenPipeError, ConnectionResetError):
                pass  # the helper may answer (a refusal) before it reads anything
        if shutdown:
            ours.shutdown(socket.SHUT_WR)
        answer = b""
        while not answer.endswith(b"\n"):
            chunk = ours.recv(64)
            if not chunk:
                break
            answer += chunk
        ours.close()
        proc.wait(timeout=30)
        return answer.decode()

    def test_right_pin(self):
        self.assertEqual(self.ask(b"2468\n", min_fail_ms=0), "ok\n")

    def test_length_framed_request(self):
        self.assertEqual(self.ask(b"2468", shutdown=True, min_fail_ms=0), "ok\n")

    def test_wrong_pin_counts_down(self):
        self.assertEqual(self.ask(b"1111\n", min_fail_ms=0), "fail 9\n")
        self.assertEqual(self.ask(b"1112\n", min_fail_ms=0), "fail 8\n")

    def test_lockout_after_ten_is_reported_as_locked(self):
        for i in range(9):
            self.assertEqual(self.ask(b"0000\n", min_fail_ms=0), f"fail {9 - i}\n")
        tenth = self.ask(b"0000\n", min_fail_ms=0)
        self.assertTrue(tenth.startswith("locked "), tenth)
        self.assertTrue(880 <= int(tenth.split()[1]) <= 901, tenth)
        # The right PIN is refused while locked, and says so.
        after = self.ask(b"2468\n", min_fail_ms=0)
        self.assertTrue(after.startswith("locked "), after)

    def test_success_resets_the_count(self):
        for _ in range(3):
            self.ask(b"0000\n", min_fail_ms=0)
        self.assertEqual(self.ask(b"2468\n", min_fail_ms=0), "ok\n")
        self.assertEqual(self.ask(b"0000\n", min_fail_ms=0), "fail 9\n")

    def test_wrong_uid_refused_and_nothing_counted(self):
        self.assertEqual(self.ask(b"2468\n", active_uid=UID + 1), "error caller\n")
        self.assertEqual(os.listdir(self.tally), [])

    def test_bad_requests(self):
        self.assertEqual(self.ask(b"x" * 257 + b"\n"), "error request\n")
        self.assertEqual(self.ask(b"\n"), "error request\n")
        self.assertEqual(self.ask(b"24\x0068\n"), "error request\n")
        self.assertEqual(self.ask(b"2468\nmore\n"), "error request\n")
        self.assertEqual(os.listdir(self.tally), [])

    def test_silent_client_is_dropped_after_three_seconds(self):
        start = time.monotonic()
        self.assertEqual(self.ask(b""), "error request\n")
        elapsed = time.monotonic() - start
        self.assertGreaterEqual(elapsed, 2.5)
        self.assertLess(elapsed, 4.5, "the request timeout is 3 s")

    def test_pam_system_failure_is_an_error_not_a_wrong_pin(self):
        # A module that cannot be loaded: pam_authenticate fails with something other than
        # PAM_AUTH_ERR. That is not a wrong PIN and must not read like one.
        self.stack(f"auth required {self.tmp.name}/missing/pam_missing.so\n")
        self.assertEqual(self.ask(b"2468\n", min_fail_ms=0), "error system\n")

    def test_missing_service_is_an_error(self):
        os.unlink(os.path.join(self.conf, "velrune-lock"))
        self.assertEqual(self.ask(b"2468\n", min_fail_ms=0), "error system\n")

    def test_failed_attempt_takes_two_seconds_success_does_not(self):
        start = time.monotonic()
        self.assertEqual(self.ask(b"0000\n"), "fail 9\n")
        self.assertGreaterEqual(time.monotonic() - start, 2.0)
        start = time.monotonic()
        self.assertEqual(self.ask(b"2468\n"), "ok\n")
        self.assertLess(time.monotonic() - start, 1.5)

    def test_parallel_connections_are_rate_limited(self):
        answers = []
        def one():
            answers.append(self.ask(b"0000\n"))
        threads = [threading.Thread(target=one) for _ in range(4)]
        start = time.monotonic()
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        elapsed = time.monotonic() - start
        self.assertEqual(sorted(answers), ["fail 6\n", "fail 7\n", "fail 8\n", "fail 9\n"])
        self.assertGreaterEqual(elapsed, 8.0, "4 parallel failures must take 4 x 2 s")


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0], "-v"])
