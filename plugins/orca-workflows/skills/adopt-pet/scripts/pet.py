#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["pillow>=10"]
# ///
"""Build, check and preview an Orca .codex-pet bundle.

    slice     cut a grid image into frame files
    build     fit frames into the default 8x9 sheet, fill missing rows, write the bundle
    validate  check a bundle with the rules Orca applies on import
    preview   write a labelled PNG of a bundle's sheet

Every rule here was read from Orca 1.4.256's app bundle (see references/spec.md).
The only input that needs judgment is plan.json: which image goes to which row.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageEnhance, ImageFont, ImageSequence

FRAME_W, FRAME_H, COLUMNS = 192, 208, 8
# name -> (row, frames). Orca fills these in when pet.json leaves out frame/animations.
ROWS = {
    "idle": (0, 6), "running-right": (1, 8), "running-left": (2, 8), "waving": (3, 4),
    "jumping": (4, 5), "failed": (5, 8), "waiting": (6, 6), "running": (7, 6), "review": (8, 6),
}
SHEET_W, SHEET_H = FRAME_W * COLUMNS, FRAME_H * len(ROWS)
MAX_BYTES = 64 * 1024 * 1024
SHEET_TYPES = {".png", ".apng", ".jpg", ".jpeg", ".gif", ".webp"}
# Room left around the character: overlays (bubble, sparkles, "!") sit in the top margin.
PAD_X, PAD_TOP, PAD_BOTTOM = 14, 34, 6


def die(msg: str) -> None:
    sys.exit(f"error: {msg}")


# ---------- slice ----------

def cmd_slice(a) -> None:
    im = Image.open(a.image).convert("RGBA")
    if im.width % a.cols or im.height % a.rows:
        print(f"warning: {im.width}x{im.height} is not a clean multiple of {a.cols}x{a.rows}; "
              "the remainder is dropped", file=sys.stderr)
    fw, fh = im.width // a.cols, im.height // a.rows
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    for r in range(a.rows):
        for c in range(a.cols):
            tile = im.crop((c * fw, r * fh, (c + 1) * fw, (r + 1) * fh))
            if tile.getbbox() is None:
                continue  # empty cell
            p = out / f"r{r}c{c}.png"
            tile.save(p)
            print(p)


# ---------- build ----------

def clear_background(im: Image.Image, tolerance: int) -> Image.Image:
    """Flood-fill the corner colour to transparent when the image has no transparency."""
    if im.getextrema()[3][0] < 255:
        return im
    im = im.copy()
    for xy in ((0, 0), (im.width - 1, 0), (0, im.height - 1), (im.width - 1, im.height - 1)):
        if im.getpixel(xy)[3]:
            ImageDraw.floodfill(im, xy, (0, 0, 0, 0), thresh=tolerance)
    return im


def load_frames(paths: list[str], base: Path, background: str, tolerance: int) -> list[Image.Image]:
    """Each path is one frame, except an animated GIF/WebP/APNG, which adds all of its frames."""
    out = []
    for p in paths:
        f = (base / p) if not Path(p).is_absolute() else Path(p)
        if not f.is_file():
            die(f"frame not found: {f}")
        src = Image.open(f)
        for frame in ImageSequence.Iterator(src):
            im = frame.convert("RGBA")
            if background == "auto":
                im = clear_background(im, tolerance)
            box = im.getbbox()
            if box is None:
                continue  # blank frame inside an animation
            out.append(im.crop(box))
    if not out:
        die(f"no visible frames in {paths}")
    return out


def fitter(all_frames: list[Image.Image], style: str):
    """One scale for every frame, so the character keeps its size across rows."""
    max_w = max(f.width for f in all_frames)
    max_h = max(f.height for f in all_frames)
    scale = min((FRAME_W - 2 * PAD_X) / max_w, (FRAME_H - PAD_TOP - PAD_BOTTOM) / max_h)
    if style == "pixel" and scale >= 1:
        scale = math.floor(scale)  # whole-number scaling keeps pixel art crisp
    resample = Image.NEAREST if style == "pixel" else Image.LANCZOS

    def fit(f: Image.Image) -> Image.Image:
        w, h = max(1, round(f.width * scale)), max(1, round(f.height * scale))
        canvas = Image.new("RGBA", (FRAME_W, FRAME_H))
        canvas.alpha_composite(f.resize((w, h), resample), ((FRAME_W - w) // 2, FRAME_H - PAD_BOTTOM - h))
        return canvas
    return fit, resample


def stretch(frames: list[Image.Image], n: int) -> list[Image.Image]:
    """Map any number of given frames onto the row's fixed frame count."""
    return [frames[math.floor(i * len(frames) / n)] for i in range(n)]


