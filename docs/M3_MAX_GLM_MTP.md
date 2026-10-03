# GLM 5.3 Flash's built-in draft mode on a MacBook Pro M3 Max

[Speculative decoding](SPECULATIVE_DECODING.md) | [DS4 vs GLM](M3_MAX_DS4_VS_GLM.md) | [README](../README.md)

GLM 5.3 Flash ships with a small extra block that guesses the next word before
the main model has worked it out. If the guess is right you get two words for
roughly the price of one; if it is wrong you have paid for the guess and still
need the real answer. It is off by default, and `--mtp` turns it on.

**Short answer: on this laptop, with ordinary prose, it makes GLM about 38%
slower rather than faster.** It is not broken — it is being asked to guess text
it cannot guess well enough for the arithmetic to work.

How much slower depends heavily on the passage, so any single percentage is a
summary of a wide distribution: across 32 context frontiers the loss ranged from
8% to 53%. Earlier versions of this page led with −13%, which was the average
over four short frontiers that happened to sit at the favourable end.

## What it costs

Over the full sweep, 2,000 to 65,000 tokens, 32 frontiers:

| | Writing speed | vs plain |
| --- | ---: | ---: |
| Plain decode (no `--mtp`) | 15.9/s | — |
| `--mtp`, default settings | 9.8/s | **−38%** |

Over 2,000-8,000 tokens only, where the margin settings were compared — one run
each, so read the column as "all three lose", not as a ranking:

| | Writing speed | vs plain |
| --- | ---: | ---: |
| Plain decode (no `--mtp`) | 17.5/s | — |
| `--mtp`, default settings | 12.1/s | −31% |
| `--mtp --mtp-margin 1` | 12.4/s | −29% |
| `--mtp --mtp-margin 0` | 12.6/s | −29% |

The three margin settings land within three points of each other here, and
their ordering is not the one an earlier run produced. Treat the ordering as
noise and the direction as the result.

![Writing speed with and without MTP](../speed-bench/m3_max_mtp_decode.svg)

The gap is wide and it widens with the conversation. It is also visibly
*ragged* in a way the plain line is not — that jaggedness is the point of this
page, and the next two sections are about it.

Reading speed is unaffected, as it should be — the draft block only
participates in writing:

![Reading speed with and without MTP](../speed-bench/m3_max_mtp_prefill.svg)

Memory is unaffected too. The per-conversation cache is **byte-identical**
with and without `--mtp` at every context measured; the draft block reuses the
same cache rather than keeping its own.

## Why: the arithmetic of guessing

Turning on the timing counters (`--mtp-timing`) shows what each cycle costs.
Across 347 cycles:

| | Frequency | Cost | Per word |
| --- | ---: | ---: | ---: |
| Guess was right | 46% | 93 ms → 2 words | **46 ms** |
| Guess was wrong | 54% | 147 ms → 1 word | **147 ms** |
| *(plain decode, for comparison)* | | ~65 ms → 1 word | ~65 ms |

**A correct guess saves about 19 ms. A wrong guess costs about 82 ms.** One
miss cancels out four hits.

That ratio sets the bar: the guesses need to be right **77-91% of the time**
before the feature breaks even, depending on where plain decode actually sits.
It is achieving **46%**. It is not marginally short — it would still lose at
70%.

Those cycle timings predict 9.9 words/s. The benchmark measured 9.4. Close
enough to say the mechanism is understood rather than guessed at.

## It is wildly inconsistent

This matters more than the average, and an average hides it completely.

Over the long-conversation range, plain GLM's speed varies by 2% between
measurements. With `--mtp` it varies by **69%** — from 7.4/s to 13.8/s.

The variation is not random. Repeat runs reproduce the same peaks and troughs
at the same points in the text, because it depends on how guessable that
particular passage is. At one measurement point MTP reached 18.0/s against
plain decode's 16.4/s — a genuine win, in the middle of an overall loss.

So "MTP is 38% slower" is true and close to useless. It is sometimes much
slower and occasionally faster, depending entirely on what is being written —
and because the spread is this wide, the headline figure moves with the range
you average over. That is why this page now quotes the full sweep rather than a
window within it.

## The knobs, and what they do not fix

