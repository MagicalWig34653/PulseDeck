<p align="center">
  <img src="docs/images/app-icon.png" width="160" alt="PulseDeck app icon">
</p>

<h1 align="center">PulseDeck</h1>

<p align="center">
  A native macOS system monitor that combines the information density of the Windows&nbsp;11
  Task Manager <em>Performance</em> view with macOS&nbsp;26 design and Liquid Glass.
</p>

<p align="center">
  <a href="https://github.com/MagicalWig34653/PulseDeck/actions/workflows/ci.yml"><img src="https://github.com/MagicalWig34653/PulseDeck/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/MagicalWig34653/PulseDeck/releases/latest"><img src="https://img.shields.io/github/v/release/MagicalWig34653/PulseDeck?include_prereleases&label=release" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-blue" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
</p>

---

> [!IMPORTANT]
> **Early development.** CPU, memory, network and disk monitoring are live (Milestones 2–5), with
> 60-second charts and hover inspection. GPU, energy and the process table follow in Milestones 6–8
> and show **Not Available** until then. PulseDeck never displays invented or placeholder values.

## Screenshots

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/performance-dark.png">
    <img src="docs/images/performance-light.png" width="780" alt="PulseDeck Performance view with top-bar navigation">
  </picture>
</p>

| Top bar navigation | Sidebar navigation |
|---|---|
| <img src="docs/images/performance-dark.png" alt="Performance view, dark appearance"> | <img src="docs/images/sidebar-light.png" alt="Sidebar navigation, light appearance"> |

Screenshots are captured automatically from the real app on a macOS 26 runner by the
[Screenshots workflow](.github/workflows/screenshots.yml).

## Features

Implemented:

- **CPU** — total, user, system and idle utilization; per-logical-processor charts; model name,
  logical/physical core counts and performance/efficiency clusters.
- **Memory** — used (App Memory + Wired + Compressed), available, wired, compressed, cached files,
  free, swap and memory pressure, with a composition bar.
- **Network** — every interface individually (Ethernet, Wi‑Fi, Thunderbolt, bridges, VPN/tunnels),
  download/upload rates from 64-bit kernel counters, totals, and hot-plug/VPN reconnect handling.
- **Disks** — every storage device with read/write throughput, cumulative transfer, capacity and
  available space (APFS containers counted once).
- **60-second history charts** with hover inspection: a vertical rule, highlighted points, the
  sample's time and all series values. Hovering only reads recorded history.
- **Menu bar app** — keeps running in the menu bar when the window closes; the Dock icon appears
  only while the main window is open. Compact overview popover and an optional live metric in the
  menu bar (CPU, memory, network download/upload of the primary interface).
- **Two navigation styles** — Liquid Glass top bar (default) or sidebar, persisted in Settings.
- **Energy-aware sampling** — 1 Hz while the window is visible; every 3 s when it is closed,
  minimised or fully covered; stopped during sleep, with all counter baselines discarded on wake so
  no bogus spikes appear.

Planned, following [`SPEC.md`](SPEC.md) §39: GPU (Metal identification and utilization), energy
(battery and power), a process table with actions, Instruments profiling, accessibility polish and
Launch at Login.

Some requested metrics have no reliable public macOS API (for example system-wide GPU utilization,
CPU/GPU package power and disk active time). These will be shown as *Not Available*; see
[`TECHNICAL_LIMITATIONS.md`](TECHNICAL_LIMITATIONS.md).

## Installation

1. Download `PulseDeck-<version>.dmg` from the
   [latest release](https://github.com/MagicalWig34653/PulseDeck/releases/latest).
2. Open the disk image and drag **PulseDeck** into **Applications**.

<p align="center">
  <img src="docs/images/dmg-window.png" width="520" alt="PulseDeck disk image window">
</p>

> [!NOTE]
> Release builds are currently **ad-hoc signed and not notarized** (no Developer ID yet). On first
> launch macOS will refuse to open the app. Open **System Settings → Privacy & Security** and click
> **Open Anyway**, or remove the quarantine attribute:
>
> ```sh
> xattr -dr com.apple.quarantine /Applications/PulseDeck.app
> ```

Each release also includes a `.sha256` checksum file.

## Requirements

- macOS 26 or later (Apple Silicon primary; release builds are universal)
- To build: Xcode 26 or later

## Building from source

```sh
git clone https://github.com/MagicalWig34653/PulseDeck.git
cd PulseDeck
open PulseDeck.xcodeproj          # then Run the "PulseDeck" scheme
```

Command line:

```sh
# Core package tests (models, engine, ring buffer, counter math, formatting)
swift test --package-path PulseDeckKit

# App build + tests through the Xcode scheme
xcodebuild -project PulseDeck.xcodeproj -scheme PulseDeck -destination 'platform=macOS' test
```

Build a disk image locally:

```sh
xcodebuild -project PulseDeck.xcodeproj -scheme PulseDeck -configuration Release \
  -derivedDataPath build/DerivedData CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- build
scripts/build-dmg.sh build/DerivedData/Build/Products/Release/PulseDeck.app 0.1.0 build/PulseDeck-0.1.0.dmg
```

## Project layout

| Path | Contents |
|---|---|
| `PulseDeck/` | SwiftUI app: lifecycle, main window, menu bar, settings, `AppIcon.icon` (Icon Composer) |
| `PulseDeckKit/` | UI-free Swift package: snapshot models, `MonitoringEngine`, `SamplingPolicy`, `RingBuffer`, counter math, tests |
| `packaging/dmg/` | DMG layout (`dmgbuild` settings) and the AppKit background renderer |
| `scripts/` | DMG build script and window capture helper |
| `.github/workflows/` | CI, release (DMG), screenshots |

Documentation:

- [`SPEC.md`](SPEC.md) — product and engineering specification (authoritative)
- [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) — architecture, telemetry matrix, milestones
- [`TECHNICAL_LIMITATIONS.md`](TECHNICAL_LIMITATIONS.md) — metrics without reliable public APIs

## Releasing

Push a version tag; the [Release workflow](.github/workflows/release.yml) runs the tests, builds a
universal Release app, packages the DMG and publishes the GitHub release:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

Alternatively run the Release workflow manually on `main` with a version (e.g. `0.1.0`); it tags
that commit and publishes the release. Publishing a release from the GitHub UI also attaches a
DMG. `0.x` versions are marked as pre-releases.

## Privacy

All telemetry stays on your Mac. PulseDeck has no analytics, makes no network requests and never
transmits process names or system statistics.
