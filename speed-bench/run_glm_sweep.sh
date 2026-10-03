#!/bin/zsh
# run_glm_sweep.sh TAG BIN_DIR CTX_MAX GEN [extra ds4-bench args...]
# GLM SSD-streaming sweep in 2048-token steps with GEN generated tokens per
# step. Runs from BIN_DIR: Metal sources are loaded from the working directory.
set -u
tag=$1; bindir=$2; ctxmax=$3; gen=$4; shift 4
cd "$(dirname "$0")/.."
here=$PWD
day=${RUN_DAY:-$(date +%m%d)}   # file date tag; RUN_DAY=1003 reproduces old names
export DS4_BENCH_SNAPSHOT_MAX_BYTES=4294967296
csv=speed-bench/m3_max_glm53f_q2_${day}_${tag}.csv
log=speed-bench/m3_max_glm53f_q2_${day}_${tag}.log
rm -f "$csv"
echo "=== glm $tag start $(date +%H:%M:%S) bin=$bindir args: $*"
(cd "$bindir" && ./ds4-bench -m "$here/gguf/GLM-5.3-Flash-Q2.gguf" --ssd-streaming "$@" \
  --prompt-file "$here/speed-bench/promessi_sposi.txt" \
  --ctx-start 2048 --ctx-max "$ctxmax" --step-incr 2048 --gen-tokens "$gen" \
  --csv "$here/$csv") 2> "$log"
rc=$?
echo "=== glm $tag exit $rc $(date +%H:%M:%S)"
tail -n +2 "$csv" 2>/dev/null | cut -d, -f1,3,5,6,8
