# Android Optimize Kit

This folder optimizes Android phones over ADB without root. The main tool is `./android-optimize.sh`, a single self-contained file. The split scripts (`debloat.sh`, `battery_report.sh`, etc.) do the same jobs.

@AGENTS.md

## Claude-specific
- **Start read-only:** `./android-optimize.sh report <rated_mAh>` and `./android-optimize.sh debloat --dry-run <set>`. Show the user what would change before anything else.
- **Ask before changing anything:** get explicit approval before `debloat`, `tune` or `restore`. If the user approves the `core` sets, that doesn't cover the `optional` ones; ask again.
- **Long jobs:** run `calibrate watch full|empty` in the background, since it takes hours. Tell the user exactly when to plug in or unplug.
- **Device:** if several devices are connected, set `ADB_DEVICE`. If the user pastes a placeholder like `[PASTE ... HERE]` instead of data, collect the data from the device yourself.
- **Final report:** give counts of removed, disabled and restricted packages; what survives a reboot (everything except log buffer size); and how to undo (`restore`, `tune --restore`).
