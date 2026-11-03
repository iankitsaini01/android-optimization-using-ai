#!/usr/bin/env bash
# UI + background tweaks that use only standard settings. Originals are backed up once.
# Usage: ./optimize.sh [--anim 0.5] | ./optimize.sh --restore
set -u
source "$(dirname "$0")/lib.sh"
pick_device
BACKUP="$STATE_DIR/settings_backup.txt"
KEYS=(window_animation_scale transition_animation_scale animator_duration_scale
      wifi_scan_always_enabled ble_scan_always_enabled)

if [[ "${1:-}" == "--restore" ]]; then
  [[ -f "$BACKUP" ]] || { echo "No backup at $BACKUP"; exit 1; }
  while read -r k v; do
    if [[ "$v" == "null" ]]; then A settings delete global "$k" >/dev/null; else A settings put global "$k" "$v"; fi
    echo "restored $k=$v"
  done < "$BACKUP"
  A logcat -b main,system,radio,events -G 4M && echo "log buffers -> 4M"
  exit 0
fi
ANIM=0.5; [[ "${1:-}" == "--anim" ]] && ANIM="${2:?value}"

if [[ ! -f "$BACKUP" ]]; then
  for k in "${KEYS[@]}"; do echo "$k $(A settings get global "$k")"; done > "$BACKUP"
  echo "Saved originals to $BACKUP"
fi

# 1. Animation speed - the change users actually feel
for k in window_animation_scale transition_animation_scale animator_duration_scale; do
  A settings put global "$k" "$ANIM"
done
# 2. No Wi-Fi/BLE scanning while those radios are off (fewer wakeups; slightly worse indoor location)
A settings put global wifi_scan_always_enabled 0
A settings put global ble_scan_always_enabled 0
# 3. Smaller log ring buffers. Runtime only: persist.logd.size needs root, so re-run after reboot
#    or set Developer options > Logger buffer sizes > 256K for a persistent equivalent.
A logcat -b main,system,radio,events -G 256K

echo "--- now"
for k in "${KEYS[@]}"; do echo "$k=$(A settings get global "$k")"; done
A logcat -g
