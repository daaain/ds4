# M3 Max SSD-streaming "70 GiB resident" sweep — status 2026-10-02

Goal: compare DeepSeek V4 Flash (Q2) and GLM 5.3 Flash (Q2) with the same
memory budget — `--ssd-streaming --ssd-streaming-cache-experts 62GB`, so
~8 GiB static weights + ~58 GiB expert cache ≈ 70 GiB resident — over
2K–32K context, two back-to-back passes to see the cache warm across a
fresh process. Runner: `run_ssd70.sh`, memory sampled every 15 s by
`memsample.sh` into `m3_max_ssd70_memory.csv`.

Machine: MacBook Pro M3 Max, 128 GiB, macOS 25.6.0, ~54 GiB of other apps
resident at launch (active + inactive pages).

## Power

2026-09-15: three PMU under-voltage resets (`rst uv, vddmain_uvlo`) within
1–3 min of launch on a 96 W adapter. 2026-09-16: identical sweeps ran clean
on Apple's 140 W MagSafe adapter — DS4F 13 min, GLM 13 min back to back —
and the battery *charged* 76 → 80 % during the load.

2026-10-02: **the fault did not reproduce on a 65 W adapter.** The DS4F sweep
ran both passes to completion, 22:20:09 → 22:33:01 (12 m 52 s), exit 0, with
no reset — on an adapter *smaller* than the one that failed three times for
three minutes. Battery stayed at 100 % "charged" throughout; no thermal or
performance warning was recorded.

So adapter wattage is not the variable. Two things also differed from
September and are the remaining candidates:

- **Concurrent app load.** 2026-09-15/16 had ~54 GiB of other apps resident,
  so macOS was compressing tens of GiB while the GPU and SSD ran flat out.
  2026-10-02 had 24 GiB and the compressor peaked at 4.9 GiB. If the trigger
  is a whole-system current transient rather than the GPU alone, this
  difference is larger than the adapter difference.
- **The machine itself.** Darwin 27.0.0 on 2026-10-02 vs 25.6.0 in September.
  A firmware or power-management change could have fixed throttling that was
  previously failing to engage.

Cheap next test, if it matters: reopen the apps to ~54 GiB and rerun on this
same 65 W adapter. A reset there means the trigger is concurrent memory
pressure plus inference, reproducible on demand. No reset means something
about the machine has changed since September.

Do not treat "Wattage = 140W" as a precondition any more; it was a
correlation with n=1 on each side.

## DS4F — done, valid, and reproduced

`m3_max_ds4f_q2_ssd70_pass{1,2}.csv` (2026-10-02, 65 W) and
`m3_max_ds4f_q2_ssd70_0916_pass{1,2}.csv` (2026-09-16, 140 W). Both planned
exactly as intended:

    resident model 8.20 GiB + expert cache 58.62 GiB + prefill reserve 3.38 GiB
    = 71.05 GiB planned

Prefill / steady-decode t/s, both runs, both passes:

| ctx   |      65 W p1 |      65 W p2 |     140 W p1 |     140 W p2 |
|------:|-------------:|-------------:|-------------:|-------------:|
|  2048 |  155.3/15.23 |  174.7/13.85 |  156.9/15.06 |  174.3/13.56 |
|  8192 |  152.2/19.16 |  142.9/16.93 |  139.1/19.22 |  139.0/17.14 |
| 16384 |  133.0/13.21 |  142.4/16.79 |  135.6/18.88 |  140.0/17.00 |
| 18432 |  108.6/11.48 |  139.5/16.79 |  137.4/17.44 |  140.0/16.86 |
| 24576 |  130.0/15.36 |  139.1/17.01 |  123.3/13.78 |  138.4/16.26 |
| 32768 |  134.6/16.53 |  131.2/16.99 |  133.2/16.09 |  132.8/16.28 |

**Quote pass 2.** Mean over 16K–32K, pass 2: 65 W gives 137.3 / 16.87,
140 W gives 137.0 / 16.42 — identical within noise, and if anything the
65 W run is marginally faster. Sustained throughput is therefore unaffected
by adapter wattage on this machine, which also rules out the "the SMC
clamps harder on a small adapter" explanation for the non-reset.

