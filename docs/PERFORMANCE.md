# PulseDeck — performance measurements (Milestone 10)

SPEC §26 and §36 require that the monitor itself is not a significant source of load and that it is
profiled before the project is considered complete. This document records how PulseDeck is measured,
the results, and what was changed because of them.

## Method

The development environment has no Mac, so measurements run on GitHub's macOS 26 runner through the
[Profile workflow](../.github/workflows/profile.yml) (`scripts/profile-app.sh`). It builds the
**Release** app, launches it like Finder does and measures the SPEC §36 scenarios:

| Scenario | Setup |
|---|---|
| A | Performance → CPU page visible (foreground, 1 Hz) |
| B | Processes section visible (foreground, 1 Hz, process sampling) |
| C | Main window closed, menu bar only (background sampling, 3 s) |
| D | C continued for 10 minutes, memory recorded every minute |

- **CPU**: consumed CPU time ÷ wall time over 60 s (`ps -o time`), i.e. the average share of one core.
- **Memory**: resident size every minute and the physical footprint (`footprint`) at the end of D.
- **Wakeups/energy**: `top` `IDLEW` and `POWER` columns for the last 10 s of D.
- **Where the time goes**: `sample(1)` call trees for A–C, summarised per PulseDeck function by
  `scripts/sample-summary.py`; an Instruments Time Profiler trace (`xctrace`) of B is uploaded as an
  artifact for inspection in Instruments.

Trigger it with *Run workflow* on `main`, or push a commit whose message contains `[profile]`.

**Caveats.** The runner is a virtual machine ("Apple M2 Pro (Virtual)", 5 cores, paravirtual GPU, 16
mounted disk images). Rendering is more expensive than on real hardware and there are more disks and
processes than on a typical Mac, so the foreground numbers are pessimistic. Compare runs with each
other; confirm the budgets on a real Mac with Instruments (Time Profiler, Allocations, Energy Log).

## Budgets (IMPLEMENTATION_PLAN.md §13)

- Foreground < 1 % of one core on average, background < 0.3 %.
- No growth in resident memory after the first minute.

## Results

| Scenario | Baseline (v0.4 code) | After round 1 | After round 2 |
|---|---|---|---|
| A · CPU page visible | 2.73 % | 3.15 % | 2.65 % |
| B · Processes visible | 8.87 % | 8.62 % | **6.62 %** |
| C · Menu bar only | 0.28 % | 0.30 % | 0.22 % |
| D · 10 min background | 0.27 %, 71 MiB flat, footprint 14 MB | 0.26 %, 72 MiB flat, footprint 14 MB | 0.19 %, 71 MiB flat, footprint 14 MB |

A moved from 2.73 % to 3.15 % between the first two runs although round 1 changed nothing on the CPU
page, so treat differences of that size as run-to-run noise on the shared runner.

**Background (C, D) meets its budget** and memory does not grow: resident size stayed at 71–72 MiB for
all ten minutes of D in both runs, with a 14 MB physical footprint. `top` reported 0.2–0.4 % CPU and
a POWER score of 0.2–0.4 for PulseDeck.

**Foreground (A, B) does not meet the 1 % budget on the VM.** The per-function profile shows that
little of A's time is in PulseDeck's own code (collectors ≈ 3 ms per tick, view bodies ≈ 1 ms); the
rest is AppKit/SwiftUI rendering and compositing of the redrawn charts on a VM without a real GPU.
This needs confirming on real hardware.

### What the profiles found, and the fixes

| Finding (from `sample` summaries) | Fix |
|---|---|
| B: ~270 other-user processes cost 4 failing system calls each per tick (task info, BSD info, `kinfo_proc`, rusage). | `ProcessMonitor` lists all processes with one `sysctl(KERN_PROC_ALL)` and remembers refusals per process identity. Collector time in B: ≈ 3.6 ms per tick. |
| B: every table cell with a missing value registered a tooltip on each refresh. | No per-cell tooltips in tables; the footer explains restricted rows. VoiceOver still says "Not Available". |
| B: `ProcessesView.rows` ≈ 6.4 ms per tick — `sorted(using: KeyPathComparator)` reads keys through dynamic key paths on every comparison. | `ProcessSorting` (core, tested) reads each key once and sorts indices; ties by PID keep rows stable. |
| A–C: `DiskMonitor.readDisk` was the heaviest collector (≈ 2–3 ms per tick with 16 disks): ~10 IORegistry calls per disk. | Static disk descriptions are cached per IOMedia entry; 4 calls per disk and tick remain. |
| A: every sparkline built an accessibility summary and chart descriptor each tick, although sparklines are hidden from VoiceOver. | Sparklines are marked decorative and skip that work; full and per-core charts keep it. |

Design choices that already kept the background cheap (verified by C/D): GPU, energy and process
collectors are demand-driven (`SamplingDemand`, unit tested); the background interval is 3 s with 10 %
timer tolerance; the menu bar label is reassigned only when its text changes; history is a fixed
61-sample ring buffer per series.

Round 2 cut B by a quarter: in its profile `ProcessesView.rows` no longer appears among the heavy
frames, and `DiskMonitor` takes about half the samples it did. B's resident size grew by less than
1 MiB in 60 s (caches of names and icons warming up).

## Open

- Instruments on a real Mac: Time Profiler and SwiftUI templates for A and B, Energy Log for C/D.
