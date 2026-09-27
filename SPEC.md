# Native macOS Task Manager — Product & Engineering Specification

## 1. Project Goal

Build a high-performance, native macOS system monitor/task manager in Swift.

The application should combine:

- the information architecture and readability of the Windows 11 Task Manager Performance view
- native macOS interaction patterns
- macOS 26+ Liquid Glass
- efficient low-level system telemetry
- very low idle CPU and energy impact
- menu bar/background operation

The application is NOT intended to clone the Windows Task Manager visually.

It should feel like an Apple-designed macOS application while adopting the useful information density and performance-monitoring concepts of the Windows Task Manager.

Primary sections:

1. Performance
2. Processes

Do NOT implement:

- Services
- Startup Apps
- Users
- App History
- Windows-specific concepts

## 2. Platform

Target:

- macOS 26+
- Apple Silicon as primary architecture
- Swift 6+
- SwiftUI
- Xcode 26+

Prefer native Apple frameworks and Darwin APIs.

The application must NOT use Electron, Catalyst, WebViews, JavaScript UI frameworks, or cross-platform UI frameworks.

Avoid shell commands for normal telemetry collection.

Do NOT continuously execute `top`, `ps`, `iostat`, `netstat`, `ioreg`, `powermetrics`, or similar CLI utilities. Telemetry should be obtained through native APIs wherever technically possible.

## 3. Design Principles

The application must be native, responsive, information-dense, energy efficient, visually calm, technically accurate, modular, and testable.

Accuracy is more important than displaying a metric. If a metric cannot be obtained reliably, display `Not Available`. Do not invent values, silently approximate values, or display `0` when the metric is unavailable. Estimated values must explicitly be marked as estimates.

## 4. Application Architecture

Use a modular architecture approximately following:

```text
TaskMonitor/
├── App/
│   ├── TaskMonitorApp.swift
│   ├── AppState.swift
│   └── AppLifecycleController.swift
├── Models/
│   ├── SystemSnapshot.swift
│   ├── CPUSnapshot.swift
│   ├── CPUCoreSnapshot.swift
│   ├── MemorySnapshot.swift
│   ├── DiskSnapshot.swift
│   ├── NetworkSnapshot.swift
│   ├── GPUSnapshot.swift
│   ├── EnergySnapshot.swift
│   └── ProcessSnapshot.swift
├── Monitoring/
│   ├── MonitoringEngine.swift
│   ├── SamplingPolicy.swift
│   ├── CPU/CPUMonitor.swift
│   ├── Memory/MemoryMonitor.swift
│   ├── Disk/DiskMonitor.swift
│   ├── Network/NetworkMonitor.swift
│   ├── GPU/GPUMonitor.swift
│   ├── Energy/EnergyMonitor.swift
│   └── Processes/ProcessMonitor.swift
├── Features/
│   ├── Performance/
│   └── Processes/
├── MenuBar/
├── Components/
├── System/
└── Utilities/
```

Exact file structure may change where justified. Keep telemetry collection separated from presentation.

## 5. Concurrency Model

Use Swift Concurrency. Telemetry collection must NOT execute on the MainActor. The UI receives immutable snapshots.

Conceptually:

```text
Native APIs
    ↓
Monitoring Actors
    ↓
MonitoringEngine
    ↓
SystemSnapshot
    ↓
MainActor
    ↓
SwiftUI
```

Avoid large numbers of independently observable telemetry objects. Prefer batching updates into snapshots.

## 6. Sampling

Default foreground sampling interval: 1 second.

Maintain approximately 60 seconds of high-resolution history using fixed-size ring buffers. Do NOT continuously append to unbounded arrays.

Each metric point must contain a timestamp and value(s). Use monotonic time for calculating deltas whenever possible. Wall-clock time may additionally be stored for UI presentation.

## 7. Adaptive Sampling

When the main window is visible, target 1 Hz. When only the menu bar/background is active, use a reduced sampling strategy, initially 2–5 seconds.

Do not perform expensive per-process sampling unless the Processes tab is visible, the metrics are otherwise required, or the user explicitly enables a related menu-bar metric.

GPU and energy telemetry should also use demand-driven sampling where appropriate.

## 8. Main Navigation

The application contains exactly two primary sections: Performance and Processes.

Default navigation uses a Liquid Glass top navigation/toolbar. The user must be able to switch the navigation presentation to a sidebar, and this preference must persist.

Use native macOS 26 navigation APIs wherever possible, including `NavigationSplitView`, toolbar APIs, and native Liquid Glass behavior.

## 9. Liquid Glass

Use Liquid Glass primarily for toolbar, navigation controls, sidebar, popovers, menus, and relevant floating controls.

Do not unnecessarily apply glass effects to every table row, graph, statistics block, or entire content surface.

