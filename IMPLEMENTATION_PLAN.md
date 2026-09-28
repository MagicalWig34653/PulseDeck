# PulseDeck — Implementation Plan

Derived from [`SPEC.md`](SPEC.md), which remains authoritative. Where this plan and
`SPEC.md` disagree, `SPEC.md` wins and this document is wrong.

Requirements that cannot be met reliably with public APIs are listed in
[`TECHNICAL_LIMITATIONS.md`](TECHNICAL_LIMITATIONS.md); this plan refers to them
as **L‑n**.

- Product: `PulseDeck` · Bundle ID: `de.linolaske.PulseDeck`
- Target: macOS 26+, Apple Silicon primary, Swift 6 language mode, SwiftUI, Xcode 26+

---

## 0. How API claims in this document were verified

The authoring environment for this plan was a **Linux container without Xcode or the
macOS SDK**, so API claims were verified against the closest available primary sources
instead of an installed SDK:

| Source | Used to verify |
|---|---|
| `apple-oss-distributions/xnu` (main) | `host_info.h`, `processor_info.h`, `machine.h`, `vm_statistics.h`, `sys/proc_info.h`, `sys/resource.h`, `libproc.h`, `net/if.h`, `net/if_var.h`, `net/if_types.h`, `net/if_mib.h`, `sys/socket.h`, `sys/sysctl.h`, `IOKit/pwr_mgt/IOPM.h`, `kern_sysctl.c`, `kern_memorystatus_notify.c` |
| `apple-oss-distributions/IOStorageFamily` | `IOBlockStorageDriver.h` statistics keys and units |
| `apple-oss-distributions/IOKitUser` | `IOPowerSources.h`, `IOPSKeys.h`, `IOPMLib.h` |
| developer.apple.com documentation JSON | Availability of SwiftUI / Metal / ServiceManagement / IOKit symbols (e.g. `glassEffect(_:in:)` macOS 26.0, `GlassEffectContainer` 26.0, `.glass` button style 26.0, `MenuBarExtra` 13.0, `defaultLaunchBehavior(_:)` 15.0, `SMAppService` 13.0, `MTLCopyAllDevices()` 10.11, `IOPSCopyPowerSourcesInfo` 10.2). IOReport returned **no documentation page** (consistent with it being private). |

Open-source xnu headers are a superset of the SDK headers (they contain `#ifdef PRIVATE`
sections that are stripped from the SDK). Every struct/field cited below was checked to be
**outside** `PRIVATE`/`KERNEL` guards. Nevertheless, **every Darwin API must be re-verified
against the Xcode 26 SDK on a Mac when its milestone is implemented** (see §14, risk R1).
The macOS CI workflow (`.github/workflows/ci.yml`) is the first line of that verification.

---

## 1. Architecture overview

```text
┌──────────────────────── PulseDeck.app (Xcode target, SwiftUI, @MainActor UI) ─────────────────────────┐
│ App/            PulseDeckApp (scenes) · AppState (@Observable) · AppLifecycleController (NSApp delegate) │
│ Features/       MainWindow · Performance · Processes                                                   │
│ MenuBar/        MenuBarExtra label + window-style overview                                             │
│ Settings/       Settings scene                                                                         │
│ System/         Window visibility observer · sleep/wake bridge · (later) login item                    │
│ Components/     Shared views (metric value labels, later: charts)                                     │
└──────────────────────────────────────────────┬─────────────────────────────────────────────────────────┘
                                               │ depends on (local Swift package)
┌──────────────────────── PulseDeckKit (Swift package, no UI) ───────────────────────────────────────────┐
│ PulseDeckCore       Models · MetricState/capabilities · MonitoringEngine (actor) · SamplingPolicy ·      │
│                     TelemetryProvider protocol · RingBuffer · counter/rate math · monotonic clock        │
│                     (Foundation only — builds & tests on macOS and Linux)                               │
│ PulseDeckTelemetry  Darwin collectors (CPU, memory, network, disk; later GPU, energy, processes).      │
│                     macOS-only, each collector is an actor conforming to TelemetryProvider.            │
└────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

Rationale:

- **Separation of telemetry and presentation (SPEC §4)** is enforced by the module boundary:
  `PulseDeckCore` cannot import SwiftUI/AppKit.
- **Testability (SPEC §35)**: all math (deltas, rates, ring buffer, nearest-sample lookup,
  CPU tick math, formatting) lives in `PulseDeckCore` and is tested with Swift Testing via
  `swift test` and via the Xcode scheme.
- **Dependency injection (SPEC §38)**: `MonitoringEngine` receives a `TelemetryProviders`
  value and a `MonotonicClock`. Tests inject deterministic test doubles; production injects
  Darwin collectors. No singletons in telemetry code.
- **No third-party dependencies.** Nothing in the SPEC requires one.

### Module structure mapping to SPEC §4

SPEC §4 names the tree `TaskMonitor/…`; the product is named PulseDeck, so the same layout
is used under `PulseDeck/` (app) and `PulseDeckKit/Sources/PulseDeckCore/` (core). The SPEC
allows justified deviation; the split into an app target + package is the justified one.

```text
PulseDeck.xcodeproj                      (objectVersion 77, file-system-synchronized groups,
                                          shared scheme "PulseDeck": builds app, tests PulseDeckCoreTests)
