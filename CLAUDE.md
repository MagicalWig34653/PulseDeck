# PulseDeck — handoff notes for new sessions

Native macOS 26 system monitor (Swift 6, SwiftUI, menu bar app). Bundle ID `de.linolaske.PulseDeck`.

**Read first:** [`SPEC.md`](SPEC.md) is authoritative. [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md)
holds the architecture, telemetry matrix and milestone plan (§15). [`TECHNICAL_LIMITATIONS.md`](TECHNICAL_LIMITATIONS.md)
lists what has no reliable public API (L‑1…L‑9) and the product owner's decisions on each.

## Status (last updated after release v0.7.0)

| Milestone (SPEC §39) | State |
|---|---|
| 1 Foundation — project, lifecycle, menu bar, navigation, models, engine | ✅ done (v0.1.0) |
| 2 CPU · 3 Memory · 4 Network · 5 Disk — collectors, 60 s charts with hover | ✅ done (v0.2.0) |
| Extra: interface IP addresses, hide never-used interfaces, HIG polish | ✅ done (v0.3.0) |
| 6 GPU · 7 Energy · 8 Processes | ✅ done (v0.4.0) |
| 9 Menu bar · 10 Optimization · 11 Polish · per-device sidebar | ✅ done (v0.5.0) |
| Owner feature batch: CPU freq/uptime/P‑E, memory compression/pie, disk bus/mounts/snapshots, link speed/Wi‑Fi, Tailscale, Containers, USB tree, Ctrl pause, refresh interval, smooth charts | ✅ done (v0.6.0, v0.6.1) |
| Thermals (SMC temperatures on a schematic board, fans, battery health) + cheaper workflows | ✅ done (v0.7.0) |

All SPEC §39 milestones are implemented. Remaining work needs a real Mac (see *Next*).

The product owner approves each milestone explicitly. Ask before starting one unless the request already says so.

### What M6–M8 added (read before touching them)
- `GPUMonitor` (Metal + IOAccelerator `Device Utilization %`), `EnergyMonitor` (IOPS battery, derived
  battery power, `SystemPowerIn`, adapter rating), `ProcessMonitor` + `ProcessControl` (libproc, PID +
  start-time identity). Maths in `PulseDeckCore/Calculation/{GPUUtilization,EnergyCalculator,ProcessUsageTracker}.swift`.
- GPU/energy/processes are demand-driven. `SystemHistory.gpus` (per registry ID) and `.energy`
  (series: system power in, battery charging W, battery discharging W). `AppState.latestProcesses` holds
  the table while the Processes section is visible.
- Undocumented sources carry a visible `SourceNote` on their page. Derived values render with
  "(derived)" via `Format.attributed`.
- **Needs a real Mac** (CI is a VM without battery; its paravirtual GPU has no utilization key):
  GPU utilization vs. Activity Monitor, `SystemPowerIn`/battery values on a MacBook (AC and battery),
  process CPU % vs. Activity Monitor, Quit/Force Quit of an app. L‑5 (process energy) is still unvalidated,
  so there is no Energy column.

### What M9–M11 added
- M9: `MenuBarContentView` rows (value + `ResourceSparkline`, click opens the page via
  `AppState.requestedItem`), `MenuBarMetric.batteryCharge`, energy metric titled "Battery Power"
  (raw value `energy` kept), background refresh interval (2/3/5 s). Sampling rules moved to
  `PulseDeckCore/Monitoring/SamplingDemand.swift` (tested): the panel counts as foreground; the
  sidebar keeps GPU/energy previews live next to Processes.
- M10: `.github/workflows/profile.yml` + `scripts/profile-app.sh` measure scenarios A–D on the Release
  build (`[profile]` in a commit message triggers it on a branch). Results and fixes: `docs/PERFORMANCE.md`.
  Processes use one `sysctl(KERN_PROC_ALL)` per tick and cache refusals; `ProcessSorting` (core);
  `DiskMonitor` caches static disk descriptions; sparklines are `isDecorative`.
- Sidebar per device (owner request): `PerformanceItem` (`.category`, `.disk(id)`, `.networkInterface(id)`;
  raw value `disk:disk0` is the scene-storage selection), `AppState.performanceItems`/`resolve(_:)`
  (`.category(.disks/.network)` = first disk / primary interface), `SidebarVisibility` (core, tested;
  per-device overrides over defaults, persisted as JSON), Settings → Sidebar, row context menu
  "Hide in Sidebar". Disk and network pages show one device; their device tables were removed.
