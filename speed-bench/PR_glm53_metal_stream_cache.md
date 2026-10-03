# metal: stream GLM 5.3 Q2 through the expert cache, for decode and prefill

## Problem

GLM 5.3 Flash Q2 (`GLM-5.3-Flash-Q2.gguf`: routed IQ2_XXS gate/up, Q2_K down, eight experts per token) has no bounded SSD-streaming mode on Metal.

`glm_stream_selected_expert_cache_supported` refuses IQ2/Q2_K on Apple unless `DS4_N_EXPERT_USED == 6`, because the IQ2/Q2 selected-slot down kernel (`kernel_mul_mv_slots6_q2_K_sum6_f32`) sums exactly six experts. No layer counts as streamed, so:

- **Default (static decode map):** the decode map covers every routed tensor, i.e. the whole 89.88 GiB file. It ignores `--ssd-streaming-cache-experts`: a 62 GB request becomes a 9 GiB cache inside a 106 GiB plan.
- **Where that map does not fit (Macs under 128 GB), or with `DS4_METAL_DISABLE_STREAMING_STATIC_DECODE_MAP=1`:** the per-layer fallback stays within budget, but it maps each layer's full expert span every token, and the cache is budgeted but never filled. Decode is **0.58 tok/s** on a 128 GB Mac, where spare RAM caches much of the file. With 64 GB locked away (a simulated 64 GB Mac), it is **0.03 tok/s**: 32 tokens took about 18 minutes.

Related: #1171 / #1172 fix the same kind of bypass for Q2_K gate/up with Q4_K down. That one only needs a predicate change; this one needs kernels.

## Who this helps

On a 128 GB Mac with default flags nothing changes: the whole-file map still fits and is still chosen. The cache route is taken on an explicit `--ssd-streaming-cache-experts`, or **automatically wherever the whole-file map does not fit**, which is the case for 64 and 96 GB Macs. There it replaces the per-layer fallback (0.03 tok/s decode on a simulated 64 GB Mac).

## Change (five commits)

1. **Decode through the cache.** `kernel_mul_mv_addr_q2_K_f32` (`metal/moe.metal`) is a per-expert Q2_K down projection through the streaming address table, the Q2_K twin of `kernel_mul_mv_addr_iq2_xxs_f32`. The IQ2 address-table route takes a Q2_K down whenever the six-slot path does not apply; with eight experts the existing `moe_sum_experts` reduces the rows. `ds4_engine_fit_glm_streaming_budget` picks the route once per engine. Metal TP refuses an engine on this route.
2. **Full-layer reads for continued chunks.** Continued prefill chunks of GLM 5.3 skipped the full-layer `pread` prepare so typed Flash layouts can reuse cached experts. This layout had no such route, so its layers were demand-faulted from the mmap at about 1.9 GB/s. They now use the prepare (about 5.3 GB/s, waits hidden).
3. **Seed the cache from the final full-layer chunk only.** The per-layer seed syncs and copies, and only warms the decode after the final chunk. Layouts whose continued chunks do not read full layers keep seeding from the first chunk.
4. **Short chunks through the cache.** Chunks under 256 tokens (chat appends, prompt tails) do not read full layers. IQ2/IQ2 already served them from the cache; with a Q2_K down they faulted whole layers in, since 128 tokens with eight experts touch nearly every expert of a layer. Adds Q2_K instantiations of the cached (`EXPERT_ADDRESSES`) `mul_mm_id` kernels and accepts a Q2_K down in the cached batch route and its decode-only map. The arithmetic is the resident kernels' with only the source pointer changed.
5. **Large chunks through the cache, misses read ahead.** A chunk of 128 or more tokens selects nearly all of a layer's 256 experts, so its misses are the uncached experts, known before routing. Such chunks take the cached batch route, and a page-in job reads each layer's uncached experts one layer ahead on the existing read threads (new `ds4_gpu_stream_expert_cache_layer_cached()` lists them without touching recency or hit counts). While the cache holds under a quarter of all routed experts, a chunk reads full layers and seeds instead, because copying almost every expert in costs more than it saves. `DS4_METAL_DISABLE_GLM_STREAMING_PREFILL_CACHE=1` restores full-layer reads.

DeepSeek V4 Flash (the same layout, six experts) is unchanged: `use_iq2_selected_slots` still wins at six, and the IQ2/IQ2 cached route keeps its 256-token limit.

## Validation

All on an M3 Max 128 GiB. Identical runs drift by up to 15% under sustained SSD reads, so the A/B pairs below were interleaved. "Simulated 64 GB Mac" means `--simulate-used-memory 64GB` (64 GB mlocked before load, so the page cache cannot hold the file) and a 28 GB cache, roughly what a 64 GB Mac auto-sizes.