.github/workflows/ci.yml                 (macOS 26 runner: swift test + xcodebuild build/test)
PulseDeck/
├── App/            PulseDeckApp.swift · AppState.swift · AppLifecycleController.swift · Preferences.swift
├── Features/
│   ├── MainWindow/ MainWindowView.swift · AppSection.swift
│   ├── Performance/ PerformanceView · ResourceCategory · ResourceListRow · ResourceDetailView ·
│   │                CPU/Memory/Network/DiskPerformanceView
│   └── Processes/  ProcessesView.swift
├── MenuBar/        MenuBarLabel.swift · MenuBarContentView.swift
├── Settings/       SettingsView.swift
├── Components/     MetricPresentation.swift (MetricStateText, previews, statistics), TimeSeriesChart.swift
└── System/         WindowVisibilityObserver.swift   (sleep/wake observers live in AppLifecycleController)
PulseDeckKit/
├── Package.swift
├── Sources/PulseDeckCore/
│   ├── Models/     SystemSnapshot, CPUSnapshot, CPUCoreSnapshot, MemorySnapshot, DiskSnapshot,
│   │               NetworkSnapshot, GPUSnapshot, EnergySnapshot, ProcessSnapshot, MetricState, MetricKind
│   ├── Monitoring/ MonitoringEngine, SamplingPolicy, TelemetryProvider, TelemetryProviders
│   ├── Calculation/ CPUUsageCalculator, MemoryCalculator, CounterRateTracker,
│   │               NetworkInterfaceClassifier, ChartScale
│   ├── History/    RingBuffer (+ TimestampedSample nearest lookup), SystemHistory
│   └── Utilities/  MonotonicClock, CounterDelta (+ RateCalculator), MetricFormatting
├── Sources/PulseDeckTelemetry/   (macOS only) CPUMonitor, MemoryMonitor, NetworkMonitor, DiskMonitor,
│                                 Sysctl, DarwinTelemetry (provider factory)
├── Tests/PulseDeckCoreTests/     (run on macOS and Linux)
└── Tests/PulseDeckTelemetryTests/ (macOS smoke tests against the real system)
```

---

## 2. Concurrency model (SPEC §5)

```text
Darwin APIs ──► collector actors (one per domain, own their baselines)
                    │  async, concurrently via `async let`
                    ▼
            MonitoringEngine (actor) ── owns SamplingPolicy, loop Task, sequence numbers
                    │  AsyncStream<SystemSnapshot>  (bufferingNewest(4))
                    ▼
            AppState (@MainActor @Observable) ── one observable object; appends to HistoryStore
                    ▼
            SwiftUI views (read-only)
