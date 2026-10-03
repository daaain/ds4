#!/bin/zsh
# Wait for any in-flight ssd70 runner, then run both resident sweeps back to back.
cd /Users/dain/workspace/ds4
while pgrep -q -f run_ssd70.sh; do sleep 10; done
echo "=== ssd70 runner finished, starting resident sweeps $(date +%H:%M:%S)"
sleep 20   # let the streaming process release its mappings
speed-bench/run_resident.sh ds4f gguf/DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-0731.gguf
echo "=== ds4f resident done $(date +%H:%M:%S)"
sleep 20
speed-bench/run_resident.sh glm53f gguf/GLM-5.3-Flash-Q2.gguf
echo "=== glm53f resident done $(date +%H:%M:%S)"
