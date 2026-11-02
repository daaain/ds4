#!/bin/zsh
# replot.sh — regenerate every SVG the M3 Max docs embed, from the 2026-10-02 runs.
#
# plot_comparison.py always writes compare_{prefill,decode,kvcache}.svg into
# --out-dir, so each chart set is generated into a temp dir and renamed to the
# name the docs reference.
set -eu
cd "$(dirname "$0")"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

plot() {          # plot OUT_PREFIX [args...]
  local prefix=$1; shift
  # Skip the set if any CSV it needs is missing, so this can be re-run while
  # the measurement queue is still working through its list.
  local a missing=0
  for a in "$@"; do
    case "$a" in
      *=*.csv) [ -f "${a#*=}" ] || { echo "skip ${prefix}: missing ${a#*=}"; missing=1 };;
    esac
  done
  [ $missing -eq 1 ] && return 0
  rm -f "$TMP"/compare_prefill.svg "$TMP"/compare_decode.svg "$TMP"/compare_kvcache.svg 2>/dev/null || true
  # Writing speed is the steady rate, matching the tables in the docs: the
  # overall rate folds in the first-token wait, which under SSD streaming is
  # over a second and would swamp the comparison.
  python3 plot_comparison.py --out-dir "$TMP" --machine "MacBook Pro M3 Max" \
    --decode-column gen_steady_tps "$@"
  # Only the long-context set publishes a KV-cache chart: the cache depends on
  # the model and the context length, not on where the weights live, so the
  # other sets would just redraw the same two lines over a shorter range.
  local measures="prefill decode"
  [ "${KV:-0}" = 1 ] && measures="prefill decode kvcache"
  for m in ${=measures}; do
    [ -f "$TMP/compare_$m.svg" ] && cp "$TMP/compare_$m.svg" "${prefix}_$m.svg" && echo "wrote ${prefix}_$m.svg"
  done
}

# 1. The main resident comparison, 2K-64K, pass 2 of each model.
plot m3_max \
  --run "DeepSeek V4 Flash=m3_max_ds4f_q2_1002_resident_pass2.csv" \
  --run "GLM 5.3 Flash=m3_max_glm53f_q2_1002_resident_pass2.csv"

# 2. Long context, single pass each. Charts start at 48K because below that a
#    24-minute sweep is still measuring the machine warming up.
KV=1 plot m3_max_128k --min-ctx 49152 \
  --run "DeepSeek V4 Flash=m3_max_ds4f_q2_1002_128k.csv" \
  --run "GLM 5.3 Flash=m3_max_glm53f_q2_1002_128k.csv"

# 3. GLM with and without the embedded MTP block.
plot m3_max_mtp \
  --run "GLM 5.3 Flash=m3_max_glm53f_q2_1002_resident_pass2.csv" \
  --run "GLM 5.3 Flash + MTP=m3_max_glm53f_q2_1002_mtp_pass2.csv"

# 4. New: resident (2K-64K) vs 62 GiB SSD streaming (2K-32K), both models.
#    Colour is the model, dashes mean streamed. GLM streamed is the fixed build
#    from fix/glm53-metal-iq2-q2k-stream-cache, pass 2 of two back to back.
#    Upstream GLM (m3_max_glm53f_q2_ssd70_pass2.csv) is left out: it ignores
#    the budget and maps the whole file, so it is not streaming.
plot m3_max_streaming \
  --run "DeepSeek resident=m3_max_ds4f_q2_1002_resident_pass2.csv" \
  --run "GLM resident=m3_max_glm53f_q2_1002_resident_pass2.csv" \
  --run "DeepSeek streamed=m3_max_ds4f_q2_ssd70_apps24_pass2.csv" \
  --run "GLM streamed (fix)=m3_max_glm53f_q2_1004_fix_32k_p2.csv" \
  --like "DeepSeek streamed=DeepSeek resident" \
  --like "GLM streamed (fix)=GLM resident"

echo "done"
