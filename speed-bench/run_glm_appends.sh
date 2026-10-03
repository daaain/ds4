#!/bin/zsh
# run_glm_appends.sh TAG BIN_DIR INCR STEPS [extra ds4-bench args...]
# GLM SSD-streaming short appends: a 2048-token prompt, then STEPS appends of
# INCR tokens (each a continued chunk), 32 generated tokens per step.
set -u
tag=$1; bindir=$2; incr=$3; steps=$4; shift 4
cd "$(dirname "$0")/.."
here=$PWD
day=${RUN_DAY:-$(date +%m%d)}   # file date tag; RUN_DAY=1003 reproduces old names
export DS4_BENCH_SNAPSHOT_MAX_BYTES=4294967296
csv=speed-bench/m3_max_glm53f_q2_${day}_${tag}.csv
log=speed-bench/m3_max_glm53f_q2_${day}_${tag}.log
rm -f "$csv"
echo "=== glm $tag start $(date +%H:%M:%S) bin=$bindir incr=$incr steps=$steps args: $*"
(cd "$bindir" && ./ds4-bench -m "$here/gguf/GLM-5.3-Flash-Q2.gguf" --ssd-streaming "$@" \
  --prompt-file "$here/speed-bench/promessi_sposi.txt" \
  --ctx-start 2048 --ctx-max $((2048 + incr * steps)) --step-incr "$incr" --gen-tokens 32 \
  --csv "$here/$csv") 2> "$log"
rc=$?
echo "=== glm $tag exit $rc $(date +%H:%M:%S)"
cat "$csv" 2>/dev/null
