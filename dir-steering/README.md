# Directional Steering

Directional steering is a runtime activation edit for DS4. A steering file is a
flat `f32` matrix with one normalized hidden-width direction per normal
transformer layer. During inference, ds4 can apply the edit after attention
outputs, FFN outputs, or both:

```text
y = y - scale * direction[layer] * dot(direction[layer], y)
```

Positive scale removes the represented direction. Negative scale amplifies it.
With no steering file or zero scales, ds4 follows the normal inference path.

The file shape depends on the model:

- DeepSeek V4 Flash: `43 x 4096`.
- GLM 5.3 Flash: `45 x 4096`. The separate MTP predictor layer is omitted.

GLM 5.2 steering is not implemented.

## Runtime Options

```text
--dir-steering-file FILE   load one f32 direction per normal model layer
--dir-steering-ffn F       apply steering after FFN outputs; default is 1 when a file is provided
--dir-steering-attn F      apply steering after attention outputs; default is 0

--dir-steering-redirect-ffn F   write the removed component back along the
                                file's redirect direction, at FFN outputs
--dir-steering-redirect-attn F  the same, at attention outputs
```

## Redirection

A plain direction file removes a direction. It cannot *replace* one: the removal
and the addition point different ways, and there is only one vector per layer to
say it with.

A **redirect file** is twice as tall — `86 x 4096` for DeepSeek V4 Flash — the
normal read directions followed by one write direction per layer. With a
non-zero `--dir-steering-redirect-ffn`, ds4 applies:

```text
y = y - scale    * v[layer] * dot(v[layer], y)   remove, as before
      + redirect * w[layer] * dot(v[layer], y)   write it back along w
```

The component measured along `v` is deposited along `w`: read one concept, write
another. Concatenate the read directions and the write directions in that order.

The byte count is the format tag, so a `43 x 4096` file keeps working exactly as
before and an `86 x 4096` one enables the redirect. Asking for a redirect scale
with a plain file is an error rather than a silent plain projection.

Redirection is Metal-only and DeepSeek V4 Flash only. The CPU reference backend
runs the plain projection and refuses a redirect scale rather than quietly
dropping the write term; GLM is unaffected.

The FFN output is usually the best first target because it is late enough in
each layer to represent behavior, style, and topic signals. Attention steering
is available for experiments, but it can be more fragile.

## GLM 5.3 Example

Build a GLM 5.3 direction from paired target and control prompt lists:

```sh
python3 dir-steering/tools/build_direction.py \
  --profile glm-5.3-flash \
  --ds4 ./ds4 \
  --model gguf/GLM-5.3-Flash-Q2.gguf \
  --good-file /path/to/target-prompts.txt \
  --bad-file /path/to/control-prompts.txt \
  --out dir-steering/out/glm53-direction.json \
  --component ffn_out \
  --ctx 512
```

Generated `.f32` vectors are local artifacts and are not stored in the
repository. GLM 5.3 steering works with `--mtp`, `ds4-server`, native session
batching, and two-Mac tensor parallelism. For tensor parallelism, pass the same
steering file and scales to both the worker and coordinator.

## Verbosity Example

The bundled example builds a style direction from 100 paired prompts. Each pair
asks for the same information in two ways:

- `examples/succinct.txt`: terse target prompts.
- `examples/verbose.txt`: detailed contrast prompts.

Because the extracted direction is `succinct - verbose`, negative FFN scales
make answers shorter, while positive FFN scales tend to make answers longer and
more explanatory.

Build the vector:

```sh
python3 dir-steering/tools/build_direction.py \
  --profile deepseek-v4-flash \
  --ds4 ./ds4 \
  --model ds4flash.gguf \
  --good-file dir-steering/examples/succinct.txt \
  --bad-file dir-steering/examples/verbose.txt \
  --out dir-steering/out/verbosity.json \
  --component ffn_out \
  --ctx 512
```

This writes:

```text
dir-steering/out/verbosity.json
dir-steering/out/verbosity.f32
```

Try a terse run:

```sh
./ds4 -m ds4flash.gguf --nothink --temp 0 -n 160 \
  --dir-steering-file dir-steering/out/verbosity.f32 \
  --dir-steering-ffn -1 \
  -p "Explain why databases use indexes."
```

Try a verbose run:

