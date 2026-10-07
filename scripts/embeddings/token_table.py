#!/usr/bin/env python3
"""The split token-embedding table's file formats (#59, #60).

`convert_coreml.py` exports a text-embedding model from `inputs_embeds`
onward and writes the token table next to it; the app memory-maps it
(`TokenEmbeddingTable` in BlauMemory). Two formats, row `i` for token `i`:

- float16, `<name>.token-embeddings.f16`: `width` little-endian float16
  values per row.
- int8, `<name>.token-embeddings.i8`: per row, a little-endian float32 scale
  followed by `width` int8 codes, `value = code * scale` with the row's
  largest magnitude at +/-127. Half the size (EmbeddingGemma: 202 MB instead
  of 403 MB). The default since #60.

Converts an existing float16 table (or a hosting folder) to int8:

    python3 scripts/embeddings/token_table.py <table.f16> --width 768
    python3 scripts/embeddings/token_table.py --hosting <hosting folder>   # also rewrites blau-embedding.json

Needs numpy only.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

INT8_SUFFIX = ".token-embeddings.i8"
FLOAT16_SUFFIX = ".token-embeddings.f16"


def quantize_rows(table: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Symmetric per-row int8: (codes [V, H] int8, scales [V] float32)."""
    values = table.astype(np.float32)
    largest = np.abs(values).max(axis=1)
    scales = (largest / 127.0).astype(np.float32)
    safe = np.where(scales > 0, scales, 1.0)[:, None]
    codes = np.clip(np.rint(values / safe), -127, 127).astype(np.int8)
    return codes, scales


def dequantize_rows(codes: np.ndarray, scales: np.ndarray) -> np.ndarray:
    """What the app feeds the model: codes * scale, as float16."""
    return (codes.astype(np.float32) * scales[:, None]).astype(np.float16)


def write_int8(table: np.ndarray, path: Path) -> None:
    codes, scales = quantize_rows(table)
    rows = np.empty((table.shape[0], 4 + table.shape[1]), dtype=np.uint8)
    rows[:, :4] = scales.astype("<f4").view(np.uint8).reshape(-1, 4)
    rows[:, 4:] = codes.view(np.uint8)
    rows.tofile(path)


def read_int8(path: Path, width: int) -> np.ndarray:
    """The table as the app sees it (dequantized, float16)."""
    raw = np.fromfile(path, dtype=np.uint8)
    if raw.size % (width + 4):
        raise ValueError(f"{path}: {raw.size} bytes is not a whole number of {width}-wide int8 rows")
    rows = raw.reshape(-1, width + 4)
    scales = rows[:, :4].copy().view("<f4").reshape(-1)
    codes = rows[:, 4:].copy().view(np.int8)
    return dequantize_rows(codes, scales)


def read_float16(path: Path, width: int) -> np.ndarray:
    return np.fromfile(path, dtype="<f2").reshape(-1, width)


def convert_file(source: Path, width: int) -> Path:
    if not source.name.endswith(FLOAT16_SUFFIX):
        raise SystemExit(f"{source} is not a {FLOAT16_SUFFIX} table")
    target = source.with_name(source.name[: -len(FLOAT16_SUFFIX)] + INT8_SUFFIX)
    table = read_float16(source, width)
    write_int8(table, target)
    error = np.abs(read_int8(target, width).astype(np.float32) - table.astype(np.float32)).max()
    print(f"wrote {target} ({target.stat().st_size / 1e6:.0f} MB, max abs error {error:.5f})")
    return target


def convert_hosting(folder: Path) -> None:
    metadata_path = folder / "blau-embedding.json"
    metadata = json.loads(metadata_path.read_text())
    info = metadata.get("tokenEmbeddings")
    if not info or info["dtype"] != "float16":
        raise SystemExit(f"{metadata_path}: no float16 token table to convert")
    source = folder / info["file"]
    target = convert_file(source, info["width"])
    source.unlink()
    info.update({"file": target.name, "dtype": "int8"})
    metadata_path.write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"updated {metadata_path}; removed {source.name}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("table", nargs="?", type=Path, help="a .token-embeddings.f16 file")
    parser.add_argument("--width", type=int, help="values per row (the model's hidden size)")
    parser.add_argument("--hosting", type=Path, help="a hosting folder from convert_coreml.py")
    args = parser.parse_args()
    if args.hosting:
        convert_hosting(args.hosting)
    elif args.table and args.width:
        convert_file(args.table, args.width)
    else:
        parser.error("give a table and --width, or --hosting")
    return 0


if __name__ == "__main__":
    sys.exit(main())
