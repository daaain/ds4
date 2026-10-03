#!/bin/zsh
# memsample.sh OUT.csv RUN_TAG FRONTIER_CSV
# Sample vm_stat every 15s, tagged with the last frontier the bench has written to FRONTIER_CSV.
out=$1; tag=$2; fcsv=$3
[ -f "$out" ] || echo "ts,run,frontier,wired_gb,free_gb,anon_gb,file_gb,compressor_gb,swap_used_mb" > "$out"
while true; do
  f=$( [ -f "$fcsv" ] && tail -1 "$fcsv" | cut -d, -f1 | grep -E '^[0-9]+$' || echo 0 )
  vm_stat | awk -v ts="$(date +%H:%M:%S)" -v tag="$tag" -v f="$f" -v sw="$(sysctl -n vm.swapusage | sed -E 's/.*used = ([0-9.]+)M.*/\1/')" '
    /Pages wired down/ {w=$4} /Pages free/ {fr=$3} /Anonymous pages/ {a=$3} /File-backed pages/ {fb=$3} /occupied by compressor/ {c=$5}
    END { g=16384/1073741824; printf "%s,%s,%s,%.2f,%.2f,%.2f,%.2f,%.2f,%s\n", ts, tag, f, w*g, fr*g, a*g, fb*g, c*g, sw }' >> "$out"
  sleep 15
done