**Decode and the 2K-step sweep** (`--ssd-streaming-cache-experts 62GB`, 2048-token steps, 128 generated tokens):

| GLM 5.3 Flash Q2 | planned | prefill t/s 2K / 4K / 6K / 8K | decode t/s |
|---|---:|---|---:|
| before: static map, budget ignored | 106 GiB | 151 / 141–142 | 15.6–16.1 |
| before: static map disabled (per-layer, cache empty) | 73 GiB | 162 / — | **0.58** |
| commit 1 | 73 GiB | 118 / 43–45 | 11.0–13.1 |
| commits 1–2 | 73 GiB | 112 / 106 / 80 / — | 10.8–13.8 |
| **all five** | **73 GiB** | **124 / 132 / 138 / 122** | **11.2–13.8** |
| resident | — | 178 / 159–162 | 17.1–17.7 |

**Default flags on a 128 GB Mac** keep the whole-file map, and every prefill decision there reduces to upstream's: continued chunks don't re-read full layers, no seed is deferred, and the Q2_K batch is forced off the cache routes unless the engine chose the cache route (`glm_stream_selected_expert_cache_supported`). An interleaved A/B against `0aaea5a` stayed within run-to-run drift.

**Simulated 64 GB Mac, main against this PR** (28 GB cache, 2048-token steps, 32 generated tokens; main forced onto the per-layer fallback with `DS4_METAL_DISABLE_STREAMING_STATIC_DECODE_MAP=1`, since its budget sizing sees the physical 128 GB):

| | 2K prefill t/s | 2K decode t/s (steady) | 2K first token | 4K prefill t/s | 4K decode t/s (steady) |
|---|---:|---|---:|---:|---|
| main, one run | 122.9 | **0.03** (0.03) | 32.7 s | not run (about 20 min per step) | — |
| this PR, two runs | 104.1, 110.0 | **5.9, 6.4** (7.3–7.4) | 0.82–1.25 s | 125.3, 128.2 | 8.7 (9.0) |

On the cold first chunk both read full layers, but this PR also seeds the cache from it so that decode starts warm, which costs 10–15% of that chunk's prefill.

**One 16K-token prompt, then 128 tokens** (interleaved, two runs each, commit 5 toggled with its env var):

| | prefill t/s | decode t/s | first token |
|---|---:|---:|---:|
| 62 GB cache, commits 1–4 | 114–124 | 9.5–9.6 | 0.84–0.89 s |
| 62 GB cache, all five | 111–112 | 12.1–12.4 | 0.16–0.17 s |
| simulated 64 GB Mac, commits 1–4 | 92–97 | 6.1–6.3 | 1.2–1.4 s |
| simulated 64 GB Mac, all five | 96–98 | 6.6 | 0.35–0.38 s |

Commit 5 leaves prefill level, because the cache inserts are still synchronous per layer. What it buys is the warm cache that decode starts from. Commit 3 alone took this prompt from 91 to 114 tok/s.

**128-token appends after a 2K prompt** (62 GB cache, 32 generated tokens each):

| | prefill t/s | time per append | decode t/s |
|---|---:|---:|---:|
| commits 1–3 | 3.4–3.6 | ~36 s | 7.4–8.0 |
| all five | 36–51 | 2.5–3.6 s | 12.7–13.5 |

**Correctness**
- `make test-metal-iq2-q2k-stream-cache`: decode at six and eight experts; prefill batches of 4, 31, 64, 200 and 512 tokens at eight experts (tiny pair, `mul_mv_id` and `mul_mm_id` kernels). Each case takes a resident reference, then zeroes the mapped weights and streams with only the file holding real weights. It also checks that the cached-expert listing matches the batch's selection.
- Greedy parity, streamed vs resident, byte-identical (`cmp`) over 96 tokens, `--temp 0 --nothink`, `--ssd-streaming-cache-experts 62GB`. Prompts: 2183 tokens (a full chunk plus a 135-token tail), and 5477 tokens (cold, warm and short chunks).
- `make test` and `make test-metal-moe-prefill` pass, with `ds4flash.gguf` = DeepSeek V4 Flash IQ2XXS-w2Q2K.

Not run: a real 64 or 96 GB Mac (simulated only), CUDA/ROCm (untouched), and distributed/TP hardware (the TP guard is a refusal).

## Possible follow-up

Making the large-chunk cache inserts asynchronous should lift prefill toward compute-bound. That means staging misses into a transient buffer and building the address table without a per-layer readback, so no GPU drain per layer. It's a larger change (an estimated 700+ lines), best as a separate PR.