def moved(f: Image.Image, dx=0, dy=0, angle=0.0, sy=1.0, resample=Image.NEAREST) -> Image.Image:
    g = f
    if sy != 1.0:
        h = max(1, round(FRAME_H * sy))
        g = Image.new("RGBA", (FRAME_W, FRAME_H))
        g.alpha_composite(f.resize((FRAME_W, h), resample), (0, FRAME_H - h))
    if angle:
        g = g.rotate(angle, resample=Image.BICUBIC if resample != Image.NEAREST else Image.NEAREST,
                     center=(FRAME_W // 2, FRAME_H - PAD_BOTTOM))
    out = Image.new("RGBA", (FRAME_W, FRAME_H))
    out.alpha_composite(g, (dx, dy)) if dx >= 0 and dy >= 0 else out.paste(g, (dx, dy), g)
    return out


INK, PAPER, SPARK, SWEAT = (40, 32, 52, 255), (252, 248, 236, 255), (255, 236, 140, 255), (140, 200, 255, 255)


def bubble(f: Image.Image, dots: int) -> Image.Image:
    f = f.copy(); d = ImageDraw.Draw(f)
    d.rounded_rectangle((118, 4, 186, 30), 8, fill=PAPER, outline=INK, width=3)
    d.polygon([(130, 29), (140, 29), (128, 38)], fill=PAPER, outline=INK)
    for k in range(dots):
        d.ellipse((134 + k * 14, 14, 141 + k * 14, 21), fill=INK)
    return f


def sparkles(f: Image.Image, phase: float) -> Image.Image:
    f = f.copy(); d = ImageDraw.Draw(f)
    for k in range(3):
        a = phase + k * 2.1
        x, y = 160 + round(14 * math.cos(a)), 20 + round(12 * math.sin(a))
        d.polygon([(x, y - 7), (x + 2, y - 2), (x + 7, y), (x + 2, y + 2), (x, y + 7),
                   (x - 2, y + 2), (x - 7, y), (x - 2, y - 2)], fill=SPARK, outline=INK)
    return f


def mark(f: Image.Image) -> Image.Image:
    f = f.copy(); d = ImageDraw.Draw(f)
    d.rounded_rectangle((164, 2, 176, 24), 4, fill=SPARK, outline=INK, width=2)
    d.ellipse((164, 26, 176, 36), fill=SPARK, outline=INK, width=2)
    return f


def drop(f: Image.Image, i: int) -> Image.Image:
    f = f.copy(); d = ImageDraw.Draw(f)
    y = 40 + (i % 4) * 6
    d.polygon([(150, y), (144, y + 12), (156, y + 12)], fill=SWEAT, outline=INK)
    d.ellipse((143, y + 6, 157, y + 18), fill=SWEAT, outline=INK)
    return f


def synth(name: str, base: Image.Image, n: int, rs) -> list[Image.Image]:
    """Motion made from one still frame, for rows the plan leaves empty."""
    m = lambda **k: moved(base, resample=rs, **k)
    if name == "idle":
        return [m(dy=dy) for dy in (0, 2, 3, 2, 0, 0)][:n]
    if name in ("running-right", "running-left"):
        fr = [m(dy=-abs(round(6 * math.sin(math.pi * i / 4))), angle=-4 if i % 2 else 4) for i in range(n)]
        return [f.transpose(Image.FLIP_LEFT_RIGHT) for f in fr] if name == "running-left" else fr
    if name == "waving":
        return [m(angle=a, dy=-2) for a in (6, -6, 6, -6)][:n]
    if name == "jumping":
        return [m(sy=0.93), m(dy=-14), m(dy=-26), m(dy=-14), m(sy=0.93)][:n]
    if name == "failed":
        out = []
        for i in range(n):
            t = min(i, 4) / 4
            g = ImageEnhance.Color(base).enhance(1 - 0.7 * t)
            g = moved(g, angle=-10 * t, dy=round(6 * t), resample=rs)
            out.append(drop(g, i) if i >= 3 else g)
        return out
    if name == "waiting":
        return [bubble(m(dy=(0, 1, 2, 1, 0, 0)[i % 6]), i % 4) for i in range(n)]
    if name == "running":
        return [sparkles(m(dy=-(0, 3, 5, 3, 0, 1)[i % 6]), 2 * math.pi * i / n) for i in range(n)]
    if name == "review":
        return [mark(m(dy=(0, 1, 1, 0, 0, 0)[i])) if i in (2, 3) else m(dy=(0, 1, 1, 0, 0, 0)[i]) for i in range(n)]
    die(f"no synthesis for {name}")


def cmd_build(a) -> None:
    plan_path = Path(a.plan)
    plan = json.loads(plan_path.read_text())
    base_dir = plan_path.parent
    unknown = set(plan.get("animations", {})) - set(ROWS)
    if unknown:
        die(f"unknown animation(s) {sorted(unknown)}; use {list(ROWS)}")
    bg, tol = plan.get("background", "auto"), int(plan.get("tolerance", 24))
    given = {k: load_frames(v, base_dir, bg, tol) for k, v in plan.get("animations", {}).items() if v}
    base_src = plan.get("base") or (plan["animations"]["idle"][0] if given.get("idle") else None)
    if not base_src:
        die("plan needs \"base\" (one still image) or at least one \"idle\" frame")
    base_raw = load_frames([base_src], base_dir, bg, tol)[0]
    style = plan.get("style", "pixel")
    if style not in ("pixel", "smooth"):
        die("style must be \"pixel\" or \"smooth\"")
    fit, rs = fitter([base_raw] + [f for fs in given.values() for f in fs], style)
    base = fit(base_raw)

    sheet = Image.new("RGBA", (SHEET_W, SHEET_H))
    report = []
    for name, (row, n) in ROWS.items():
        if name in given:
            frames, how = [fit(f) for f in stretch(given[name], n)], f"{len(given[name])} given"
        elif name == "running-left" and "running-right" in given:
            frames = [fit(f).transpose(Image.FLIP_LEFT_RIGHT) for f in stretch(given["running-right"], n)]
            how = "mirrored running-right"
        else:
            frames, how = synth(name, base, n, rs), "synthesized from base"
        for i, f in enumerate(frames):
            sheet.alpha_composite(f, (i * FRAME_W, row * FRAME_H))
        report.append(f"  row {row} {name:<14} {n} frames  ({how})")

    out = Path(a.out)
    if out.suffix != ".codex-pet":
        die("--out must end in .codex-pet")
    if out.exists() and any(out.iterdir()) and not a.force:
        die(f"{out} is not empty; pass --force to overwrite")
    out.mkdir(parents=True, exist_ok=True)
    sheet.save(out / "spritesheet.webp", lossless=True)
    meta = {k: plan[k] for k in ("id", "displayName", "description") if plan.get(k)}
    (out / "pet.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n")
    print(f"wrote {out}  ({SHEET_W}x{SHEET_H}, style={style})")
    print("\n".join(report))
    errs = validate(out)
    if errs:
        die("bundle failed validation:\n  " + "\n  ".join(errs))
    print("validate: ok")


# ---------- validate ----------

def validate(bundle: Path) -> list[str]:
    errs: list[str] = []
    manifest = bundle / "pet.json"
    if not manifest.exists():
        return ["pet.json missing"]
    if manifest.is_symlink():
        errs.append("pet.json must not be a symlink")
    try:
        m = json.loads(manifest.read_text())
    except json.JSONDecodeError as e:
        return [f"pet.json does not parse: {e}"]
    for k, lim in (("id", 128), ("displayName", 120), ("description", 2000)):
        v = m.get(k)
        if v is not None and (not isinstance(v, str) or len(v) > lim or (k != "description" and not v)):
            errs.append(f"{k}: string of 1-{lim} characters")
    rel = m.get("spritesheetPath", "spritesheet.webp")
    if rel.startswith(("/", "\\")) or ".." in rel or "\0" in rel or ":" in rel[:2]:
        return errs + [f"spritesheetPath {rel!r} must be relative and stay inside the bundle"]
    sheet = bundle / rel
    if not sheet.is_file():
        return errs + [f"spritesheet {rel} not found"]
    if sheet.is_symlink():
        errs.append("spritesheet must not be a symlink")
    if sheet.suffix.lower() not in SHEET_TYPES:
        errs.append(f"spritesheet type {sheet.suffix} not in {sorted(SHEET_TYPES)}")
    if sheet.stat().st_size > MAX_BYTES:
        errs.append("spritesheet is over 64 MB")
    im = Image.open(sheet).convert("RGBA")

    custom = "frame" in m or "animations" in m or Path(rel).name.lower() != "spritesheet.webp"
    if not custom:  # Orca fills in the default layout, so the sheet must match it
        if im.size != (SHEET_W, SHEET_H):
            errs.append(f"sheet is {im.width}x{im.height}; the default layout needs {SHEET_W}x{SHEET_H}")
            return errs
        for name, (row, n) in ROWS.items():
            for i in range(n):
                cell = im.crop((i * FRAME_W, row * FRAME_H, (i + 1) * FRAME_W, (row + 1) * FRAME_H))
                if cell.getbbox() is None:
                    errs.append(f"{name} frame {i} (row {row}) is empty")
        return errs

    fr = m.get("frame")
    if not fr:
        errs.append("a custom spritesheetPath or animations also needs \"frame\"")
        return errs
    fw, fh = fr.get("width", 0), fr.get("height", 0)
    if not (isinstance(fw, int) and isinstance(fh, int) and 0 < fw <= 1024 and 0 < fh <= 1024):
        return errs + ["frame width/height must be integers 1-1024"]
    if im.width % fw or im.height % fh:
        return errs + [f"sheet {im.width}x{im.height} is not a clean multiple of frame {fw}x{fh}"]
    cols, rows = im.width // fw, im.height // fh
    fps = m.get("fps", 8)
    if not (isinstance(fps, (int, float)) and 0 < fps <= 60):
        errs.append("fps must be > 0 and <= 60")
    anims = m.get("animations") or {}
    for name, spec in anims.items():
        r, n, d = spec.get("row"), spec.get("frames"), spec.get("frameDurationsMs")
        if not isinstance(r, int) or r >= rows or r < 0:
            errs.append(f"{name}: row {r} outside 0-{rows - 1}")
        if not isinstance(n, int) or n < 1 or n > cols:
            errs.append(f"{name}: frames {n} outside 1-{cols}")
        if d is not None and len(d) != n:
            errs.append(f"{name}: {len(d)} durations for {n} frames")
    if m.get("defaultAnimation") and m["defaultAnimation"] not in anims:
        errs.append(f"defaultAnimation {m['defaultAnimation']!r} is not in animations")
    missing = [k for k in ROWS if k not in anims]
    if missing:
        print(f"warning: no {missing}; Orca shows these states with whatever it falls back to",
              file=sys.stderr)
    return errs


def cmd_validate(a) -> None:
    errs = validate(Path(a.bundle))
    if errs:
        print("\n".join(f"error: {e}" for e in errs), file=sys.stderr)
        sys.exit(1)
    print("ok")


# ---------- preview ----------

def cmd_preview(a) -> None:
    bundle = Path(a.bundle)
    m = json.loads((bundle / "pet.json").read_text())
    im = Image.open(bundle / m.get("spritesheetPath", "spritesheet.webp")).convert("RGBA")
    label_w = 150
    out = Image.new("RGBA", (im.width + label_w, im.height), (236, 236, 240, 255))
    d = ImageDraw.Draw(out)
    for k in range(0, out.width, 16):          # checkerboard shows transparency
        for j in range(0, out.height, 16):
            if (k // 16 + j // 16) % 2:
                d.rectangle((k, j, k + 15, j + 15), fill=(222, 222, 228, 255))
    out.alpha_composite(im, (label_w, 0))
    font = ImageFont.load_default()
    for name, (row, n) in ROWS.items():
        y = row * FRAME_H
        d.line((0, y, out.width, y), fill=(160, 160, 170, 255))
        d.rectangle((0, y, label_w - 1, y + FRAME_H - 1), fill=(250, 250, 252, 255))
        d.text((8, y + 8), f"{row} {name}\n{n} frames", fill=(30, 30, 40, 255), font=font)
    out.save(a.out)
    print(a.out)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("slice"); s.add_argument("image"); s.add_argument("--cols", type=int, required=True)
    s.add_argument("--rows", type=int, required=True); s.add_argument("--out", required=True)
    b = sub.add_parser("build"); b.add_argument("--plan", required=True); b.add_argument("--out", required=True)
    b.add_argument("--force", action="store_true")
    v = sub.add_parser("validate"); v.add_argument("bundle")
    p = sub.add_parser("preview"); p.add_argument("bundle"); p.add_argument("--out", required=True)
    a = ap.parse_args()
    {"slice": cmd_slice, "build": cmd_build, "validate": cmd_validate, "preview": cmd_preview}[a.cmd](a)


if __name__ == "__main__":
    main()
