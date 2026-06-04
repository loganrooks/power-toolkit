#!/bin/zsh
emulate -L zsh
set -u
# Bluetooth-on-sleep saver. Turns Bluetooth OFF once the lid has been shut for
# BT_DROP_AFTER_MIN, and back ON when the lid reopens. Short closes keep BT.
#   usage: power-saver.sh [tick|sleep|wake]
# Only restores BT it disabled itself (won't fight a manual toggle).

PT_ROOT=${0:A:h:h}; source "$PT_ROOT/config.sh"
zmodload zsh/datetime 2>/dev/null
mkdir -p "$PT_LOG"
EVENT=${1:-tick}
CLOSED_SINCE="$PT_VAR/bt-closed-since"
DROPPED="$PT_VAR/bt-dropped"
LOG="$PT_LOG/saver.log"

ts()  { strftime '%Y-%m-%d %H:%M:%S' $EPOCHSECONDS; }
log() { print -- "$(ts) $1" >> "$LOG"; }
lid_closed() { ioreg -r -k AppleClamshellState 2>/dev/null | grep -q '"AppleClamshellState" = Yes'; }
on_battery() { pmset -g batt 2>/dev/null | grep -q "Battery Power"; }
bt_on()      { [[ "$(blueutil -p 2>/dev/null)" == "1" ]]; }

evaluate() {
  if lid_closed; then
    [[ -f "$CLOSED_SINCE" ]] || print -- "$EPOCHSECONDS" > "$CLOSED_SINCE"
    local since=$(cat "$CLOSED_SINCE" 2>/dev/null || print 0)
    local mins=$(( (EPOCHSECONDS - since) / 60 ))
    if (( mins >= BT_DROP_AFTER_MIN )); then
      if (( BT_DROP_ON_BATTERY_ONLY == 0 )) || on_battery; then
        if bt_on; then
          blueutil -p 0 && { : > "$DROPPED"; log "lid closed ${mins}m -> Bluetooth OFF"; }
        fi
      fi
    fi
  else
    if [[ -f "$DROPPED" ]]; then
      blueutil -p 1 && log "lid open -> Bluetooth ON (restored)"
      rm -f "$DROPPED"
    fi
    rm -f "$CLOSED_SINCE"
  fi
}

case "$EVENT" in
  sleep) lid_closed && { [[ -f "$CLOSED_SINCE" ]] || print -- "$EPOCHSECONDS" > "$CLOSED_SINCE"; } ;;
  *)     evaluate ;;
esac
