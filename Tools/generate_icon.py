#!/usr/bin/env python3
"""Quiet Vibe Status app icon generator.

Follows the Quiet Apps icon rules: true n=5 superellipse on a 1024x1024 canvas with a 9%
transparent safe-area ring, and a single vertical gradient on the icon body.

Colour deviates from the Quiet Apps blue on request, and is picked to stay clear of its siblings —
Quiet Notch is mauve, Quiet Lens is indigo, Quiet Keys is graphite and amber. Deep teal is open,
and it reads as "live" rather than as the brand accent.

Mark: a terminal prompt — ">_" — painted straight onto the icon body, with the notch bitten out of
the top edge above it and a lit dot sitting in the notch. This is the app in one glyph: it watches
your terminal (the prompt), it lives in the notch (the bite), and something there is waiting on you
(the dot). The notch is a true cut-out, so the gradient shows through it the way the real hardware
notch shows through a MacBook's lid. The prompt is painted solid, not cut, so it stays crisp and
high-contrast at every size instead of punching through to whatever is behind the icon.
"""

import os
import sys

import numpy as np
from PIL import Image, ImageDraw

CANVAS = 1024
SS = 4  # supersample factor

BODY_TOP = (20, 94, 83)      # #145E53 deep teal
BODY_BOTTOM = (7, 40, 36)    # #072824 near-black teal
PROMPT = (243, 247, 245)     # #F3F7F5 off-white — the painted ">_", high-contrast on the gradient
LIT = (46, 205, 148)         # #2ECD94 the "something needs you" dot

NOTCH_WIDTH = 0.30    # of body width
NOTCH_HEIGHT = 0.11   # of body height

PROMPT_STROKE = 0.075   # chevron stroke width, of body height
PROMPT_SIZE = 0.34      # chevron height, of body height


def superellipse_mask(size, n=5.0):
    """True n=5 superellipse alpha mask — not a rounded rect."""
    y, x = np.mgrid[0:size, 0:size]
    c = (size - 1) / 2
    r = size / 2
    v = np.abs((x - c) / r) ** n + np.abs((y - c) / r) ** n
    return (v <= 1.0).astype(np.uint8) * 255


def body(s):
    grad = np.zeros((s, s, 4), dtype=np.uint8)
    t = np.linspace(0, 1, s)[:, None]
    for channel in range(3):
        grad[..., channel] = (
            (1 - t) * BODY_TOP[channel] + t * BODY_BOTTOM[channel]
        ).astype(np.uint8)
    grad[..., 3] = superellipse_mask(s)
    return Image.fromarray(grad, "RGBA")


def cut_notch(alpha, s):
    """Bite the hardware-notch silhouette straight out of the body's alpha channel."""
    mask = Image.fromarray(alpha, "L")
    draw = ImageDraw.Draw(mask)

    notch_w = int(s * NOTCH_WIDTH)
    notch_h = int(s * NOTCH_HEIGHT)
    notch_x = (s - notch_w) // 2
    radius = int(notch_h * 0.55)

    draw.rounded_rectangle(
        [notch_x, -radius, notch_x + notch_w, notch_h],
        radius=radius,
        fill=0,
    )
    draw.rectangle([notch_x, -radius, notch_x + notch_w, radius], fill=0)
    return np.array(mask), (notch_x, notch_h, notch_x + notch_w)


def draw_prompt(canvas, s):
    """Paint the ">_" terminal prompt solid on top of the body — never a see-through hole."""
    draw = ImageDraw.Draw(canvas)

    glyph_h = s * PROMPT_SIZE
    stroke = max(int(s * PROMPT_STROKE), 2)
    cx, cy = s * 0.5, s * 0.58

    chevron_w = glyph_h * 0.52
    x0 = cx - glyph_h * 0.30
    x1 = x0 + chevron_w
    y0 = cy - glyph_h / 2
    y1 = cy
    y2 = cy + glyph_h / 2

    draw.line([(x0, y0), (x1, y1), (x0, y2)], fill=PROMPT + (255,), width=stroke, joint="curve")
    cap = stroke / 2
    for px, py in ((x0, y0), (x1, y1), (x0, y2)):
        draw.ellipse([px - cap, py - cap, px + cap, py + cap], fill=PROMPT + (255,))

    bar_x0 = x1 + glyph_h * 0.16
    bar_x1 = bar_x0 + glyph_h * 0.30
    bar_y0 = cy - stroke * 0.5
    bar_y1 = cy + stroke * 0.5
    draw.rounded_rectangle([bar_x0, bar_y0, bar_x1, bar_y1], radius=stroke / 2, fill=PROMPT + (255,))


def draw_notch_dot(canvas, s, notch_span):
    """The lit dot sitting inside the notch — something in there is waiting on you."""
    draw = ImageDraw.Draw(canvas)
    notch_x0, notch_h, notch_x1 = notch_span
    r = notch_h * 0.30
    cx = notch_x1 - notch_h * 0.85
    cy = notch_h * 0.5
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=LIT + (255,))


def build():
    s = int(CANVAS * 0.82) * SS
    icon = body(s)

    arr = np.array(icon)
    alpha, notch_span = cut_notch(arr[..., 3], s)
    arr[..., 3] = alpha
    icon = Image.fromarray(arr, "RGBA")

    draw_prompt(icon, s)
    draw_notch_dot(icon, s, notch_span)

    # Re-apply the outer silhouette so nothing painted outside the squircle body.
    arr = np.array(icon)
    arr[..., 3] = np.minimum(arr[..., 3], superellipse_mask(s))
    icon = Image.fromarray(arr, "RGBA")

    art = int(CANVAS * 0.82)  # 9% transparent ring on every side
    icon = icon.resize((art, art), Image.LANCZOS)
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.paste(icon, ((CANVAS - art) // 2, (CANVAS - art) // 2), icon)
    return canvas


SIZES = [16, 32, 64, 128, 256, 512, 1024]


def main():
    target = sys.argv[1] if len(sys.argv) > 1 else (
        "QuietVibeStatus/Resources/Assets.xcassets/AppIcon.appiconset"
    )
    os.makedirs(target, exist_ok=True)

    master = build()
    for size in SIZES:
        path = os.path.join(target, f"icon_{size}.png")
        master.resize((size, size), Image.LANCZOS).save(path)
        print(f"wrote {path}")


if __name__ == "__main__":
    main()
