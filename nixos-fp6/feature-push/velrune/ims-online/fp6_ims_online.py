"""fp6-ims-online: VoLTE follows the modem's Online state (flight mode).

Settings' airplane mode and the Shell's flight toggle set oFono's Modem.Online to
false. That ends the IMS PDN; fp6-ims-pdn and imsd only start with oFono at boot,
so VoLTE stayed down after flight mode until someone recovered it by hand.

  fp6-ims-online watch    (fp6-ims-online-watch.service, long-running, root)
      Follows Online through oFono's PropertyChanged signals (dbus-monitor) and a
      slow poll. Online true -> false, still false DEBOUNCE s later: stop
      fp6-ims-online-recover, imsd and fp6-ims-pdn, and any fp6-ims-recover run or
      retry (those would restart oFono, whose fp6-ofono-online sets Online back to
      true and undoes flight mode), then reset-failed; remember it in STATE_DIR.
      Online false -> true after such a stop: start fp6-ims-online-recover, at most
      MAX_PER_HOUR times an hour. Only ever undoes its own stop: the boot path
      (Online false -> true from fp6-ofono-online) and oFono restarts (the modem
      vanishes) are left alone.

  fp6-ims-online recover  (fp6-ims-online-recover.service, oneshot)
      The manual recovery of 2026-11-10 without the oFono restart (oFono stayed up):
      wait for registration and PS attach, then every RETRY s
      `systemctl reset-failed fp6-ims-pdn imsd; systemctl start fp6-ims-pdn` until the
      PDN stays up (the modem needs 1-2 min; early tries fail with CallFailed
      internal/211 or cm/1110), then `systemctl start imsd`. Past DEADLINE, or with no
      attach, it hands over to fp6-ims-recover@pdn, which restarts oFono with its own
      guards (never during a call, at most every 2 min, 6 an hour). Stops quietly if
      the modem goes offline again. Never touches msm-modem-uim-selection.

Every value is read from the environment so the tests can shrink them.
"""
import json
import os
import select
import subprocess
import sys
import time

PDN = "fp6-ims-pdn.service"
IMSD = "imsd.service"
RECOVER = "fp6-ims-online-recover.service"
ESCALATE = "fp6-ims-recover@pdn.service"
# fp6-ims-recover's transient units (velrune-session.nix: fp6-ims-recover-run-%i,
# fp6-ims-recover.sh: fp6-ims-recover-retry-<trigger>). Globs match loaded units only.
OLD_RECOVERY = ["fp6-ims-recover-run-*.service", "fp6-ims-recover-retry-*.timer",
                "fp6-ims-recover-retry-*.service"]
MONITOR_MATCHES = ["type='signal',interface='org.ofono.Modem',member='PropertyChanged'",
                   "type='signal',interface='org.ofono.Manager'",
                   "type='signal',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.ofono'"]


def env_int(name, default):
    try:
        return int(os.environ.get(name, default))
    except ValueError:
        return default


def log(msg):
    print(msg, file=sys.stderr, flush=True)


# ---- oFono and systemd through busctl / systemctl --------------------------------

def parse_modems(text):
    """busctl --json=short GetModems -> [(path, {property: value})]."""
    out = []
    for path, props in json.loads(text)["data"][0]:
        out.append((path, {k: v.get("data") for k, v in props.items()}))
    return out


def parse_props(text):
    """busctl --json=short ...GetProperties -> {property: value}."""
    return {k: v.get("data") for k, v in json.loads(text)["data"][0].items()}


