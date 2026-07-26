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

# Aggregate accumulators — filled from the SAME ps pass below (no second scan, no per-process
# shell-outs). See the aggregate gate after the loop.
typeset -A AGGCPU AGGCNT
AGG_TOTAL=0; AGG_MAXPROC=0; AGG_PERPROC_FIRED=0

: > "$STATE.tmp"
while read -r pid cpu comm; do
  [[ -n "$pid" && -n "$cpu" ]] || continue

  # --- aggregate accounting: EVERY process, before the per-process gates below ---
  if (( AGG_ENABLE )) && (( cpu >= AGG_MIN_PROC_CPU )); then
    AGG_TOTAL=$(( AGG_TOTAL + cpu ))
    AGGCPU[$comm]=$(( ${AGGCPU[$comm]:-0} + cpu ))
    AGGCNT[$comm]=$(( ${AGGCNT[$comm]:-0} + 1 ))
    (( cpu > AGG_MAXPROC )) && AGG_MAXPROC=$cpu
  fi

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
    AGG_PERPROC_FIRED=1            # a named culprit exists; aggregate alert de-escalates to corroboration
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

# ---------- aggregate / distributed-runaway gate ----------
# Fires on SYSTEM oversubscription (load per core), which the per-process gate above cannot see
# when load is spread across many sub-threshold processes. DETECTION-ONLY: there is deliberately
# no kill path here — an aggregate signal identifies that the system is saturated but not WHO is
# saturating it, and blame is a precondition for termination (brief 0002, GOAL_CONTRACT §4).
if (( AGG_ENABLE )); then
  AGG_STATE="$PT_VAR/cpu-agg-state"          # streak \t noted
  agg_streak=0; agg_noted=0
  if [[ -f "$AGG_STATE" ]]; then
    IFS=$'\t' read -r agg_streak agg_noted < "$AGG_STATE"
    [[ -n "$agg_streak" ]] || agg_streak=0
    [[ -n "$agg_noted" ]] || agg_noted=0
  fi

  ncpu=$(sysctl -n hw.ncpu 2>/dev/null || print 1); (( ncpu > 0 )) || ncpu=1
  la=( ${=$(sysctl -n vm.loadavg 2>/dev/null)} )      # "{ 1.23 4.56 7.89 }"
  load1=${la[2]:-0}
  per_core=$(( load1 / ncpu ))

  AGG_SUSTAIN_CHECKS=$(( (AGG_SUSTAIN_MIN * 60 + WATCHDOG_INTERVAL_SEC - 1) / WATCHDOG_INTERVAL_SEC ))
  (( AGG_SUSTAIN_CHECKS < 1 )) && AGG_SUSTAIN_CHECKS=1
  AGG_RENOTIFY_EVERY=$(( AGG_SUSTAIN_CHECKS * 4 ))

  if (( per_core >= AGG_LOAD_PER_CORE )); then
    agg_streak=$(( agg_streak + 1 ))
    agg_due=0
    if (( agg_streak == AGG_SUSTAIN_CHECKS )); then agg_due=1
    elif (( agg_streak > AGG_SUSTAIN_CHECKS && agg_streak - agg_noted >= AGG_RENOTIFY_EVERY )); then agg_due=1
    fi

    if (( agg_due )); then
      # Rank contributors. Shell-out to sort happens ONLY here (under pressure), never per tick.
      top=$(for k in ${(k)AGGCPU}; do printf '%s\t%s\t%s\n' "${AGGCPU[$k]}" "${AGGCNT[$k]}" "$k"; done \
            | sort -rn | head -n $AGG_TOP_N \
            | awk -F'\t' '{printf "%d×%s@%.0f%% ", $2, $3, $1}')
      msg="load $(printf '%.1f' $load1) on ${ncpu} cores ($(printf '%.1f' $per_core)/core) for ~$(mins_for $agg_streak)+ min; summed %CPU=$(printf '%.0f' $AGG_TOTAL), hottest single proc=$(printf '%.0f' $AGG_MAXPROC)% — top: ${top}"

      if (( AGG_PERPROC_FIRED )); then
        # A per-process alert already named a culprit this tick; log only, don't double-notify.
        print -- "$(ts) AGG    $msg" >> "$LOG"
      else
        # The blind-spot signature: system saturated, yet nothing crossed CPU_THRESHOLD.
        print -- "$(ts) AGG-DISTRIBUTED  $msg" >> "$LOG"
        notify "⚠️ Distributed CPU runaway" "No single process is hot — $msg"
      fi
      agg_noted=$agg_streak
    fi
  else
    agg_streak=0; agg_noted=0
  fi
  printf '%s\t%s\n' "$agg_streak" "$agg_noted" > "$AGG_STATE"
fi
