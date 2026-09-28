#!/usr/bin/env python3
"""Summarises a `sample(1)` report: inclusive sample counts per function of one binary.

    scripts/sample-summary.py <sample.txt> [image=PulseDeck] [limit=40]

`sample` prints a call tree per thread with the number of samples in which each frame was on the
stack. Idle waits dominate its "top of stack" list, so this prints the heaviest frames of the
given image instead: the functions of our own code that were on the stack most often (summed
across threads and call sites), which is what the M10 optimisation needs.
"""
import collections
import re
import sys

path = sys.argv[1]
image = sys.argv[2] if len(sys.argv) > 2 else "PulseDeck"
limit = int(sys.argv[3]) if len(sys.argv) > 3 else 40

frame = re.compile(r"^[\s+!:|]*?(\d+)\s+(.+?)\s+\(in ([^)]+)\)")
totals = collections.Counter()
in_graph = False
for line in open(path, errors="replace"):
    if line.startswith("Call graph:"):
        in_graph = True
        continue
    if in_graph and line.startswith("Total number in stack"):
        break
    if not in_graph:
        continue
    match = frame.match(line)
    if match and match.group(3) == image:
        symbol = re.sub(r"\s+\+\s+\d+.*$", "", match.group(2))
        totals[symbol] += int(match.group(1))

print(f"Heaviest {image} frames in {path} (inclusive samples, ~1 ms each):")
for symbol, count in totals.most_common(limit):
    print(f"{count:8d}  {symbol[:160]}")
