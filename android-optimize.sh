#!/usr/bin/env bash
# android-optimize.sh - single-file Android debloat / optimize / battery toolkit over ADB (no root).
# Every change is reversible and logged to ./state/<device>/. Tested: iQOO 12, Funtouch OS, Android 16.
#
#   ./android-optimize.sh report [rated_mAh]          battery health + drain + top power users (read-only)
#   ./android-optimize.sh debloat [--dry-run] <set>   sets: core | optional | vivo-core | vivo-optional | all
#                                                     or a path to your own list file
#   ./android-optimize.sh restore [pkg...]            undo debloat (all, or listed packages)
#   ./android-optimize.sh tune [--anim 0.5]           0.5x animations, no idle Wi-Fi/BT scans, small log buffers
#   ./android-optimize.sh tune --restore              put original settings back
#   ./android-optimize.sh calibrate check|start|watch full|watch empty|finish
#
# Target device: $ADB_DEVICE (serial or ip:port), else the only connected device.
# AI agents: dry-run first, show the user, get an explicit yes before any change. Never use FORCE=1 unasked.
set -u
STATE_ROOT="${STATE_ROOT:-$(pwd)/state}"

# ---------------------------------------------------------------- package lists
# Regex, full-name match. These are never touched (bootloop / lost calls / locked out).
NEVER_REMOVE='
android
com\.android\.(systemui|phone|settings|server\.telecom|shell|providers\..*|launcher3|vending|nfc|bluetooth|se|mms\.service|externalstorage|keychain|location\.fused|inputdevices|intentresolver|permissioncontroller|packageinstaller|incallui|carrierconfig.*)
com\.google\.android\.(gms|gsf|webview|permissioncontroller|packageinstaller|providers\..*|networkstack.*|ext\.services|ext\.shared|modulemetadata|documentsui|setupwizard|ondevicepersonalization\.services|adservices\.api|configupdater|rkpdapp|cellbroadcast.*|captiveportallogin)
com\.google\.mainline\..*
com\.qualcomm\..*
com\.qti\..*
vendor\.qti\..*
org\.codeaurora\.ims
.*\.overlay(\..*)?
.*(fingerprint|faceunlock|faceui).*
com\.vivo\.(daemonService|abe|sps|pem|epm|frameworkui|systemuiplugin|upslide|recents|connbase.*|devicepower|crontab|vms|safecenter|appfilter|setupwizard|gamewatch)
com\.bbk\.(account|updater|SuperPowerSave)
com\.iqoo\.powersaving
'
LIST_core='
com.facebook.appmanager          # Facebook preinstall services (not the user apps)
com.facebook.services
com.facebook.system
com.google.android.feedback
com.google.android.printservice.recommendation
com.android.egg
'
LIST_optional='
com.microsoft.appmanager                      # Link to Windows
com.microsoft.deviceintegrationservice
com.microsoftsdk.crossdeviceservicebroker
com.google.android.apps.tachyon               # Google Meet
com.google.android.projection.gearhead        # Android Auto
com.google.android.apps.bard                  # Gemini
com.android.hotwordenrollment.okgoogle        # "Hey Google" voice match
com.android.hotwordenrollment.xgoogle
'
LIST_vivo_core='
com.android.bbklog               # vivo logging
com.bbk.iqoo.logsystem           # iQOO log system (protected on iQOO 12 -> restricted)
com.vivo.feedback
com.vivo.nps                     # in-app surveys
com.vivo.magazine                # lock-screen ad magazine (-> disabled)
com.vivo.hybrid                  # quick apps / ad mini-apps
com.vivo.appstore                # V-Appstore (protected -> restricted)
com.vivo.game
com.vivo.browser
com.vivo.globalsearch            # sponsored search (protected -> restricted)
com.vivo.numbermark              # caller-ID marking, uploads numbers
com.iqoo.website                 # (protected -> restricted)
com.vivo.unionpay                # China UnionPay
com.yozo.vivo.office
'
LIST_vivo_optional='
com.vivo.pushservice     # vivo apps lose notifications
com.vivo.cota            # carrier OTA, reinstalls bloat
com.vivo.hiboard         # Jovi -1 screen
com.vivo.assistant       # Jovi smart scenes
com.vivo.easyshare
com.vivo.pcsuite
com.vivo.vhome
com.vivo.tws.vivotws     # vivo earbuds
com.vivo.weather
com.vivo.videoeditor
com.android.bbkmusic     # vivo Music
'

