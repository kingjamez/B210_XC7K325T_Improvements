#!/usr/bin/env bash
# RX-only throughput baseline for a K7 B210 FPGA image.
#
#   tools/baseline.sh [fpga.bin] [serial]
#
# Defaults to the vendor image in vendor/baseline/. Receive only: nothing is
# transmitted. Results go to docs/baselines/<host>-<image>-<date>.txt.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
img="${1:-$repo/vendor/baseline/vendor_b210_k7.bin}"
serial="${2:-}"
duration="${DURATION:-10}"
# USB transport tuning. Stock UHD defaults drop samples above ~40 Msps on macOS;
# these values ran 61.44 Msps (1ch) and 2x30.72 Msps clean on an M-series Mac.
# Set TUNE= (empty) to measure the UHD defaults.
tune="${TUNE-num_recv_frames=128,recv_frame_size=16360}"

# BENCH=/path/to/benchmark_rate overrides the search (e.g. Arch's libuhd ships
# no examples: build host/examples/benchmark_rate.cpp against libuhd).
bench="${BENCH:-$(dirname "$(command -v uhd_config_info)")/../lib/uhd/examples/benchmark_rate}"
[ -x "$bench" ] || bench="$(command -v benchmark_rate || true)"
[ -x "$bench" ] || { echo "benchmark_rate not found" >&2; exit 1; }

args="type=b200,fpga=$img"
[ -n "$serial" ] && args="$args,serial=$serial"
[ -n "$tune" ] && args="$args,$tune"

mkdir -p "$repo/docs/baselines"
out="$repo/docs/baselines/$(hostname -s)-$(basename "$img" .bin)-$(date +%Y%m%d-%H%M).txt"

{
  echo "# Baseline $(date -u +%FT%TZ)"
  echo "# host: $(uname -srm)"
  echo "# uhd:  $(uhd_config_info --version)"
  echo "# img:  $img"
  echo "# sha256: $( (sha256sum "$img" 2>/dev/null || shasum -a 256 "$img") | cut -d' ' -f1)"
  echo "# transport: ${tune:-UHD defaults}  duration: ${duration}s"
  echo
  # name  rate    channels  master-clock
  while read -r name rate chans mcr; do
    echo "=== $name: rx_rate=$rate channels=$chans mcr=$mcr"
    "$bench" --args "$args,master_clock_rate=$mcr" \
      --rx_rate "$rate" --rx_channels "$chans" --duration "$duration" 2>&1 \
      | grep -E 'Num received samples|Num sequence errors \(Rx\)|Num dropped samples|Num overruns|Num timeouts|Num late|Testing receive rate|ERROR|Error' || true
    echo
  done <<'EOF'
1ch-30.72M  30.72e6  0    30.72e6
1ch-40M     40e6     0    40e6
1ch-56M     56e6     0    56e6
1ch-61.44M  61.44e6  0    61.44e6
2ch-15.36M  15.36e6  0,1  30.72e6
2ch-30.72M  30.72e6  0,1  30.72e6
EOF
} | tee "$out"

echo "Saved: $out"