class Ofono:
    """The first oFono modem, read through busctl (root, system bus)."""

    def _call(self, path, iface, method):
        try:
            r = subprocess.run(["busctl", "--system", "--json=short", "call", "org.ofono",
                                path, iface, method], capture_output=True, text=True, timeout=20)
        except (OSError, subprocess.TimeoutExpired):
            return None
        return r.stdout if r.returncode == 0 else None

    def modem(self):
        text = self._call("/", "org.ofono.Manager", "GetModems")
        if not text:
            return None
        try:
            modems = parse_modems(text)
        except (ValueError, KeyError, IndexError, TypeError):
            return None
        return modems[0] if modems else None

    def online(self):
        """True or False, or None when oFono or the modem is not there."""
        m = self.modem()
        if m is None or "Online" not in m[1]:
            return None
        return bool(m[1]["Online"])

    def _prop(self, iface, name):
        m = self.modem()
        if m is None:
            return None
        text = self._call(m[0], iface, "GetProperties")
        if not text:
            return None
        try:
            return parse_props(text).get(name)
        except (ValueError, KeyError, IndexError, TypeError):
            return None

    def registered(self):
        return self._prop("org.ofono.NetworkRegistration", "Status") in ("registered", "roaming")

    def attached(self):
        return self._prop("org.ofono.ConnectionManager", "Attached") is True


class Systemd:
    def run(self, *args, timeout=None):
        cmd = ["systemctl", *args]
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            log(f"{' '.join(cmd)}: no answer in {timeout} s")
            return False
        except OSError as e:
            log(f"{' '.join(cmd)}: {e}")
            return False
        return r.returncode == 0

    def is_active(self, unit):
        return self.run("is-active", "--quiet", unit, timeout=20)


class Clock:
    def now(self):
        return time.monotonic()

    def sleep(self, s):
        time.sleep(s)


# ---- The watcher's state machine (pure) ------------------------------------------

class Watcher:
    """Turns Online observations into actions: "stop-chain" and "start-recovery"."""

    def __init__(self, stopped=False, debounce=4, max_per_hour=10):
        self.last = None            # last known Online, None after oFono or the modem vanished
        self.offline_since = None   # an online -> offline change waiting out the debounce
        self.stopped = stopped      # this watcher stopped the chain and has not restored it
        self.debounce = debounce
        self.max_per_hour = max_per_hour
        self.starts = []            # times of recent recovery starts
        self.limited = False        # "rate limited" already logged

    @property
    def pending(self):
        return self.offline_since is not None

    def observe(self, online, now):
        actions = []
        if online is None:
            # oFono restarting or no modem: no baseline. A modem that reappears offline is
            # not a person's flight mode (fp6-ofono-online sets it online shortly).
            self.last = None
            self.offline_since = None
            return actions
        if online is False:
            if self.last is True and self.offline_since is None:
                self.offline_since = now
            if (self.offline_since is not None and not self.stopped
                    and now - self.offline_since >= self.debounce):
                actions.append("stop-chain")
                self.stopped = True
                self.offline_since = None
            if self.stopped:
                self.offline_since = None
        else:
            self.offline_since = None
            if self.stopped:
                self.starts = [t for t in self.starts if now - t < 3600]
                if len(self.starts) < self.max_per_hour:
                    actions.append("start-recovery")
                    self.starts.append(now)
                    self.stopped = False
                    self.limited = False
                elif not self.limited:
                    actions.append("rate-limited")
                    self.limited = True
        self.last = online
        return actions


def stop_chain(systemd):
    log("modem offline (flight mode): stopping imsd and the IMS PDN until it is back online")
    systemd.run("stop", RECOVER, timeout=60)
    systemd.run("stop", *OLD_RECOVERY, timeout=60)
    systemd.run("stop", IMSD, PDN, timeout=90)
    systemd.run("reset-failed", PDN, IMSD, timeout=20)


def start_recovery(systemd):
    log("modem back online: starting fp6-ims-online-recover")
    if not systemd.run("start", "--no-block", RECOVER, timeout=20):
        log("fp6-ims-online-recover could not be started (start limit?)")


class StateFile:
    def __init__(self, directory):
        self.path = os.path.join(directory, "stopped")
        os.makedirs(directory, mode=0o700, exist_ok=True)

    def get(self):
        return os.path.exists(self.path)

    def set(self, stopped):
        if stopped:
            with open(self.path, "w") as f:
                f.write("stopped by fp6-ims-online: modem offline\n")
        elif os.path.exists(self.path):
            os.unlink(self.path)


