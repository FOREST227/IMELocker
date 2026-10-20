#!/usr/bin/env python3
from __future__ import annotations

import io
import os
import shutil
import struct
import subprocess
from pathlib import Path

from PIL import Image


SVG_NS = "http://www.w3.org/2000/svg"


def build_composite_svg(*, compact: bool = False) -> str:
    # Small icons use six larger keys and a solid lock body. They are authored
    # separately rather than shrinking details designed for a 1024px canvas.
    columns = 3 if compact else 4
    key_size = 88 if compact else 64
    gap = 48 if compact else 40
    start_x = (1024 - (columns * key_size + (columns - 1) * gap)) / 2
    keys = "\n".join(
        f'<rect x="{start_x + column * (key_size + gap)}" y="{y}" '
        f'width="{key_size}" height="{key_size}" rx="{12 if compact else 10}" />'
        for y in ([332, 444] if compact else [340, 436])
        for column in range(columns)
    )
    keyhole = '' if compact else '<circle cx="0" cy="36" r="13" fill="#376bc0" />'
    shadow = '' if compact else ' filter="url(#cardShadow)"'
    badge_shadow = '' if compact else ' filter="url(#badgeShadow)"'
    return f"""<svg xmlns="{SVG_NS}" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="tile" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#fcfdff" />
      <stop offset="100%" stop-color="#edf2f9" />
    </linearGradient>
    <linearGradient id="keyboard" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#527fc6" />
      <stop offset="100%" stop-color="#4774bb" />
    </linearGradient>
    <linearGradient id="badge" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#4277cc" />
      <stop offset="100%" stop-color="#3265b8" />
    </linearGradient>
    <filter id="cardShadow" x="-20%" y="-20%" width="140%" height="150%">
      <feDropShadow dx="0" dy="12" stdDeviation="14" flood-color="#21334f" flood-opacity="0.12" />
    </filter>
    <filter id="badgeShadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="8" stdDeviation="10" flood-color="#21334f" flood-opacity="0.18" />
    </filter>
  </defs>
  <rect x="96" y="96" width="832" height="832" rx="184" fill="url(#tile)"{shadow} />
  <rect x="224" y="272" width="576" height="384" rx="64" fill="url(#keyboard)" />
  <g fill="#f7faff">
    {keys}
    <rect x="392" y="568" width="240" height="32" rx="10" />
  </g>
  <g transform="translate(736 724)">
    <rect x="-136" y="-136" width="272" height="272" rx="68" fill="url(#badge)"{badge_shadow} />
    <path d="M -48 -8 V -44 A 48 48 0 0 1 48 -44 V -8" fill="none"
          stroke="#f7faff" stroke-width="{26 if compact else 22}" stroke-linecap="round" />
    <rect x="-74" y="-18" width="148" height="112" rx="20" fill="#f7faff" />
    {keyhole}
  </g>
</svg>
"""


def rasterize_svg(svg_path: Path, output_dir: Path) -> Path:
    # Quick Look thumbnails flatten SVG transparency onto white. Render the
    # source directly so legacy ICNS users get the intended rounded silhouette.
    output = output_dir / f"{svg_path.name}.png"
    env = os.environ.copy()
    module_paths = [str(output_dir / "icon-tools" / "node_modules"), env.get("NODE_PATH", "")]
    env["NODE_PATH"] = os.pathsep.join(path for path in module_paths if path)
    subprocess.run(
        ["node", str(Path(__file__).with_name("render_icon.cjs")), str(svg_path), str(output)],
        check=True,
        env=env,
    )
    return output


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    build_dir = root / "build"
    iconset = build_dir / "AppIcon.iconset"
    icns_out = root / "Resources" / "AppIcon.icns"

    build_dir.mkdir(parents=True, exist_ok=True)
    if iconset.exists():
        shutil.rmtree(iconset)
    iconset.mkdir(parents=True, exist_ok=True)

    composite_svg = build_dir / "AppIcon_library.svg"
    composite_png = build_dir / "AppIcon_library_1024.png"
    app_png = build_dir / "AppIcon_1024.png"

    svg_contents = build_composite_svg()
    composite_svg.write_text(svg_contents, encoding="utf-8")

    rendered_png = rasterize_svg(composite_svg, build_dir)
    Image.open(rendered_png).save(composite_png, format="PNG")
    Image.open(rendered_png).save(app_png, format="PNG")

    sizes: list[tuple[str, int]] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]

    base = Image.open(composite_png).convert("RGBA")
    compact_svg = build_dir / "AppIcon_compact.svg"
    compact_svg.write_text(build_composite_svg(compact=True), encoding="utf-8")
    compact = Image.open(rasterize_svg(compact_svg, build_dir)).convert("RGBA")

    def image_at_size(size: int) -> Image.Image:
        source = compact if size <= 32 else base
        return source if size == 1024 else source.resize((size, size), Image.Resampling.LANCZOS)

    for filename, size in sizes:
        image = image_at_size(size)
        image.save(iconset / filename, format="PNG")

    def png_bytes(image: Image.Image) -> bytes:
        buffer = io.BytesIO()
        image.save(buffer, format="PNG")
        return buffer.getvalue()

    (root / "Resources" / "AppIcon.png").write_bytes(png_bytes(base))

    variants: list[tuple[str, int]] = [
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

    chunks: list[tuple[str, bytes]] = []
    for code, size in variants:
        image = image_at_size(size)
        chunks.append((code, png_bytes(image)))

    total_length = 8 + sum(8 + len(data) for _, data in chunks)
    output = bytearray()
    output += b"icns"
    output += struct.pack(">I", total_length)
    for code, data in chunks:
        output += code.encode("latin1")
        output += struct.pack(">I", 8 + len(data))
        output += data
    icns_out.write_bytes(output)

    print(f"Wrote: {icns_out} (from {composite_png})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
