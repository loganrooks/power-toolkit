#!/bin/zsh
emulate -L zsh
set -u
# Flags processes that peg CPU *continuously* for a sustained window, then notifies
# (and optionally kills). Bursty/legit load is ignored. Reads thresholds from config.sh.

PT_ROOT=${0:A:h:h}; source "$PT_ROOT/config.sh"
zmodload zsh/datetime 2>/dev/null
mkdir -p "$PT_LOG"
# Paths and the ps source honor optional CPU_*_OVERRIDE env (unset in production / launchd) so
# the state-validity guards can be tested deterministically without waiting for a real runaway.
# Mirrors the MEM_*_OVERRIDE hooks the memory guardian already uses.
STATE="${CPU_STATE_OVERRIDE:-$PT_VAR/cpu-state.tsv}"       # pid \t hotcount \t notedcount \t comm \t start
AGG_STATE="${CPU_AGG_STATE_OVERRIDE:-$PT_VAR/cpu-agg-state}"   # streak \t noted \t last_sample_epoch
LOG="${CPU_LOG_OVERRIDE:-$PT_LOG/watchdog.log}"
pt_rotate_log "$LOG"     # bound the history; see PT_LOG_MAX_KB in config.sh

# N observations spaced WATCHDOG_INTERVAL_SEC apart span (N-1)*interval of ELAPSED time, not
# N*interval. Both the threshold and the reported duration were off by one interval: the
# balanced per-process gate alerted after 2 intervals (10 min) while claiming 15, and
# `AGG_SUSTAIN_MIN=5` in aggressive mode collapsed to a SINGLE sample claiming 5 sustained
# minutes. Derived in ONE place so the per-process and aggregate gates cannot drift apart.
# (Codex F1 on PR #2 — which saw only the aggregate site, since the per-process one predates
# the diff. Fixed as a class.)
sustain_checks() {                      # $1 = minutes -> REPLY = observations required
  REPLY=$(( ($1 * 60 + WATCHDOG_INTERVAL_SEC - 1) / WATCHDOG_INTERVAL_SEC + 1 ))
  (( REPLY < 2 )) && REPLY=2            # a single sample spans zero elapsed time
}
sustain_checks $SUSTAIN_MIN; SUSTAIN_CHECKS=$REPLY
RENOTIFY_EVERY=$(( SUSTAIN_CHECKS * 4 ))

