#!/bin/zsh
# queue_all.sh — rebuild every published M3 Max number on the current build + OS.
#
# The figures in docs/M3_MAX_DS4_VS_GLM.md and docs/M3_MAX_GLM_MTP.md were taken
# on upstream main @6289c51 under macOS 26.6.1. This machine is now on a fork
# build under macOS 27.0.1, so they are not comparable with anything measured
# tonight. Every run below writes *_1002_* so the originals stay intact.
#
# Runs sequentially, continues past failures, records the app load before each.
set -u
cd /Users/dain/workspace/ds4
DS4F=gguf/DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-0731.gguf
GLM=gguf/GLM-5.3-Flash-Q2.gguf
PROMPT=speed-bench/promessi_sposi.txt
MEM=speed-bench/m3_max_1002_memory.csv

# run NAME SNAPSHOT_GIB CTX_MAX GGUF [extra ds4-bench args...]
run() {
  local name=$1 snap=$2 ctxmax=$3 gguf=$4; shift 4
  local csv=speed-bench/m3_max_${name}.csv
  local log=speed-bench/m3_max_${name}.log
  rm -f "$csv"
  local apps=$(ps -Ao rss= | awk '{s+=$1} END {printf "%.1f", s/1048576}')
  echo "=== $name start $(date +%H:%M:%S)  ctx_max=$ctxmax snapshot=${snap}GiB apps=${apps}GiB args=$*"
  speed-bench/memsample.sh "$MEM" "$name" "$csv" &
  local mpid=$!
  DS4_BENCH_SNAPSHOT_MAX_BYTES=$(( snap * 1073741824 )) \
  ./ds4-bench -m "$gguf" --prompt-file "$PROMPT" \
    --ctx-start 2048 --ctx-max "$ctxmax" --step-incr 2048 --gen-tokens 128 \
    "$@" --csv "$csv" 2> "$log"
  local rc=$?
  kill $mpid 2>/dev/null
  local rows=0; [ -f "$csv" ] && rows=$(( $(wc -l < "$csv") - 1 ))
  echo "=== $name exit $rc $(date +%H:%M:%S) rows=$rows"
  [ $rc -ne 0 ] && { echo "--- tail of $log ---"; tail -15 "$log"; }
  sleep 25   # let mappings be released before the next model load
}

while pgrep -q -f run_ssd70.sh; do sleep 10; done
echo "=== ssd70 runner finished; queue starts $(date +%H:%M:%S)"
sleep 25

# 1-4: resident 2K-64K, two passes each, both models. The streaming baseline
#      and the doc's main comparison table in one go.
run ds4f_q2_1002_resident_pass1   4 65536  "$DS4F"
run ds4f_q2_1002_resident_pass2   4 65536  "$DS4F"
run glm53f_q2_1002_resident_pass1 4 65536  "$GLM"
run glm53f_q2_1002_resident_pass2 4 65536  "$GLM"

# 5-6: GLM embedded MTP, two passes (docs/M3_MAX_GLM_MTP.md main table).
run glm53f_q2_1002_mtp_pass1 4 65536 "$GLM" --mtp
run glm53f_q2_1002_mtp_pass2 4 65536 "$GLM" --mtp

# 7-9: MTP confidence margin, 2K-8K, one run each as published.
run glm53f_q2_1002_mtp_margin_default 4 8192 "$GLM" --mtp
run glm53f_q2_1002_mtp_margin_1       4 8192 "$GLM" --mtp --mtp-margin 1
run glm53f_q2_1002_mtp_margin_0       4 8192 "$GLM" --mtp --mtp-margin 0

# 10-11: 128K single pass each, 8 GiB snapshot budget. GLM peaked at 99.3 GB
#        pinned here in September on an otherwise idle machine, so this is the
#        run most likely to be refused or to page with VMs resident.
run ds4f_q2_1002_128k   8 131072 "$DS4F"
run glm53f_q2_1002_128k 8 131072 "$GLM"

echo "=== queue complete $(date +%H:%M:%S)"
