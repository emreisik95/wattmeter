# Wattmeter

> See your Claude Code usage effortlessly.

Native macOS menubar app for tracking Claude Code usage — real-time 5-hour and weekly limits, cost breakdown by model/project/session, burn-rate forecast, threshold notifications, CSV export.

Reads transcripts from `~/.claude/projects/` and live rate-limit data from `~/.claude/rate_limits.json` (populated by Claude Code's statusLine hook). All processing local — nothing leaves the machine.

## Screenshots

| Overview | Models | Limits |
| :---: | :---: | :---: |
| ![Overview](docs/screenshots/overview.png) | ![Models](docs/screenshots/models.png) | ![Limits](docs/screenshots/limits.png) |

## Features

- **Live limits** — 5-hour and weekly usage from Claude Code's own statusLine output. No API calls.
- **Cost breakdown** — by model (Opus / Sonnet / Haiku), project, and session.
- **Burn-rate forecast** — projects time-to-limit at current usage trajectory.
- **Heatmap** — 7-day × 24-hour activity grid.
- **Threshold notifications** — configurable alerts at 75% / 90% / 100% of any limit.
- **Streaming parser** — UI shows cached snapshot instantly on launch, then merges live data in-flight.
- **Notarized** — signed Developer ID, hardened runtime, Gatekeeper accepted.

## Install

Grab the latest `Wattmeter.dmg` from [Releases](../../releases). Drag to `/Applications`, launch.

First launch: click **Connect to Claude limits** — Wattmeter patches `~/.claude/settings.json` to write rate-limit JSON after every prompt. Send one Claude prompt to populate.

## Build from source

```bash
swift build -c release
./build.sh           # produces Wattmeter.app
```

Requires macOS 14+, Swift 5.10+.

## Architecture

Pure SwiftUI + AppKit. No external dependencies.

- `Parser.swift` — streaming JSONL parser with byte-level prefilter + per-file mtime cache.
- `UsageStore.swift` — `AsyncStream` refresh, persistent plist snapshot at `~/Library/Application Support/Wattmeter/`.
- `Aggregator.swift` — model/project/session/heatmap rollups.
- `Forecasting.swift` — burn-rate projection.
- `Limits.swift` — watches `~/.claude/rate_limits.json` with mtime + content-fingerprint dedup.
- `Theme.swift` — single accent (Crail #C15F3C) + semantic limit colors.

## License

MIT — see [LICENSE](LICENSE).

Not affiliated with Anthropic. "Claude" and "Claude Code" are trademarks of Anthropic, PBC.
