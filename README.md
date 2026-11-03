# Android Optimize Kit (ADB, no root)

Debloat, speed up the UI, read battery health, and calibrate the battery gauge over USB or wireless ADB.
Every change can be undone. Built and tested on an **iQOO 12 (vivo I2220, Funtouch OS, Android 16)**. The generic lists and all scripts work on any Android phone.

> **AI agents:** read [AGENTS.md](AGENTS.md) before running anything. **Claude Code:** open this folder and `CLAUDE.md` loads automatically; or type `/android-optimize`.

## Quick start: one file
`android-optimize.sh` is self-contained: the package lists and the safety denylist are built in. You can share just this file.
```bash
./android-optimize.sh report 5000                       # battery health + drain (read-only)
./android-optimize.sh debloat --dry-run core vivo-core  # preview
./android-optimize.sh debloat core vivo-core            # apply   (sets: core optional vivo-core vivo-optional all, or a file)
./android-optimize.sh tune                              # 0.5x animations, fewer background scans, small log buffers
./android-optimize.sh calibrate check                   # then: start / watch full / watch empty / finish
./android-optimize.sh restore                           # undo debloat;  tune --restore undoes tune
```
The split scripts below do the same jobs, if you want to edit them separately.

## Requirements
- `adb` on your computer (`brew install android-platform-tools`, or Google's Platform Tools)
- On the phone, in Developer options: **USB debugging**, plus **Wireless debugging** if you connect over Wi-Fi
- macOS or Linux shell (bash 3.2+)

## Connect
```bash
adb pair <ip>:<pair-port>          # first time only, use the code shown under Wireless debugging
adb connect <ip>:<port>
export ADB_DEVICE=<ip>:<port>      # optional if only one device is connected
```

## What's in the kit
| File | What it does | Changes the phone? |
|---|---|---|
| `battery_report.sh [rated_mAh]` | Battery health, drain per hour, top power users, wakeups | No (read-only) |
| `debloat.sh [--dry-run] lists/*.txt` | Removes bloat (see below for how) | Yes, undo with `restore.sh` |
| `restore.sh [pkg...]` | Undoes `debloat.sh` (everything, or the packages you list) | Yes |
| `optimize.sh [--anim 0.5]` | Animations at 0.5x, no background Wi-Fi/BT scanning, smaller log buffers | Yes, undo with `--restore` |
| `calibrate.sh check\|start\|watch\|finish` | Guided battery-gauge calibration | No (it only monitors) |
| `lists/NEVER-REMOVE.txt` | Critical packages the scripts refuse to touch | |
| `lists/generic-*.txt`, `lists/vivo-*.txt` | Package lists (`core` = low risk, `optional` = removes features) | |

All logs and backups are saved in `state/<device>/`.

## Recommended order
```bash
./battery_report.sh 5000                                     # 1. baseline (pass your rated capacity)
./debloat.sh --dry-run lists/generic-core.txt lists/vivo-core.txt   # 2. preview
./debloat.sh lists/generic-core.txt lists/vivo-core.txt             # 3. apply
#    reboot, then test calls, SMS, mobile data, fingerprint, camera
./debloat.sh lists/generic-optional.txt lists/vivo-optional.txt     # 4. optional - read the list first
./optimize.sh                                                # 5. faster UI
```

## How debloat works
For each package, it tries these in order:
1. **Uninstall for user 0** (`pm uninstall -k --user 0`). The app is hidden for you, but the APK stays in the system partition.
2. **Disable** (`pm disable-user`) if the manufacturer blocks uninstalling.
3. **Restrict** if the manufacturer blocks disabling too, which vivo does for some apps (`DELETE_FAILED_USER_RESTRICTED`). The app stays installed but can't run in the background or send notifications.

`debloat.sh` refuses anything that matches `lists/NEVER-REMOVE.txt`: telephony, Qualcomm/QTI, SystemUI, Play services, providers, fingerprint/face unlock, and so on.

## What survives a reboot?
| Change | After reboot | When it can come back |
|---|---|---|
| Uninstalled for user 0 | **Stays removed** | Factory reset; sometimes a major system update |
| Disabled | **Stays disabled** | Factory reset; sometimes a system update |
| Restricted (background + notifications) | **Stays** | System update or the vendor's app manager may reset it |
| Animation scale, Wi-Fi/BT scanning | **Stays** | Developer options reset |
| Log buffer size | **Resets to default** | Every reboot. Re-run `optimize.sh`, or set Developer options → Logger buffer sizes → 256K, which persists |

After each system update, run `./debloat.sh --dry-run <lists>`. Anything showing `would-remove` came back.

## Battery health: reading the report
- **The cycle count needs root on most phones.** If the report can't read it, check Settings → Battery → Battery health.
- **Health = learned capacity ÷ rated capacity.** If you get under 60%, the phone is probably reporting one cell of a two-cell battery; the report also shows the result against half the rated capacity. On the iQOO 12 it reports about 2,360 of 2,500 mAh, which is **about 94%**.
- **Screen-off drain:** about 1% per hour is good. Over 2.5% per hour means something keeps waking the phone; look at "Top wakeup alarms".
- **UID 1000 ("android system") is shared** by many system parts, including the always-on display. Don't blame a single app for it.

## Battery calibration
Software can't directly calibrate a lithium battery's gauge. Calibration means one controlled full cycle, which lets the gauge re-learn where 0% and 100% are. Do it if the percentage jumps, or the phone shuts down early. **Once every few months at most:** deep discharges wear the battery.

```bash
./calibrate.sh check        # finds blockers: charge limit / smart charging, heat
./calibrate.sh start        # saves learned capacity as a baseline
./calibrate.sh watch full   # plug in; finishes at 100% + 60 min on the charger
#  unplug, use normally (no charging) down to ~5%
./calibrate.sh watch empty  # finishes at <=5%
#  charge to 100% without interruption
./calibrate.sh finish       # compares learned capacity before and after
```
- **vivo/iQOO:** turn off the **charge limit / smart charging** first, otherwise the phone never reaches a real 100%. `check` detects this (`persist.vivo.battery_charge_limit=1`). Turn it back on when you're done.
- Keep the phone below about 40 °C during the cycle. Don't run games while charging.
- Wireless ADB can drop while the screen is off. `watch` reconnects every 2 minutes (change it with `INTERVAL=60`).
- `dumpsys batterystats --reset` and deleting `batterystats.bin` do **not** calibrate anything. They only clear usage history.

## Undo everything
```bash
./restore.sh               # all debloat actions, in reverse order
./optimize.sh --restore    # original settings from the backup
```
For a manual undo of a single app:
- Uninstalled: `adb shell cmd package install-existing <pkg>`
- Disabled: `adb shell pm enable <pkg>`
- Restricted: `adb shell cmd appops set <pkg> RUN_ANY_IN_BACKGROUND allow`

## Tested results (iQOO 12, Funtouch OS, Android 16)
- **Removed:** 30 packages
- **Disabled:** `com.vivo.magazine`, `com.android.bbkmusic`
- **Restricted (vivo-protected):** `bbk.iqoo.logsystem`, `vivo.appstore`, `vivo.globalsearch`, `iqoo.website`, `vivo.pushservice`, `vivo.cota`, `vivo.hiboard`, `vivo.assistant`, `vivo.pcsuite`, `vivo.videoeditor`
- **No bootloop.** Calls, SMS, mobile data and fingerprint unlock were unaffected.