# ---------------------------------------------------------------- helpers
A() { adb -s "$DEV" shell "$@" </dev/null | tr -d '\r'; }   # stdin closed: adb would eat loop input
clean() { sed -e 's/#.*//' -e 's/[[:space:]]//g' | grep -v '^$'; }

pick_device() {
  if [[ -n "${ADB_DEVICE:-}" ]]; then
    [[ "$ADB_DEVICE" == *:* ]] && adb connect "$ADB_DEVICE" >/dev/null
    DEV="$ADB_DEVICE"
  else
    local devs n
    devs=$(adb devices | awk 'NR>1 && $2=="device"{print $1}')
    n=$(printf '%s\n' "$devs" | grep -c .)
    if [[ $n -ne 1 ]]; then
      echo "Found $n connected devices. Set ADB_DEVICE=<serial or ip:port>." >&2; adb devices >&2; exit 1
    fi
    DEV="$devs"
  fi
  STATE_DIR="$STATE_ROOT/$(echo "$DEV" | tr ':/' '__')"; mkdir -p "$STATE_DIR"
  echo "Device: $DEV ($(A getprop ro.product.manufacturer) $(A getprop ro.product.model), Android $(A getprop ro.build.version.release))"
}

is_protected() { grep -qxE "$(printf '%s\n' "$NEVER_REMOVE" | clean | paste -sd'|' -)" <<<"$1"; }

list_for() {
  case $1 in
    core) printf '%s\n' "$LIST_core" ;;
    optional) printf '%s\n' "$LIST_optional" ;;
    vivo-core) printf '%s\n' "$LIST_vivo_core" ;;
    vivo-optional) printf '%s\n' "$LIST_vivo_optional" ;;
    all) printf '%s\n' "$LIST_core" "$LIST_optional" "$LIST_vivo_core" "$LIST_vivo_optional" ;;
    *) [[ -f $1 ]] && cat "$1" || { echo "Unknown set or file: $1" >&2; exit 1; } ;;
  esac | clean
}

# Full batterystats text is ~400k lines and sometimes arrives empty over wireless ADB: retry.
batterystats_to() {
  local i
  for i in 1 2 3 4 5; do
    A dumpsys batterystats > "$1" 2>/dev/null
    grep -q 'Last learned battery capacity' "$1" && return 0; sleep 2
  done
}
learned_capacity() {
  local f; f=$(mktemp); batterystats_to "$f"
  awk -F': ' '/Last learned battery capacity/ && !v {split($2,a," "); v=a[1]} END{print v}' "$f"; rm -f "$f"
}