Each pass 1 has a mid-sweep dip that pass 2 does not: 16–20K on 2026-10-02
(down to 108.6/11.48), 20–26K on 2026-09-16. It moves between runs and
disappears once the cache is warm, so it is expert-cache churn, not a
property of the context length. Tonight's dip was *not* memory pressure —
compressor stayed at 3.4 GiB through it, free 0.10 GiB, swap 0.19 MB.
September's was (free → 0.05, compressor → 11.7 GiB, swap 145 MB), so the
two dips have different causes and only September's is memory-related.

Decode peaks ~19 t/s at 8–12K in pass 1 and settles to ~17 t/s; pass 2 is
flat at ~16.9 from 8K to 32K with no peak, so the peak is a cold-cache
artefact rather than an attention-cost effect as previously supposed.

Memory, 2026-10-02 run: wired peak 77.9 GiB, free low 0.08 GiB, compressor
peak 4.9 GiB, swap peak 0.19 MB. No paging at any point.

## GLM 5.3F — ran, but NOT the intended regime

`m3_max_glm53f_q2_ssd70_staticmap_pass{1,2}.csv` (renamed 2026-10-02 to
stop the runner overwriting them). The same flags produced a completely
different plan:

    GLM SSD streaming full resident layers: 0 (auto selected 0 layers)
    GLM SSD streaming request adjusted to fit memory: cache 8829 -> 1363 experts
    GLM SSD streaming decode map: global 89.87 GiB (87.75 GiB beyond the active layer window)
    resident model 89.87 GiB + expert cache 8.98 GiB + prefill reserve 3.80 GiB
    = 105.99 GiB planned

Cause: on Metal `metal_graph_stream_decode_static_map_enabled()`
(`ds4.c:19739`) returns `true` unconditionally, so the GLM streaming path
first tries a *global static decode map* — the entire 96 GB expert set
mmapped as resident — and only falls back to per-layer streaming if it
"doesn't fit" (`ds4.c:68440–68465`). The fit check is against total RAM,
so it passes, and the 62 GB expert cache is then shrunk to 9 GiB to make
room. DS4F has no equivalent path and honours the cache size as given.

What the memory samples show: wired memory flapping between ~24 GiB and
~94–97 GiB as the kernel wires the 90 GiB map, gives up, and lets it
page. In pass 1 the map stayed wired from 4K to ~16K (fully resident
decode → 170 / 19.5 t/s, the best numbers of the day), then got unwired
at ~18K and fell to ~125 / 14. In pass 2 it flapped throughout and the
run was flat at ~134 / 15.

| ctx   | p1 prefill | p1 gen | p2 prefill | p2 gen |
|------:|-----------:|-------:|-----------:|-------:|
|  2048 |      136.8 |   19.6 |      140.7 |   14.6 |
|  8192 |      170.5 |   19.5 |      134.4 |   14.9 |
| 16384 |      158.7 |   18.0 |      133.9 |   15.2 |
| 20480 |      138.3 |   15.0 |      134.5 |   15.4 |
| 24576 |      123.2 |   13.9 |      136.4 |   15.4 |
| 32768 |      127.1 |   14.4 |      133.7 |   15.2 |

These are a valid "GLM default streaming on a 128 GiB machine" datapoint,
not the 70 GiB like-for-like. Do not put them on the same chart as the
DS4F rows above without saying so.

### The per-layer "fix" is not usable (2026-10-02)

Rerunning with `DS4_METAL_DISABLE_STREAMING_STATIC_DECODE_MAP=1` does
produce the intended regime — log says `decode map: per-layer fallback`,
cache honoured at 62.00 GiB, 73.58 GiB planned — but it is catastrophically
slow. One frontier was measured before the run was stopped:

| ctx  | prefill | gen  | steady |
|-----:|--------:|-----:|-------:|
| 2048 |   140.5 | 1.08 |   1.09 |

