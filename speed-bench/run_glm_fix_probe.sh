#!/bin/zsh
# run_glm_fix_probe.sh TAG BIN_DIR CTX_MAX [extra ds4-bench args...]
# Short GLM SSD-streaming sweep using the ds4-bench in BIN_DIR, memory sampled.
# Runs from BIN_DIR: Metal sources are loaded from the working directory.
set -u
tag=$1; bindir=$2; ctxmax=$3; shift 3
cd "$(dirname "$0")/.."
here=$PWD
export DS4_BENCH_SNAPSHOT_MAX_BYTES=4294967296
csv=speed-bench/m3_max_glm53f_q2_1003_${tag}.csv
log=speed-bench/m3_max_glm53f_q2_1003_${tag}.log
rm -f "$csv"
speed-bench/memsample.sh speed-bench/m3_max_1003_memory.csv glm_${tag} "$csv" &
mpid=$!
echo "=== glm $tag start $(date +%H:%M:%S) bin=$bindir args: $*"
(cd "$bindir" && ./ds4-bench -m "$here/gguf/GLM-5.3-Flash-Q2.gguf" --ssd-streaming "$@" \
  --prompt-file "$here/speed-bench/promessi_sposi.txt" \
  --ctx-start 2048 --ctx-max "$ctxmax" --step-incr 2048 --gen-tokens 128 \
  --csv "$here/$csv") 2> "$log"
rc=$?
kill $mpid 2>/dev/null
echo "=== glm $tag exit $rc $(date +%H:%M:%S)"