ts() { strftime '%Y-%m-%d %H:%M:%S' $EPOCHSECONDS; }
# $1 title, $2 body. BOTH may embed a process name taken from `ps -o comm`, and any user can
# name an executable `foo"bar` or `foo\bar`. Unescaped, that terminates the AppleScript string
# literal and osascript fails to parse — and since its output is discarded, the notification is
# lost SILENTLY, precisely in the runaway case this exists to report. Backslash first, then
# quote, or the escapes escape each other. (Codex round 2 on PR #2 — flagged at the aggregate
# call site; fixed here because both call sites pass `comm`-derived text.)
notify() {
  local t=${1//\\/\\\\} b=${2//\\/\\\\}
  t=${t//\"/\\\"}; b=${b//\"/\\\"}
  osascript -e "display notification \"$b\" with title \"$t\" sound name \"Submarine\"" >/dev/null 2>&1
}
mins_for() { print -- $(( ($1 - 1) * WATCHDOG_INTERVAL_SEC / 60 )); }   # elapsed, not observed count

# Accumulated streaks are only meaningful against the policy that produced them. Switching mode
# (`pm mode`), editing a threshold, or toggling AGG_ENABLE leaves samples on disk that were
# gathered under DIFFERENT rules, and they keep counting toward the new window: two samples
# above aggressive's 2.0/core could carry into balanced and let the first 2.5/core sample alert
# immediately, despite balanced advertising ten sustained minutes. Fingerprint the policy and
# discard BOTH state files when it changes — the per-process state has the identical defect
# (HOT counts survive a CPU_THRESHOLD or SUSTAIN_MIN edit), so one mechanism covers the class.
# (Codex round 2 on PR #2, flagged for the aggregate state only.)
POLICY_FILE="${CPU_POLICY_OVERRIDE:-$PT_VAR/cpu-policy}"
POLICY="v1|$WATCHDOG_INTERVAL_SEC|$CPU_THRESHOLD|$SUSTAIN_MIN|$AGG_ENABLE|$AGG_LOAD_PER_CORE|$AGG_SUSTAIN_MIN|$AGG_MIN_PROC_CPU"
if [[ "$(cat "$POLICY_FILE" 2>/dev/null)" != "$POLICY" ]]; then
  [[ -f "$STATE" || -f "$AGG_STATE" ]] && \
    print -- "$(ts) POLICY change — discarding accumulated streaks ($POLICY)" >> "$LOG"
  rm -f "$STATE" "$AGG_STATE"
  print -- "$POLICY" > "$POLICY_FILE"
fi

# A streak is only meaningful if the samples behind it are CONSECUTIVE. Sleep, a reboot, or an
# unloaded agent leaves the old streak on disk with no record of when it was last touched, so
# one high-load sample before the gap and one after satisfy a two-observation window instantly —
# "5 sustained minutes" spanning a weekend. Anything beyond ~1.5 intervals is a missed poll.
# (Codex round 3 on PR #2, filed against the aggregate state; the per-process HOT counts have
# the identical defect, so the expiry covers both.)
STALE_AFTER=$(( WATCHDOG_INTERVAL_SEC * 3 / 2 ))
LAST_SAMPLE=0
[[ -f "$AGG_STATE" ]] && LAST_SAMPLE=$(cut -f3 "$AGG_STATE" 2>/dev/null)
[[ "$LAST_SAMPLE" == <-> ]] || LAST_SAMPLE=0
GAP=$(( EPOCHSECONDS - LAST_SAMPLE ))
if (( LAST_SAMPLE > 0 && GAP > STALE_AFTER )); then
  print -- "$(ts) GAP    ${GAP}s since the last sample (> ${STALE_AFTER}s) — discarding streaks" >> "$LOG"
  rm -f "$STATE" "$AGG_STATE"
fi

typeset -A HOT NOTED PSTART
if [[ -f "$STATE" ]]; then
  while IFS=$'\t' read -r pid hc nt cm st; do
    [[ -n "$pid" ]] && { HOT[$pid]=$hc; NOTED[$pid]=$nt; PSTART[$pid]=${st:--1}; }
  done < "$STATE"
fi

# Aggregate accumulators — filled from the SAME ps pass below (no second scan, no per-process
# shell-outs). See the aggregate gate after the loop.
typeset -A AGGCPU AGGCNT
AGG_TOTAL=0; AGG_MAXPROC=0; AGG_PERPROC_FIRED=0
AGG_ALLOWLISTED=0        # summed %CPU attributable to ALERT_ALLOWLIST batch daemons

# etime rides along on the SAME ps (one scan per tick, GOAL_CONTRACT §4) so history can be keyed
# on process IDENTITY rather than on the PID alone.
etime_sec() {            # $1 = ps etime -> REPLY seconds. SS | MM:SS | HH:MM:SS | DD-HH:MM:SS
  local e=$1 d=0 p
  [[ $e == *-* ]] && { d=${e%%-*}; e=${e#*-} }
  local -a p; p=( ${(s.:.)e} )
  case ${#p} in
    3) REPLY=$(( p[1]*3600 + p[2]*60 + p[3] ));;
    2) REPLY=$(( p[1]*60 + p[2] ));;
    *) REPLY=$(( e ));;
  esac
  REPLY=$(( d*86400 + REPLY ))
}

: > "$STATE.tmp"
while read -r pid cpu etime comm; do
  [[ -n "$pid" && -n "$cpu" ]] || continue

  # --- aggregate accounting: EVERY process, before the per-process gates below ---
  if (( AGG_ENABLE )) && (( cpu >= AGG_MIN_PROC_CPU )); then
    AGG_TOTAL=$(( AGG_TOTAL + cpu ))
    AGGCPU[$comm]=$(( ${AGGCPU[$comm]:-0} + cpu ))
    AGGCNT[$comm]=$(( ${AGGCNT[$comm]:-0} + 1 ))
    (( cpu > AGG_MAXPROC )) && AGG_MAXPROC=$cpu
    for a in ${=ALERT_ALLOWLIST}; do
      [[ "$comm" == *$a* ]] && { AGG_ALLOWLISTED=$(( AGG_ALLOWLISTED + cpu )); break }
    done
  fi

  (( cpu >= CPU_THRESHOLD )) || continue
  kill -0 "$pid" 2>/dev/null || continue
  for a in ${=ALERT_ALLOWLIST}; do [[ "$comm" == *$a* ]] && continue 2; done   # skip expected daemons

  # PID REUSE: a PID is unique only among LIVE processes. macOS recycles them, so keying the
  # streak on the PID alone lets a fresh process inherit a dead one's hotcount and cross
  # SUSTAIN_CHECKS on its first tick — and in aggressive mode (AUTO_KILL=1) that is a SIGTERM
  # to the wrong process on evidence it never earned. Identity is (pid, start); start comes
  # from etime on the same ps. 5s tolerance absorbs etime resolution and snapshot drift.
  # (Codex F5 on PR #2 — the mem-watchdog twin was fixed the same way on PR #1.)
  etime_sec "$etime"; start=$(( EPOCHSECONDS - REPLY ))
  prev_start=${PSTART[$pid]:--1}
  if (( prev_start >= 0 )); then
    d=$(( start - prev_start )); (( d < 0 )) && d=$(( -d ))
    if (( d > 5 )); then unset "HOT[$pid]" "NOTED[$pid]"; else start=$prev_start; fi
  fi

  count=$(( ${HOT[$pid]:-0} + 1 ))
  noted=${NOTED[$pid]:-0}

  # A named culprit EXISTS as soon as something is sustained-hot — not merely on the ticks
  # where a notification happens to be due. `count` accumulates across invocations via STATE,
  # so this spans ticks. Previously this was set inside `if (( due ))`, which made the flag mean
  # "we notified this tick"; because the two schedules interleave rather than coincide (balanced:
  # per-process at 4, 16, 28…; aggregate at 3, 11, 19…), an ongoing incident with a named hot
  # process kept re-emitting AGG-DISTRIBUTED and its "No single process is hot" notification.
  # (Codex F2 on PR #2.) Alert-allowlisted daemons `continue` above and deliberately never set
  # this: "culprit" means something we would have named, not merely something busy.
  (( count >= SUSTAIN_CHECKS )) && AGG_PERPROC_FIRED=1

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
  printf '%s\t%s\t%s\t%s\t%s\n' "$pid" "$count" "$noted" "$comm" "$start" >> "$STATE.tmp"
done < <(if [[ -n "${CPU_PS_SOURCE:-}" && -r "${CPU_PS_SOURCE}" ]]; then cat "$CPU_PS_SOURCE"
         else ps -arcwwwxo pid=,%cpu=,etime=,comm=; fi)

mv "$STATE.tmp" "$STATE"

# ---------- aggregate / distributed-runaway gate ----------
# Fires on SYSTEM oversubscription (load per core), which the per-process gate above cannot see
# when load is spread across many sub-threshold processes. DETECTION-ONLY: there is deliberately
# no kill path here — an aggregate signal identifies that the system is saturated but not WHO is
# saturating it, and blame is a precondition for termination (brief 0002, GOAL_CONTRACT §4).
if (( AGG_ENABLE )); then
  agg_streak=0; agg_noted=0
  if [[ -f "$AGG_STATE" ]]; then
    IFS=$'\t' read -r agg_streak agg_noted agg_last < "$AGG_STATE"   # 3rd field or agg_noted eats it
    [[ -n "$agg_streak" ]] || agg_streak=0
    [[ -n "$agg_noted" ]] || agg_noted=0
  fi

  ncpu=$(sysctl -n hw.ncpu 2>/dev/null || print 1); (( ncpu > 0 )) || ncpu=1
  la=( ${=$(sysctl -n vm.loadavg 2>/dev/null)} )      # "{ 1.23 4.56 7.89 }"
  load1=${la[2]:-0}
  per_core=$(( load1 / ncpu ))

  sustain_checks $AGG_SUSTAIN_MIN; AGG_SUSTAIN_CHECKS=$REPLY
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

      # ALERT_ALLOWLIST exists so that Spotlight, backup and media-analysis daemons pegging a
      # core do not page the operator. The per-process gate skips them; the aggregate gate used
      # to ignore the list entirely, so the SAME indexing workload came back as an
      # AGG-DISTRIBUTED "runaway" — defeating the allowlist for exactly the multi-process batch
      # jobs this gate observes. If most of the load is attributable to allowlisted daemons, log
      # it and stay quiet. (Codex round 3 on PR #2.)
      agg_allow_pct=0
      (( AGG_TOTAL > 0 )) && agg_allow_pct=$(( 100 * AGG_ALLOWLISTED / AGG_TOTAL ))

      if (( AGG_PERPROC_FIRED )); then
        # A per-process alert already named a culprit this tick; log only, don't double-notify.
        print -- "$(ts) AGG    $msg" >> "$LOG"
      elif (( agg_allow_pct >= AGG_ALLOWLIST_PCT )); then
        print -- "$(ts) AGG-EXPECTED  ${agg_allow_pct}% of load is ALERT_ALLOWLIST batch work — $msg" >> "$LOG"
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
  printf '%s\t%s\t%s\n' "$agg_streak" "$agg_noted" "$EPOCHSECONDS" > "$AGG_STATE"
fi
