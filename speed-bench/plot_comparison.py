#!/usr/bin/env python3
"""Generate comparison SVG charts from several ds4-bench CSV files.

One chart per measure. Prefill and decode never share a y axis: they are
different quantities on different scales, and a shared-axis plot invites the
reader to infer a relationship the data does not support. Sibling script
plot_speed.py draws a single run; this one overlays several runs so the
models can be compared at the same context frontiers.

Only the standard library is used, matching plot_speed.py.
"""

import argparse
import csv
import html
import math
from pathlib import Path

# Categorical slots 1-3 of the validated palette; assigned in fixed order and
# never cycled. Verified for colour-vision deficiency separation as a set.
SERIES_COLORS = ["#2a78d6", "#eb6834", "#1baf7a"]

SURFACE = "#fcfcfb"
INK_PRIMARY = "#0b0b0b"
INK_SECONDARY = "#52514e"
INK_MUTED = "#898781"
GRIDLINE = "#e1e0d9"
AXIS = "#c3c2b7"

WIDTH, HEIGHT = 960, 520
M_LEFT, M_RIGHT, M_TOP, M_BOTTOM = 78, 168, 78, 68


def nice_ceil(value):
    """Round a positive axis maximum up to a human-friendly tick boundary."""
    if value <= 0:
        return 1.0
    magnitude = 10 ** math.floor(math.log10(value))
    normalized = value / magnitude
    for step in (1, 1.5, 2, 2.5, 3, 4, 5, 10):
        if normalized <= step:
            return step * magnitude
    return 10 * magnitude


def nice_step(span, target_ticks):
    """Return a readable tick spacing close to span / target_ticks."""
    if span <= 0:
        return 1.0
    raw = span / target_ticks
    magnitude = 10 ** math.floor(math.log10(raw))
    normalized = raw / magnitude
    for step in (1, 2, 2.5, 5, 10):
        if normalized <= step:
            return step * magnitude
    return 10 * magnitude


def read_series(path, column, scale=1.0, min_ctx=0):
    """Return [(ctx_tokens, value)] for one ds4-bench CSV column.

    min_ctx drops leading frontiers. A long sweep starts cold and passes
    through the thermal trough before settling, so its early points measure
    the machine warming up rather than the model, and plotting them next to
    another run that started warm invents a crossing that is not there.
    """
    points = []
    with open(path, newline="", encoding="utf-8-sig") as fh:
        for row in csv.DictReader(fh):
            try:
                x = int(row["ctx_tokens"])
                y = float(row[column]) * scale
            except (KeyError, TypeError, ValueError):
                continue
            if y > 0 and x >= min_ctx:
                points.append((x, y))
    return sorted(points)


