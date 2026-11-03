#!/usr/bin/env bash
# Read-only battery health + drain report.
# Usage: ./battery_report.sh [rated_capacity_mAh]   e.g. ./battery_report.sh 5000
set -u
source "$(dirname "$0")/lib.sh"
pick_device
DESIGN="${1:-}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo; echo "== Current state"
A dumpsys battery | grep -E '^ +(status|health|level|voltage|temperature|Charge counter|technology):' |
  awk -F': ' '{k=$1; gsub(/^ +/,"",k); v=$2
    if(k=="status"){m["1"]="unknown";m["2"]="charging";m["3"]="discharging";m["4"]="not charging";m["5"]="full"; v=v" ("m[v]")"}
    if(k=="health"){h["1"]="unknown";h["2"]="good";h["3"]="overheat";h["4"]="dead";h["5"]="overvoltage";h["6"]="failure";h["7"]="cold"; v=v" ("h[v]")"}
    if(k=="temperature") v=v/10" C"
    if(k=="voltage") v=v" mV"
    if(k=="Charge counter") v=int(v/1000)" mAh remaining (as reported)"
    printf "  %-15s %s\n", k, v}'

echo; echo "== Cycle count"
cc=$(A cat /sys/class/power_supply/battery/cycle_count 2>/dev/null | grep -E '^[0-9]+$')
[[ -n "$cc" ]] && echo "  $cc cycles" || echo "  Not readable without root on this device - check Settings > Battery > Battery health."

# The dump occasionally comes back empty over wireless ADB, so retry.
for i in 1 2 3 4 5; do
  A dumpsys batterystats > "$TMP/bs.txt" 2>/dev/null
  grep -q 'Last learned battery capacity' "$TMP/bs.txt" && break; sleep 2
done
echo; echo "== Capacity / health"
grep -E 'Estimated battery capacity|learned battery capacity' "$TMP/bs.txt" | sed 's/^ */  /'
learned=$(grep -m1 'Last learned battery capacity' "$TMP/bs.txt" | grep -oE '[0-9]+' | head -1)
if [[ -n "$DESIGN" && -n "$learned" ]]; then
  awk -v l="$learned" -v d="$DESIGN" 'BEGIN{
    r=l/d*100; printf "  Health vs %d mAh rated: %.0f%%\n", d, r
    if (r<60) printf "  NOTE: <60%% usually means the device reports one cell of a dual-cell pack.\n        Health vs %d mAh (half): %.0f%%\n", d/2, l/(d/2)*100 }'
fi

echo; echo "== Drain since last charge"
awk -F': ' '
  function hrs(s,  t,n,i,u){t=0;n=split(s,p," ");for(i=1;i<=n;i++){u=p[i];
    if(u~/ms$/)t+=u/3600000; else if(u~/h$/)t+=u+0; else if(u~/m$/)t+=u/60; else if(u~/s$/)t+=u/3600}; return t}
  /Time on battery screen off:/{split($2,a," [(]"); off=hrs(a[1])}
  /Screen on: .*Interactive/{split($2,a," [(]"); on=hrs(a[1])}
  /^  Screen off discharge:/{offd=$2+0} /^  Screen on discharge:/{ond=$2+0}
  /Last learned battery capacity/{cap=$2+0}
  END{ if(cap>0){
    if(on>0)  printf "  Screen on : %.1f h, %d mAh -> %.1f%%/h\n", on, ond, ond/on/cap*100
    if(off>0) printf "  Screen off: %.1f h, %d mAh -> %.1f%%/h (good: ~1%%/h, high: >2.5%%/h)\n", off, offd, offd/off/cap*100 }}' "$TMP/bs.txt"

# -c, not --checkin: --checkin also emits (and deletes) the previous period's saved stats.
A dumpsys batterystats -c --charged > "$TMP/ci.txt" 2>/dev/null
A pm list packages -3 --user 0 | sed 's/package://' > "$TMP/user_apps.txt"
A pm list packages -U --user 0 | sed 's/package://' | awk '{split($2,a,":"); if(!(a[2] in s)) s[a[2]]=$1; else s[a[2]]="(shared-uid)"} END{for(u in s) print u, s[u]}' > "$TMP/uid.txt"
name() { case $1 in 0) echo "kernel/root";; 1000) echo "android system (shared: AOD, SystemUI services, etc.)";; 1001) echo "radio/telephony";;
  *) n=$(awk -v u="$1" '$1==u{print $2}' "$TMP/uid.txt"); echo "${n:-uid $1}";; esac; }

echo; echo "== Top apps by estimated power (mAh)"
awk -F, '$4=="pwi" && $5=="uid"{print $6, $2}' "$TMP/ci.txt" | sort -rn | head -12 |
  while read -r mah uid; do printf "  %8s  %s\n" "$mah" "$(name "$uid")"; done

echo; echo "== User apps active while not on screen (hours: fg service / background)"
awk -F, '$4=="st" && $2>=10000{print ($6+$9)/3600000, $6/3600000, $9/3600000, $2}' "$TMP/ci.txt" | sort -rn |
  while read -r tot fgs bg uid; do n=$(name "$uid"); grep -qx "$n" "$TMP/user_apps.txt" && printf "  %5.1f / %5.1f  %s\n" "$fgs" "$bg" "$n"; done | head -8

echo; echo "== Top wakeup alarms"
awk -F, '$4=="wua"{print $6, $2, $5}' "$TMP/ci.txt" | sort -rn | head -8 |
  while read -r n uid tag; do printf "  %5s  %-40s %s\n" "$n" "$(name "$uid" | cut -c1-40)" "$tag"; done

echo; echo "== Longest app wakelocks (min)"
awk -F, '$4=="wl"{for(i=6;i<=NF;i++) if($i=="p"){print $(i+1)/60000, $2, $5; break}}' "$TMP/ci.txt" | sort -rn | head -5 |
  while read -r m uid tag; do printf "  %6.1f  %s  %s\n" "$m" "$(name "$uid")" "$tag"; done
