#!/usr/bin/env bash
# Tests for fp6-ims-recover with stand-ins for systemctl, busctl and logger on PATH.
# usage: test-ims-recover.sh SCRIPT
set -u
script=$1
fails=0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat > "$work/bin/systemctl" <<'S'
#!/usr/bin/env bash
echo "systemctl $*" >> "$LOG"
case "$*" in
  "is-active --quiet imsd.service") [ "${IMSD_ACTIVE:-no}" = yes ] ;;
  *) exit 0 ;;
esac
S
cat > "$work/bin/busctl" <<'S'
#!/usr/bin/env bash
case "$*" in
  *GetModems*) echo 'a(oa{sv}) 1 "/qrtrsoc_0" 0' ;;
  *GetCalls*) if [ "${CALLS:-0}" = 0 ]; then echo 'a(oa{sv}) 0'; else echo 'a(oa{sv}) 1 "/qrtrsoc_0/voicecall01" 1 "State" s "active"'; fi ;;
esac
S
cat > "$work/bin/logger" <<'S'
#!/usr/bin/env bash
echo "logger $*" >> "$LOG"
S
# The stand-ins run with this bash (a Nix build has no /usr/bin/env).
sed -i "1s|.*|#!$(command -v bash)|" "$work/bin/"*
chmod +x "$work/bin/"*

run() { # name trigger [env...]; runs the script with a fresh log, keeps the state dir
  local trigger=$1; shift
  : > "$work/log"
  env PATH="$work/bin:$PATH" LOG="$work/log" STATE_DIR="$work/state" "$@" bash "$script" "$trigger" >/dev/null 2>&1
  echo $?
}
expect() { # description, grep pattern, present(1)/absent(0)
  if grep -q -- "$2" "$work/log"; then got=1; else got=0; fi
  if [ "$got" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "---- log:"; cat "$work/log"; echo "----"; fails=$((fails+1)); fi
}
fresh() { rm -rf "$work/state"; }

fresh; run imsd IMSD_ACTIVE=yes NOW=1000 >/dev/null
expect "imsd active: nothing is restarted" "systemctl restart" 0
expect "imsd active: no start either" "systemctl start" 0

fresh; run imsd NOW=1000 >/dev/null
expect "first imsd failure: the PDN is restarted" "systemctl restart fp6-ims-pdn.service" 1
expect "first imsd failure: oFono is not restarted" "restart ofono.service" 0
expect "first imsd failure: imsd is started" "systemctl start imsd.service" 1
expect "first imsd failure: failed states are cleared" "systemctl reset-failed fp6-ims-pdn.service imsd.service" 1

run imsd NOW=1300 >/dev/null
expect "second imsd failure within 15 min: escalates to oFono" "systemctl restart ofono.service fp6-ofono-online.service fp6-ofono-data-on.service" 1
expect "escalation: then PDN and imsd are started" "systemctl start fp6-ims-pdn.service imsd.service" 1

fresh; run pdn NOW=1000 >/dev/null
expect "PDN failed past its start limit: oFono, online and data-on restart" "systemctl restart ofono.service fp6-ofono-online.service fp6-ofono-data-on.service" 1
expect "PDN failed: reset-failed before the start" "systemctl reset-failed fp6-ims-pdn.service imsd.service" 1
expect "PDN failed: PDN and imsd started" "systemctl start fp6-ims-pdn.service imsd.service" 1

run pdn NOW=1060 >/dev/null
expect "oFono restarts at most every 2 min" "restart ofono.service" 0
expect "rate-limited attempt is logged" "logger.*oFono was restarted" 1

fresh; run pdn CALLS=1 NOW=1000 >/dev/null
expect "a call in oFono: oFono is not restarted" "restart ofono.service" 0
expect "a call in oFono: logged" "logger.*call" 1

fresh; run imsd NOW=1000 >/dev/null; run imsd NOW=2000 >/dev/null
expect "imsd failures 16 min apart: no escalation" "restart ofono.service" 0

if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
