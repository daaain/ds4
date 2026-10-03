#!/bin/zsh
# run_glm_longprompt.sh TAG BIN_DIR CTX [extra ds4-bench args...]
# One GLM SSD-streaming prefill of CTX tokens (so CTX/2048 chunks, all but the
# last continued) followed by 128 generated tokens. Runs from BIN_DIR: Metal
# sources are loaded from the working directory.
set -u
tag=$1; bindir=$2; ctx=$3; shift 3
cd "$(dirname "$0")/.."
here=$PWD
day=${RUN_DAY:-$(date +%m%d)}   # file date tag; RUN_DAY=1003 reproduces old names
export DS4_BENCH_SNAPSHOT_MAX_BYTES=4294967296
csv=speed-bench/m3_max_glm53f_q2_${day}_${tag}.csv
log=speed-bench/m3_max_glm53f_q2_${day}_${tag}.log
rm -f "$csv"
echo "=== glm $tag start $(date +%H:%M:%S) bin=$bindir ctx=$ctx args: $*"
(cd "$bindir" && ./ds4-bench -m "$here/gguf/GLM-5.3-Flash-Q2.gguf" --ssd-streaming "$@" \
  --prompt-file "$here/speed-bench/promessi_sposi.txt" \
  --ctx-start "$ctx" --ctx-max "$ctx" --gen-tokens 128 \
  --csv "$here/$csv") 2> "$log"
rc=$?
echo "=== glm $tag exit $rc $(date +%H:%M:%S)"
cat "$csv" 2>/dev/null
