# NetWatch

DIY macOS menubar app for travel-time network monitoring. Open-source replacement for TripMode ($20/yr).

![NetWatch Screenshot](assets/screenshot.png)

## What it does

- **Live counter** — bytes/sec in menubar
- **Per-app traffic** — icons + bytes consumed today
- **Daily / weekly history** — SQLite-backed, ~7 day charts
- **Travel Mode** — bulk quit known background parasites (Dropbox, iCloud sync, Spotify, etc.)
- **Cost estimate** — based on $4/GB Starlink rate (configurable)

## What it does NOT do

- True per-app firewall — that's [Lulu's](https://objective-see.org/products/lulu.html) job (free). On macOS, per-app network blocking without quitting the process requires a signed Network Extension = $99/yr Apple Developer Program. NetWatch goes a simpler route: quit / launchctl bootout to actually stop the consumption.

## Requirements

- macOS 14+ (Sonoma or newer)
- Xcode Command Line Tools (`xcode-select --install`)
- One-time: grant Full Disk Access to NetWatch in System Settings → Privacy & Security (for `nettop` to see other processes' traffic)

## Build & run

```bash
git clone https://github.com/<your-user>/netwatch.git
cd netwatch
swift build -c release
.build/release/NetWatch
```

For dev:
```bash
swift run NetWatch
```

To install as a proper `.app` bundle in `/Applications`:
```bash
./scripts/install.sh
```

## Data location

- SQLite stats: `~/Library/Application Support/NetWatch/stats.sqlite`
- Travel Mode preset: `UserDefaults` under `netwatch.travelTargets`

## Contributing

PRs welcome. A few good-first-issues to start with:
- Inline `Database.getDayStats(date:)` into `getTodayStats()` (only caller)
- Combine `MenubarView.inSettings` + `selectedPeriod` into a single enum state
- Extract `3 * NSEC_PER_SEC` magic number in `AppController.swift` into a named constant

## License

MIT — see [LICENSE](LICENSE). Free for personal, commercial, and educational use.
