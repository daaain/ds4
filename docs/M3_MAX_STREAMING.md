# Keeping your RAM back: SSD streaming on a MacBook Pro M3 Max

[Models larger than RAM](SSD_STREAMING.md) | [Model comparison](M3_MAX_DS4_VS_GLM.md) | [README](../README.md)

Both DeepSeek V4 Flash and GLM 5.3 Flash fit on a 128 GB M3 Max at their
smallest quantisation — but only just, and with nothing much left for the rest
of your machine. This page measures what happens when you ask for less: an
expert cache capped so that roughly 70 GiB of weights stay resident and the
remainder is read from the GGUF on demand.

**Short answer: it works well for DeepSeek and not at all for GLM.** DeepSeek
gives up about a third of its reading speed and almost none of its writing
speed, at the cost of a one-second pause before each reply. GLM, asked for the
same budget, declines it: it maps all 90 GiB of its experts anyway and plans
106 GiB in total, which is more memory than running it resident.

## What was asked for

```sh
./ds4-bench -m MODEL.gguf --ssd-streaming --ssd-streaming-cache-experts 62GB \
  --prompt-file speed-bench/promessi_sposi.txt \
  --ctx-start 2048 --ctx-max 32768 --step-incr 2048 --gen-tokens 128 --csv OUT.csv
```

62 GiB was chosen because both models carry about 8.2 GiB of non-routed weights
that stay resident whatever the cache setting — attention projections, the token
embedding, the output head, shared experts. 62 + 8.2 ≈ 70 GiB, leaving nearly
60 GB of a 128 GB machine for everything else.

DeepSeek plans exactly that:

    resident model 8.20 GiB + expert cache 58.62 GiB + prefill reserve 3.38 GiB
    = 71.05 GiB planned

## DeepSeek: a real trade, and a reasonable one

Pass 2 of each configuration, same build, same machine, same night:

| Conversation so far | resident | streamed | reading | writing |
| --- | ---: | ---: | ---: | ---: |
| 2,000 | 254/22.2 | 175/13.9 | −31% | −38% |
| 8,000 | 239/21.9 | 143/16.9 | −40% | −23% |
| 16,000 | 223/20.6 | 142/16.8 | −36% | −18% |
| 24,000 | 203/18.9 | 139/17.0 | −32% | −10% |
| 32,000 | 188/18.0 | 131/17.0 | −30% | **−5%** |

Reading and writing speed in tokens per second; a token is roughly ¾ of a word.

![Reading and writing speed, resident vs streamed](../speed-bench/m3_max_streaming_prefill.svg)

![Writing speed, resident vs streamed](../speed-bench/m3_max_streaming_decode.svg)

**The writing penalty disappears as the conversation grows** — 38% at 2,000
tokens, 5% at 32,000. Past about 24,000 tokens the two configurations write at
the same speed. At long context, attention over what has already been said
dominates the cost of each token, so the expert reads matter proportionally
less.

**The reading penalty does not.** It stays at 30–40% throughout, because prefill
touches far more experts per token than decode does: every token in the prompt
routes independently, so a 2,048-token chunk reaches most of the model while a
single decoded token reaches a handful of experts.

**The cost you actually feel is the first token.** Averaged over 16K–32K:

| | resident | streamed |
| --- | ---: | ---: |
| First token after a prompt | 42 ms | **1,311 ms** |
| Sustained writing | 19.1/s | 16.9/s |
| Reading | 203/s | 137/s |

A 31× increase. Sustained writing speed at long context is nearly identical, so
a streamed reply *reads* at almost the same rate once it starts — it just starts
about 1.3 seconds late, every time.

## GLM: the budget is ignored

Given the same flags, GLM 5.3 Flash reports this instead:

    GLM SSD streaming full resident layers: 0 (auto selected 0 layers)
    GLM SSD streaming request adjusted to fit memory: cache 8829 -> 1363 experts
    GLM SSD streaming decode map: global 89.87 GiB
    resident model 89.87 GiB + expert cache 8.98 GiB + prefill reserve 3.80 GiB
    = 105.99 GiB planned

The 62 GiB cache became 9 GiB, and the whole 89.87 GiB expert set was mapped as
a *global static decode map* instead. The plan is 106 GiB — about 35 GiB more
than DeepSeek's streamed plan, and more than GLM needs to run fully resident.

Its speeds are consequently close to its resident speeds, because the
configuration is close to resident:

| | GLM resident | GLM "streamed" |
| --- | ---: | ---: |
| Reading, mean 16K–32K | 146/s | 139/s |
| Writing, mean 16K–32K | 15.8/s | 15.9/s |
| First token | 55 ms | 886 ms |

**Read carelessly, that table says GLM streams better than DeepSeek. It does
not — GLM barely streams at all.** And the memory it asks for is not available:
sampling every 15 seconds through the run shows wired memory flapping between
24 GiB and 97 GiB as the kernel wires the map, gives up, and lets it fall back
to page cache, over and over. Swap was touched (167 MB) and the compressor
reached 16 GiB, squeezing two running VMs from 31 GiB resident down to 3 GiB.
The DeepSeek streamed run, by contrast, peaked at 77.9 GiB wired with 4.9 GiB of
compressor and 0.19 MB of swap.

