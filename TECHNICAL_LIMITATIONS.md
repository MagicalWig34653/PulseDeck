# PulseDeck — Technical Limitations

This document lists requirements from [`SPEC.md`](SPEC.md) that cannot be implemented
reliably with appropriate public/native APIs. It does **not** change `SPEC.md`; it records
how each requirement is honoured (SPEC §3, §42: *"Not Available"* over an incorrect value).

Verification basis: open-source xnu / IOKitUser / IOStorageFamily headers and Apple's
documentation index (see `IMPLEMENTATION_PLAN.md` §0). The installed Xcode 26 SDK could not be
inspected in the authoring environment; each item is to be re-checked on a Mac when its milestone
is implemented. Anything below marked *needs on-device validation* is a known unknown, not a
conclusion.

Decisions by the product owner are recorded under each item.

---

## L‑1 · System-wide GPU utilization

- **SPEC requirement:** §18 — "native IOKit/driver statistics for system GPU utilization …
  If global GPU utilization cannot be retrieved reliably, display `Not Available`." §40 GPU:
  "supported utilization, honest unsupported state".
- **APIs investigated:**
  - Metal (`MTLDevice`, `MTLCopyAllDevices`, counter sample buffers / `MTLCounterSet`): only
    identification and *per-command-buffer* counters for work the app itself submits. No
    system-wide utilization API. `MTLDevice.currentAllocatedSize` is this process's allocation,
    not system GPU memory.
  - IOKit: `IOAccelerator` services expose a `PerformanceStatistics` dictionary containing keys such
    as `Device Utilization %`, `Renderer Utilization %`, `Tiler Utilization %`. The IOKit calls are
    public, **the property keys and their semantics are undocumented** and vary between GPU
    drivers (AGX on Apple Silicon vs. AMD/Intel drivers).
  - IOReport (`IOReportCopyChannelsInGroup`, "GPU Stats" group): **private** library, no SDK
    header, no documentation page.
- **Limitation:** there is no documented public API for system-wide GPU utilization on macOS.
- **Possible fallback:** Metal-based identification only.
- **Resulting UI behavior:** GPU page shows device name(s), unified-memory flag, low-power /
  removable flags; *Utilization: Not Available* with explanation "macOS provides no public API for
  system-wide GPU utilization". No GPU chart; the resource-list preview shows the device name.
- **Undocumented/private alternatives:** yes — `IOAccelerator` `PerformanceStatistics` (undocumented
  keys via public IOKit calls) and IOReport (private).
- **Recommendation:** Do not use IOReport (private SPI). `IOAccelerator` `PerformanceStatistics` is
  widely used by monitoring tools and needs no privileges; it could be added as an **explicitly
  labelled, opt-in "undocumented source"** with runtime capability detection (key missing ⇒
  `Not Available`).
- **Decision (approved by the product owner):** use `IOAccelerator` `PerformanceStatistics`, clearly
  labelled as an undocumented source, with automatic fallback to `Not Available`. To be implemented in
  Milestone 6. IOReport stays excluded.
