# fp6-ims-recover TRIGGER: bring VoLTE back after imsd or the IMS PDN failed for good.
#
# Started detached (fp6-ims-recover@<trigger> runs it with systemd-run as its own unit),
# never inside the OnFailure= job: doing the restarts from there met "Requested
# transaction contradicts existing jobs: Resource deadlock avoided" (2026-11-10 12:04).
#
# TRIGGER:
#   imsd  imsd failed past its start limit. First: a fresh PDN, then imsd. A second
#         imsd failure within ESCALATE_WINDOW escalates.
#   pdn   fp6-ims-pdn failed past its start limit (StartNetwork failed ~20 times).
#         Escalate at once.
# Escalation (what worked by hand at 11:39 and 12:14): stop the PDN and imsd, restart
# oFono, fp6-ofono-online and fp6-ofono-data-on, wait for NetworkRegistration
# "registered" (or roaming) and SETTLE seconds more (the modem needs 30-60 s after an
# oFono restart; earlier StartNetwork fails internal/211, then cm/1110), then start the
# PDN with backoff (PDN_BACKOFF, about 5 min in all), then imsd.
#
# Never in flight mode: with the modem offline (oFono Modem.Online false) nothing is done,
# because restarting oFono would bring the modem online (fp6-ofono-online) and undo it;
# fp6-ims-online brings VoLTE back when the modem is online again.
# Never while VoLTE works or a call is up: nothing is done when imsd is active, and oFono
# is not restarted while it lists a voice call. oFono at most once per OFONO_MIN_INTERVAL;
# when that or a call holds an escalation back, a retry is scheduled (transient timer)
# instead of giving up.
#
# PATH provides systemctl, systemd-run, busctl, logger, grep, head, tr, cat, mkdir, date,
# sleep, timeout. STATE_DIR keeps the times of the last recovery and oFono restart.
set -u
trigger=${1:-imsd}
state=${STATE_DIR:-/run/fp6-ims-recover}
now=${NOW:-$(date +%s)}
escalate_window=${ESCALATE_WINDOW:-900}
ofono_min_interval=${OFONO_MIN_INTERVAL:-120}
settle=${SETTLE:-30}
reg_timeout=${REG_TIMEOUT:-180}
pdn_backoff=${PDN_BACKOFF:-10 10 20 20 30 30 60 60 60}
pdn_start_timeout=${PDN_START_TIMEOUT:-120}
mkdir -p "$state"

log() { logger -p user.warning -t fp6-ims-recover "$*"; }
since() { # seconds since the time stored in a state file; large if none
  local t
  t=$(cat "$state/$1" 2>/dev/null) || t=0
  echo $((now - ${t:-0}))
}
retry_in() { # schedule fp6-ims-recover@TRIGGER again in $1 seconds (one pending retry at most)
  systemd-run --on-active="$1" --unit="fp6-ims-recover-retry-$trigger" --collect \
    systemctl start "fp6-ims-recover@$trigger.service" >/dev/null 2>&1 \
    && log "retry of $trigger scheduled in $1 s" \
    || log "a retry of $trigger is already scheduled"
}
modem() {
  busctl --system call org.ofono / org.ofono.Manager GetModems 2>/dev/null \
    | grep -o '"/[A-Za-z0-9_]*"' | head -1 | tr -d '"'
}
calls_up() {
  local m calls
  m=$(modem)
  [ -n "$m" ] || return 1
  calls=$(busctl --system call org.ofono "$m" org.ofono.VoiceCallManager GetCalls 2>/dev/null) || return 1
  case "$calls" in
    "a(oa{sv}) 0"*) return 1 ;;
    *) return 0 ;;
  esac
}
offline() { # the modem says Online false (flight mode)
  local m props
  m=$(modem)
  [ -n "$m" ] || return 1
  props=$(busctl --system call org.ofono "$m" org.ofono.Modem GetProperties 2>/dev/null) || return 1
  printf '%s' "$props" | grep -q '"Online" b false'
}
registered() {
  local m props
  m=$(modem)
  [ -n "$m" ] || return 1
  props=$(busctl --system call org.ofono "$m" org.ofono.NetworkRegistration GetProperties 2>/dev/null) || return 1
  printf '%s' "$props" | grep -Eq '"Status" s "(registered|roaming)"'
}
start_pdn_with_backoff() {
  local wait
  for wait in $pdn_backoff; do
    systemctl reset-failed fp6-ims-pdn.service imsd.service
    if timeout "$pdn_start_timeout" systemctl start fp6-ims-pdn.service; then
      log "IMS PDN up; starting imsd"
      systemctl start --no-block imsd.service
      return 0
    fi
    log "IMS PDN did not come up; next try in ${wait} s"
    sleep "$wait"
  done
  return 1
}

if systemctl is-active --quiet imsd.service; then
  log "imsd is active ($trigger triggered): nothing to recover"
  exit 0
fi

if offline; then
  log "the modem is offline (flight mode; $trigger triggered): nothing to recover, fp6-ims-online restarts VoLTE when it is back online"
  exit 0
fi

level=pdn
if [ "$trigger" = pdn ] || [ "$(since last-recover)" -lt "$escalate_window" ]; then
  level=ofono
fi
echo "$now" > "$state/last-recover"

if [ "$level" = ofono ]; then
  if calls_up; then
    log "$trigger failed, but oFono lists a call: not restarting oFono now"
    retry_in 120
    exit 1
  fi
  left=$((ofono_min_interval - $(since last-ofono)))
  if [ "$left" -gt 0 ]; then
    log "$trigger failed again, but oFono was restarted less than ${ofono_min_interval}s ago"
    retry_in $((left + 5))
    exit 1
  fi
  echo "$now" > "$state/last-ofono"
  log "$trigger failed: restarting oFono, fp6-ofono-online and fp6-ofono-data-on, then the IMS PDN and imsd"
  systemctl stop imsd.service fp6-ims-pdn.service
  systemctl restart ofono.service fp6-ofono-online.service fp6-ofono-data-on.service \
    || log "oFono restart reported a failure; going on"
  waited=0
  until registered; do
    if [ "$waited" -ge "$reg_timeout" ]; then
      log "no network registration ${reg_timeout} s after the oFono restart"
      retry_in 300
      exit 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
  log "registered ${waited} s after the oFono restart; letting the modem settle ${settle} s"
  sleep "$settle"
  if start_pdn_with_backoff; then exit 0; fi
  log "IMS PDN still down after the backoff"
  retry_in 600
  exit 1
fi

log "$trigger failed: restarting the IMS PDN, then imsd"
systemctl stop imsd.service fp6-ims-pdn.service
if start_pdn_with_backoff; then exit 0; fi
log "IMS PDN still down after the backoff"
retry_in 300
exit 1
