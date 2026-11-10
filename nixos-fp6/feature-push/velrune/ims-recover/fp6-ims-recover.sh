# fp6-ims-recover TRIGGER: bring VoLTE back after imsd or the IMS PDN failed for good.
#
# TRIGGER is the unit whose OnFailure= started this (fp6-ims-recover@<trigger>):
#   imsd  imsd failed past its start limit (registration keeps failing). First: a fresh
#         PDN, then imsd. A second imsd failure within ESCALATE_WINDOW escalates.
#   pdn   fp6-ims-pdn failed past its start limit: StartNetwork has already failed
#         about 20 times, which a PDN restart does not cure. Escalate at once.
# Escalation is what fixed it by hand on 2026-11-10 (CallFailed internal/211, cm/1110):
# restart oFono, fp6-ofono-online and fp6-ofono-data-on, clear the failed states, start
# the PDN and imsd.
#
# Never while VoLTE works or a call is up: nothing is done when imsd is active, and oFono
# is not restarted while it lists a voice call. oFono is restarted at most once per
# OFONO_MIN_INTERVAL. The unit's own start limit bounds everything else.
#
# PATH provides systemctl, busctl, logger, grep, head, tr, cat, mkdir, date. STATE_DIR keeps
# the times of the last recovery and the last oFono restart (default /run/fp6-ims-recover).
set -u
trigger=${1:-imsd}
state=${STATE_DIR:-/run/fp6-ims-recover}
now=${NOW:-$(date +%s)}
escalate_window=${ESCALATE_WINDOW:-900}
ofono_min_interval=${OFONO_MIN_INTERVAL:-120}
mkdir -p "$state"

log() { logger -p user.warning -t fp6-ims-recover "$*"; }
since() { # seconds since the time stored in a state file; large if none
  local t
  t=$(cat "$state/$1" 2>/dev/null) || t=0
  echo $((now - ${t:-0}))
}

if systemctl is-active --quiet imsd.service; then
  log "imsd is active ($trigger triggered): nothing to recover"
  exit 0
fi

calls_up() {
  local modem calls
  modem=$(busctl --system call org.ofono / org.ofono.Manager GetModems 2>/dev/null \
    | grep -o '"/[A-Za-z0-9_]*"' | head -1 | tr -d '"')
  [ -n "$modem" ] || return 1
  calls=$(busctl --system call org.ofono "$modem" org.ofono.VoiceCallManager GetCalls 2>/dev/null) || return 1
  case "$calls" in
    "a(oa{sv}) 0"*) return 1 ;;
    *) return 0 ;;
  esac
}

level=pdn
if [ "$trigger" = pdn ] || [ "$(since last-recover)" -lt "$escalate_window" ]; then
  level=ofono
fi
echo "$now" > "$state/last-recover"

if [ "$level" = ofono ]; then
  if calls_up; then
    log "$trigger failed, but oFono lists a call: not restarting oFono now"
    exit 1
  fi
  if [ "$(since last-ofono)" -lt "$ofono_min_interval" ]; then
    log "$trigger failed again, but oFono was restarted less than ${ofono_min_interval}s ago: waiting"
    exit 1
  fi
  echo "$now" > "$state/last-ofono"
  log "$trigger failed: restarting oFono, fp6-ofono-online and fp6-ofono-data-on, then the IMS PDN and imsd"
  systemctl restart ofono.service fp6-ofono-online.service fp6-ofono-data-on.service \
    || log "oFono restart reported a failure; starting the IMS PDN anyway"
  systemctl reset-failed fp6-ims-pdn.service imsd.service
  systemctl start fp6-ims-pdn.service imsd.service
  exit $?
fi

log "$trigger failed: restarting the IMS PDN, then imsd"
systemctl reset-failed fp6-ims-pdn.service imsd.service
systemctl restart fp6-ims-pdn.service || log "fp6-ims-pdn restart reported a failure; starting imsd anyway"
systemctl start imsd.service