- **Implemented (Milestone 6):** `GPUMonitor` identifies devices with `MTLCopyAllDevices()` and reads
  `Device Utilization %` from every `IOAccelerator`'s `PerformanceStatistics`. A Metal device is paired
  with the accelerator whose registry entry (or one of its three nearest parents) has the device's
  `registryID`; with exactly one device and one accelerator they are paired directly. Missing key or
  no match ⇒ *Not Available* (`noPublicAPI`); values outside 0–100 ⇒ `—`. The GPU page shows a visible
  "undocumented driver statistic" note under the chart. Observed on the CI VM ("Apple Paravirtual
  device"): the key is absent, so the page shows *Utilization Not Available* — a real Apple silicon Mac
  still needs a manual check that the AGX driver's value matches Activity Monitor's GPU History.

## L‑2 · System, CPU/package and GPU power (watts)

- **SPEC requirement:** §19 — total system power, CPU/package power, GPU power "where reliably
  available"; §10 "Only display wattage when a reliable source exists"; "Do not continuously invoke
  `powermetrics`. Avoid privileged helpers."
- **APIs investigated:**
  - `powermetrics` — CLI, requires root; forbidden by SPEC §2/§19.
  - IOReport "Energy Model" channels (what `powermetrics` uses on Apple Silicon) — **private**.
  - SMC keys (e.g. `PSTR`, `PCPC`) via the `AppleSMC` IOKit user client — **undocumented**, key
  names differ per model, structure layout undocumented.
  - `AppleSmartBattery` registry `PowerTelemetryData` (e.g. `SystemPowerIn`) — **undocumented**, only
    on portables.
  - IOPS keys (`IOPSKeys.h`): battery `Voltage` (mV) and `Current` (mA) — **public**.
  - `IOPSCopyExternalPowerAdapterDetails` — adapter *rating* in watts (not consumption).
- **Limitation:** no public API reports system, CPU-package or GPU power.
- **Possible fallback:** battery charge/discharge power **derived** from `Voltage × Current`
  (portables only), clearly labelled; adapter rating labelled as a rating.
- **Resulting UI behavior:** Energy page shows battery state, charge %, time remaining, battery
  power (*derived*, signed: charging / discharging), adapter rating. *System power*, *CPU power*,
  *GPU power*: **Not Available**. On AC with a full battery, battery power ≈ 0 W is shown as a
  battery value only and is never labelled as system power (SPEC §19). Desktops without battery:
  battery section hidden, power rows *Not Available*. No wattage in the resource-list preview unless
  battery power is available (and then labelled "Battery").
- **Undocumented/private alternatives:** yes (IOReport, SMC, `PowerTelemetryData`).
- **Recommendation:** do not use IOReport or SMC in v1 (private/undocumented, model-specific, risk of
  wrong values).
- **Decision (approved by the product owner):** use `PowerTelemetryData.SystemPowerIn` (portables
  only) as a clearly labelled undocumented source with fallback to `Not Available`. To be implemented
  and validated in Milestone 7. IOReport and SMC stay excluded.
- **Implemented (Milestone 7):** `SystemPowerIn` (mW) is shown as **System Power In** — the power drawn
  from the adapter, which includes battery charging — with a visible "undocumented" note. It is *not
  applicable* on battery power (the controller reports no adapter input then; it is never replaced by
  battery power, and never shown as `0 W`). Zero or > 1 kW readings on AC ⇒ `—`. Battery power is derived
  from IOPS `Voltage` × `Current` and labelled "(derived)" with its direction (charging/discharging).
  Adapter rating is shown as "N W rated". The CI VM has no battery, so these paths are covered by unit
  tests only; **needs a manual check on a MacBook** (on AC and on battery). If IOPS omits `Voltage` or
  `Current` on some model, battery power shows *Not Available*; the undocumented `AppleSmartBattery`
  `Voltage`/`Amperage` properties could fill that gap but were not approved and are not used.

## L‑3 · Disk utilization / active time

- **SPEC requirement:** §15 — "utilization/active time where reliably obtainable".
- **APIs investigated:** `IOBlockStorageDriver` `Statistics` (public header): `Bytes`, `Operations`,
  `Latency Time`, `Total Time (Read/Write)` (nanoseconds spent performing reads/writes),
  `Retries`, `Errors`. DiskArbitration (identity only). No busy-time / queue-depth counter.
- **Limitation:** `Total Time` is the **sum of per-request service times**. With NVMe queue depths
  > 1, concurrent requests overlap, so `ΔTotalTime / Δt` can exceed 100 % and does not equal the
  fraction of time the device was busy (Windows "Active time"). There is no public busy-time
  counter.
- **Possible fallback:** average I/O latency (`ΔTotalTime / ΔOperations`) and IOPS are reliable and
  could be displayed instead (additional, not a substitute labelled as active time).
- **Resulting UI behavior:** *Active time: Not Available*. Read/write throughput, cumulative bytes,
  capacity/free shown. Optionally (M5) "Avg. response time" from the documented counters.
- **Undocumented/private alternatives:** none known that give true busy time.
- **Recommendation:** show `Not Available`; do not present a clamped `TotalTime/elapsed` value as
  active time.

## L‑4 · Per-process network traffic

- **SPEC requirement:** §20 — "Add … Network … only where reliably available without excessive
  overhead."
- **APIs investigated:** `proc_pidinfo` flavors (`PROC_PIDFDSOCKETINFO` gives socket state, not
  byte counts), `rusage_info_v6` (no network fields), NetworkStatistics.framework (used by `nettop`,
  **private**), Network Extension content filters (require a system extension + user approval and
  intercept traffic — excessive and inappropriate).
- **Limitation:** no public API provides per-process network byte counters.
- **Possible fallback:** none that is public and cheap.
- **Resulting UI behavior:** the Processes table has **no Network column**. System and per-interface
  network remain on the Performance page.
- **Undocumented/private alternatives:** NetworkStatistics.framework (private); running `nettop`
  (shell polling, forbidden by SPEC §2).
- **Recommendation:** do not implement.

## L‑5 · Per-process energy

- **SPEC requirement:** §19 "process energy impact where supported"; §20 Energy column "only where
  reliably available".
- **APIs investigated:** `proc_pid_rusage(RUSAGE_INFO_V6)` — `ri_energy_nj`, `ri_penergy_nj`,
  `ri_billed_energy`, `ri_serviced_energy`, `ri_pkg_idle_wkups`, `ri_interrupt_wkups`. These fields
  are in the public section of `sys/resource.h` (not `PRIVATE`), but their semantics/units are not
  documented (the `_nj` suffix suggests nanojoules), and `libproc.h` declares itself
  "private interfaces … subject to change". Activity Monitor's "Energy Impact" is a proprietary
  score computed by a private daemon (not reproducible).
- **Limitation:** no documented per-process energy metric; "Energy Impact" cannot be reproduced.
- **Possible fallback:** an **estimated** per-process power `Δri_energy_nj / Δt` (labelled "est.")
  if on-device validation shows it is non-zero, monotonic and plausible (sum across processes ≤
  measured battery discharge power). *Needs on-device validation.*
- **Resulting UI behavior:** until validated, the Energy column is **not shown**. If validated, an
  optional column "Energy (est.)" in watts, never called "Energy Impact".
- **Undocumented/private alternatives:** coalition energy via private `coalition_info` SPI;
  `powermetrics --show-process-energy` (root CLI, forbidden).
- **Recommendation:** validate `ri_energy_nj` in Milestone 8; ship only if validation passes.
- **Status (Milestone 8):** not validated — validation needs a real Mac on battery, which the CI VM is
  not. The Processes table therefore has **no Energy column**.

## L‑6 · Friendly VPN names

- **SPEC requirement:** §17 — classify interfaces when possible, otherwise `VPN / Tunnel` + interface
  name; never hide an interface.
- **APIs investigated:** SystemConfiguration (`SCNetworkServiceCopyAll`, `SCNetworkInterface*`) —
  sees system-configured PPP/IPSec/IKEv2 services; `NEVPNManager` — only the calling app's own
  configurations; Network Extension–based VPNs (most third-party clients) appear as `utunN` with no
  public mapping from interface to provider.
- **Limitation:** mapping `utunN` → VPN product name is not reliably possible with public APIs.
  (`utun` interfaces are also used by the system itself, e.g. iCloud Private Relay/Continuity.)
- **Resulting UI behavior:** `VPN / Tunnel (utun4)`; friendly name only when a SystemConfiguration
  service unambiguously maps to that BSD interface.
- **Undocumented/private alternatives:** reading `/Library/Preferences/SystemConfiguration`
  plists / private NE SPIs. **Recommendation:** do not use.

## L‑7 · Per-process details for other users' processes

- **SPEC requirement:** §20–22 process table, §22 "Permission failures must be handled gracefully".
- **APIs investigated:** `proc_pidinfo(PROC_PIDTASKINFO)`, `proc_pid_rusage`, `kill`.
- **Limitation:** for processes owned by other users (notably root), task-level info and signals may
  be refused (`EPERM`) for a non-root app. *Needs on-device validation* for each flavor on macOS 26.
- **Resulting UI behavior:** row still shown (name/PID from `PROC_PIDTBSDINFO`/`proc_name` where
  permitted); cells that fail show *Not Available* (`—` with tooltip), never `0`. Kill/Terminate
  failures show an alert explaining the permission error.
- **Privileged alternative:** `SMAppService.daemon` privileged helper. **Recommendation:** not in v1
  (SPEC §37: avoid unless unavoidable).
- **Verified (Milestone 8, CI runner, macOS 26):** for other users' processes `PROC_PIDTASKALLINFO`,
  `PROC_PIDTBSDINFO` and `proc_pid_rusage` all fail with `EPERM` (234 of 525 processes on the runner).
  Identity (start time), owner and short name then come from `sysctl(KERN_PROC_PID)` → `kinfo_proc`
  (public, what `ps` uses), so these rows are still listed; CPU/memory/threads/disk show `—` with the
  explanation, and the footer counts them.

## L‑8 · Current memory-pressure level at launch

- **SPEC requirement:** §14 "memory pressure".
- **APIs investigated:** `DispatchSource.makeMemoryPressureSource` (documented) delivers
  *transitions* (normal/warning/critical) only; it does not report the level at subscription time.
  `sysctl kern.memorystatus_vm_pressure_level` (readable, no privileges) — **undocumented** sysctl
  (present in xnu `kern_memorystatus_notify.c`).
- **Limitation:** with documented APIs only, the pressure level is unknown until the first
  transition (which may never occur in a healthy system).
- **Possible fallback:** show *Not Available* until a transition is received.
- **Undocumented alternative:** the sysctl above (cheap, read-only, stable for many releases).
- **Decision (approved, implemented in Milestone 3):** `MemoryMonitor` reads
  `kern.memorystatus_vm_pressure_level` on every sample (one read-only sysctl). Verified in xnu
  `kern_memorystatus_notify.c`: on macOS it needs no privilege and returns the dispatch level
  (`NOTE_MEMORYSTATUS_PRESSURE_NORMAL/WARN/CRITICAL` = 1/2/4). Any other value or a failure shows
  *Not Available*. The Memory page labels the value's source. Because the level is polled, the
  dispatch source is not needed.

## L‑10 · Space used by APFS snapshots

- **Owner request:** Disks page "used space for snapshots".
- **APIs investigated:** `fs_snapshot_list(2)` (public, `<sys/snapshot.h>`) lists snapshots by name
  and date only. The per-snapshot "private size" that `tmutil`/Disk Utility show comes from APFS
  internals (`apfs` fsctl / private frameworks). No public API reports it.
- **Decision (implemented in v0.6.0):** the snapshot *count* is shown (`fs_snapshot_list`, counted
  per mounted APFS volume; the sealed system snapshot mounted at "/" counts too). *Snapshot Space*
  shows *Not Available* with that explanation. No shell tools (`tmutil`, `diskutil`) are polled.

## L‑11 · Current CPU frequency

- **Owner request:** CPU page "frequency".
- **APIs investigated:** `sysctl hw.cpufrequency` does not exist on Apple silicon; no documented API
  reports current clock speeds.
- **Decision (owner approved "IOReport"):** `CPUFrequencyMonitor` opens the private
  `libIOReport.dylib` with `dlopen` (never linked) and reads the "CPU Stats" → "CPU Complex
  Performance States" residencies per cluster; state frequencies come from the IORegistry
  (`IODeviceTree:/arm-io/pmgr` voltage-state tables). The page shows the activity-weighted average
  frequency per cluster, labelled as coming from a private library. Missing library, channels or
  tables → *Not Available* (the CI VM has none). **Needs a real Mac** to validate against
  `powermetrics`.

## L‑12 · Power per USB port

- **Owner request:** "power consumption of every USB port".
- **APIs investigated:** macOS measures no per-port current. The IORegistry exposes what the host
  *allocated* to each device (`UsbPowerSinkAllocation`, mA; legacy `Requested Power` in 2 mA units)
  and port limits (`kUSBWakePortCurrentLimit`) — undocumented keys, verified present on the CI VM.
- **Decision (owner approved "allocated, labelled"):** the USB section shows allocated bus power per
  device and totals per bus, at 5 V, with a note that it is an allocation, not a measurement, and
  excludes self-powered devices and USB‑C Power Delivery.

## L‑9 · Verification environment (process limitation, not a product limitation)

- Milestone 1 was authored in a Linux container without Xcode. The platform-independent core was
  compiled and tested locally with Swift 6.2.3 for Linux; the Xcode project and SwiftUI/AppKit code
  are verified by the macOS GitHub Actions workflow. Milestone 1 result (run 36301687997, macOS 26.6.2,
  Xcode 26.6 / Swift 6.3.3): `swift test -Xswiftc -warnings-as-errors` 50/50 passed; `xcodebuild build`
  with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` succeeded; `xcodebuild test` 50/50 passed.
- CI cannot exercise the running GUI (menu bar residency, window close/reopen, Dock switching, sleep/wake)
  or Darwin telemetry on real hardware; these need a manual check on a Mac. Instruments profiling
  (SPEC §36) is scheduled for Milestone 10.
- Milestone 10 profiling ran on the CI runner instead of a developer Mac: CPU time, memory and
  wakeups of the Release build per scenario, `sample` call trees and an `xctrace` Time Profiler trace
  (`docs/PERFORMANCE.md`). The runner is a GPU-less VM, so foreground rendering costs are pessimistic;
  the budgets still need confirming with Instruments on real hardware.
