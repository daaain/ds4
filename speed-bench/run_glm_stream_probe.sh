#!/bin/zsh
# run_glm_stream_probe.sh TAG CTX_MAX [extra ds4-bench args...]
# One short GLM SSD-streaming sweep (2K..CTX_MAX) with memory sampled; env vars pass through.
set -u
tag=$1; ctxmax=$2; shift 2
cd "$(dirname "$0")/.."
export DS4_BENCH_SNAPSHOT_MAX_BYTES=4294967296
export DS4_METAL_STREAMING_EXPERT_HOTLIST_PROFILE=1
csv=speed-bench/m3_max_glm53f_q2_1003_${tag}.csv
log=speed-bench/m3_max_glm53f_q2_1003_${tag}.log
rm -f "$csv"
speed-bench/memsample.sh speed-bench/m3_max_1003_memory.csv glm_${tag} "$csv" &
mpid=$!
echo "=== glm $tag start $(date +%H:%M:%S) env: $(env | grep -E '^DS4_(METAL|GLM)_' | tr '\n' ' ')"
./ds4-bench -m gguf/GLM-5.3-Flash-Q2.gguf --ssd-streaming "$@" \
  --prompt-file speed-bench/promessi_sposi.txt \
  --ctx-start 2048 --ctx-max "$ctxmax" --step-incr 2048 --gen-tokens 128 \
  --csv "$csv" 2> "$log"
rc=$?
kill $mpid 2>/dev/null
echo "=== glm $tag exit $rc $(date +%H:%M:%S)"