## 10. Performance Overview

Required categories:

- CPU
- Memory
- Disks
- Network Interfaces
- GPU
- Energy

The navigation area displays a compact live preview for each resource. Only display wattage when a reliable source exists.

## 11. Chart System

Create a reusable native SwiftUI chart implementation, preferably using lightweight primitives such as Canvas, Path, and GeometryReader.

Charts must support approximately 60 seconds of history, resizing, Retina displays, light/dark mode, hover inspection, and multiple series where required.

Avoid continuous animations that consume unnecessary CPU/GPU.

## 12. Chart Hover Inspection

Mandatory for every historical performance chart.

When the pointer moves over a chart:

1. determine the nearest historical sample
2. display a vertical inspection line
3. highlight the selected point
4. show its timestamp
5. show the exact metric value(s)

For multi-value charts, show all relevant series at that sample, e.g. disk read/write or network download/upload.

Hover behavior must inspect existing ring-buffer data only and must never trigger additional telemetry requests.

## 13. CPU Monitoring

Required:

- total CPU utilization
- user/system utilization where available
- idle
- logical processor/core utilization
- logical processor count
- physical core information where reliably available
- CPU/model name

Use native Mach APIs and calculate utilization from deltas between cumulative counters.

Provide Overall Utilization and Logical Processors chart modes.

## 14. Memory Monitoring

Required where available:

- total physical memory
- used memory
- available/free memory
- wired memory
- compressed memory
- cached/inactive memory
- swap used/total
- memory pressure

Display absolute values and percentage utilization. Document the exact calculation used for Memory Used.

## 15. Disk Monitoring

Discover relevant storage devices dynamically.

For each relevant disk expose name, identifier, capacity, free/used space, read/write throughput, cumulative read/write bytes, and utilization/active time where reliably obtainable.

Use native storage/IOKit APIs and handle internal SSDs, external/removable drives, and dynamic mount/unmount safely.

## 16. Network Monitoring

Enumerate interfaces dynamically and display them individually rather than aggregating all network traffic.

Include Ethernet, Wi-Fi, bridge, Thunderbolt networking, utun, VPN/tunnel, and other active interfaces.

Collect RX/TX bytes and rates using counter deltas and actual elapsed monotonic time. Handle interface creation/removal, counter reset, sleep/wake, and VPN connection/disconnection.

## 17. VPN Interfaces

VPN/tunnel interfaces must be visible. Do not hardcode a single VPN provider.

Classify interfaces when possible. If a friendly VPN name cannot reliably be determined, display a generic `VPN / Tunnel` label plus the interface name. Never hide an interface merely because it cannot be classified.

## 18. GPU Monitoring

Use Metal for GPU device identification and, where possible, native IOKit/driver statistics for system GPU utilization.

Implement capability detection. If global GPU utilization cannot be retrieved reliably, display `Not Available`; never return fake zeroes.

## 19. Energy / Power Monitoring

Energy monitoring is a first-class Performance category.

Potential metrics include total system power where reliably available, CPU/package power, GPU power, battery charge/discharge information, current battery power derived from reliable voltage/current data, and process energy impact where supported.

The implementation must distinguish directly reported, derived, and unavailable values.

Never claim battery discharge power equals total system package power. Do not continuously invoke `powermetrics`. Avoid privileged helpers unless absolutely necessary.

## 20. Processes

Provide a native process table.

Required columns:

- Process Name
- PID
- CPU
- Memory
- Threads

Add Disk Read, Disk Write, Network, and Energy only where reliably available without excessive overhead.

Support sorting, search, selection, context menu, and keyboard navigation.

## 21. Process Sampling

Use native Darwin/libproc APIs such as `proc_listpids`, `proc_pidinfo`, and `proc_taskinfo` where appropriate.

Handle disappearing processes as a normal race condition. Calculate CPU utilization using deltas and account for PID reuse where possible.

## 22. Process Actions

Provide Quit/Terminate Process, Force Quit/Kill Process, and Show in Finder where possible.

Destructive actions require appropriate confirmation. Permission failures must be handled gracefully.

## 23. Menu Bar Application

The application must live in the macOS menu bar and continue operating when the main window is closed.

The menu bar UI should provide a compact overview of available CPU, Memory, GPU, Energy, and Network metrics plus actions to open the Task Monitor and quit.

## 24. Menu Bar Metric

Support one optional compact live metric directly in the menu bar, initially selectable from CPU, Memory, GPU, Network Download, Network Upload, and Energy.

Design the architecture so additional display modes can be added later. Avoid unnecessary menu-bar updates.

## 25. Application Lifecycle

On launch, start MonitoringEngine and menu bar functionality. The main window appears according to preference.

Closing the main window keeps the app running and switches SamplingPolicy to background mode. Reopening restores foreground sampling. Explicit Quit stops monitoring and exits cleanly.

