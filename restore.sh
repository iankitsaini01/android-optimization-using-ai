#!/usr/bin/env bash
# Undoes debloat.sh. No args: undo everything in the log. With args: only those packages.
set -u
source "$(dirname "$0")/lib.sh"
pick_device
LOG="$STATE_DIR/actions.log"
[[ -f "$LOG" ]] || { echo "No log at $LOG - nothing to restore."; exit 1; }

awk '{a[NR]=$0} END{for(i=NR;i>0;i--) print a[i]}' "$LOG" | while read -r action p _; do
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
[[ $# -eq 0 ]] && mv "$LOG" "$LOG.restored.$(date +%Y%m%d_%H%M%S)"
