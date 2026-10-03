#!/bin/zsh
# run_resident.sh MODEL_TAG GGUF
# Two back-to-back 2K-32K sweeps with the model FULLY RESIDENT (no --ssd-streaming),
# so the streaming runs in m3_max_*_ssd70_* have a same-build, same-OS baseline.
# Memory sampled throughout into m3_max_resident1002_memory.csv.
set -u
tag=$1; gguf=$2
cd "$(dirname "$0")/.."
export DS4_BENCH_SNAPSHOT_MAX_BYTES=4294967296
for pass in 1 2; do
  csv=speed-bench/m3_max_${tag}_q2_resident1002_pass${pass}.csv
  log=speed-bench/m3_max_${tag}_q2_resident1002_pass${pass}.log
  rm -f "$csv"
  speed-bench/memsample.sh speed-bench/m3_max_resident1002_memory.csv ${tag}_resident_pass${pass} "$csv" &
  mpid=$!
  echo "=== $tag resident pass $pass start $(date +%H:%M:%S)"
  ./ds4-bench -m "$gguf" \
    --prompt-file speed-bench/promessi_sposi.txt \
    --ctx-start 2048 --ctx-max 32768 --step-incr 2048 --gen-tokens 128 \
    --csv "$csv" 2> "$log"
  rc=$?
  kill $mpid 2>/dev/null
  echo "=== $tag resident pass $pass exit $rc $(date +%H:%M:%S)"
  [ $rc -ne 0 ] && { tail -25 "$log"; exit $rc; }
done
