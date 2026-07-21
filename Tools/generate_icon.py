#!/usr/bin/env python3
"""Quiet Vibe Status app icon generator.

Follows the Quiet Apps icon rules: true n=5 superellipse on a 1024x1024 canvas with a 9%
transparent safe-area ring, and a single vertical gradient on the icon body.

Colour deviates from the Quiet Apps blue on request, and is picked to stay clear of its siblings —
Quiet Notch is mauve, Quiet Lens is indigo, Quiet Keys is graphite and amber. Deep teal is open,
and it reads as "live" rather than as the brand accent.

Mark: a card with the notch bitten out of its top edge — the bite is a true cut-out of the card
layer only, so the gradient body shows through it, the same way the real hardware notch shows
through a MacBook's lid. A lit dot sits in the notch like a camera housing. On the card, a bold
`>_` terminal prompt is painted solid in the dark ink colour — not cut out — so it stays crisp and
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
CARD = (243, 247, 245)       # #F3F7F5 off-white card
INK = (11, 43, 38)           # #0B2B26 the prompt glyph, dark against the card
LIT = (46, 205, 148)         # #2ECD94 the notch dot — something needs you

CARD_RECT = (0.11, 0.20, 0.89, 0.80)
CARD_RADIUS = 0.09

NOTCH_WIDTH = 0.34     # of card width
NOTCH_HEIGHT = 0.15    # of card height

PROMPT_STROKE = 0.11    # chevron stroke width, of card height
PROMPT_SIZE = 0.46      # chevron height, of card height


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


def card_layer(s, rect):
    """The card, with the notch punched out of its top edge as real transparency —
    the body gradient behind it shows through, the way a lid shows the hardware notch."""
    layer = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    x0, y0, x1, y1 = rect

    draw.rounded_rectangle([x0, y0, x1, y1], radius=int(s * CARD_RADIUS), fill=CARD + (255,))

    notch_w = int((x1 - x0) * NOTCH_WIDTH)
    notch_h = int((y1 - y0) * NOTCH_HEIGHT)
    notch_x = (x0 + x1) // 2 - notch_w // 2
    radius = int(notch_h * 0.55)

    draw.rounded_rectangle(
        [notch_x, y0 - radius, notch_x + notch_w, y0 + notch_h],
        radius=radius,
        fill=(0, 0, 0, 0),
    )
    draw.rectangle([notch_x, y0 - radius, notch_x + notch_w, y0 + radius], fill=(0, 0, 0, 0))
    return layer, (notch_x, y0, notch_x + notch_w, y0 + notch_h)


def draw_notch_dot(layer, notch_rect):
    """The lit dot sitting in the notch, like a camera housing — something needs you."""
    draw = ImageDraw.Draw(layer)
    nx0, ny0, nx1, ny1 = notch_rect
    r = (ny1 - ny0) * 0.26
    cx = nx1 - (ny1 - ny0) * 0.9
    cy = (ny0 + ny1) / 2
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=LIT + (255,))


def draw_prompt(layer, rect):
    """A bold, solid `>_` painted on the card — always crisp, never a see-through hole."""
    draw = ImageDraw.Draw(layer)
    x0, y0, x1, y1 = rect
    width, height = x1 - x0, y1 - y0
    cx, cy = x0 + width * 0.5, y0 + height * 0.58

    glyph_h = height * PROMPT_SIZE
    stroke = max(int(height * PROMPT_STROKE), 2)

    chevron_w = glyph_h * 0.52
    cx0 = cx - glyph_h * 0.34
    cx1 = cx0 + chevron_w
    cy0 = cy - glyph_h / 2
    cy1 = cy
    cy2 = cy + glyph_h / 2

    draw.line([(cx0, cy0), (cx1, cy1), (cx0, cy2)], fill=INK + (255,), width=stroke, joint="curve")
    cap = stroke / 2
    for px, py in ((cx0, cy0), (cx1, cy1), (cx0, cy2)):
        draw.ellipse([px - cap, py - cap, px + cap, py + cap], fill=INK + (255,))

    bar_x0 = cx1 + glyph_h * 0.18
    bar_x1 = bar_x0 + glyph_h * 0.32
    bar_y0 = cy - stroke * 0.5
    bar_y1 = cy + stroke * 0.5
    draw.rounded_rectangle([bar_x0, bar_y0, bar_x1, bar_y1], radius=stroke / 2, fill=INK + (255,))


def build():
    s = int(CANVAS * 0.82) * SS
    icon = body(s)

    rect = tuple(int(s * f) for f in CARD_RECT)
    layer, notch_rect = card_layer(s, rect)
    draw_prompt(layer, rect)
    icon.alpha_composite(layer)
    draw_notch_dot(icon, notch_rect)

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