```

Rules:

1. **Collectors are actors** and are the only owners of their previous-sample baselines.
   No telemetry state is shared mutable state.
2. **`MonitoringEngine` is an actor.** Its sampling loop is an unstructured `Task` created from
   actor-isolated code, so it runs on the global concurrent executor — never on the MainActor.
   Blocking Darwin calls (`sysctl`, `host_processor_info`, IOKit property copies) are short and
   run inside collector actors, off the main thread.
3. **Snapshots are immutable `Sendable` value types.** The UI never calls a collector.
4. **One observable object.** `AppState` is the single `@Observable` that changes per tick,
   avoiding many independently observed objects (SPEC §5). Views read only the properties they
   need, so Observation invalidates only the affected views.
5. **Back-pressure:** the stream buffers the newest 4 snapshots. If the main thread stalls longer
   than that, older snapshots are dropped and appear as a **time gap** in history — never
   interpolated or fabricated.
6. Swift 6 language mode everywhere (strict concurrency checking = complete). The app target
   keeps the default *nonisolated* default-actor-isolation and marks UI types explicitly
   `@MainActor` so isolation is visible in code review.

---

## 3. Telemetry pipeline

Each domain has a collector conforming to:

```swift
public protocol TelemetryProvider<Reading>: Actor {
    associatedtype Reading: Sendable
    func capability() async -> TelemetryCapability          // typed capability detection (SPEC §34)
    func sample(at instant: MonotonicInstant) async -> MetricState<Reading>
    func invalidateBaselines() async                        // sleep/wake, counter reset
}
```

`MetricState<Value>` is the typed state every metric carries (SPEC §3, §28, §34):

| State | Meaning | UI |
|---|---|---|
| `.available(value)` | valid measurement | value |
| `.unavailable(.awaitingBaseline)` | first sample of a delta metric | `—` (no value yet) |
| `.unavailable(.invalidDelta)` | counter reset/overflow/sleep gap | gap in chart, `—` |
| `.unavailable(.noPublicAPI / .unsupportedHardware / .permissionDenied / .sourceRemoved / .notImplemented / .transientFailure)` | not obtainable | **Not Available** + reason in help/tooltip |
| `.notSampled` | demand-driven sampling skipped it (nobody observing) | previous visible state; not charted |

Values that are not directly reported carry a provenance (`ValueProvenance.reported / .derived /
.estimated`, SPEC §19) and the UI labels derived values ("derived") and estimates ("est.").

`SystemSnapshot` = `{ sequence, timestamp (monotonic + wall), samplingMode, cpu, memory, disks,
network, gpu, energy, processes }`, each a `MetricState`.

---

## 4. Sampling architecture (SPEC §6, §7, §26)

`SamplingPolicy` (value type, owned by the engine, updated by the app):

| Mode | Trigger | Interval | Timer tolerance |
|---|---|---|---|
| `foreground` | main window visible and not occluded | 1 s | 10 % (100 ms) — lets the kernel coalesce wakeups |
| `background` | window closed/occluded, menu bar only | 3 s (clamped to 2–5 s) | 10 % |
| `suspended` | system sleep (between `willSleep` and `didWake`) | none — loop stopped | — |

Demand set (`Set<MetricKind>`), computed by `AppState` from what is on screen:

- Always: `cpu`, `memory`, `network`, `disk` (all are single cheap syscalls/IOKit reads per tick;
  needed for continuous history and menu bar).
- `gpu`, `energy`: only when their Performance page / preview is visible, the menu bar popover
  is open, or the selected menu bar metric needs them.
- `processes`: only when the Processes tab is visible or a process-dependent menu bar metric is
  selected (none in v1).

Loop: `sample → yield → Task.sleep(for: interval, tolerance:)`. A policy change restarts the loop
(awaiting the previous loop's completion first, so samples never overlap), so switching from
background to foreground takes effect immediately instead of after up to 5 s.

Monotonic time: `ContinuousClock` (Darwin: `mach_continuous_time`, which **includes** sleep).
Deltas therefore never divide by a too-small elapsed time after sleep; in addition any elapsed time
greater than `maxSampleGap` (3 × interval, min 10 s) marks rates `.invalidDelta`. Wall-clock
`Date` is stored alongside only for display.

---

## 5. History / ring-buffer design (SPEC §6, §29)

- `RingBuffer<Element>`: fixed capacity, `ContiguousArray` storage that grows once to capacity and
  then overwrites the oldest slot. `append` O(1), random access O(1), `RandomAccessCollection`
  conformance (logical order oldest→newest), no per-append allocation after warm-up.
- Capacity: 60 s / 1 s = 60 points (+ 1 so a full 60 s window has both edges) → **61**. In
  background mode points are 3 s apart, so the same 61 slots cover ~3 min — still bounded.
- Points: `HistoryPoint { timestamp: MonotonicInstant, wallTime: Date, values: fixed-size array of Double? }`.
  `nil` = no valid sample (gap) — drawn as a break in the line, never as 0.
- `nearestIndex(to:)`: binary search on the monotonic timestamp (timestamps are strictly increasing
  within a buffer), O(log n). Hover converts pointer x → time → nearest index.
- `HistoryStore` (MainActor, M2) holds one buffer per series; per-core CPU uses one buffer of
  per-core arrays (not N buffers). Memory bound: e.g. 32 cores × 61 × 9 B ≈ 18 KB.
- Rendering reads the buffer in place (no copies per render); copies happen at most once per tick.

---

## 6. Chart and hover architecture (SPEC §11, §12) — Milestone 2

- `TimeSeriesChart` (Components/): a single `Canvas` view drawing grid, filled area and line(s)
  with `Path`, sized by `GeometryReader`. Colors from semantic `Color`s (light/dark, Increase
  Contrast). Stroke widths in points → Retina-correct.
- X axis = time window `[now − 60 s, now]` based on the newest sample's timestamp, **not** on a
  running clock, so no redraw happens between ticks (no continuous animation, SPEC §11).
- Hover: `.onContinuousHover` stores a pointer x in `@State`. The overlay (separate small view)
  maps x → time → `nearestIndex`, draws the vertical rule and point highlight and a value callout
  with timestamp and all series values. Hover only reads the ring buffer (SPEC §12) — it never
  calls into the engine.
- Multi-series: series descriptors (label, color, value index) passed to the chart; the callout
  lists all series at the sample.
- Accessibility: `accessibilityLabel` summary ("CPU, last 60 seconds, current 12 %, peak 48 %"),
  `AXChartDescriptor` via `accessibilityChartDescriptor`.
- Invisible charts are not drawn: only the selected Performance page renders a large chart; the
  resource list shows small sparklines only for visible rows (lazy list).

---

## 7. Menu bar / window lifecycle (SPEC §23–25, §32)

Scenes (`PulseDeckApp`):

1. `Window("PulseDeck", id: "main")` — a single unique main window.
   `.defaultLaunchBehavior(showMainWindowAtLaunch ? .presented : .suppressed)` (macOS 15+).
2. `MenuBarExtra(isInserted:)` with `.menuBarExtraStyle(.window)` — popover-like overview with
   *Open PulseDeck*, *Settings…*, *Quit*.
3. `Settings` scene.

`AppLifecycleController` (`NSApplicationDelegate` via `@NSApplicationDelegateAdaptor`):

- `applicationShouldTerminateAfterLastWindowClosed` → `!keepRunningWhenWindowCloses`.
- Activation policy: `.regular` (Dock icon) while the main window is open, `.accessory` when only
  the menu bar item remains — the standard pattern for menu-bar-resident apps with a main window.
- Owns sleep/wake observers (`NSWorkspace.willSleepNotification` / `didWakeNotification`) and
  forwards them to the engine.
- `applicationWillTerminate` stops the engine.

Window visibility → sampling mode: a zero-size `NSViewRepresentable` (`WindowVisibilityObserver`)
attaches to the hosting `NSWindow` and observes `didChangeOcclusionStateNotification` and
`willCloseNotification`. Visible ⇒ foreground; closed, minimised or fully occluded ⇒ background.

Menu bar metric: `MenuBarMetric` enum (`none, cpu, memory, gpu, networkDownload, networkUpload,
energy`), persisted with `@AppStorage`. The label text is computed in `AppState` and assigned
**only when the formatted string changes**, so the status item is not invalidated every tick.
New modes = new enum cases + formatter; no architectural change.

Navigation (SPEC §8): `NavigationPresentation` (`topBar` default, `sidebar`), persisted.

- *Top bar*: section picker (Performance / Processes) in the window toolbar (`.principal`), which
  macOS 26 renders with Liquid Glass automatically. Performance shows its resource list + detail.
- *Sidebar*: `NavigationSplitView` whose sidebar lists the Performance resources and Processes.
  The macOS 26 sidebar is Liquid Glass by default.
- Glass is **not** applied to tables, charts or statistic blocks (SPEC §9). Custom glass
  (`glassEffect`, `.buttonStyle(.glass)`) is only used for floating controls if/when needed.

---

## 8. Sleep / wake (SPEC §27, §28)

- `willSleep` → engine `systemWillSleep()`: mode `suspended`, loop cancelled.
- `didWake` → engine `systemDidWake()`: `invalidateBaselines()` on every collector, resume previous
  mode. The first post-wake sample of every delta metric is `.awaitingBaseline` (UI shows `—`),
  disks/interfaces are re-enumerated by their collectors on the next sample.
- Belt and braces: the `maxSampleGap` rule (§4) catches missed notifications (e.g. a stalled process).

## 9. Counter handling (SPEC §28)

| Case | Handling |
|---|---|
| First sample | `.awaitingBaseline` |
| 64-bit counter decreases (reset/interface re-created) | `.invalidDelta`, new baseline |
| 32-bit counters (Mach CPU ticks are `natural_t`) | modular `&-` delta; plausibility bound (≤ elapsed × tick rate × 2) else `.invalidDelta` |
| Elapsed ≤ 0 or > `maxSampleGap` | `.invalidDelta` |
| Device/interface/process disappears | removed from snapshot; baseline discarded |
| PID reuse | process identity = (pid, start time `pbi_start_tvsec/usec`); mismatch ⇒ new baseline |

## 10. Per-domain design notes (Milestones 2–8)

- **CPU** — `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` per-core ticks (`USER, SYSTEM, IDLE, NICE`);
  user% = (user+nice)/total. Total = sum over cores. Array returned by the call must be
  `vm_deallocate`d. Static info via `sysctlbyname`: `machdep.cpu.brand_string`, `hw.logicalcpu`,
  `hw.physicalcpu`, `hw.nperflevels`, `hw.perflevelN.{name,physicalcpu,logicalcpu}`.
- **Memory** — `host_statistics64(HOST_VM_INFO64)`, page size `vm_kernel_page_size`, `hw.memsize`,
  `vm.swapusage` (`struct xsw_usage`). **Memory Used** (documented per SPEC §14):
  `used = (internal_page_count − purgeable_count + wire_count + compressor_page_count) × pageSize`
  i.e. App Memory + Wired + Compressed (the Activity Monitor definition).
  `cached = (external_page_count + purgeable_count) × pageSize`, `available = total − used`.
  Pressure: polled from `kern.memorystatus_vm_pressure_level` (undocumented, approved; L‑8).
- **Disk** — IOKit: `IOServiceGetMatchingServices(IOBlockStorageDriver)` → `Statistics` dictionary
  (`Bytes (Read)`, `Bytes (Write)`, `Operations (…)`, `Total Time (…)` ns), child `IOMedia`
  (`BSD Name`, `Removable`, `Size`), parent device `Protocol Characteristics` (internal/external/
  disk image) and `Device Characteristics` (product name). Devices are re-matched on every sample
  (a handful of registry entries), so hot-plug and ejection need no separate notification path;
  a re-attached device gets a new registry entry ID and therefore a fresh counter baseline.
  Available space: `URLResourceValues.volumeAvailableCapacityForImportantUsage` of every mounted
  volume whose BSD node descends from the disk in the IORegistry (disk0 → disk0s2 → APFS container
  disk3 → disk3sN), counting each APFS container once; refreshed every 30 s or when the device set
  changes. Active time: L‑3.
- **Network** — `sysctl(CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0)` → `if_msghdr2.ifm_data`
  (`struct if_data64`, 64-bit `ifi_ibytes/ifi_obytes`). **Not** `getifaddrs`: its `if_data` counters
  are `u_int32_t` and wrap every 4 GiB. Classification: `ifi_type` (`IFT_ETHER`, `IFT_BRIDGE`,
  `IFT_CELLULAR`, `IFT_LOOP`, `IFT_GIF`, `IFT_STF`, `IFT_PPP`…) + `SCNetworkInterfaceCopyAll()`
  (Wi‑Fi = `IEEE80211`, Thunderbolt Bridge, Ethernet) + name prefix (`utun`, `ipsec`, `ppp`, `tun`,
  `tap`, `wg`) ⇒ `VPN / Tunnel`. `IFT_ETHER` without SystemConfiguration information stays
  unclassified (it may be Wi‑Fi). Loopback and never-used down interfaces are behind a "Show all
  interfaces" toggle; unclassified interfaces are always shown (SPEC §17). The primary interface
  (`State:/Network/Global/IPv4` → `PrimaryInterface`) drives the resource-list preview and the menu
  bar network metric, avoiding double counting of tunnel and bridge traffic.
- **GPU** — Metal `MTLCopyAllDevices()` for identification (name, `registryID`, `hasUnifiedMemory`,
  `isLowPower`, `isRemovable`). Utilization: L‑1.
- **Energy** — `IOPSCopyPowerSourcesInfo` + `IOPSNotificationCreateRunLoopSource` (charge %, state,
  time remaining, `Voltage` mV, `Current` mA). Battery power = V × I, **derived**, labelled
  "Battery (charge/discharge) power", never presented as system power. System/CPU/GPU power: L‑2.
- **Processes** — `proc_listallpids`, `proc_pidinfo(PROC_PIDTASKALLINFO)` (falls back to
  `PROC_PIDTBSDINFO`, then `sysctl(KERN_PROC_PID)` for other users' processes),
  `proc_pid_rusage(RUSAGE_INFO_V4)` (CPU times, `ri_phys_footprint`, `ri_diskio_bytesread/written`),
  `proc_pidpath`/`NSRunningApplication` for names and icons. CPU time units: see R3. Actions:
  `NSRunningApplication.terminate()/forceTerminate()` for apps, `kill(SIGTERM/SIGKILL)` otherwise,
  confirmation dialogs, `EPERM` surfaced as an alert. Show in Finder:
  `NSWorkspace.activateFileViewerSelecting`. Network/energy columns: L‑4, L‑5.

## 11. Privileges, entitlements, distribution (SPEC §37)

- **No App Sandbox.** A sandboxed app cannot inspect or signal other users' processes via libproc
  and `kill`, which the Processes feature requires. Distribution: Developer ID + Hardened Runtime
  (`ENABLE_HARDENED_RUNTIME = YES`), notarized.
- **No entitlements** are introduced in Milestone 1. No privileged helper, no kernel extension.
- No network access, no analytics, nothing leaves the machine.

## 12. Testing strategy (SPEC §35)

- Framework: Swift Testing (`import Testing`) in `PulseDeckKit/Tests/PulseDeckCoreTests`.
  Runs with `swift test` (macOS and Linux) and in Xcode via the `PulseDeck` scheme's test action.
- Test doubles live **only** in the test target and are named `Stub…`/`Fake…`.
- Coverage by milestone: M1 ring buffer, nearest lookup, counter deltas, rates, sampling policy,
  engine lifecycle (start/stop/policy/sleep/wake/ordering); M2 CPU tick math + formatting; M4/M5
  network/disk rate engines using recorded counter sequences (fixtures captured from a real Mac);
  M8 PID-reuse and disappearing-process handling.
- Darwin collectors get *smoke* tests on macOS (call returns plausible ranges, never crashes).
- CI: GitHub Actions `macos-26` runner builds the Xcode project (`xcodebuild build`, code signing
  disabled) and runs `swift test` for the package.

## 13. Performance strategy (SPEC §26, §36)

- Budgets (to verify with Instruments in M10): foreground < 1 % of one core average, background
  < 0.3 %, zero growth in resident memory after the first minute.
- Techniques: timer tolerance for wakeup coalescing; demand-driven collectors; reuse buffers for
  `sysctl`/`proc_listallpids` (grow-only scratch storage inside collector actors); per-process
  sampling only while the Processes tab is visible; free-space queries throttled to 30 s; configd
  queries only on interface-set changes or every 5 s; label/snapshot assignment only on
  change; `Canvas` charts that redraw once per tick and never animate.
- Instruments runs (M10): Time Profiler, Allocations/Leaks, SwiftUI, Energy Log, System Trace
  (wakeups) for scenarios A–D in SPEC §36.

## 14. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | API claims verified against open-source headers and docs, not the installed Xcode 26 SDK (no Mac in the authoring environment) | macOS CI build; re-verify each API when its milestone is implemented |
| R2 | `libproc.h` states *"private interfaces … subject to change"* although it ships in the SDK and SPEC §21 mandates it | Isolate behind `ProcessMonitor`; degrade to `.unavailable` on failure |
| R3 | `proc_taskinfo.pti_total_*` / `rusage_info.ri_*_time` units are Mach absolute-time ticks on Apple Silicon (ns on Intel) | Convert with `mach_timebase_info`; verify against `ps` manually in M8 |
| R4 | Per-process info for other users' (e.g. root) processes may fail with `EPERM` without privileges | Show row with name/PID, other columns `Not Available`; no privileged helper |
| R5 | Liquid Glass behaviour of toolbar/sidebar is automatic and may differ from expectations | Use system containers first; custom glass only for floating controls |

## 15. Milestone plan (SPEC §39)

Current status and hand-off notes for the next session: [`CLAUDE.md`](CLAUDE.md).

| # | Milestone | Deliverables | Exit criteria | Status |
|---|---|---|---|---|
| 1 | Foundation | Xcode project, package, models, `MetricState`, `TelemetryProvider`, `MonitoringEngine`, `SamplingPolicy`, `RingBuffer`, counter/rate math, lifecycle, menu bar, navigation (top bar/sidebar), settings for navigation/menu-bar metric/window behaviour | Builds; core tests pass; window close keeps app in menu bar; reopen/quit work; all metrics show *Not Available* (no fake data) | ✅ v0.1.0 |
| 2 | CPU | `CPUMonitor`, `SystemHistory`, `TimeSeriesChart`, hover, logical-processor grid, formatting | tests for tick math, hover lookup, formatting | ✅ v0.2.0 |
| 3 | Memory | `MemoryMonitor`, pressure source, charts | documented Used formula | ✅ v0.2.0 |
| 4 | Network | `NetworkMonitor`, classification, VPN/tunnel, hot-plug | per-interface charts, counter-reset tests | ✅ v0.2.0 (IP addresses v0.3.0) |
| 5 | Disk | `DiskMonitor`, IORegistry capacity mapping | hot-plug safe, rate tests | ✅ v0.2.0 |
| 6 | GPU | Metal identification, capability detection | honest unavailable state (L‑1) | ✅ v0.4.0 (IOAccelerator utilization, labelled) |
| 7 | Energy | IOPS battery metrics, provenance labels | derived/unavailable clearly shown | ✅ v0.4.0 (`SystemPowerIn` labelled; needs MacBook check) |
| 8 | Processes | `ProcessMonitor`, `Table`, sort/search/actions | PID reuse + disappearance tests | ✅ v0.4.0 (`kinfo_proc` fallback for other users, L‑7) |
| 9 | Menu Bar | popover content, menu bar metric, adaptive demand | reduced background sampling verified | ✅ (`SamplingDemand` tests; C/D measured) |
| 10 | Optimization | Instruments A–D, fixes | budgets met, no growth | ✅ on CI VM (`docs/PERFORMANCE.md`): background budget met, no growth; foreground above budget on the VM — confirm on a Mac |
| 11 | Polish | accessibility, Launch at Login (`SMAppService.mainApp`), error states | VoiceOver pass | ✅ implemented; VoiceOver pass by ear needs a Mac |

---

## 16. Telemetry matrix

Legend — **Public API?**: *Yes* = documented or declared in a public SDK header without private
markers; *SDK/unstable* = public SDK header that describes itself as subject to change;
*Undocumented* = reachable through a public mechanism (IOKit/sysctl) but the keys/semantics are not
documented; *Private* = private framework/SPI.

| Metric | Source API | Public API? | Privileges | Reliability | Sampling Cost | Fallback |
|---|---|---|---|---|---|---|
| CPU total / user / system / idle | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` tick deltas (sum of cores) | Yes (Mach, Kernel docs) | None | High | Very low (1 Mach call + `vm_deallocate`) | — |
| CPU per logical processor | same, per core | Yes | None | High | Very low | — |
| Logical / physical core count, P/E clusters | `sysctlbyname("hw.logicalcpu" / "hw.physicalcpu" / "hw.nperflevels" / "hw.perflevelN.*")` | Yes (`sysctlbyname` documented; `hw.perflevel*` keys not formally documented) | None | High (static) | Once at launch | Omit cluster breakdown if keys missing |
| CPU model name | `sysctlbyname("machdep.cpu.brand_string")` | Yes (key not formally documented) | None | High | Once | `Not Available` |
| Memory total | `sysctlbyname("hw.memsize")` | Yes | None | High | Once | — |
| Memory used / wired / compressed / cached / free | `host_statistics64(HOST_VM_INFO64)` × `vm_kernel_page_size` | Yes | None | High (formula is a definition, §10) | Very low | — |
| Swap used / total | `sysctlbyname("vm.swapusage")` → `xsw_usage` | Yes (`VM_SWAPUSAGE` in `sys/sysctl.h`) | None | High | Very low | — |
| Memory pressure | `kern.memorystatus_vm_pressure_level` sysctl (polled) | **Undocumented** (approved, L‑8) | None | Medium-high | Very low | `Not Available` |
| Disk list / identity / removable | IOKit `IOBlockStorageDriver` → `IOMedia`, parent characteristics | Yes | None | High | Low (re-matched per sample) | — |
| Disk read/write bytes & throughput | IOKit `IOBlockStorageDriver` `Statistics` (`Bytes (Read/Write)`) deltas | Yes (keys in public `IOBlockStorageDriver.h`) | None | High | Low (1 property copy per disk per tick) | `Not Available` per disk |
| Disk capacity / available | `IOMedia` `Size`; `URLResourceValues` `volumeAvailableCapacityForImportantUsage` of mounted descendant volumes | Yes | None (non-sandboxed) | High | Low; refreshed every 30 s | `volumeAvailableCapacity` |
| Disk active time / utilization | — (`Total Time (Read/Write)` = summed per-I/O latency, not busy time) | n/a | — | **Not reliable** (L‑3) | — | `Not Available` |
| Network per-interface RX/TX bytes & rates | `sysctl(NET_RT_IFLIST2)` → `if_msghdr2` / `if_data64` | Yes (BSD routing sysctl, public headers) | None | High (64-bit counters) | Low (one sysctl for all interfaces) | — |
| Interface classification | `ifi_type`, `SCNetworkInterfaceCopyAll`, name prefix | Yes | None | Medium (VPN friendly name rarely obtainable) | Low; refresh on change | Generic `VPN / Tunnel` + BSD name |
| GPU identification | `MTLCopyAllDevices()` | Yes | None | High | Once + on device change (`MTLCopyAllDevicesWithObserver`) | — |
| GPU utilization (system) | IOKit `IOAccelerator` `PerformanceStatistics` (`Device Utilization %`) / IOReport | **Undocumented / Private** | None | Medium, undocumented | Low | `Not Available` — L‑1 |
| Battery charge %, charging, time remaining | `IOPSCopyPowerSourcesInfo`, `IOPSGetPowerSourceDescription` | Yes | None | High | Event-driven (`IOPSNotificationCreateRunLoopSource`) | Hidden on desktops (no battery ≠ 0) |
| Battery voltage / current | IOPS `Voltage` (mV), `Current` (mA) keys (`IOPSKeys.h`) | Yes | None | Medium-high (published by Apple power sources) | Low | `Not Available` |
| Battery charge/discharge power | derived: V × I | Yes (derived) | None | Medium (derived) | Low | `Not Available` |
| Power adapter rating | `IOPSCopyExternalPowerAdapterDetails` `Watts` | Yes | None | High (rating, not draw) | Event-driven | omit |
| System / CPU / GPU package power | IOReport "Energy Model", SMC keys, `powermetrics` | **Private / Undocumented / forbidden by SPEC** | IOReport none; `powermetrics` root | — | — | `Not Available` — L‑2 |
| Process list, name, PID, path | `proc_listallpids`, `proc_pidinfo(PROC_PIDTBSDINFO)`, `proc_pidpath` | SDK/unstable (`libproc.h`) | Other users' processes may be restricted (R4) | High | Medium (O(#processes)) — only when Processes visible | `Not Available` per cell |
| Process CPU %, threads, memory | `proc_pidinfo(PROC_PIDTASKINFO)`, `proc_pid_rusage(RUSAGE_INFO_V6)` (`ri_phys_footprint`) | SDK/unstable | as above | High | Medium | `Not Available` per cell |
| Process disk read/write | `proc_pid_rusage` `ri_diskio_bytesread/written` | SDK/unstable | as above | High | included in above call | `Not Available` |
| Process network | NetworkStatistics.framework (nettop) | **Private** | — | — | — | column omitted — L‑4 |
| Process energy | `rusage_info_v6.ri_energy_nj` / `ri_billed_energy` | SDK/unstable, semantics undocumented | as above | Unknown — needs on-device validation | included | column omitted until validated — L‑5 |
| Thermal state (not required) | `ProcessInfo.thermalState` | Yes | None | High | Event-driven | — |