That is **~18× slower decode** than the static map at the same frontier
(19.6 t/s), and 15× slower than DS4F under the same 62 GB budget. Partial
output in `m3_max_glm53f_q2_ssd70_perlayer_partial.{csv,log}`.

This reframes the open questions below. The global static decode map is not
an oversight that overrides the user's cache budget by accident — on Metal
it appears to be load-bearing for GLM decode, and the per-layer path is not
a viable alternative at this budget. The honest conclusion may be that **GLM
5.3F has no usable 70 GiB-resident configuration on this machine**, not that
the earlier measurement was taken wrongly. One frontier is thin evidence for
that claim; a full pass at 2K–8K would settle it cheaply (it would take
~20 min at 1 t/s, so cap `--ctx-max`).

## To resume

DS4F is done and reproduced. GLM is the open end, and the question has
changed: not "rerun it properly" but **"does GLM have any usable
configuration at a 70 GiB budget?"** The per-layer path answers no at 2K;
confirm with a short sweep before concluding:

    DS4_METAL_DISABLE_STREAMING_STATIC_DECODE_MAP=1 \
      speed-bench/run_ssd70.sh glm53f gguf/GLM-5.3-Flash-Q2.gguf

— but edit `--ctx-max` down to 8192 first, or a pass at ~1 t/s takes an
hour. Worth trying instead: a larger budget (`--ssd-streaming-cache-experts
80GB`) to find where GLM's per-layer path becomes usable, which would give
the comparison a "GLM needs N GiB to match DS4F at 70" shape rather than a
missing row.

The runner does `rm -f "$csv"`, so rename any CSVs worth keeping before
relaunching — the September static-map and 140 W DS4F runs are already
renamed out of its path.

Open questions, revised by the per-layer measurement above:

- Should the static-map fit check consider free memory rather than total?
  As it stands, on a 128 GiB machine with 54 GiB of apps open it commits
  to a 106 GiB plan that the kernel then can't keep wired — wired memory
  flaps between 24 and 97 GiB for the whole run. Given how slow the
  fallback is, the fix is probably not "fall back sooner" but "size the
  map to what will stay wired".
- Is "static map wins over an explicit `--ssd-streaming-cache-experts`"
  the intended precedence? A user asking for a 62 GB cache probably
  doesn't expect it to become 9 GB silently — the adjustment is logged,
  but only on stderr. Arguably the right behaviour is to refuse: if the
  only configuration that performs needs 106 GiB, say so rather than
  quietly delivering a 9 GiB cache.
- Why is GLM's per-layer decode ~18× slower than its static map, when
  DS4F's per-layer path runs at 17 t/s under the same budget? GLM has 45
  KV layers with a recurrent mechanism on most of them; if that forces a
  wider per-token expert working set, the cache may be thrashing rather
  than missing. The streaming hit-rate counters would show this — they
  are logged only under a verbosity flag that these runs did not set.

## Files

| File | What it is |
|---|---|
| `m3_max_ds4f_q2_ssd70_pass{1,2}.csv` | DS4F, 65 W, 2026-10-02 — current |
| `m3_max_ds4f_q2_ssd70_0916_pass{1,2}.csv` | DS4F, 140 W, 2026-09-16 |
| `m3_max_glm53f_q2_ssd70_staticmap_pass{1,2}.csv` | GLM default static map, 2026-09-16 (106 GiB plan) |
| `m3_max_glm53f_q2_ssd70_perlayer_partial.csv` | GLM per-layer, 2026-10-02, one frontier |
| `m3_max_ssd70_memory.csv` | memory samples, all runs, tagged by pass |
| `m3_max_ssd70_memory_upto_0916.csv` | backup of the above before the 2026-10-02 runs |
| `run_ssd70.sh`, `memsample.sh` | the harness |

Notes on the memory CSV: it also holds three `ds4f_ssd70_pass1` rows from
the aborted 2026-09-15 attempt (09:14–09:15), and the 2026-10-02 rows share
pass tags with the 2026-09-16 ones — filter by time, not tag alone, if
charting. All of the above is still untracked in git.