# ---------------------------------------------------------------- debloat / restore
cmd_debloat() {
  local dry=0; [[ "${1:-}" == "--dry-run" ]] && { dry=1; shift; }
  [[ $# -ge 1 ]] || { echo "Usage: debloat [--dry-run] core|optional|vivo-core|vivo-optional|all|<file>..."; exit 1; }
  local pkgs; pkgs=$(for s in "$@"; do list_for "$s"; done | awk '!seen[$0]++')
  pick_device
  local log="$STATE_DIR/actions.log" installed p
  installed=$(A pm list packages --user 0 | sed 's/package://')
  for p in $pkgs; do
    if is_protected "$p" && [[ "${FORCE:-0}" != 1 ]]; then echo "REFUSED      $p (critical package)"; continue; fi
    grep -qx "$p" <<<"$installed" || { echo "skip         $p (not installed)"; continue; }
    [[ $dry == 1 ]] && { echo "would-remove $p"; continue; }
    if A pm uninstall -k --user 0 "$p" | grep -q '^Success'; then
      echo "uninstalled $p" | tee -a "$log"
    elif A pm disable-user --user 0 "$p" 2>&1 | grep -q 'disabled-user'; then
      echo "disabled $p" | tee -a "$log"
    else   # OEM-protected: best non-root option is no background + no notifications
      A cmd appops set "$p" RUN_ANY_IN_BACKGROUND ignore >/dev/null 2>&1
      A pm revoke "$p" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1
      echo "restricted $p" | tee -a "$log"
    fi
  done
  [[ $dry == 1 ]] || echo "Log: $log. Reboot, then test calls, SMS, data, fingerprint, camera. Undo: $0 restore"
}

cmd_restore() {
  pick_device
  local log="$STATE_DIR/actions.log" action p r
  [[ -f "$log" ]] || { echo "No log at $log - nothing to restore."; exit 1; }
  awk '{a[NR]=$0} END{for(i=NR;i>0;i--) print a[i]}' "$log" | while read -r action p _; do
    if [[ $# -gt 0 ]] && ! printf '%s\n' "$@" | grep -qx "$p"; then continue; fi
    case $action in
      uninstalled) r=$(A cmd package install-existing --user 0 "$p" 2>&1) ;;
      disabled)    r=$(A pm enable --user 0 "$p" 2>&1) ;;
      restricted)  A cmd appops set "$p" RUN_ANY_IN_BACKGROUND allow >/dev/null 2>&1
                   A pm grant "$p" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1
                   r="background + notifications allowed" ;;
      *) continue ;;
    esac
    echo "$p: $r"
  done
  [[ $# -eq 0 ]] && mv "$log" "$log.restored.$(date +%Y%m%d_%H%M%S)"
}

# ---------------------------------------------------------------- tune
cmd_tune() {
  pick_device
  local backup="$STATE_DIR/settings_backup.txt" k v anim=0.5
  local keys="window_animation_scale transition_animation_scale animator_duration_scale wifi_scan_always_enabled ble_scan_always_enabled"
  if [[ "${1:-}" == "--restore" ]]; then
    [[ -f "$backup" ]] || { echo "No backup at $backup"; exit 1; }
    while read -r k v; do
      if [[ "$v" == "null" ]]; then A settings delete global "$k" >/dev/null; else A settings put global "$k" "$v"; fi
      echo "restored $k=$v"
    done < "$backup"
    A logcat -b main,system,radio,events -G 4M && echo "log buffers -> 4M"
    return
  fi
  [[ "${1:-}" == "--anim" ]] && anim="${2:?value}"
  if [[ ! -f "$backup" ]]; then
    for k in $keys; do echo "$k $(A settings get global "$k")"; done > "$backup"; echo "Saved originals to $backup"
  fi
  for k in window_animation_scale transition_animation_scale animator_duration_scale; do A settings put global "$k" "$anim"; done
  A settings put global wifi_scan_always_enabled 0   # trade-off: slightly worse indoor location
  A settings put global ble_scan_always_enabled 0
  A logcat -b main,system,radio,events -G 256K        # runtime only; resets on reboot (persist needs root)
  for k in $keys; do echo "$k=$(A settings get global "$k")"; done
  echo "Log buffers 256K until reboot (persistent: Developer options > Logger buffer sizes)."
}

# ---------------------------------------------------------------- report
cmd_report() {
  pick_device
  local design="${1:-}"
  REPORT_TMP=$(mktemp -d); trap 'rm -rf "$REPORT_TMP"' EXIT   # global: the trap runs after this function returns
  local tmp="$REPORT_TMP"

  echo; echo "== Current state"
  A dumpsys battery | grep -E '^ +(status|health|level|voltage|temperature|Charge counter|technology):' |
    awk -F': ' '{k=$1; gsub(/^ +/,"",k); v=$2
      if(k=="status"){m["1"]="unknown";m["2"]="charging";m["3"]="discharging";m["4"]="not charging";m["5"]="full"; v=v" ("m[v]")"}
      if(k=="health"){h["1"]="unknown";h["2"]="good";h["3"]="overheat";h["4"]="dead";h["5"]="overvoltage";h["6"]="failure";h["7"]="cold"; v=v" ("h[v]")"}
      if(k=="temperature") v=v/10" C"; if(k=="voltage") v=v" mV"
      if(k=="Charge counter") v=int(v/1000)" mAh remaining (as reported)"
      printf "  %-15s %s\n", k, v}'

  echo; echo "== Cycle count"
  local cc; cc=$(A cat /sys/class/power_supply/battery/cycle_count 2>/dev/null | grep -E '^[0-9]+$')
  [[ -n "$cc" ]] && echo "  $cc cycles" || echo "  Not readable without root - check Settings > Battery > Battery health."

  batterystats_to "$tmp/bs.txt"
  echo; echo "== Capacity / health"
  grep -E 'Estimated battery capacity|learned battery capacity' "$tmp/bs.txt" | sed 's/^ */  /'
  local learned; learned=$(awk -F': ' '/Last learned battery capacity/ && !v {split($2,a," "); v=a[1]} END{print v}' "$tmp/bs.txt")
  [[ -n "$design" && -n "$learned" ]] && awk -v l="$learned" -v d="$design" 'BEGIN{
    r=l/d*100; printf "  Health vs %d mAh rated: %.0f%%\n", d, r
    if (r<60) printf "  <60%% usually = per-cell reporting on a dual-cell pack. Health vs %d mAh: %.0f%%\n", d/2, l/(d/2)*100 }'

  echo; echo "== Drain since last charge"
  awk -F': ' '
    function hrs(s,  t,n,i,u,p){t=0;n=split(s,p," ");for(i=1;i<=n;i++){u=p[i];
      if(u~/ms$/)t+=u/3600000; else if(u~/h$/)t+=u+0; else if(u~/m$/)t+=u/60; else if(u~/s$/)t+=u/3600}; return t}
    /Time on battery screen off:/{split($2,a," [(]"); off=hrs(a[1])}
    /Screen on: .*Interactive/{split($2,a," [(]"); on=hrs(a[1])}
    /^  Screen off discharge:/{offd=$2+0} /^  Screen on discharge:/{ond=$2+0}
    /Last learned battery capacity/{cap=$2+0}
    END{ if(cap>0){
      if(on>0)  printf "  Screen on : %.1f h, %d mAh -> %.1f%%/h\n", on, ond, ond/on/cap*100
      if(off>0) printf "  Screen off: %.1f h, %d mAh -> %.1f%%/h (good ~1%%/h, high >2.5%%/h)\n", off, offd, offd/off/cap*100 }}' "$tmp/bs.txt"

  # -c, not --checkin: --checkin also emits (and deletes) the previous period's saved stats.
  A dumpsys batterystats -c --charged > "$tmp/ci.txt" 2>/dev/null
  A pm list packages -3 --user 0 | sed 's/package://' > "$tmp/user.txt"
  A pm list packages -U --user 0 | sed 's/package://' |
    awk '{split($2,a,":"); if(!(a[2] in s)) s[a[2]]=$1; else s[a[2]]="(shared-uid)"} END{for(u in s) print u, s[u]}' > "$tmp/uid.txt"
  name() { case $1 in 0) echo "kernel/root";; 1000) echo "android-system(shared:AOD,SystemUI...)";; 1001) echo "radio/telephony";;
    *) local n; n=$(awk -v u="$1" '$1==u{print $2}' "$tmp/uid.txt"); echo "${n:-uid-$1}";; esac; }

  echo; echo "== Top apps by estimated power (mAh, since last charge)"
  awk -F, '$4=="pwi" && $5=="uid"{print $6, $2}' "$tmp/ci.txt" | sort -rn | head -12 |
    while read -r mah uid; do printf "  %8s  %s\n" "$mah" "$(name "$uid")"; done

  echo; echo "== User apps active off-screen (hours: fg service / background)"
  awk -F, '$4=="st" && $2>=10000{print ($6+$9)/3600000, $6/3600000, $9/3600000, $2}' "$tmp/ci.txt" | sort -rn |
    while read -r tot fgs bg uid; do n=$(name "$uid"); grep -qx "$n" "$tmp/user.txt" && printf "  %5.1f / %5.1f  %s\n" "$fgs" "$bg" "$n"; done | head -8

  echo; echo "== Top wakeup alarms"
  awk -F, '$4=="wua"{print $6, $2, $5}' "$tmp/ci.txt" | sort -rn | head -8 |
    while read -r n uid tag; do printf "  %5s  %-38s %s\n" "$n" "$(name "$uid" | cut -c1-38)" "$tag"; done
}