- M11: Launch at Login (`System/LoginItemController.swift`, `SMAppService.mainApp`; state is read from
  the system, not stored), VoiceOver Audio Graphs (`accessibilityChartDescriptor`), Increase Contrast
  chart styling, `CategoryUnavailableView` error states, spoken menu bar metric.

### What v0.6.0 added
- Collectors (all demand-driven via `ObservationState.detailPageDemand`, set by `ResourceDetailView`):
  `CPUFrequencyMonitor` (private IOReport via dlopen + pmgr tables, L‑11; CPU page),
  `TailscaleMonitor` (LocalAPI `/localapi/v0/status`: unix socket, or TCP port + sameuserproof token;
  Tailscale interface page), `ContainerMonitor` + `ContainerControl` (Docker Engine API on
  Colima/Docker sockets; Containers section = `AppSection.containers`), `USBMonitor` (IOUSB plane,
  `USBSpeed`, `UsbPowerSinkAllocation` mA — L‑12; its own section `AppSection.usb`, a left-to-right tree diagram laid
  out by `TreeLayout` in core). `LocalHTTPClient` does the
  socket HTTP; parsing (`HTTPResponse`, `TailscaleStatusTracker`, `DockerStatsTracker`) is in core.
- Existing collectors: core types (`IODeviceTree:/cpus` `cluster-type`), `kern.boottime`, compressor
  original size, disk bus / mount points / `fs_snapshot_list` count (needs `ATTR_CMN_RETURNED_ATTRS`,
  else EINVAL; snapshot bytes L‑10), `ifi_baudrate` link speed, CoreWLAN Wi‑Fi (no location permission
  needed for PHY mode/rate/RSSI/channel).
- Memory page: optional pie of memory by process (`ProcessMemoryBreakdown`, top 5 by name + rest;
  demands `.processes` only while the toggle is on). `-initialScrollAnchor bottom` opens pages scrolled
  down (screenshots).
- `SystemHistory.capacity` = 121 (60 s at 0.5 s); `cpuFrequency` history. Foreground interval 0.5–5 s
  (Settings → General). Smooth scrolling: `ChartWindow(history:scrollingOver:now:)` in a
  `TimelineView(.animation(minimumInterval: 1/30))`, only full-size charts, only when the window
  `appearsActive`, not paused, no Reduce Motion. Holding Control alone pauses (`ControlKeyPause`,
  `AppState.setPaused` buffers snapshots and replays them).