### Why

On Metal, `metal_graph_stream_decode_static_map_enabled()` (`ds4.c:19739`)
returns `true` unconditionally, so the GLM streaming path tries the global
static map first and falls back to per-layer streaming only if the map "does not
fit" (`ds4.c:68440-68465`). **That fit check is against total RAM, not free
RAM** — so on a 128 GiB machine a 90 GiB map always fits, and an explicit
`--ssd-streaming-cache-experts` is reduced to make room for it.

This is a sensible heuristic for the case the feature was built for, where the
model is larger than RAM and mapping everything is the best available move. It
is the wrong question for "the model fits, but I want my memory back", which is
the case measured here. DeepSeek has no equivalent path and honours the budget
as given.

### Forcing the issue does not yet work either

`DS4_METAL_DISABLE_STREAMING_STATIC_DECODE_MAP=1` does produce the intended
regime — the log says `decode map: per-layer fallback`, the cache is honoured at
62.00 GiB, and the plan is 73.58 GiB. One frontier was measured:

| ctx | reading | writing |
| ---: | ---: | ---: |
| 2,048 | 140/s | 1.09/s |

That is 15× slower than DeepSeek under the same budget. **It is also not a fair
measurement, and should not be quoted as one:** GLM demand-fills its expert
cache unless `--ssd-streaming-preload-experts N` is given explicitly, so this
number is a completely cold 58 GiB cache being filled from the GGUF during its
first 128 tokens. For comparison, DeepSeek's own first frontier reads 13.9/s
against 17/s once warm, and that is *with* its automatic preload doing the work.

GLM's genuine streaming performance at this budget is therefore **unmeasured**.
Three untried levers, in the order worth trying:

- `--ssd-streaming-preload-experts N` — populate the cache before decoding.
- `--ssd-streaming-full-layers N` — keep the first N routed layers wholly
  resident and stream the rest. The auto-selection chose 0 layers; GLM's
  recurrent design may need its early layers hot.
- `--simulate-used-memory 40GB` — lock 40 GiB before load so the machine
  presents as 88 GiB, the 90 GiB static map genuinely does not fit, and the
  per-layer path is taken *with* the footprint cap enforced. The cleanest way to
  test the regime this page is about.

## Does it leave you a usable laptop?

That was the question this started from, and the answer is yes, with one
caveat.

The DeepSeek streamed sweep was run twice: once with 24 GiB of other
applications resident, and once with two VMs up at 38 GiB. The cost of the
busier machine:

| | quiet (24 GiB apps) | VMs up (38 GiB apps) |
| --- | ---: | ---: |
| Reading, mean 16K–32K | 137/s | 129/s |
| Writing, mean 16K–32K | 16.9/s | 16.2/s |
| First token | 1,311 ms | 1,594 ms |

**6% reading, 4% writing, 22% on first-token latency.** Smaller than expected,
and far smaller than the streaming penalty itself.

The caveat is what happens to the other applications rather than to the model.
Starting a model at this budget compresses whatever else is resident: the two
VMs went from 31 GiB to 3 GiB within a minute of launch, still running but with
nothing warm left in them. They are fine when you return to them; they are not
fast for the first little while.

## Reproducing this

```sh
export DS4_BENCH_SNAPSHOT_MAX_BYTES=4294967296
speed-bench/run_ssd70.sh ds4f gguf/DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-0731.gguf
```

`speed-bench/run_ssd70.sh` runs two back-to-back passes and samples memory every
15 seconds via `speed-bench/memsample.sh`. **Quote pass 2.** Pass 1 carries a
mid-sweep dip from expert-cache churn — 16K–20K on one run, 20K–26K on another,
down to 108/11.5 at its worst — which does not survive into pass 2 and is not a
property of the context length.

Charts: `speed-bench/replot.sh`.

Host: MacBook Pro M3 Max, 40 GPU cores, 128 GiB, macOS 27.0.1, Metal.
Build: `058e5a4`, Apple clang. Both models at their smallest quantisation; see
[the model comparison](M3_MAX_DS4_VS_GLM.md#exactly-what-was-measured) for exact
filenames and revisions. 2026-10-02.

## What this does not tell you

- **GLM's actual streaming speed.** Only the static-map regime was measured
  properly. See the three levers above.
- **Anything about budgets other than 62 GiB.** A larger cache would narrow the
  reading gap; where the curve flattens is unmeasured.
- **Quality.** This is speed only, and streaming does not change the arithmetic
  — only when the weights arrive.
- **Behaviour past 32,000 tokens.** The streamed sweeps stop there; the resident
  sweeps run to 65,000.
- **Other machines.** On a machine where these models genuinely do not fit, the
  static map cannot be mapped and GLM takes the per-layer path by default. The
  behaviour documented here is specific to a model that fits with room to spare.
