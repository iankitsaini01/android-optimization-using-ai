#!/usr/bin/env bash
# Removes packages for user 0 (reversible). If the OEM blocks removal it tries disable,
# then falls back to blocking background running + notifications. Every action is logged
# to state/<device>/actions.log so restore.sh can undo it.
# Usage: ./debloat.sh [--dry-run] lists/<list>.txt [more lists...]
set -u
source "$(dirname "$0")/lib.sh"
DRY=0; [[ "${1:-}" == "--dry-run" ]] && { DRY=1; shift; }
[[ $# -ge 1 ]] || { echo "Usage: $0 [--dry-run] <list.txt>..."; exit 1; }
pick_device
LOG="$STATE_DIR/actions.log"
INSTALLED=$(A pm list packages --user 0 | sed 's/package://')

for p in $(read_list "$@" | awk '!seen[$0]++'); do
  if is_protected "$p" && [[ "${FORCE:-0}" != 1 ]]; then
    echo "REFUSED     $p (matches NEVER-REMOVE.txt)"; continue
  fi
  if ! grep -qx "$p" <<<"$INSTALLED"; then echo "skip        $p (not installed)"; continue; fi
  if [[ $DRY == 1 ]]; then echo "would-remove $p"; continue; fi

  if A pm uninstall -k --user 0 "$p" | grep -q '^Success'; then
    echo "uninstalled $p" | tee -a "$LOG"
  elif A pm disable-user --user 0 "$p" 2>&1 | grep -q 'disabled-user'; then
    echo "disabled    $p" | tee -a "$LOG"
  else
    A cmd appops set "$p" RUN_ANY_IN_BACKGROUND ignore >/dev/null 2>&1
    A pm revoke "$p" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1
    echo "restricted  $p (OEM-protected: background + notifications blocked)" | tee -a "$LOG"
  fi
done
[[ $DRY == 1 ]] || echo "Log: $LOG  - reboot, then test calls, SMS, data, fingerprint, camera. Undo: ./restore.sh"
