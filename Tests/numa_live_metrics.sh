#!/bin/zsh
set -euo pipefail

pid="${1:?usage: $0 PID EXPECTED_EXECUTABLE}"
expected="${2:?usage: $0 PID EXPECTED_EXECUTABLE}"
actual=$(ps -p "$pid" -o comm=)
[[ "$actual" == "$expected" ]]

samples=$(mktemp)
trap 'rm -f "$samples"' EXIT
for _ in {1..20}; do
  ps -p "$pid" -o %cpu=,rss= >> "$samples"
  sleep 0.5
done
awk '
  { cpu += $1; rss += $2; if ($1 > maxcpu) maxcpu = $1; if ($2 > maxrss) maxrss = $2 }
  END {
    if (NR == 0) exit 1
    printf "cpu_mean_percent=%.2f cpu_max_percent=%.2f rss_max_mb=%.2f samples=%d\n", cpu/NR, maxcpu, maxrss/1024, NR
  }
' "$samples"
