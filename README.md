# NetWatch

DIY macOS menubar app for travel-time network monitoring. Replacement for TripMode ($20/yr).

## What it does

- **Live counter** — bytes/sec in menubar
- **Per-app traffic** — icons + bytes consumed today
- **Daily / weekly history** — SQLite-backed, ~7 day charts
- **Travel Mode** — bulk quit known background paraсites (Dropbox, iCloud sync, Spotify, etc.)
- **Cost estimate** — based on $4/GB Starlink rate (configurable)

## What it does NOT do

- True per-app firewall — that's [Lulu's](https://objective-see.org/products/lulu.html) job (free). On macOS, per-app network blocking without quitting the process requires a signed Network Extension = $99/yr Apple Developer Program. NetWatch goes a simpler route: quit / launchctl bootout to actually stop the consumption.

## Requirements

- macOS 13+ (Ventura or newer)
- Xcode Command Line Tools (`xcode-select --install`)
- One-time: grant Full Disk Access to NetWatch in System Settings → Privacy & Security (for `nettop` to see other processes' traffic)

## Build & run

```bash
git clone <this repo> ~/Projects/netwatch
cd ~/Projects/netwatch
swift build -c release
.build/release/NetWatch
```

For dev:
```bash
swift run NetWatch
```

## Data location

- SQLite stats: `~/Library/Application Support/NetWatch/stats.sqlite`
- Travel Mode preset: `UserDefaults` under `netwatch.travelTargets`

## License

Personal use. Built in an evening for a ferry crossing.
