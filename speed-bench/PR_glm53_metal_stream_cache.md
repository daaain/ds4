# metal: stream GLM 5.3 Q2 experts through the expert cache

## Problem

GLM 5.3 Flash Q2 (`GLM-5.3-Flash-Q2.gguf`: routed IQ2_XXS gate/up, Q2_K down, eight experts per token) has no bounded SSD-streaming mode on Metal.

`glm_stream_selected_expert_cache_supported` refuses IQ2/Q2_K on Apple unless `DS4_N_EXPERT_USED == 6`, because the IQ2/Q2 selected-slot down kernel (`kernel_mul_mv_slots6_q2_K_sum6_f32`) sums exactly six experts. No layer counts as streamed, so:

- **Default (static decode map):** the decode map covers every routed tensor, i.e. the whole 89.88 GiB file. It ignores `--ssd-streaming-cache-experts`: a 62 GB request becomes a 9 GiB cache inside a 106 GiB plan.
- **`DS4_METAL_DISABLE_STREAMING_STATIC_DECODE_MAP=1`:** this fallback stays within budget, but it maps each layer's full expert span every token. The 58 GiB cache is budgeted and never filled: about 14 GiB wired, **0.58 tok/s**.

Related: #1171 / #1172 fix the same kind of bypass for Q2_K gate/up with Q4_K down. That one only needs a predicate change; this one needs a kernel.

## Change

- `metal/moe.metal`: `kernel_mul_mv_addr_q2_K_f32` is a per-expert Q2_K down projection through the streaming address table. It is the Q2_K twin of `kernel_mul_mv_addr_iq2_xxs_f32` and wraps the existing `kernel_mul_mv_q2_K_f32_impl`.
- `ds4_metal.m`: the IQ2 address-table route (`use_iq2_stream_addr_table`, already up to eight experts for IQ2/IQ2) now also takes a Q2_K down whenever the six-slot path does not apply. With eight experts `direct_down_sum` is false, so the existing `moe_sum_experts` reduces the per-expert rows, the same reduction the resident eight-expert path uses.
- `ds4.c`: on Metal, IQ2/Q2_K with a count other than six is supported via the address table (`DS4_METAL_DISABLE_IQ2_STREAM_ADDR_TABLE` still opts out). The expert-cache seed gate also accepts a Q2_K down for GLM, so an explicit preload or hotlist can seed it.

- Policy: when the whole-file map fits it is still faster, so `ds4_engine_fit_glm_streaming_budget` picks the cache route once per engine, either on an explicit `--ssd-streaming-cache-experts` or when that map does not fit. Default behaviour on large machines is unchanged.
- Metal TP: `ds4_engine_tp_bind` refuses an engine that has chosen this route. The Metal route also stays off wherever `direct_down_sum` applies, which is the TP eight-expert case.

DeepSeek V4 Flash (the same layout, six experts) is unchanged: `use_iq2_selected_slots` still wins at six.

## Validation

- New `make test-metal-iq2-q2k-stream-cache` covers IQ2_XXS/Q2_K at six and eight experts. Each case takes a resident reference, then zeroes the mapped weights and streams with only the file holding real weights. Each runs cold, all-hit and half-changed. Selected-path profile at eight: `iq2/q2-addr`, hits/misses 0/8, 8/0, 4/4. At six it is still `iq2/q2`.
- Real model, M3 Max 128 GiB, `--ssd-streaming --ssd-streaming-cache-experts 62GB`, 2K–8K, 128 generated tokens:

  | GLM 5.3 Flash Q2, M3 Max 128 GiB | planned | wired | prefill t/s (2K / 4K–8K) | decode t/s (2K / 4K–8K) |
  |---|---:|---:|---:|---:|
  | before: `--ssd-streaming-cache-experts 62GB` (static map, budget ignored) | 106 GiB | up to 97 GiB | 151 / 141–142 | 15.6 / 15.8–16.1 |
  | before: same, static map disabled (per-layer, cache empty) | 73 GiB | ~14 GiB | 162 / — | **0.58** / — |
  | **after: `--ssd-streaming-cache-experts 62GB`** | **73 GiB** | 66–74 GiB | 118 / 43–45 | **11.0 / 12.5–13.1** |
  | after: default flags | 106 GiB (unchanged) | — | unchanged | unchanged |
  | resident | — | — | 178 / 159–162 | 17.1 / 17.7 |

  Decode runs from the bounded cache, about 26–30% below resident in steady state. Prefill is slower than with the whole-file map: Metal GLM streaming prefill still maps full layers (the existing `glm_graph_stream_prefill_expert_addr_supported` covers only IQ2/IQ2/IQ2 below 256 tokens). Once the cache holds the budget, those reads come from the SSD rather than the page cache. A batch Q2_K address kernel for prefill would be a natural follow-up; it is not in this PR.

- Greedy parity, streamed vs resident: byte-identical (`cmp`) over 96 tokens, `--temp 0 --nothink`, resident vs `--ssd-streaming --ssd-streaming-cache-experts 62GB`.
- `make test` passes, with `ds4flash.gguf` = DeepSeek V4 Flash IQ2XXS-w2Q2K, the same layout at six experts.

Not run: CUDA/ROCm (untouched: their IQ2/Q2_K predicate had no six-only restriction) and distributed/TP hardware. The TP guard is a refusal, so it was not exercised on two machines.
