#!/bin/bash
# Measures PulseDeck's own resource use in the SPEC §36 scenarios on a macOS machine.
#
#   scripts/profile-app.sh <PulseDeck.app> <output-dir> [measure-seconds] [extended-seconds]
#
# A  Performance/CPU page visible (foreground, 1 Hz)
# B  Processes section visible (foreground, 1 Hz, process sampling)
# C  Main window closed, menu bar only (background sampling)
# D  Extended background operation: memory samples every minute to detect growth
#
# CPU is measured as consumed CPU time over wall time (`ps -o time`), i.e. the average share of
# one core, which is what the budgets in IMPLEMENTATION_PLAN.md §13 refer to. Call trees come
# from `sample(1)`; a Time Profiler trace is recorded with `xctrace` where the host allows it.
set -euo pipefail

app=$1
out=$2
measure=${3:-60}
extended=${4:-600}
warmup=20
bundle_id=de.linolaske.PulseDeck
mkdir -p "$out"
results="$out/results.md"

cpu_seconds() {
    ps -o time= -p "$1" | python3 -c '
import sys
total = 0.0
for part in sys.stdin.read().strip().split(":"):
    total = total * 60 + float(part)
print(total)'
}

rss_kib() { ps -o rss= -p "$1" | tr -d " "; }

footprint_line() { footprint -p "$1" 2>/dev/null | grep -m1 -i "footprint" || echo "footprint unavailable"; }

stop_app() {
    pkill -x PulseDeck 2>/dev/null || true
    sleep 3
}

# Launches the app like Finder does and prints its PID.
launch() {
    stop_app
    open -n "$app" --args "$@"
    local pid=""
    for _ in $(seq 1 30); do
        pid=$(pgrep -x PulseDeck || true)
        [[ -n "$pid" ]] && break
        sleep 1
    done
    [[ -n "$pid" ]] || { echo "PulseDeck did not start" >&2; exit 1; }
    echo "$pid"
}

# measure <scenario> <pid> <seconds>: appends one row to the results table.
measure() {
    local name=$1 pid=$2 seconds=$3
    local cpu0 cpu1 rss0 rss1 start end
    cpu0=$(cpu_seconds "$pid"); rss0=$(rss_kib "$pid"); start=$(date +%s)
    sleep "$seconds"
    cpu1=$(cpu_seconds "$pid"); rss1=$(rss_kib "$pid"); end=$(date +%s)
    python3 - "$name" "$cpu0" "$cpu1" "$start" "$end" "$rss0" "$rss1" >> "$results" <<'PY'
import sys
name, cpu0, cpu1, start, end, rss0, rss1 = sys.argv[1], *map(float, sys.argv[2:])
wall = end - start
print(f"| {name} | {wall:.0f} s | {(cpu1 - cpu0) / wall * 100:.2f} % | {rss0 / 1024:.1f} MiB | {rss1 / 1024:.1f} MiB |")
PY
}

{
    echo "## PulseDeck self-measurement"
    echo
    echo "Host: $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.logicalcpu) logical CPUs, macOS $(sw_vers -productVersion)"
    echo
    echo "| Scenario | Duration | Avg CPU (share of one core) | RSS start | RSS end |"
    echo "|---|---|---|---|---|"
} > "$results"

defaults write "$bundle_id" showMainWindowAtLaunch -bool YES

# A: CPU page in the foreground.
pid=$(launch -navigationPresentation topBar -initialCategory cpu)
sleep "$warmup"
measure "A · CPU page visible" "$pid" "$measure"
sample "$pid" 10 -file "$out/A-sample.txt" >/dev/null 2>&1 || echo "sample failed (A)"

# B: Processes section in the foreground.
pid=$(launch -navigationPresentation topBar -initialSection processes)
sleep "$warmup"
measure "B · Processes visible" "$pid" "$measure"
sample "$pid" 10 -file "$out/B-sample.txt" >/dev/null 2>&1 || echo "sample failed (B)"
xcrun xctrace record --template "Time Profiler" --attach "$pid" --time-limit 20s \
    --output "$out/B-time-profiler.trace" >"$out/xctrace.log" 2>&1 || echo "xctrace failed; see xctrace.log"

# E: Processes in the sidebar presentation (previews, GPU and energy stay live next to the
# table), dark appearance. Memory every 30 s for 3 minutes to catch growth.
defaults write -g AppleInterfaceStyle Dark
pid=$(launch -navigationPresentation sidebar -initialSection processes)
sleep "$warmup"
{
    echo
    echo "### E · Processes in the sidebar (dark)"
    echo
    echo "| Seconds | RSS | Footprint |"
    echo "|---|---|---|"
} > "$out/sidebar.md"
cpu_e0=$(cpu_seconds "$pid")
for step in 0 1 2 3 4 5 6; do
    echo "| $((step * 30)) | $(( $(rss_kib "$pid") / 1024 )) MiB | $(footprint_line "$pid" | sed 's/.*Footprint: //') |" >> "$out/sidebar.md"
    if [[ "$step" -lt 6 ]]; then sleep 30; fi
done
cpu_e1=$(cpu_seconds "$pid")
python3 - "$cpu_e0" "$cpu_e1" >> "$out/sidebar.md" <<'PY'
import sys
start, end = map(float, sys.argv[1:])
print(f"\nAverage CPU over 180 s: {(end - start) / 180 * 100:.2f} % of one core")
PY
defaults delete -g AppleInterfaceStyle 2>/dev/null || true

# C and D: menu bar only.
defaults write "$bundle_id" showMainWindowAtLaunch -bool NO
pid=$(launch)
sleep "$warmup"
measure "C · Menu bar only" "$pid" "$measure"
sample "$pid" 10 -file "$out/C-sample.txt" >/dev/null 2>&1 || echo "sample failed (C)"

{
    echo
    echo "### D · Extended background operation"
    echo
    echo "| Minute | RSS | CPU time total |"
    echo "|---|---|---|"
} > "$out/extended.md"
minutes=$((extended / 60))
cpu_start=$(cpu_seconds "$pid")
for minute in $(seq 0 "$minutes"); do
    echo "| $minute | $(( $(rss_kib "$pid") / 1024 )) MiB | $(cpu_seconds "$pid") s |" >> "$out/extended.md"
    if [[ "$minute" -lt "$minutes" ]]; then sleep 60; fi
done
cpu_end=$(cpu_seconds "$pid")
python3 - "$cpu_start" "$cpu_end" "$((minutes * 60))" >> "$out/extended.md" <<'PY'
import sys
start, end, wall = map(float, sys.argv[1:])
print(f"\nAverage CPU over {wall:.0f} s: {(end - start) / wall * 100:.2f} % of one core")
PY
echo "Footprint at end: $(footprint_line "$pid")" >> "$out/extended.md"
top -l 2 -s 10 -pid "$pid" -stats pid,command,cpu,idlew,mem,power > "$out/D-top.txt" 2>&1 || true

stop_app
defaults delete "$bundle_id" showMainWindowAtLaunch 2>/dev/null || true

cat "$out/sidebar.md" "$out/extended.md" >> "$results"
{
    echo
    echo "### Wakeups and energy (top, last 10 s of D)"
    echo
    echo '```'
    tail -n 3 "$out/D-top.txt"
    echo '```'
} >> "$results"
cat "$results"