**Draft width is not adjustable.** GLM 5.3 declares one draft head
(`n_nextn_predict = 1`), and the engine hardcodes a width of 2 for the GLM
family — one real word plus one guess. That is already the cheapest possible
configuration. `--mtp-draft` applies only to an external support model, not to
this built-in block.

**The confidence margin does not rescue it.** `--mtp-margin` decides how sure
the draft block must be before its guess is taken on the fast path. Lowering it
to 1 and disabling the gate entirely (0) both landed within three points of the
default of 3 — slightly ahead of it on the latest run, slightly behind on an
earlier one. Whatever the right setting is, it is not one that turns a losing
trade into a winning one here.

## When it would be worth turning on

The benchmark continues 19th-century Italian prose. That is close to a
worst case for a small draft head: fluent, varied, and not formulaic.

The mechanism rewards *predictable* text. Boilerplate code, structured output,
repeated formatting, long quotations, anything with strong local regularity —
those plausibly reach the 80%+ acceptance the arithmetic needs, and the same
feature that loses 38% here would win. Recorded runs on other machines show
GLM going from 34.5 to 42.0 words/s with this enabled, which is what winning
looks like.

So the honest guidance is: **try it on your own workload and measure, because
the answer depends on what you write, not on the model or the machine.**

```sh
# your workload, with and without
./ds4-bench -m gguf/GLM-5.3-Flash-Q2.gguf --prompt-file YOUR_TEXT.txt \
  --ctx-start 2048 --ctx-max 8192 --step-incr 2048 --gen-tokens 128 --csv plain.csv
./ds4-bench -m gguf/GLM-5.3-Flash-Q2.gguf --prompt-file YOUR_TEXT.txt \
  --ctx-start 2048 --ctx-max 8192 --step-incr 2048 --gen-tokens 128 --mtp --csv mtp.csv

# and to see the acceptance rate directly
./ds4-bench ... --mtp-timing 2>&1 | grep -c ACCEPT
```

If acceptance is comfortably above 80%, turn it on. Below 70%, do not.

## Caveats

- **One machine, one workload.** Nothing here says MTP is a bad feature; it
  says this text is hard to guess. A different corpus could reverse it.
- **One run per margin setting.** Given how much this workload varies, the
  ordering between margin values is not reliable — it has already changed
  between runs. That all three lost to plain decode is the robust part.
- **The benchmark's decode probe is synthetic** — a fixed greedy continuation
  with end-of-text suppressed, not a real conversation.
- Writing speed on this laptop drops ~45% once it is hot; see the
  [thermal note](M3_MAX_DS4_VS_GLM.md#heat). All figures here are sustained.

## Exactly what was measured

Model: `GLM-5.3-Flash-Q2.gguf`, 96,505,816,384 bytes, source revision
`84c6a6aa9497188e15a635ba793b0f95a79b1033`.
Host: MacBook Pro M3 Max, 40 GPU cores, 128 GiB, macOS 27.0.1, Metal.
Build: `058e5a4` (upstream `main` at `6289c51` plus 23 commits, including the
`--mtp`/`--mtp-margin` support in `ds4-bench`).
`DS4_BENCH_SNAPSHOT_MAX_BYTES=4294967296`. Speed figures measured 2026-10-02;
the acceptance-rate and per-cycle timings below are from 2026-09-15 on
`6289c51` under macOS 26.6.1 and were not re-measured, though the speeds they
explain reproduced to within 4%.

Raw data in `speed-bench/`: `m3_max_glm53f_q2_1002_mtp_pass{1,2}.csv`
(full sweeps) and `m3_max_glm53f_q2_1002_mtp_margin_{default,0,1}.csv`
(margin sweep), with the 2026-09-15 originals under the same names without
`_1002`,
and `m3_max_glm53f_q2_mtp_timing.log` (347 logged cycles, the source of the
acceptance figure). Plain GLM for comparison is
`m3_max_glm53f_q2_pass2.csv`; charts are drawn with
`speed-bench/plot_comparison.py`.

Both models' plain-decode comparison, including the long-context behaviour that
this page does not cover, is in [DeepSeek vs GLM](M3_MAX_DS4_VS_GLM.md).
