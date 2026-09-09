#!/usr/bin/env python3
"""Print reproducible provenance for a GGUF: header metadata and quant mix.

Filenames are not enough to identify what was measured. There are several
DeepSeek V4 Flash checkpoints and several quantisations of each, and the GLM
releases do not encode their recipe in the name at all. This reads the header
and reports what the file actually contains: size, an endpoint hash, the
architecture keys, and which quantisation each tensor role uses.

    ./gguf-tools/gguf_provenance.py model.gguf
    ./gguf-tools/gguf_provenance.py model.gguf --all

Only the header is read, so it is fast even on a 90 GiB file. Standard library
only, matching the other tools here.
"""

import argparse
import collections
import hashlib
import os
import struct
import sys

VALUE_TYPES = {
    0: "uint8", 1: "int8", 2: "uint16", 3: "int16", 4: "uint32", 5: "int32",
    6: "float32", 7: "bool", 8: "string", 9: "array", 10: "uint64",
    11: "int64", 12: "float64",
}

SCALAR_FMT = {
    0: "<B", 1: "<b", 2: "<H", 3: "<h", 4: "<I", 5: "<i", 6: "<f",
    7: "<?", 10: "<Q", 11: "<q", 12: "<d",
}

QUANT_NAMES = {
    0: "F32", 1: "F16", 2: "Q4_0", 3: "Q4_1", 6: "Q5_0", 7: "Q5_1",
    8: "Q8_0", 9: "Q8_1", 10: "Q2_K", 11: "Q3_K", 12: "Q4_K", 13: "Q5_K",
    14: "Q6_K", 15: "Q8_K", 16: "IQ2_XXS", 17: "IQ2_XS", 19: "IQ3_XXS",
    20: "IQ1_S", 21: "IQ4_NL", 23: "IQ3_S", 26: "IQ2_S", 29: "IQ4_XS",
    30: "BF16", 39: "MXFP4",
}

# Roles worth showing by default: the ones that decide how many bytes a token
# costs. --all prints every role instead.
INTERESTING = (
    "ffn_gate_exps", "ffn_up_exps", "ffn_down_exps", "ffn_gate_shexp",
    "kda_q.weight", "kda_k.weight", "kda_v.weight", "kda_output",
    "attn_q_b", "attn_output", "indexer.attn_q_b",
    "output.weight", "token_embd",
)

ENDPOINT_BYTES = 8 << 20


def read_struct(fh, fmt):
    return struct.unpack(fmt, fh.read(struct.calcsize(fmt)))


def read_string(fh):
    (n,) = read_struct(fh, "<Q")
    return fh.read(n).decode("utf-8", "replace")


def read_value(fh, vtype):
    """Read one metadata value. Every array element must be consumed, or the
    file position desynchronises on the tokenizer's token list and everything
    after it is garbage."""
    if vtype == 8:
        return read_string(fh)
    if vtype == 9:
        (elem_type,) = read_struct(fh, "<I")
        (count,) = read_struct(fh, "<Q")
        values = [read_value(fh, elem_type) for _ in range(count)]
        return values[:8] + ([f"...({count} items)"] if count > 8 else [])
    if vtype in SCALAR_FMT:
        return read_struct(fh, SCALAR_FMT[vtype])[0]
    raise ValueError(f"unknown metadata value type {vtype}")


def endpoint_hash(path, size):
    """Hash the first and last few MiB. Strong enough to tell releases apart
    without reading 90 GiB."""
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        digest.update(fh.read(ENDPOINT_BYTES))
        if size > ENDPOINT_BYTES:
            fh.seek(-min(ENDPOINT_BYTES, size), os.SEEK_END)
            digest.update(fh.read())
    return digest.hexdigest()


def tensor_role(name):
    """blk.31.ffn_down_exps.weight -> ffn_down_exps.weight; others unchanged."""
    return name.split(".", 2)[-1] if name.startswith("blk.") else name


def read_header(path):
    with open(path, "rb") as fh:
        if fh.read(4) != b"GGUF":
            raise SystemExit(f"{path}: not a GGUF file")
        version, n_tensors, n_kv = read_struct(fh, "<IQQ")
        meta = {}
        for _ in range(n_kv):
            key = read_string(fh)
            (vtype,) = read_struct(fh, "<I")
            meta[key] = read_value(fh, vtype)
        totals = collections.Counter()
        roles = collections.defaultdict(collections.Counter)
        for _ in range(n_tensors):
            name = read_string(fh)
            (n_dims,) = read_struct(fh, "<I")
            for _ in range(n_dims):
                read_struct(fh, "<Q")
            (qtype,) = read_struct(fh, "<I")
            read_struct(fh, "<Q")
            quant = QUANT_NAMES.get(qtype, f"type{qtype}")
            totals[quant] += 1
            roles[tensor_role(name)][quant] += 1
    return version, n_tensors, meta, totals, roles


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("path")
    ap.add_argument("--all", action="store_true",
                    help="show every tensor role, not just the ones that "
                         "dominate per-token cost")
    args = ap.parse_args()

    if not os.path.exists(args.path):
        raise SystemExit(f"{args.path}: no such file")
    size = os.path.getsize(args.path)
    version, n_tensors, meta, totals, roles = read_header(args.path)

    print(f"file            {os.path.basename(args.path)}")
    print(f"bytes           {size:,}  ({size / 2**30:.2f} GiB)")
    print(f"endpoint sha256 {endpoint_hash(args.path, size)[:32]}  "
          f"(first+last {ENDPOINT_BYTES >> 20} MiB)")
    print(f"gguf version    {version}   tensors {n_tensors}   "
          f"metadata keys {len(meta)}")

    for key in sorted(meta):
        if not (key.startswith("general.") or "expert" in key
                or "block_count" in key):
            continue
        value = str(meta[key])
        if len(value) < 90:
            print(f"  {key:34} {value}")

    print("quant mix:")
    for quant, count in totals.most_common():
        print(f"  {quant:10} {count:5} tensors")

    print("per-tensor-role quant:" if args.all
          else "per-tensor-role quant (selected; --all for every role):")
    for role in sorted(roles):
        if args.all or any(k in role for k in INTERESTING):
            print(f"  {role:26} {dict(roles[role])}")


if __name__ == "__main__":
    sys.exit(main())
