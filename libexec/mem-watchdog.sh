#!/bin/zsh
emulate -L zsh
set -u
# Adaptive, pressure-aware memory guardian over ALL processes (the rg-to-17GB swap-exhaustion
# failure mode). Decides intervention by a HEADROOM-AWARE risk score + profile class, never a
# flat absolute RSS ceiling. Reads everything from config.sh.
#
# M0 = OBSERVE-ONLY: this script never signals any process. It logs, per tick, system headroom
# and — for each notable process — the risk score, profile, and the action it WOULD take. The
# kill code path is introduced in M1, after observe evidence shows the scores are sane.
#
# Steady-state cost: exactly one `ps` (the per-process scan) + a few O(1) sysctls per tick.

PT_ROOT=${0:A:h:h}; source "$PT_ROOT/config.sh"
zmodload zsh/datetime 2>/dev/null
mkdir -p "$PT_LOG"
# Paths honor optional MEM_*_OVERRIDE env (unset in production / launchd) so the test harness
# can run in full isolation without touching the live observe-soak log or state.
LOG="${MEM_LOG_OVERRIDE:-$PT_LOG/mem-watchdog.log}"
STATE="${MEM_STATE_OVERRIDE:-$PT_VAR/mem-state.tsv}"   # pid \t rss_kb \t first_seen \t last_seen \t streak \t start
SWAPLAST="${MEM_SWAPLAST_OVERRIDE:-$PT_VAR/mem-swap-last}"   # last swap-used (MB), for the growth delta

ts() { strftime '%Y-%m-%d %H:%M:%S' $EPOCHSECONDS; }

# ---------- system headroom (all O(1): no per-process scan) ----------
press=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || print 1)   # 1 normal/2 warn/4 critical
free_pct=$(sysctl -n kern.memorystatus_level 2>/dev/null || print 100)          # free %
swap_used=$(sysctl -n vm.swapusage 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="used"){v=$(i+2); gsub(/M/,"",v); print int(v); exit}}')
[[ -n "$free_pct" ]] || free_pct=100
[[ -n "$swap_used" ]] || swap_used=0
[[ -n "$press" ]] || press=1

prev_swap=$(cat "$SWAPLAST" 2>/dev/null || print "$swap_used")
swap_delta=$(( swap_used - prev_swap ))
print -- "$swap_used" > "$SWAPLAST"

rank() { case "$1" in critical) print 2;; caution) print 1;; *) print 0;; esac }   # worse = higher
# free-% band
if   (( free_pct <= MEM_FREE_CRITICAL_PCT )); then band=critical
elif (( free_pct <= MEM_FREE_CAUTION_PCT  )); then band=caution
else band=healthy; fi
# kernel pressure band
case "$press" in 4) pband=critical;; 2) pband=caution;; *) pband=healthy;; esac
# headroom_state = worse of the two
if (( $(rank $pband) > $(rank $band) )); then headroom=$pband; else headroom=$band; fi

# Test-only injection (unset in production / launchd): force a headroom state and/or feed
# synthetic process rows from a file, so the would-action ladder + kill-safety list can be
# verified deterministically without inducing real memory pressure. See goal/tools/test-decision.sh.
[[ -n "${MEM_FORCE_HEADROOM:-}" ]] && headroom="$MEM_FORCE_HEADROOM"
[[ -n "${MEM_TOPN_OVERRIDE:-}" ]] && MEM_TOP_N="$MEM_TOPN_OVERRIDE"   # test-only: raise display cap
# etime is here so that process IDENTITY, not just the PID, keys the history below. It costs
# nothing: same single `ps`, one extra column, placed before comm because comm may contain
# spaces and must stay last.
if [[ -n "${MEM_PS_SOURCE:-}" && -r "${MEM_PS_SOURCE}" ]]; then ps_cmd=(cat "$MEM_PS_SOURCE"); else ps_cmd=(ps -axo pid=,rss=,etime=,comm=); fi

NOW=$EPOCHSECONDS
: > "$STATE.tmp"

