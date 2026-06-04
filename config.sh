#!/bin/zsh
# power-toolkit — SINGLE SOURCE OF TRUTH.
# Sourced by `pm`, the watchdog, and the saver. Edit values here, then `pm apply`.
# PT_ROOT is exported by whichever entry script sources this file.

: ${PT_ROOT:?config.sh must be sourced with PT_ROOT set}
PT_VAR="$PT_ROOT/var"
PT_LOG="$PT_VAR/log"
PT_MODE=$(cat "$PT_VAR/mode" 2>/dev/null || print balanced)

PT_LABEL_PREFIX="${PT_LABEL_PREFIX:-local.powertoolkit}"
WATCHDOG_LABEL="$PT_LABEL_PREFIX.cpu-watchdog"
SAVER_LABEL="$PT_LABEL_PREFIX.power-saver"
SLEEPWATCHER_LABEL="$PT_LABEL_PREFIX.sleepwatcher"

# ---------- defaults (balanced mode) ----------
# CPU watchdog — catches processes pegging a core continuously (the pyenv-loop failure mode).
CPU_THRESHOLD=85                 # %CPU; ~100 == one core fully pegged
SUSTAIN_MIN=15                   # sustained minutes above threshold before alerting
WATCHDOG_INTERVAL_SEC=300        # how often the watchdog samples
AUTO_KILL=0                      # 1 = SIGTERM offenders (allowlist always protected)
KILL_ALLOWLIST="kernel_task WindowServer launchd loginwindow coreaudiod hidd powerd bluetoothd mds mds_stores backupd"
# Known heavy-but-legit system daemons (indexing / media analysis / backup) — never even alert;
# they routinely peg a core doing self-limiting batch work, usually only on AC.
ALERT_ALLOWLIST="mediaanalysisd photoanalysisd photolibraryd cloudphotod mds mds_stores mdworker mdworker_shared Spotlight backupd XProtect XprotectService corespeechd amplibraryagent AMPDeviceDiscoveryAgent"

# Bluetooth-on-sleep saver — drop BT only if the lid has been shut a while (keeps short room-moves snappy).
BT_DROP_AFTER_MIN=30             # lid closed this long -> turn Bluetooth off
BT_DROP_ON_BATTERY_ONLY=1        # 1 = only act when unplugged
SAVER_INTERVAL_SEC=300           # how often the saver ticks

# pmset desired state — "profile setting value"; profile: b=battery, c=AC, a=all.
# `pm apply` reconciles actual pmset to this list (needs sudo).
PMSET_DESIRED=(
  "b tcpkeepalive 0"
  "b powernap 0"
  "c tcpkeepalive 1"
  "c powernap 1"
)

# ---------- mode overrides ----------
case "$PT_MODE" in
  aggressive)
    AUTO_KILL=1
    BT_DROP_AFTER_MIN=15
    PMSET_DESIRED+=( "b womp 0" "b standby 1" )
    ;;
  conservative)
    AUTO_KILL=0
    BT_DROP_AFTER_MIN=60
    PMSET_DESIRED=( "b tcpkeepalive 0" )     # minimal touch
    ;;
  balanced|*) ;;                             # use defaults above
esac
