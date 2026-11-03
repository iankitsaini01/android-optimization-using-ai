# Shared helpers, sourced by the other scripts.
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Selects the target device: $ADB_DEVICE (serial or ip:port), else the only connected device.
pick_device() {
  if [[ -n "${ADB_DEVICE:-}" ]]; then
    [[ "$ADB_DEVICE" == *:* ]] && adb connect "$ADB_DEVICE" >/dev/null
    DEV="$ADB_DEVICE"
  else
    local devs n
    devs=$(adb devices | awk 'NR>1 && $2=="device"{print $1}')
    n=$(printf '%s\n' "$devs" | grep -c .)
    if [[ $n -ne 1 ]]; then
      echo "Found $n connected devices. Set ADB_DEVICE=<serial or ip:port>." >&2
      adb devices >&2; exit 1
    fi
    DEV="$devs"
  fi
  STATE_DIR="$KIT_DIR/state/$(echo "$DEV" | tr ':/' '__')"
  mkdir -p "$STATE_DIR"
  echo "Device: $DEV ($(A getprop ro.product.manufacturer) $(A getprop ro.product.model), Android $(A getprop ro.build.version.release))"
}

# Runs a command on the device. stdin is closed so adb doesn't swallow loop input.
A() { adb -s "$DEV" shell "$@" </dev/null | tr -d '\r'; }

# Prints package names from list files, ignoring comments and blank lines.
read_list() { sed -e 's/#.*//' -e 's/[[:space:]]//g' "$@" | grep -v '^$'; }

# True if the package matches lists/NEVER-REMOVE.txt.
is_protected() { grep -qxE "$(read_list "$KIT_DIR/lists/NEVER-REMOVE.txt" | paste -sd'|' -)" <<<"$1"; }
