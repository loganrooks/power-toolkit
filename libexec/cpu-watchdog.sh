#!/bin/zsh
emulate -L zsh
set -u
# Flags processes that peg CPU *continuously* for a sustained window, then notifies
# (and optionally kills). Bursty/legit load is ignored. Reads thresholds from config.sh.

PT_ROOT=${0:A:h:h}; source "$PT_ROOT/config.sh"
zmodload zsh/datetime 2>/dev/null
mkdir -p "$PT_LOG"
STATE="$PT_VAR/cpu-state.tsv"            # pid \t hotcount \t notedcount \t comm
LOG="$PT_LOG/watchdog.log"

SUSTAIN_CHECKS=$(( (SUSTAIN_MIN * 60 + WATCHDOG_INTERVAL_SEC - 1) / WATCHDOG_INTERVAL_SEC ))
(( SUSTAIN_CHECKS < 1 )) && SUSTAIN_CHECKS=1
RENOTIFY_EVERY=$(( SUSTAIN_CHECKS * 4 ))

ts() { strftime '%Y-%m-%d %H:%M:%S' $EPOCHSECONDS; }
notify() { osascript -e "display notification \"$2\" with title \"$1\" sound name \"Submarine\"" >/dev/null 2>&1; }
mins_for() { print -- $(( $1 * WATCHDOG_INTERVAL_SEC / 60 )); }

typeset -A HOT NOTED
if [[ -f "$STATE" ]]; then
  while IFS=$'\t' read -r pid hc nt cm; do
    [[ -n "$pid" ]] && { HOT[$pid]=$hc; NOTED[$pid]=$nt; }
  done < "$STATE"
fi

: > "$STATE.tmp"
while read -r pid cpu comm; do
  [[ -n "$pid" && -n "$cpu" ]] || continue
  (( cpu >= CPU_THRESHOLD )) || continue
  kill -0 "$pid" 2>/dev/null || continue
  for a in ${=ALERT_ALLOWLIST}; do [[ "$comm" == *$a* ]] && continue 2; done   # skip expected daemons

  count=$(( ${HOT[$pid]:-0} + 1 ))
  noted=${NOTED[$pid]:-0}
  due=0
  if (( count == SUSTAIN_CHECKS )); then due=1
  elif (( count > SUSTAIN_CHECKS && count - noted >= RENOTIFY_EVERY )); then due=1
  fi

  if (( due )); then
    etime=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
    msg="$comm (pid $pid) — ${cpu}% CPU for ~$(mins_for $count)+ min (process up $etime)"
    print -- "$(ts) ALERT  $msg" >> "$LOG"
    notify "⚠️ Runaway CPU process" "$msg"
    noted=$count
    if (( AUTO_KILL )); then
      skip=0
      for a in ${=KILL_ALLOWLIST}; do [[ "$comm" == *$a* ]] && skip=1; done
      (( skip )) || { kill -TERM "$pid" 2>/dev/null && print -- "$(ts) KILLED $msg" >> "$LOG"; }
    fi
  fi
  printf '%s\t%s\t%s\t%s\n' "$pid" "$count" "$noted" "$comm" >> "$STATE.tmp"
done < <(ps -arcwwwxo pid=,%cpu=,comm=)

mv "$STATE.tmp" "$STATE"