# ---------------------------------------------------------------- calibrate
cmd_calibrate() {
  pick_device
  local base="$STATE_DIR/calibration_baseline.txt" clog="$STATE_DIR/calibration.log"
  read_state() {
    local b; b=$(A dumpsys battery)
    LEVEL=$(awk -F': ' '/^  level:/{print $2}' <<<"$b")
    STATUS=$(awk -F': ' '/^  status:/{print $2}' <<<"$b")
    TEMP=$(awk -F': ' '/^  temperature:/{print $2/10}' <<<"$b")
    COUNTER=$(awk -F': ' '/^  Charge counter:/{print int($2/1000)}' <<<"$b")
    PLUGGED=$(grep -cE '^  (AC|USB|Wireless) powered: true' <<<"$b")
  }
  case "${1:-check}" in
    check)
      read_state
      echo "level=$LEVEL% status=$STATUS plugged=$PLUGGED temp=${TEMP}C counter=${COUNTER}mAh learned=$(learned_capacity)mAh"
      [[ "$(A getprop persist.vivo.battery_charge_limit)" == 1 ]] && echo "BLOCKER: vivo charge limit / smart charging is ON - turn it off in Settings > Battery (re-enable afterwards)."
      awk -v t="$TEMP" 'BEGIN{ if (t>35) print "WARN: battery is " t "C - let it cool below 35C first." }' ;;
    start)
      read_state
      printf 'date=%s\nlevel=%s\ncounter=%s\nlearned=%s\n' "$(date '+%F %T')" "$LEVEL" "$COUNTER" "$(learned_capacity)" > "$base"
      cat "$base"; echo "Baseline saved. Next: plug in and run: $0 calibrate watch full" ;;
    watch)
      local goal="${2:?full|empty}" full_since="" left
      while true; do
        read_state
        echo "$(date '+%F %T') level=$LEVEL status=$STATUS plugged=$PLUGGED temp=${TEMP}C counter=$COUNTER" | tee -a "$clog"
        awk -v t="$TEMP" 'BEGIN{ if (t>42) print "  WARN: " t "C - let the phone rest, heat skews the result" }'
        if [[ $goal == full ]]; then
          [[ $PLUGGED -eq 0 ]] && echo "  Not plugged in - connect the charger."
          if [[ $LEVEL -ge 100 && $PLUGGED -gt 0 ]]; then
            full_since=${full_since:-$(date +%s)}; left=$(( 60 - ($(date +%s) - full_since) / 60 ))
            [[ $left -le 0 ]] && { echo "FULL phase done. Unplug, use normally to ~5%, then: $0 calibrate watch empty"; break; }
            echo "  At 100% - keep plugged ${left} more min."
          else full_since=""; fi
        else
          [[ $PLUGGED -gt 0 ]] && echo "  Still plugged in - unplug for the discharge phase."
          [[ $LEVEL -le 5 ]] && { echo "EMPTY phase done. Charge uninterrupted to 100%, then: $0 calibrate finish"; break; }
        fi
        sleep "${INTERVAL:-120}"
        adb connect "$DEV" >/dev/null 2>&1 || true   # wireless ADB drops while the screen is off
      done ;;
    finish)
      [[ -f "$base" ]] || { echo "No baseline - run: $0 calibrate start"; exit 1; }
      local now before; now=$(learned_capacity); before=$(awk -F= '/^learned=/{print $2}' "$base")
      echo "Learned capacity: before ${before} mAh -> now ${now} mAh"
      awk -v b="$before" -v n="$now" 'BEGIN{ d=n-b; printf "Change: %+d mAh (%+.1f%%)\n", d, (b>0? d/b*100:0)
        if (d==0) print "Unchanged: Android updates this after a full charge from low - do one more full charge." }'
      echo "Turn smart charging / the charge limit back on." ;;
    *) echo "Usage: calibrate check|start|watch full|watch empty|finish"; exit 1 ;;
  esac
}

# ---------------------------------------------------------------- main
cmd="${1:-}"; shift || true
case "$cmd" in
  report) cmd_report "$@" ;;
  debloat) cmd_debloat "$@" ;;
  restore) cmd_restore "$@" ;;
  tune) cmd_tune "$@" ;;
  calibrate) cmd_calibrate "$@" ;;
  *) sed -n '2,14p' "$0"; exit 1 ;;
esac
