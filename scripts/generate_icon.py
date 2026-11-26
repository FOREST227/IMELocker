#!/usr/bin/env python3
"""Package Resources/AppIcon.png (1024x1024 RGBA) into Resources/AppIcon.icns.

Preserves exact bytes of AppIcon.png in the ic10 chunk and generates all 11
standard macOS ICNS variants with transparent corners and opaque artwork.
"""
from __future__ import annotations

import io
import struct
from pathlib import Path

from PIL import Image, ImageFilter

VARIANTS: list[tuple[str, int]] = [
    ("icp4", 16),
    ("icp5", 32),
    ("icp6", 64),
    ("ic11", 32),
    ("ic12", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic13", 256),
    ("ic09", 512),
    ("ic14", 512),
    ("ic10", 1024),
]


def resize_variant(master: Image.Image, size: int) -> Image.Image:
    if size == 1024:
        return master
    resized = master.resize((size, size), Image.Resampling.LANCZOS)
    if size <= 32:
        # Sharpen RGB slightly for crispness at 16px/32px while keeping alpha untouched.
        rgb = resized.convert("RGB").filter(ImageFilter.UnsharpMask(radius=0.6, percent=80, threshold=2))
        alpha = resized.getchannel("A")
        resized = Image.merge("RGBA", (*rgb.split(), alpha))
    return resized


def png_bytes(image: Image.Image) -> bytes:
    buffer = io.BytesIO()
    image.save(buffer, format="PNG", optimize=True)
    return buffer.getvalue()


def verify_alpha(image: Image.Image, label: str) -> None:
    if image.mode != "RGBA":
        raise SystemExit(f"error: {label} must be RGBA, got {image.mode}")
    w, h = image.size
    for x, y in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)):
        if image.getpixel((x, y))[3] >= 3:
            raise SystemExit(f"error: {label} corner ({x},{y}) is not transparent")
    if image.getpixel((w // 2, h // 2))[3] <= 252:
        raise SystemExit(f"error: {label} center pixel is not opaque")


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    master_path = root / "Resources" / "AppIcon.png"
    icns_out = root / "Resources" / "AppIcon.icns"

    master_raw = master_path.read_bytes()
    master = Image.open(io.BytesIO(master_raw)).convert("RGBA")
    if master.size != (1024, 1024):
        raise SystemExit(f"error: {master_path} must be 1024x1024, got {master.size}")
    verify_alpha(master, "AppIcon.png")

    chunks: list[tuple[str, bytes]] = []
    cached_by_size: dict[int, bytes] = {1024: master_raw}
    for code, size in VARIANTS:
        if size not in cached_by_size:
            variant = resize_variant(master, size)
            verify_alpha(variant, f"{code} ({size}px)")
            cached_by_size[size] = png_bytes(variant)
        chunks.append((code, cached_by_size[size]))

    total_length = 8 + sum(8 + len(data) for _, data in chunks)
    output = bytearray()
    output += b"icns"
    output += struct.pack(">I", total_length)
    for code, data in chunks:
        output += code.encode("latin1")
        output += struct.pack(">I", 8 + len(data))
        output += data
    icns_out.write_bytes(output)

    print(f"Wrote: {icns_out} ({len(output)} bytes, {len(chunks)} variants from {master_path.name})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
