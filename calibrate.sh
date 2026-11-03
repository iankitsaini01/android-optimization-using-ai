#!/usr/bin/env bash
# Guided fuel-gauge calibration. Software can't calibrate a Li-ion gauge directly; this script
# checks blockers, records a baseline, watches the physical cycle, and compares the result.
#   ./calibrate.sh check            blockers + current readings (read-only)
#   ./calibrate.sh start            save baseline
#   ./calibrate.sh watch full       poll while charging; done at 100% + 60 min plugged
#   ./calibrate.sh watch empty      poll while discharging; done at <=5%
#   ./calibrate.sh finish           compare learned capacity with the baseline
set -u
source "$(dirname "$0")/lib.sh"
pick_device
BASE="$STATE_DIR/calibration_baseline.txt"
CLOG="$STATE_DIR/calibration.log"

read_state() {
  local b; b=$(A dumpsys battery)
  LEVEL=$(awk -F': ' '/^  level:/{print $2}' <<<"$b")
  STATUS=$(awk -F': ' '/^  status:/{print $2}' <<<"$b")       # 2 charging, 3 discharging, 5 full
  TEMP=$(awk -F': ' '/^  temperature:/{print $2/10}' <<<"$b")
  COUNTER=$(awk -F': ' '/^  Charge counter:/{print int($2/1000)}' <<<"$b")
  PLUGGED=$(grep -cE '^  (AC|USB|Wireless) powered: true' <<<"$b")
}
# Reads the whole dump (no early exit) - stopping mid-stream makes adb return empty output.
# The dump is ~400k lines and occasionally comes back empty over wireless ADB, so retry.
learned() {
  local v i
  for i in 1 2 3 4; do
    v=$(A dumpsys batterystats | awk -F': ' '/Last learned battery capacity/ && !v {split($2,a," "); v=a[1]} END{print v}')
    [[ -n "$v" ]] && { echo "$v"; return; }
    sleep 2
  done
}

case "${1:-check}" in
  check)
    read_state
    echo "level=$LEVEL% status=$STATUS plugged=$PLUGGED temp=${TEMP}C counter=${COUNTER}mAh learned=$(learned)mAh"
    lim=$(A getprop persist.vivo.battery_charge_limit)
    [[ "$lim" == 1 ]] && echo "BLOCKER: vivo charge limit / smart charging is ON - the phone stops below 100%, so the gauge can't learn 'full'.
         Turn it off: Settings > Battery > Battery health / Smart charging (re-enable after calibration)."
    awk -v t="$TEMP" 'BEGIN{ if (t>35) print "WARN: battery is " t "C - let it cool below 35C first." }'
    ;;
  start)
    read_state
    printf 'date=%s\nlevel=%s\ncounter=%s\nlearned=%s\n' "$(date '+%F %T')" "$LEVEL" "$COUNTER" "$(learned)" > "$BASE"
    cat "$BASE"; echo "Baseline saved. Next: plug in and run ./calibrate.sh watch full"
    ;;
  watch)
    goal="${2:?full|empty}"; full_since=""
    while true; do
      read_state
      echo "$(date '+%F %T') level=$LEVEL status=$STATUS plugged=$PLUGGED temp=${TEMP}C counter=$COUNTER" | tee -a "$CLOG"
      awk -v t="$TEMP" 'BEGIN{ if (t>42) print "  WARN: " t "C - unplug/rest the phone, heat skews the result" }'
      if [[ $goal == full ]]; then
        [[ $PLUGGED -eq 0 ]] && echo "  Not plugged in - connect the charger."
        if [[ $LEVEL -ge 100 && $PLUGGED -gt 0 ]]; then
          full_since=${full_since:-$(date +%s)}
          left=$(( 60 - ($(date +%s) - full_since) / 60 ))
          [[ $left -le 0 ]] && { echo "FULL phase done. Unplug, use normally down to ~5%, then: ./calibrate.sh watch empty"; break; }
          echo "  At 100% - keep plugged ${left} more min so the gauge registers full."
        else full_since=""; fi
      else
        [[ $PLUGGED -gt 0 ]] && echo "  Still plugged in - unplug for the discharge phase."
        [[ $LEVEL -le 5 ]] && { echo "EMPTY phase done. Charge uninterrupted to 100%, then: ./calibrate.sh finish"; break; }
      fi
      sleep "${INTERVAL:-120}"
      adb connect "$DEV" >/dev/null 2>&1 || true   # wireless ADB can drop while the screen is off
    done
    ;;
  finish)
    [[ -f "$BASE" ]] || { echo "No baseline - run ./calibrate.sh start first."; exit 1; }
    read_state; now=$(learned); before=$(awk -F= '/^learned=/{print $2}' "$BASE")
    echo "Learned capacity: before ${before} mAh -> now ${now} mAh"
    awk -v b="$before" -v n="$now" 'BEGIN{ d=n-b; printf "Change: %+d mAh (%+.1f%%)\n", d, (b>0? d/b*100:0)
      if (d==0) print "Unchanged: Android only updates the learned value after a full charge from low - finish one more full charge." }'
    echo "Remember to turn smart charging / the charge limit back on."
    ;;
  *) sed -n '2,9p' "$0"; exit 1 ;;
esac
