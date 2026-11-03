# AGENTS.md: playbook for AI agents optimizing Android devices over ADB

Use this when a user asks you to debloat, speed up, analyze the battery of, or calibrate an Android phone connected over ADB. The scripts are documented in [README.md](README.md). This file covers how to use them safely.

## Hard rules
1. **Never remove, disable or restrict anything in `lists/NEVER-REMOVE.txt`.** Don't set `FORCE=1` unless the user names the specific package and accepts the risk.
2. **Removing packages:** always run `--dry-run` first, show the user the list, and wait for an explicit yes. Every removal changes their phone. Run `optional` lists only after a separate yes.
3. **Only use reversible methods:** `pm uninstall -k --user 0`, `pm disable-user`, appops/permission restrictions, `settings put`. Never use root, `pm uninstall` without `--user 0`, `rm` on system paths, `wipe`, `reboot bootloader/recovery`, `setprop` on `ro.*`, or flashing.
4. **Don't touch apps the user installed** (`pm list packages -3`) unless the user names them.
5. **Report faithfully.** Give counts of removed, disabled and restricted packages, and say exactly which steps failed or were skipped.
6. **Don't sell placebo.** Skip "speed tweaks" with no measurable effect, such as GPU-rendering flags or random `build.prop` values. Say what each change actually does and what it costs.

## Workflow
```bash
export ADB_DEVICE=<ip:port or serial>
adb -s $ADB_DEVICE shell getprop ro.product.manufacturer   # pick lists for the OEM
adb -s $ADB_DEVICE shell pm list packages --user 0         # full list (ask the user if it's needed)
./battery_report.sh <rated_mAh>                            # read-only baseline
./debloat.sh --dry-run lists/generic-core.txt lists/<oem>-core.txt
#  show the result, get a yes
./debloat.sh lists/generic-core.txt lists/<oem>-core.txt
#  ask the user to reboot and test: calls, SMS, mobile data, fingerprint, camera
./optimize.sh            # after a yes
```

### Same workflow with the single-file tool
`./android-optimize.sh` has the lists and NEVER-REMOVE built in. Sets: `core`, `optional`, `vivo-core`, `vivo-optional`, `all`, or a list file.
```bash
./android-optimize.sh report <rated_mAh>                  # read-only baseline
./android-optimize.sh debloat --dry-run core vivo-core    # `core` alone on non-vivo phones
./android-optimize.sh debloat core vivo-core              # after a yes
./android-optimize.sh debloat optional vivo-optional      # only after a separate yes; explain each item
./android-optimize.sh tune                                # after a yes
./android-optimize.sh restore [pkg ...]                   # undo all debloat actions, or only the named packages
./android-optimize.sh tune --restore                      # put the original settings back
```
`tune` sets 0.5x animations, turns off Wi-Fi/BT scanning while those radios are off, and sets 256K log buffers (the buffers reset on reboot). Calibration uses `./android-optimize.sh calibrate check|start|watch full|watch empty|finish`, the same steps as `calibrate.sh` below.

### When the device's OEM has no list yet
Write a list from the device's package list and the NEVER-REMOVE rules. Start new `<oem>-core.txt` lists conservatively and comment each line. Good candidates:
- Ads/promo surfaces: lock-screen magazines, app stores, "quick apps", browsers
- Survey and feedback apps
- Logging apps (`*log*`), if not blocked
- Facebook and Microsoft preinstalls
- Region-specific payment apps that don't fit the user

Never include radio/IMS packages, anything with `daemon`/`power`/`framework` in the name, OEM account/updater apps, launchers, or anything you can't identify.

## Interpreting results
| Output | Meaning | What to do |
|---|---|---|
| `Success` | Removed for user 0 | Log it |
| `DELETE_FAILED_USER_RESTRICTED` | The OEM blocks removal (common on vivo/iQOO) | The script tries disable, then restrict |
| `DELETE_FAILED_INTERNAL_ERROR` | Removal is blocked another way | Disable usually works |
| `SecurityException ... no root permission` on disable | OEM-protected | Restrict (background + notifications) is the most you can do without root |
| `Shell does not have permission to access user 10` | A second space or app-clone user exists | Harmless; the kit works on user 0 only |

## Battery analysis notes
- **Cycle count:** usually in `/sys/class/power_supply/battery/cycle_count`, which is often root-only. If you can't read it, say so plainly and don't invent a number.
- **Health** = `Last learned battery capacity` ÷ rated capacity. Values around 45–50% usually mean a two-cell battery that reports per cell. Compare against half the rated capacity, and confirm with the charge counter: `Charge counter / level%` should roughly equal the learned capacity.
- **Use `dumpsys batterystats -c --charged`, not `--checkin`.** `--checkin` also prints the previous period's saved stats and then deletes them, which gives wrong per-app numbers.
- **UID 1000 is shared** by the system and things like AOD or SystemUI parts. Map UIDs with `pm list packages -U`, and never attribute UID 1000 to the first package that matches it.
- **`st` fields:** in `st` rows, field 6 is foreground-service time and field 9 is background time (ms). System services are always bound in the foreground, so only flag user apps.
- **Screen-off drain:** about 1%/h is good; over 2.5%/h means look at `wua` (wakeup alarms) and `wl` (wakelocks).
- **Retries:** the full `dumpsys batterystats` text is around 400k lines and sometimes comes back empty over wireless ADB. Retry, and never pipe it into `grep -m1` or `head`, because closing early truncates the read.

## Battery calibration
Software can't directly calibrate a lithium battery's gauge. Tell the user that, then guide one physical cycle with `calibrate.sh`. It takes hours and the user has to plug and unplug the phone, so you can only monitor.
1. `./calibrate.sh check`. Fix the blockers first: on vivo/iQOO, `persist.vivo.battery_charge_limit=1` means the user must turn off the charge limit / smart charging in Settings. ADB can't change it.
2. `./calibrate.sh start` saves the learned-capacity baseline.
3. `./calibrate.sh watch full` runs until 100% plus 60 minutes plugged in. Run it in the background and tell the user when to unplug.
4. The user drains the phone to about 5%: `./calibrate.sh watch empty`.
5. The user charges to 100% without interruption, then `./calibrate.sh finish` compares the learned capacity.
6. Remind the user to turn the charge limit back on. Don't recommend calibrating more than every few months.

Don't present `dumpsys batterystats --reset` or deleting `batterystats.bin` as calibration.

## Gotchas
- **ADB stdin:** `adb shell` reads stdin. Inside `while read` loops, use `</dev/null` (the kit's `A` helper does this).
- **Log buffers:** `persist.logd.size` can't be set from shell without root; `logcat -G` only lasts until reboot.
- **Wireless ADB:** the port changes when wireless debugging is toggled; reconnect with `adb connect`.
- **OEM changes:** OEM updates may re-enable bloat or undo restrictions. Suggest a dry-run after each update.
