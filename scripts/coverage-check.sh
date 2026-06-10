#!/usr/bin/env bash
# Compare line coverage from an lcov report against the committed
# baseline.  Coverage is deterministic for a fixed toolchain, so any
# drop fails.  With --update, write the current number as the new
# baseline instead.

set -euo pipefail

lcov_file="${LCOV_FILE:-coverage/lcov.info}"
baseline_file="${COVERAGE_BASELINE:-baselines/coverage.txt}"

if [ ! -f "$lcov_file" ]; then
  echo "coverage-check: missing $lcov_file (run 'make coverage' first)" >&2
  exit 1
fi

# undercover's lcov writer emits only DA:<line>,<count> records (no
# LF:/LH: summaries), so derive the totals from the DA lines.
current=$(awk '
  /^DA:/ {
    split(substr($0, 4), parts, ",")
    found++
    if (parts[2] > 0) hit++
  }
  END { printf "%.2f", (found ? 100 * hit / found : 0) }
' "$lcov_file")

if [ "${1:-}" = "--update" ]; then
  mkdir -p "$(dirname "$baseline_file")"
  printf '%s\n' "$current" >"$baseline_file"
  echo "coverage baseline set to ${current}%"
  exit 0
fi

if [ ! -f "$baseline_file" ]; then
  echo "coverage-check: missing $baseline_file (run 'make coverage-baseline')" >&2
  exit 1
fi

baseline=$(<"$baseline_file")

if awk -v c="$current" -v b="$baseline" 'BEGIN { exit !(c + 0.001 >= b) }'; then
  echo "coverage OK: ${current}% (baseline ${baseline}%)"
else
  echo "coverage regressed: ${current}% < baseline ${baseline}%" >&2
  exit 1
fi