# ---------- one ps -> one awk pass: classify, score, decide would-be action ----------
"${ps_cmd[@]}" | awk \
  -v NOW="$NOW" -v TS="$(ts)" -v STATEIN="$STATE" -v STATEOUT="$STATE.tmp" \
  -v HEADROOM="$headroom" -v PRESS="$press" -v FREEPCT="$free_pct" \
  -v SWAP="$swap_used" -v SWAPD="$swap_delta" -v TOPN="$MEM_TOP_N" \
  -v W_SIZE="$MEM_W_SIZE" -v W_GROWTH="$MEM_W_GROWTH" -v W_PROFILE="$MEM_W_PROFILE" -v W_FG="$MEM_W_FOREGROUND" \
  -v GROWTH_REF="$MEM_GROWTH_REF_MBPS" -v R_WATCH="$MEM_RISK_WATCH" -v R_NOTIFY="$MEM_RISK_NOTIFY" -v R_KILL="$MEM_RISK_KILL" \
  -v GROWTH_MIN="$MEM_GROWTH_MIN_MBPS" -v SUSTAIN="$MEM_SUSTAIN_TICKS" -v RATIO_HARD="$MEM_RATIO_HARD" \
  -v SYS_TOL="$MEM_SYSTEM_TOL" -v SYS_BASE="$MEM_SYSTEM_BASE" \
  -v TRU_TOL="$MEM_TRUSTED_TOL" -v TRU_BASE="$MEM_TRUSTED_BASE" \
  -v DEV_TOL="$MEM_DEVRUNTIME_TOL" -v DEV_BASE="$MEM_DEVRUNTIME_BASE" \
  -v EPH_TOL="$MEM_EPHEMERAL_TOL" -v EPH_BASE="$MEM_EPHEMERAL_BASE" \
  -v UNK_TOL="$MEM_UNKNOWN_TOL" -v UNK_BASE="$MEM_UNKNOWN_BASE" \
  -v AUTOKILL="$MEM_AUTOKILL_PROFILES" -v PROTECT="$MEM_PROTECT" -v SESSION="$MEM_SESSION_PROTECT" \
  -v DEVRT="$MEM_DEVRUNTIME" -v EPHEM="$MEM_EPHEMERAL" '
  function has_substr(hay, list,    n,a,i) { n=split(list,a," "); for(i=1;i<=n;i++) if(index(hay,a[i])>0) return 1; return 0 }
  function base_match(b, list,      n,a,i) { n=split(list,a," "); for(i=1;i<=n;i++) if(b==a[i] || b ~ ("^" a[i] "[0-9.]*$")) return 1; return 0 }
  function classify(comm, b) {
    if (has_substr(comm, PROTECT) || has_substr(comm, SESSION)) return "system"
    # trusted = signed .app bundle, OR an Apple system framework/service (these burst-allocate
    # legitimately — high tolerance, notify-first, never auto-kill). (D-008)
    if (index(comm, ".app/Contents/MacOS/") > 0) return "trusted"
    if (index(comm, "/System/Library/") > 0 || index(comm, "/System/Applications/") > 0) return "trusted"
    if (b ~ /^com\.apple\./) return "trusted"
    if (base_match(b, DEVRT)) return "devruntime"
    if (base_match(b, EPHEM)) return "ephemeral"
    return "unknown"
  }
  # ps etime -> seconds. Formats: SS, MM:SS, HH:MM:SS, DD-HH:MM:SS.
  function etime_sec(e,   n,p,t,d,s) {
    d=0; n=split(e,p,"-"); if(n==2){ d=p[1]+0; e=p[2] }
    n=split(e,t,":")
    if(n==3) s=t[1]*3600+t[2]*60+t[3]; else if(n==2) s=t[1]*60+t[2]; else s=e+0
    return d*86400+s
  }
  function tol_of(p)  { if(p=="system")return SYS_TOL; if(p=="trusted")return TRU_TOL; if(p=="devruntime")return DEV_TOL; if(p=="ephemeral")return EPH_TOL; return UNK_TOL }
  function base_of(p) { if(p=="system")return SYS_BASE;if(p=="trusted")return TRU_BASE;if(p=="devruntime")return DEV_BASE;if(p=="ephemeral")return EPH_BASE;return UNK_BASE }
  BEGIN {
    while ((getline line < STATEIN) > 0) {
      nf = split(line, f, "\t")
      # 6th field is the process START epoch. Rows written before it existed have nf<6 and get
      # start=-1, which never matches, so one tick of history is discarded on upgrade.
      if (nf >= 4) { prss[f[1]]=f[2]; fseen[f[1]]=f[3]; lseen[f[1]]=f[4]; streak[f[1]]=(nf>=5?f[5]:0); pstart[f[1]]=(nf>=6?f[6]:-1) }
    }
    close(STATEIN)
    nflag = 0; maxrisk = -1; maxcomm = "-"; nproc = 0
  }
  {
    pid=$1; rss_kb=$2; etime=$3; comm=$4; for(i=5;i<=NF;i++) comm=comm" "$i
    if (pid=="" || rss_kb=="") next
    nproc++
    # PID REUSE: a PID is only unique among LIVE processes. macOS recycles them, and keying
    # history on the PID alone lets a brand-new process inherit the dead RSS, last_seen and
    # growth streak — so it can be judged as having sustained growth on its very first tick.
    # Harmless while M0 only logs; it becomes a wrong kill the moment M1 acts on that evidence.
    # Identity is therefore (pid, start). start is derived from etime rather than read per
    # process, so the one-ps-per-tick budget is unchanged. A 5s tolerance absorbs the
    # one-second etime resolution and the drift between the ps snapshot and NOW; PIDs are not
    # reused within seconds on a machine with 100k of them to cycle through first.
    start = NOW - etime_sec(etime)
    if (pid in pstart) {
      d = start - pstart[pid]; if (d < 0) d = -d
      if (d > 5) { delete prss[pid]; delete fseen[pid]; delete lseen[pid]; delete streak[pid] }
      else start = pstart[pid]   # keep the first-seen value so it cannot drift tick by tick
    }
    # basename
    b=comm; m=comm; while ((p=index(m,"/"))>0) { m=substr(m,p+1) } b=m
    rss_mb = rss_kb/1024.0
    profile = classify(comm, b)
    tol = tol_of(profile); base = base_of(profile)
    ratio = rss_mb / base
    dt = (pid in lseen) ? (NOW - lseen[pid]) : 0
    pm = (pid in prss) ? prss[pid]/1024.0 : rss_mb
    growth = (dt>0 && rss_mb>pm) ? (rss_mb-pm)/dt : 0
    gnorm = growth / GROWTH_REF
    fg = (profile=="trusted") ? 1 : 0
    risk = W_SIZE*ratio + W_GROWTH*gnorm + W_PROFILE*(1.0/tol) - W_FG*fg
    if (risk < 0) risk = 0
    # sustained-growth streak (D-008): a single noisy burst tick never reaches an action.
    grewnow = (growth >= GROWTH_MIN) ? 1 : 0
    st = (grewnow ? (((pid in streak) ? streak[pid] : 0) + 1) : 0)
    # new state (6 fields: + grow streak + process start, the identity guard)
    f0 = (pid in fseen) ? fseen[pid] : NOW
    printf "%s\t%d\t%s\t%s\t%d\t%d\n", pid, rss_kb, f0, NOW, st, start > STATEOUT
    # would-be action (M0 never acts; this is the decision it WOULD make)
    # action-eligible only when growth has SUSTAINED, or RSS is already a runaway multiple of baseline
    eligible = (st >= SUSTAIN || ratio >= RATIO_HARD) ? 1 : 0
    autok = (index(" " AUTOKILL " ", " " profile " ") > 0) ? 1 : 0
    action = "ok"
    if (profile=="system") action = "protect"
    else {
      if (risk >= R_WATCH) action = "watch"
      if (eligible) {
        if (HEADROOM=="critical" && risk>=R_KILL && autok) action="WOULD-KILL"
        else if ((HEADROOM=="critical"||HEADROOM=="caution") && risk>=R_NOTIFY) action="WOULD-NOTIFY"
      }
    }
    if (risk > maxrisk) { maxrisk=risk; maxcomm=b }
    # collect flagged (anything reaching the watch floor, or any would-* action)
    if (risk >= R_WATCH || action=="WOULD-NOTIFY" || action=="WOULD-KILL") {
      nflag++
      fr[nflag]=risk
      ftext[nflag]=sprintf("%s %-12s %-26s pid=%-6s rss=%.0fM ratio=%.1f growth=%.1fMB/s streak=%d risk=%.2f profile=%s headroom=%s", \
        TS, action, b, pid, rss_mb, ratio, growth, st, risk, profile, HEADROOM)
    }
  }
  END {
    close(STATEOUT)
    printf "%s TICK headroom=%s press=%s free=%s%% swap=%sM(d%+d) procs=%d top=%s:%.2f\n", \
      TS, HEADROOM, PRESS, FREEPCT, SWAP, SWAPD, nproc, maxcomm, (maxrisk<0?0:maxrisk)
    # print up to TOPN flagged, highest risk first (BSD awk has no asort -> manual selection)
    printed=0
    while (printed < TOPN && printed < nflag) {
      bi=-1; bv=-1
      for (i=1;i<=nflag;i++) if (!done[i] && fr[i]>bv) { bv=fr[i]; bi=i }
      if (bi<0) break
      done[bi]=1; print ftext[bi]; printed++
    }
    if (nflag > TOPN) printf "%s   …and %d more at/above watch floor (capped at TOPN=%d)\n", TS, nflag-TOPN, TOPN
  }' >> "$LOG"

mv "$STATE.tmp" "$STATE"