```sh
./ds4 -m ds4flash.gguf --nothink --temp 0 -n 220 \
  --dir-steering-file dir-steering/out/verbosity.f32 \
  --dir-steering-ffn 2 \
  -p "Explain why databases use indexes."
```

The same vector can be used in either direction. The sign is the important part:

- negative scale amplifies the succinct target direction;
- positive scale suppresses that direction and usually gives the model more room
  to elaborate.

## Evaluating Scales

Use the sweep helper to test several strengths on a fixed prompt set:

```sh
python3 dir-steering/tools/run_sweep.py \
  --ds4 ./ds4 \
  --model ds4flash.gguf \
  --direction dir-steering/out/verbosity.f32 \
  --prompts dir-steering/examples/eval_prompts.txt \
  --scales "-1,-0.5,0,0.5,1,2" \
  --tokens 180 \
  --nothink
```

Start with FFN scales between `-1` and `2`. If the model becomes repetitive,
ignores the prompt, or starts losing factual content, the scale is too strong.
For this example, `-1` is a good first terse setting and `2` is a good first
verbose setting. Strong negative scales such as `-2` or `-3` can over-amplify
the terse direction and collapse into repetition on some prompts.

## Observed Effect

With the 100-pair vector built from the commands above, local greedy checks
showed the expected behavior:

- Prompt: `Explain why databases use indexes.`
- `--dir-steering-ffn -1`: 67 words, one compact paragraph.
- `--dir-steering-ffn 0`: 136 words, structured explanation.
- `--dir-steering-ffn 1`: 140 words, structured explanation with more detail.

On a prompt that the unsteered model already answered briefly, positive steering
made the expansion more visible:

- Prompt: `What does DNS do?`
- `--dir-steering-ffn 0`: 44 words.
- `--dir-steering-ffn 2`: 171 words, with sections and step-by-step detail.

## Building Other Directions

The extractor compares two prompt sets:

- `good-file`: target prompts for the direction you want to represent.
- `bad-file`: contrast prompts that should be separated from the target.

It captures DS4 activations from the same local GPU graph used for inference,
averages target minus contrast, normalizes one vector per layer, and writes both
metadata JSON and the runtime `.f32` file.

Concept removal:

1. Put concept-heavy prompts in `good-file`.
2. Put neutral prompts in `bad-file`.
3. Run with a positive FFN scale.

Concept amplification:

1. Put desired concept prompts in `good-file`.
2. Put neutral prompts in `bad-file`.
3. Run with a negative FFN scale.

Style control:

1. Put prompts for the target style in `good-file`.
2. Put contrasting style prompts in `bad-file`.
3. Use negative scale to amplify the target style, positive scale to reduce it.

The method is not a fine-tune. It is a low-rank runtime edit, so it works best
for coarse behavior, topic, or style directions that are consistently present in
the activation captures.

## Changing steering at runtime

`ds4-server` reads and replaces the steering configuration over HTTP, so a rule
can be iterated on without restarting the model:

```sh
curl http://127.0.0.1:8000/v1/steering
curl -X POST http://127.0.0.1:8000/v1/steering \
  -H 'Content-Type: application/json' \
  -d '{"file":"/path/to/dirs.f32","ffn":1.0,"redirect_ffn":1.0}'
```

Every field is optional; omitting one keeps its current value, and `"file":null`
clears it. Measured swap cost: about a millisecond.

**It drops the session context by default.** Steering changes what every layer
writes, so a transcript prefilled under the old configuration holds K/V that the
new one would never have produced; generating on top of it steers the new tokens
while the context stays encoded the old way. `"reprefill":false` selects that
hybrid deliberately — which is what the CLI's live `steer` scale-nudge has always
done, and is reasonable when turning a knob rather than changing a rule.

There is no cheaper correct path. Steering at layer L leaves K/V for layers 0..L
valid and invalidates L+1 upward, so in principle only the top of the stack needs
redoing — but the cache holds K/V projections, not the residual stream, and the
forward pass cannot resume at layer L+1 without the residuals at that depth.
Recovering them means running layers 0..L again, which is the prefill.

For the same reason, **a steered session neither writes nor reads the disk KV
cache**. That cache is keyed on the rendered prompt bytes, the model and the
quantisation — it carries no steering identity, so a checkpoint saved under one
configuration would be restored into a session running another. This mirrors the
existing guard for vision state, which is absent from the key for the same kind
of reason.
