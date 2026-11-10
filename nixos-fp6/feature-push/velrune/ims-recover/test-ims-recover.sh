#!/usr/bin/env bash
# Tests for fp6-ims-recover with stand-ins for systemctl, systemd-run, busctl, logger,
# timeout and sleep on PATH (nothing really sleeps).
# usage: test-ims-recover.sh SCRIPT
set -u
script=$1
fails=0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat > "$work/bin/systemctl" <<'S'
echo "systemctl $*" >> "$LOG"
case "$*" in
  "is-active --quiet imsd.service") [ "${IMSD_ACTIVE:-no}" = yes ] ;;
  "start fp6-ims-pdn.service")
    n=$(( $(cat "$WORK/pdn-tries" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$WORK/pdn-tries"
    [ "$n" -ge "${PDN_OK_AFTER:-1}" ] ;;
  *) exit 0 ;;
esac
S
cat > "$work/bin/busctl" <<'S'
case "$*" in
  *GetModems*) echo 'a(oa{sv}) 1 "/qrtrsoc_0" 0' ;;
  *GetCalls*) if [ "${CALLS:-0}" = 0 ]; then echo 'a(oa{sv}) 0'; else echo 'a(oa{sv}) 1 "/qrtrsoc_0/voicecall01" 1 "State" s "active"'; fi ;;
  *NetworkRegistration*)
    echo "busctl registration" >> "$LOG"
    n=$(( $(cat "$WORK/reg-tries" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$WORK/reg-tries"
    if [ "${REG_AFTER:-1}" != never ] && [ "$n" -ge "${REG_AFTER:-1}" ]; then
      echo 'a{sv} 2 "Mode" s "auto" "Status" s "registered"'
    else
      echo 'a{sv} 2 "Mode" s "auto" "Status" s "searching"'
    fi ;;
esac
S
printf 'echo "logger $*" >> "$LOG"\n' > "$work/bin/logger"
printf 'echo "systemd-run $*" >> "$LOG"\n' > "$work/bin/systemd-run"
printf 'echo "sleep $*" >> "$LOG"\n' > "$work/bin/sleep"
printf 'shift; exec "$@"\n' > "$work/bin/timeout"
# The stand-ins run with this bash (a Nix build has no /usr/bin/env).
for f in "$work/bin/"*; do { echo "#!$(command -v bash)"; cat "$f"; } > "$f.new"; mv "$f.new" "$f"; done
chmod +x "$work/bin/"*

run() { # trigger [env...]: fresh log and counters, keeps the state dir
  local trigger=$1; shift
  : > "$work/log"; rm -f "$work/pdn-tries" "$work/reg-tries"
  env PATH="$work/bin:$PATH" LOG="$work/log" WORK="$work" STATE_DIR="$work/state" "$@" \
    bash "$script" "$trigger" >/dev/null 2>&1
}
expect() { # description, pattern, present(1)/absent(0)
  if grep -q -- "$2" "$work/log"; then got=1; else got=0; fi
  if [ "$got" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; sed 's/^/     | /' "$work/log"; fails=$((fails+1)); fi
}
before() { # description, pattern A, pattern B: A's first line comes before B's
  local a b
  a=$(grep -n -m1 -- "$2" "$work/log" | cut -d: -f1); b=$(grep -n -m1 -- "$3" "$work/log" | cut -d: -f1)
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then echo "ok   $1"; else echo "FAIL $1 ($a, $b)"; sed 's/^/     | /' "$work/log"; fails=$((fails+1)); fi
}
fresh() { rm -rf "$work/state"; }

fresh; run imsd IMSD_ACTIVE=yes NOW=1000
expect "imsd active: nothing is stopped" "systemctl stop" 0
expect "imsd active: nothing is restarted or started" "systemctl \(restart\|start\)" 0

fresh; run pdn NOW=1000 REG_AFTER=3
expect "PDN failed: oFono, online and data-on restart" "systemctl restart ofono.service fp6-ofono-online.service fp6-ofono-data-on.service" 1
before "PDN failed: PDN and imsd stopped before oFono restarts" "systemctl stop imsd.service fp6-ims-pdn.service" "systemctl restart ofono.service"
before "PDN failed: waits for registration before the PDN" "busctl registration" "systemctl start fp6-ims-pdn.service"
expect "PDN failed: polled registration until registered" "logger.*registered 10 s after" 1
before "PDN failed: settles 30 s after registration" "sleep 30" "systemctl start fp6-ims-pdn.service"
before "PDN failed: reset-failed before the PDN start" "systemctl reset-failed fp6-ims-pdn.service imsd.service" "systemctl start fp6-ims-pdn.service"
before "PDN failed: imsd starts after the PDN" "systemctl start fp6-ims-pdn.service" "systemctl start --no-block imsd.service"

fresh; run pdn NOW=1000 PDN_OK_AFTER=3
expect "PDN retried with backoff: two waits" "logger.*next try in 10 s" 1
expect "PDN up on the third try: imsd started" "systemctl start --no-block imsd.service" 1
expect "PDN up: no retry scheduled" "systemd-run" 0

fresh; run pdn NOW=1000 PDN_OK_AFTER=99
expect "PDN never up: imsd not started" "start --no-block imsd.service" 0
expect "PDN never up: a retry is scheduled" "systemd-run --on-active=600 --unit=fp6-ims-recover-retry-pdn" 1
expect "PDN never up: about 5 min of backoff (60 s waits)" "sleep 60" 1

fresh; run pdn NOW=1000 REG_AFTER=never REG_TIMEOUT=20
expect "no registration: the PDN is not started" "systemctl start fp6-ims-pdn.service" 0
expect "no registration: a retry is scheduled" "systemd-run --on-active=300" 1

fresh; run pdn NOW=1000; run pdn NOW=1060
expect "oFono restarted under 2 min ago: not again" "restart ofono.service" 0
expect "oFono guard: a retry is scheduled when the guard expires" "systemd-run --on-active=65 --unit=fp6-ims-recover-retry-pdn --collect systemctl start fp6-ims-recover@pdn.service" 1

fresh; run pdn CALLS=1 NOW=1000
expect "a call in oFono: oFono is not restarted" "restart ofono.service" 0
expect "a call in oFono: logged" "logger.*call" 1
expect "a call in oFono: retried later" "systemd-run --on-active=120" 1

fresh; run imsd NOW=1000
expect "first imsd failure: oFono is not restarted" "restart ofono.service" 0
before "first imsd failure: PDN and imsd stopped, then the PDN started" "systemctl stop imsd.service fp6-ims-pdn.service" "systemctl start fp6-ims-pdn.service"
expect "first imsd failure: imsd started" "systemctl start --no-block imsd.service" 1
run imsd NOW=1300
expect "second imsd failure within 15 min: escalates to oFono" "systemctl restart ofono.service" 1

fresh; run imsd NOW=1000; run imsd NOW=2000
expect "imsd failures 16 min apart: no escalation" "restart ofono.service" 0

if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