def step(watcher, ofono, systemd, state, clock):
    """One observation and its actions; returns the actions taken."""
    actions = watcher.observe(ofono.online(), clock.now())
    for a in actions:
        if a == "stop-chain":
            state.set(True)
            stop_chain(systemd)
        elif a == "start-recovery":
            start_recovery(systemd)
            state.set(False)
        elif a == "rate-limited":
            log(f"modem back online, but {watcher.max_per_hour} recoveries this hour already: "
                "waiting (fp6-ims-recover still guards imsd and the PDN)")
    return actions


def watch(ofono=None, systemd=None, clock=None):
    ofono, systemd, clock = ofono or Ofono(), systemd or Systemd(), clock or Clock()
    state = StateFile(os.environ.get("STATE_DIR", "/run/fp6-ims-online"))
    watcher = Watcher(stopped=state.get(), debounce=env_int("DEBOUNCE", 4),
                      max_per_hour=env_int("MAX_PER_HOUR", 10))
    poll = env_int("POLL", 30)
    monitor = subprocess.Popen(["dbus-monitor", "--system", *MONITOR_MATCHES],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    log(f"watching oFono Modem.Online (chain stopped by us: {watcher.stopped})")
    while True:
        step(watcher, ofono, systemd, state, clock)
        ready, _, _ = select.select([monitor.stdout], [], [], 1 if watcher.pending else poll)
        if ready and not os.read(monitor.stdout.fileno(), 65536):
            log("dbus-monitor ended; exiting for a restart")
            return 1


# ---- The recovery (fp6-ims-online-recover.service) ---------------------------------

def recover(ofono=None, systemd=None, clock=None):
    ofono, systemd, clock = ofono or Ofono(), systemd or Systemd(), clock or Clock()
    attach_timeout = env_int("ATTACH_TIMEOUT", 300)
    deadline = env_int("DEADLINE", 600)
    retry = env_int("RETRY", 10)
    pdn_timeout = env_int("PDN_START_TIMEOUT", 150)

    def escalate(why):
        log(f"{why}: handing over to fp6-ims-recover@pdn (oFono restart, guarded)")
        systemd.run("start", "--no-block", ESCALATE, timeout=20)
        return 1

    if systemd.is_active(IMSD) and systemd.is_active(PDN):
        log("imsd and the IMS PDN are active: nothing to do")
        return 0
    start = clock.now()
    while not (ofono.registered() and ofono.attached()):
        if ofono.online() is False:
            log("modem offline again: stopping")
            return 0
        if clock.now() - start >= attach_timeout:
            return escalate(f"no registration and PS attach {attach_timeout} s after going online"
                            " (mobile data off or no LTE?)")
        clock.sleep(5)
    log(f"registered and attached {int(clock.now() - start)} s after going online")
    start = clock.now()
    tries = 0
    while True:
        if ofono.online() is False:
            log("modem offline again: stopping")
            return 0
        tries += 1
        systemd.run("reset-failed", PDN, IMSD, timeout=20)
        systemd.run("start", PDN, timeout=pdn_timeout)
        if systemd.is_active(PDN):
            break
        if clock.now() - start >= deadline:
            return escalate(f"IMS PDN still down after {tries} tries in {deadline} s")
        log(f"IMS PDN not up yet (try {tries}); next try in {retry} s")
        clock.sleep(retry)
    log(f"IMS PDN up after {tries} tries; starting imsd")
    systemd.run("start", IMSD, timeout=90)
    if systemd.is_active(IMSD):
        log("imsd started; it registers by itself (journalctl -u imsd: REGISTERED)")
        return 0
    # imsd's own OnFailure (fp6-ims-recover@imsd) takes over from here.
    log("imsd did not start; its OnFailure recovery takes over")
    return 1


def main(argv):
    if len(argv) != 2 or argv[1] not in ("watch", "recover"):
        print("usage: fp6-ims-online watch|recover", file=sys.stderr)
        return 2
    return watch() if argv[1] == "watch" else recover()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
