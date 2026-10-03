#!/bin/zsh
# run_ssd70.sh MODEL_TAG GGUF
# Two back-to-back 2K-32K sweeps with a 62 GiB expert cache (~70 GiB resident weights), memory sampled throughout.
set -u
tag=$1; gguf=$2
cd "$(dirname "$0")/.."
export DS4_BENCH_SNAPSHOT_MAX_BYTES=4294967296
for pass in 1 2; do
  csv=speed-bench/m3_max_${tag}_q2_ssd70_pass${pass}.csv
  log=speed-bench/m3_max_${tag}_q2_ssd70_pass${pass}.log
  rm -f "$csv"
  speed-bench/memsample.sh speed-bench/m3_max_ssd70_memory.csv ${tag}_ssd70_pass${pass} "$csv" &
  mpid=$!
  echo "=== $tag pass $pass start $(date +%H:%M:%S)"
  ./ds4-bench -m "$gguf" --ssd-streaming --ssd-streaming-cache-experts 62GB \
    --prompt-file speed-bench/promessi_sposi.txt \
    --ctx-start 2048 --ctx-max 32768 --step-incr 2048 --gen-tokens 128 \
    --csv "$csv" 2> "$log"
  rc=$?
  kill $mpid 2>/dev/null
  echo "=== $tag pass $pass exit $rc $(date +%H:%M:%S)"
  [ $rc -ne 0 ] && { tail -20 "$log"; exit $rc; }
done