def render(series, title, subtitle, y_label, out_path, y_unit=""):
    """Write one multi-series line chart. series = [(name, [(x, y)])]."""
    series = [s for s in series if s[1]]
    if not series:
        raise SystemExit(f"no data for {out_path}")

    x_max = max(x for _, pts in series for x, _ in pts)
    # Start the x axis near the data. A trimmed sweep begins well above zero,
    # and anchoring at zero would spend most of the width on empty axis. The y
    # axis still starts at zero: these series sit close together, and a
    # truncated value axis would exaggerate how far apart they are.
    x_lo = min(x for _, pts in series for x, _ in pts)
    x_min = 0 if x_lo <= 8192 else (x_lo // 8192) * 8192
    y_max = nice_ceil(max(y for _, pts in series for _, y in pts) * 1.08)
    plot_w = WIDTH - M_LEFT - M_RIGHT
    plot_h = HEIGHT - M_TOP - M_BOTTOM

    def sx(x):
        return M_LEFT + ((x - x_min) / (x_max - x_min)) * plot_w

    def sy(y):
        return M_TOP + plot_h - (y / y_max) * plot_h

    o = []
    add = o.append
    add('<?xml version="1.0" encoding="UTF-8"?>')
    add(f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" '
        f'height="{HEIGHT}" viewBox="0 0 {WIDTH} {HEIGHT}" '
        f'role="img" aria-label="{html.escape(title)}">')
    add("<style>")
    add("text{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',"
        "Helvetica,Arial,sans-serif}")
    add(f".title{{font-size:23px;font-weight:700;fill:{INK_PRIMARY}}}")
    add(f".sub{{font-size:14px;fill:{INK_SECONDARY}}}")
    add(f".axlab{{font-size:13px;font-weight:600;fill:{INK_SECONDARY}}}")
    add(f".tick{{font-size:12px;fill:{INK_MUTED}}}")
    add(".slab{font-size:13px;font-weight:700}")
    add("</style>")
    add(f'<rect width="{WIDTH}" height="{HEIGHT}" fill="{SURFACE}"/>')
    add(f'<text class="title" x="{M_LEFT}" y="36">{html.escape(title)}</text>')
    if subtitle:
        add(f'<text class="sub" x="{M_LEFT}" y="58">'
            f'{html.escape(subtitle)}</text>')

    # Horizontal gridlines, recessive.
    step = nice_step(y_max, 5)
    v = 0.0
    while v <= y_max + 1e-9:
        y = sy(v)
        add(f'<line x1="{M_LEFT}" y1="{y:.1f}" x2="{M_LEFT + plot_w}" '
            f'y2="{y:.1f}" stroke="{GRIDLINE}" stroke-width="1"/>')
        label = f"{v:g}"
        add(f'<text class="tick" x="{M_LEFT - 10}" y="{y + 4:.1f}" '
            f'text-anchor="end">{label}</text>')
        v += step

    # X ticks every 8K tokens.
    xt = x_min
    while xt <= x_max:
        x = sx(xt)
        add(f'<line x1="{x:.1f}" y1="{M_TOP + plot_h}" x2="{x:.1f}" '
            f'y2="{M_TOP + plot_h + 5}" stroke="{AXIS}" stroke-width="1"/>')
        add(f'<text class="tick" x="{x:.1f}" y="{M_TOP + plot_h + 20}" '
            f'text-anchor="middle">{xt // 1024}K</text>')
        xt += 8192
    add(f'<line x1="{M_LEFT}" y1="{M_TOP + plot_h}" x2="{M_LEFT + plot_w}" '
        f'y2="{M_TOP + plot_h}" stroke="{AXIS}" stroke-width="1.5"/>')

    add(f'<text class="axlab" x="{M_LEFT + plot_w / 2:.0f}" '
        f'y="{HEIGHT - 18}" text-anchor="middle">'
        f'Context length (tokens already in the conversation)</text>')
    add(f'<text class="axlab" transform="translate(20,'
        f'{M_TOP + plot_h / 2:.0f}) rotate(-90)" text-anchor="middle">'
        f'{html.escape(y_label)}</text>')

    # Series: 2px lines, 8px markers ringed in the surface colour so
    # overlapping points stay separable.
    for idx, (name, pts) in enumerate(series):
        colour = SERIES_COLORS[idx % len(SERIES_COLORS)]
        d = " ".join(
            f"{'M' if i == 0 else 'L'}{sx(x):.1f},{sy(y):.1f}"
            for i, (x, y) in enumerate(pts)
        )
        add(f'<path d="{d}" fill="none" stroke="{colour}" stroke-width="2" '
            f'stroke-linejoin="round" stroke-linecap="round"/>')
        for x, y in pts:
            add(f'<circle cx="{sx(x):.1f}" cy="{sy(y):.1f}" r="4" '
                f'fill="{colour}" stroke="{SURFACE}" stroke-width="2"/>')
        # Direct label at the series end: identity is never colour-alone.
        lx, ly = pts[-1]
        # A series that stops short of the axis end is labelled inside the
        # plot, over other lines, so its label gets a surface-coloured halo.
        halo = (f' stroke="{SURFACE}" stroke-width="4" paint-order="stroke"'
                if lx < x_max else "")
        add(f'<text class="slab" x="{sx(lx) + 12:.1f}" y="{sy(ly) + 4:.1f}" '
            f'fill="{colour}"{halo}>{html.escape(name)}</text>')
        end = f"{ly:,.1f}{y_unit}"
        add(f'<text class="tick" x="{sx(lx) + 12:.1f}" '
            f'y="{sy(ly) + 20:.1f}"{halo}>{end}</text>')

    add("</svg>")
    Path(out_path).write_text("\n".join(o) + "\n", encoding="utf-8")
    return out_path


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--run", action="append", default=[], metavar="NAME=CSV",
                    help="labelled ds4-bench CSV; repeat for each run")
    ap.add_argument("--out-dir", default=".")
    ap.add_argument("--machine", default="")
    ap.add_argument("--min-ctx", type=int, default=0, metavar="N",
                    help="drop frontiers below N from the speed charts; use "
                         "when a run started cold, so its warm-up is not "
                         "plotted against a run that started warm")
    ap.add_argument("--kv-skip", action="append", default=[], metavar="NAME",
                    help="omit this run from the KV-cache chart; use for runs "
                         "whose cache is identical to another's, since an "
                         "exactly overlapping line reads as a missing series")
    args = ap.parse_args()
    if not args.run:
        ap.error("at least one --run NAME=CSV is required")

    runs = []
    for spec in args.run:
        if "=" not in spec:
            ap.error(f"--run needs NAME=CSV, got {spec!r}")
        name, path = spec.split("=", 1)
        runs.append((name, path))

    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    suffix = f" — {args.machine}" if args.machine else ""
    written = []

    written.append(render(
        [(n, read_series(p, "gen_tps", min_ctx=args.min_ctx)) for n, p in runs],
        "Writing speed" + suffix,
        "Tokens produced per second while answering. Higher is better.",
        "Tokens per second", out / "compare_decode.svg"))

    written.append(render(
        [(n, read_series(p, "prefill_tps", min_ctx=args.min_ctx)) for n, p in runs],
        "Reading speed" + suffix,
        "Tokens of your prompt digested per second before the answer starts. "
        "Higher is better.",
        "Tokens per second", out / "compare_prefill.svg"))

    kv_runs = [(n, p) for n, p in runs if n not in args.kv_skip]
    written.append(render(
        [(n, read_series(p, "kvcache_bytes", 1 / 2**30)) for n, p in kv_runs],
        "Memory used to remember the conversation" + suffix,
        "Extra memory held on top of the model itself. Lower is better.",
        "Gigabytes", out / "compare_kvcache.svg", y_unit=" GB"))

    for path in written:
        print(path)


if __name__ == "__main__":
    main()