## 26. Background Efficiency

The monitor itself must not become a significant source of load.

Optimize sampling frequency, process enumeration, chart rendering, memory allocation, observable updates, IOKit/GPU queries, and menu bar refreshes.

Do not redraw invisible charts or collect expensive detailed metrics nobody is observing.

## 27. Sleep / Wake

After wake, reset timing baselines where necessary and re-enumerate disks/interfaces as appropriate. Sleep must never generate bogus CPU, disk, or network spikes.

## 28. Counter Handling

Cumulative-counter metrics must safely handle counter reset, overflow, device/process disappearance, PID reuse, interface reset, sleep/wake, and the first sample without a baseline.

When no valid delta exists, mark the sample unavailable rather than generating an incorrect value.

## 29. History Model

Use fixed-capacity buffers with O(1) insertion, bounded memory, cheap nearest-point lookup for chart hover, and no unnecessary copies on every render.

## 30. Formatting

Use native/localized formatting for bytes, rates, percentages, and watts. Avoid excessive precision; hover inspection may show slightly higher precision than overview labels.

## 31. Accessibility

Support VoiceOver, keyboard navigation, Reduce Motion, Increase Contrast where practical, light/dark mode, and accessible chart summaries.

## 32. Preferences

Initial settings:

General:
- Launch at Login
- Show main window at launch
- Keep running when window closes

Navigation:
- Top Bar
- Sidebar

Menu Bar:
- displayed metric
- refresh behavior if needed

## 33. Launch at Login

Use Apple's supported modern login-item mechanism. Do not install arbitrary shell launch scripts.

## 34. Error Handling

Telemetry failure must not crash the application.

Expected failures include permission denied, process vanished, disk/interface removed, unsupported GPU/energy metrics, and transient IOKit failures.

Represent telemetry capability explicitly with typed states.

## 35. Testing

Create unit tests for:

- counter delta calculations
- CPU calculation
- network rates
- disk rates
- RingBuffer behavior
- hover nearest-sample lookup
- formatting

## 36. Performance Testing

Use Instruments before considering the project complete.

Profile at least:

A. CPU Performance view visible
B. Processes view visible
C. main window closed/menu bar only
D. extended background operation

Inspect CPU usage, allocations, memory growth, SwiftUI rendering, energy impact, wakeups, and I/O. There must be no unbounded memory growth.

## 37. Privacy and Security

Telemetry remains local. Do not implement analytics or telemetry upload. Do not transmit process names or system statistics.

Avoid privileged helpers unless technically unavoidable and document every entitlement or permission introduced.

## 38. Code Quality

Requirements:

- Swift 6 concurrency correctness
- no force unwraps in telemetry paths
- clear ownership
- minimal global state
- dependency injection where useful
- protocols around telemetry providers
- comments explaining non-obvious Darwin/IOKit behavior
- no unexplained magic constants

## 39. Development Strategy

Implement in milestones:

1. Foundation — project, lifecycle, menu bar, navigation, monitoring protocols/models
2. CPU — total/per-core, history, charts, hover, tests
3. Memory
4. Network — interfaces, RX/TX, VPN/tunnels, hot-plug
5. Disk — discovery, R/W, capacity, removal
6. GPU — Metal identification, capability detection, reliable utilization
7. Energy — battery/power metrics, capability model, history
8. Processes — enumeration, CPU/memory/threads, sorting/search/actions
9. Menu Bar — popover, selectable metric, adaptive sampling
10. Optimization — Instruments profiling and fixes
11. Polish — accessibility, preferences, launch at login, error states

## 40. Definition of Done

CPU: total/per-core utilization, history, hover.
Memory: utilization/categories, history, hover.
Disk: dynamic discovery, R/W rates, history, hover.
Network: dynamic per-interface discovery including VPN/tunnels, RX/TX, history, hover.
GPU: identification, supported utilization, honest unsupported state, history/hover where available.
Energy: available metrics, explicit derived/unavailable states, history/hover.
Processes: list, sorting, search, CPU/memory, safe process disappearance handling, permitted actions.
Menu Bar: survives window close, compact overview, reopen, reduced background sampling, clean quit.
Performance: bounded history, no unbounded growth, no shell-command polling, demand-driven telemetry, profiled background operation.

## 41. Non-Goals

Do not implement in v1:

- Windows Services equivalent
- startup manager
- user session management
- remote monitoring
- cloud synchronization
- long-term telemetry database
- web dashboard
- iOS/Windows versions
- kernel extensions

## 42. Engineering Rule

When choosing between displaying more metrics through fragile hacks and displaying fewer metrics through reliable native APIs, choose the reliable implementation.

Correctness, efficiency, and graceful capability detection take priority over feature count.