- Needs a real Mac: frequencies vs. `powermetrics`, Wi‑Fi fields, Tailscale auth variants (App Store
  app's group container may prompt), snapshot counts, USB allocation on real devices.

### What v0.7.0 added
- `ThermalMonitor` (SMC via `IOServiceOpen("AppleSMC")` + `IOConnectCallStructMethod`; key enumeration
  once, `ThermalClassifier` zones; fans `FNum`/`F<n>Ac|Mn|Mx|Tg`) — L‑13. Protocol encoding/decoding is
  `SMC` in core (80-byte `SMCKeyData_t` with explicit offsets; `flt `, `sp78`, `fpe2`, `fp88`, `ui*`).
  `ResourceCategory.thermals` page: `LogicBoardView` (schematic, unit-rect layout), chart
  (`SystemHistory.thermals`: hottest CPU, GPU), components, fans, battery health. Demand: detail page only;
  the list row shows `AppState.latestThermals`.
- `BatterySnapshot.health` (`BatteryHealth`) from `AppleSmartBattery`, read with `SystemPowerIn`;
  `BatteryHealthSection` on Energy and Thermals.
- **Leaner workflows** (done while the repo was private and macOS minutes ran out; the owner then made
  it public, where hosted runners are free): `ci.yml` runs on `pull_request` and on `main` only (not on
  branch pushes, not for `*.md`/`docs/**`), with cancel-in-progress, and builds once (`xcodebuild test`
  with warnings as errors). So **open a (draft) PR to get CI**. `screenshots.yml`
  takes `pages` (e.g. `thermals-dark`; `all` also does menu bar, icon, DMG). `release.yml` skips the
  package tests on `workflow_dispatch` unless `run_tests`. Don't dispatch CI or screenshots casually.

### Next
- Actions were blocked for a day by the account's spending limit ("recent account payments have
  failed…"); jobs that fail within seconds without a runner mean that again — only the owner can fix it.
- Each profile run costs ~20 macOS runner minutes; don't trigger it casually.
- Needs a real Mac: Instruments (Time Profiler/SwiftUI for A and B), Launch at Login with a signed
  build in /Applications (ad-hoc builds may be refused by `SMAppService`), VoiceOver pass by ear.

## Repository map
```
PulseDeck.xcodeproj        objectVersion 77, file-system-synchronized groups (new files in PulseDeck/ are picked up
                           automatically; package products are wired by hand in project.pbxproj)
PulseDeck/                 SwiftUI app: App/ (AppState, lifecycle, preferences), Features/ (MainWindow, Performance
                           pages, Processes), MenuBar/, Settings/, Components/ (TimeSeriesChart, MetricPresentation),
                           System/ (WindowVisibilityObserver), AppIcon.icon (Icon Composer package)
PulseDeckKit/              Swift package
  Sources/PulseDeckCore/   platform-independent: models, MetricState, MonitoringEngine (actor), SamplingPolicy,
                           RingBuffer, SystemHistory, calculators (CPU ticks, memory, rates, classifier, addresses)
  Sources/PulseDeckTelemetry/  macOS-only collectors (all files wrapped in `#if os(macOS)`): CPU, Memory,
                           Network, Disk, GPU, Energy, Process monitors, ProcessControl + DarwinTelemetry factory
  Tests/PulseDeckCoreTests/     unit tests (run on Linux and macOS)
  Tests/PulseDeckTelemetryTests/ smoke tests against the real Mac; print readings to the CI log
packaging/dmg/, scripts/   DMG build (dmgbuild + AppKit-rendered background), window capture, Linux toolchain setup
docs/images/               README screenshots (generated by the Screenshots workflow)
```

Data flow: collector actors → `MonitoringEngine` (one `SystemSnapshot` per tick) → `AppState` (@MainActor,
appends to `SystemHistory`) → SwiftUI. All maths belongs in `PulseDeckCore`, where it can be tested on Linux.
Keep Darwin readers thin.

## How to build and verify

**Cloud sessions run on Linux without Xcode.** Only `PulseDeckCore` can be compiled locally:
```sh
source <(scripts/setup-linux-swift.sh /tmp/swift-toolchain)   # ~1 min, downloads Swift 6.2.3
cd PulseDeckKit
swift build --build-tests --build-path "$SWIFT_TOOLCHAIN_DIR/build" -Xlinker -L"$SWIFT_TOOLCHAIN_DIR/stub" -Xswiftc -warnings-as-errors
swift test --skip-build --build-path "$SWIFT_TOOLCHAIN_DIR/build"
```
Everything macOS-specific (collectors, SwiftUI, Xcode project, icon) is verified **only by GitHub Actions**:

| Workflow | Trigger | Does |
|---|---|---|
| `ci.yml` | pull requests and `main` (code changes only), manual | `swift test -warnings-as-errors` (incl. telemetry smoke tests), one `xcodebuild test` with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`, icon presence check |
| `screenshots.yml` | `workflow_dispatch` (input `commit: true` pushes images to the branch; `pages` selects captures) | launches the real app on a macOS 26 runner and captures `docs/images/*` (pages, light/dark; with `all` also menu bar, DMG window, icon) |
| `release.yml` | `workflow_dispatch` on `main` with input `version` (e.g. `0.4.0`), or a `v*` tag, or a published release | (tests only for tags or `run_tests`), universal Release build, DMG with background + SHA-256, creates the GitHub release (0.x = pre-release) |

The GitHub MCP tools can trigger runs (`actions_run_trigger`) and read logs (`get_job_logs`). The public
REST API works unauthenticated through `curl` for polling run status. Always **look at the screenshots**
(Read the PNGs) after UI changes: they have caught real bugs (inactive window, missing dark mode,
"Zero kB/s").

Typical loop: edit → local core tests → push → open a draft PR (this runs `ci.yml`) → fix compile errors
from the job log → run `screenshots.yml` with `commit: true` and only the changed `pages` → pull → review
images → mark ready → merge → `release.yml`. The screenshots bot pushes to the branch: don't push while a
screenshots run is in progress, or its final `git push` is rejected.

## Git / GitHub constraints in cloud sessions
- Push only to the session's designated branch. **Tag pushes are rejected by the proxy**, so release
  through `release.yml` `workflow_dispatch` (it creates the tag). The MCP tools have no "create release".
- `workflow_dispatch` only works for workflows that already exist on `main`.
- Commits pushed by the screenshots bot (GITHUB_TOKEN) don't trigger CI. The PR's `pull_request` event
  does, so wait for that run before merging.
- After a PR is merged, restart the working branch from `origin/main` (`git checkout -B <branch> origin/main`
  and `git push --force-with-lease`).
- If CI jobs fail within seconds without a runner, check the check-run annotations: billing/spending-limit
  problems look like that and only the owner can fix them.

## Engineering rules (from SPEC; enforced so far)
- Never fabricate telemetry. Missing values are `MetricState.unavailable(reason)` → UI "Not Available"
  (or "—" for transient reasons), never `0`. Derived or estimated values carry `ValueProvenance`.
- Public APIs first. Undocumented sources only with the owner's approval, labelled in the UI, with fallback.
  Approved and implemented: memory-pressure sysctl, IOAccelerator GPU stats (M6), `SystemPowerIn` (M7).
- No shell-command polling, no private frameworks, no privileged helper, no App Sandbox (see plan §11).
- Collection happens off the MainActor in actors. History stays bounded (`SystemHistory.capacity = 61`).
- Swift 6 language mode, zero warnings (CI treats warnings as errors), no force unwraps in telemetry paths,
  comments for non-obvious Darwin/IOKit behaviour, no unexplained magic numbers.
- Tests: Swift Testing. Test doubles live only in test targets.

## Pitfalls already hit (don't rediscover them)
- `icon.json`: `"color-space-for-untagged-svg-colors"` makes `actool` crash. Every other attribute used in
  `PulseDeck/AppIcon.icon` compiles. Xcode's `ictool` exists on the runners if renders are needed.
- `[statfs](repeating: statfs(), …)` parses as an array literal of the *function* `statfs`. Use
  `Array<statfs>(unsafeUninitializedCapacity:)`.
- `&value` on a generic `T` for `sysctlbyname` is rejected. Use `withUnsafeMutableBytes` and `T: BitwiseCopyable`.
- `getifaddrs` byte counters are 32-bit and wrap at 4 GiB. Counters come from `NET_RT_IFLIST2` / `if_data64`;
  `getifaddrs` is used only for addresses.
- Foundation's `ByteCountFormatStyle` spells zero as "Zero kB" and ignores `allowedUnits` for zero on Linux.
  Rates use the custom SI formatter in `MetricFormatting.byteRate`.
- AppKit ignores `-AppleInterfaceStyle` in the argument domain. The screenshots workflow switches the runner's
  global appearance. Launch with `open -n` so the window is active.
- `mach_task_self_` compiles fine in Swift 6 on Xcode 26.6.
- The runner is a VM ("Apple M2 Pro (Virtual)", VirtIO disk, many mounted simulator disk images). That's expected.
- Screenshot pages are selected with the `-initialCategory <cpu|memory|disks|network|gpu|energy|thermals>` launch preference
  (`PreferenceKey.initialCategory`) or `-initialSection <processes|containers|usb>`; `-cpuChartMode logicalProcessors`
  selects the per-core view, `-initialScrollAnchor bottom` scrolls pages down, `-memoryProcessPie YES` shows the pie.
- On macOS 26 `PROC_PIDTBSDINFO` fails with `EPERM` for other users' processes (not only task info).
  Use `sysctl(KERN_PROC_PID)` → `kinfo_proc` for their identity; `p_starttime` is `p_un.__p_starttime` in Swift.
- `Result<Void, E>` is not `Equatable`: test with `try result.get()` / `#expect(throws:)`.
- `KeyPathComparator` sorting reads keys via dynamic key paths per comparison — slow for ~600 rows.
  Use `ProcessSorting`. In the Linux test target `KeyPathComparator` needs `import Foundation`.
- In large tables avoid `.help` per cell: tooltips are re-registered on every refresh.
- `sample` "top of stack" output is all idle waits; use `scripts/sample-summary.py` for our frames.
- `alert(item:content:)` is deprecated (fails the warnings-as-errors build); use `alert(_:isPresented:presenting:)`.

## Known open items
- Release builds are ad-hoc signed, not notarized (no Developer ID secrets). Xcode disables the hardened
  runtime for ad-hoc signing. README documents the Gatekeeper workaround.
- Foreground CPU on the CI VM is above the 1 % budget (A ≈ 2.7–3.3 %, B ≈ 6.6–8.6 %; run-to-run noise
  is ±1 point), mostly AppKit/SwiftUI rendering on a GPU-less VM; background meets 0.3 %. Sidebar +
  Processes has a ~200 MB footprint baseline (flat, not a leak). See `docs/PERFORMANCE.md`.
- Disk images are hidden from the Performance list by default (my call when the owner asked for per-device
  entries; the runner has 16). They can be shown in Settings → Sidebar.
