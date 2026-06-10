#!/usr/bin/env bash
# Compare benchmark results against the committed baseline.  Fails if
# any benchmark is more than BENCH_TOLERANCE (default 5%) slower than
# its baseline.  The harness reports each benchmark's CPU time as a
# ratio of an in-process calibration loop, so scheduler and frequency
# effects cancel out instead of skewing the comparison.  With
# --update, write the current results as the new baseline.
#
# Regenerate the baseline with 'make bench-baseline' when the Emacs
# toolchain changes.

set -euo pipefail

current_file="${BENCH_CURRENT:-bench/current.tsv}"
baseline_file="${BENCH_BASELINE:-baselines/bench.tsv}"
tolerance="${BENCH_TOLERANCE:-0.05}"

if [ ! -f "$current_file" ]; then
  echo "bench-check: missing $current_file (run 'make bench' first)" >&2
  exit 1
fi

if [ "${1:-}" = "--update" ]; then
  mkdir -p "$(dirname "$baseline_file")"
  cp "$current_file" "$baseline_file"
  echo "bench baseline updated from $current_file:"
  cat "$baseline_file"
  exit 0
fi

if [ ! -f "$baseline_file" ]; then
  echo "bench-check: missing $baseline_file (run 'make bench-baseline')" >&2
  exit 1
fi

awk -F'\t' -v tol="$tolerance" '
  NR == FNR { base[$1] = $2; next }
            { cur[$1]  = $2 }
  END {
    fail = 0
    for (name in base) {
      if (!(name in cur)) {
        printf "missing benchmark in current run: %s\n", name
        fail = 1
        continue
      }
      delta = (base[name] > 0) ? (cur[name] / base[name] - 1) * 100 : 0
      printf "%-16s baseline=%.4f current=%.4f delta=%+.1f%%\n", \
             name, base[name], cur[name], delta
      if (cur[name] > base[name] * (1 + tol)) {
        printf "  REGRESSION: %s is more than %.0f%% slower\n", name, tol * 100
        fail = 1
      }
    }
    # The reverse direction too: a benchmark with no committed
    # baseline would otherwise never be gated at all.
    for (name in cur) {
      if (!(name in base)) {
        printf "benchmark missing from baseline (run make bench-baseline): %s\n", name
        fail = 1
      }
    }
    exit fail
  }
' "$baseline_file" "$current_file"
