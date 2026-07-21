#!/usr/bin/env python3
"""Quiet Vibe Status app icon generator.

Follows the Quiet Apps icon rules: true n=5 superellipse on a 1024x1024 canvas with a 9%
transparent safe-area ring, and a single vertical gradient on the icon body.

Colour deviates from the Quiet Apps blue on request, and is picked to stay clear of its siblings —
Quiet Notch is mauve, Quiet Lens is indigo, Quiet Keys is graphite and amber. Deep teal is open,
and it reads as "live" rather than as the brand accent.

Mark: a display with the notch bitten out of its top edge, holding a small session grid on the left
and a lit alert badge on the right — the two things the app actually shows you: your agents, and
which one is waiting on you. The bite is a true cut-out — the body gradient shows through — because
a tab drawn *on top of* a card reads as a clipboard clip instead of a notch.
"""

import os
import sys

import numpy as np
from PIL import Image, ImageDraw

CANVAS = 1024
SS = 4  # supersample factor

BODY_TOP = (20, 94, 83)      # #145E53 deep teal
BODY_BOTTOM = (7, 40, 36)    # #072824 near-black teal
SCREEN = (243, 247, 245)     # #F3F7F5 off-white display
BAR = (23, 62, 56)           # #173E38 idle bars
LIT = (46, 205, 148)         # #2ECD94 the working bar

# Geometry, as fractions of the icon body.
SCREEN_RECT = (0.13, 0.23, 0.87, 0.77)
SCREEN_RADIUS = 0.075
NOTCH_WIDTH = 0.36   # of screen width
NOTCH_HEIGHT = 0.17  # of screen height

GRID_COLS = 2
GRID_ROWS = 2


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


def screen_layer(s, rect):
    """The display, with the notch punched out of its top edge as real transparency."""
    layer = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    x0, y0, x1, y1 = rect

    draw.rounded_rectangle([x0, y0, x1, y1], radius=int(s * SCREEN_RADIUS), fill=SCREEN + (255,))

    notch_w = int((x1 - x0) * NOTCH_WIDTH)
    notch_h = int((y1 - y0) * NOTCH_HEIGHT)
    notch_x = (x0 + x1) // 2 - notch_w // 2
    radius = int(notch_h * 0.5)

    # Rounded along the bottom, flush across the top — the notch silhouette.
    draw.rounded_rectangle(
        [notch_x, y0 - radius, notch_x + notch_w, y0 + notch_h],
        radius=radius,
        fill=(0, 0, 0, 0),
    )
    draw.rectangle([notch_x, y0 - radius, notch_x + notch_w, y0 + radius], fill=(0, 0, 0, 0))
    return layer


def draw_glyph(layer, rect):
    """Your agents (the grid) and whichever one is waiting on you (the badge)."""
    draw = ImageDraw.Draw(layer)
    x0, y0, x1, y1 = rect
    width, height = x1 - x0, y1 - y0
    cy = (y0 + y1) // 2

    # Session grid — a 2x2 block of cards, left of center.
    cell = int(height * 0.22)
    cell_gap = int(height * 0.09)
    grid_span = GRID_COLS * cell + (GRID_COLS - 1) * cell_gap
    grid_x0 = x0 + int(width * 0.16)
    grid_y0 = cy - grid_span // 2
    cell_radius = int(cell * 0.32)

    for row in range(GRID_ROWS):
        for col in range(GRID_COLS):
            cx0 = grid_x0 + col * (cell + cell_gap)
            cy0 = grid_y0 + row * (cell + cell_gap)
            draw.rounded_rectangle(
                [cx0, cy0, cx0 + cell, cy0 + cell],
                radius=cell_radius,
                fill=BAR + (255,),
            )

    # Alert badge — the lit circle with an exclamation mark, right of center.
    badge_r = int(height * 0.26)
    badge_cx = x1 - int(width * 0.24)
    draw.ellipse(
        [badge_cx - badge_r, cy - badge_r, badge_cx + badge_r, cy + badge_r],
        fill=LIT + (255,),
    )

    stem_w = max(int(badge_r * 0.22), 1)
    stem_h = int(badge_r * 0.72)
    stem_top = cy - badge_r * 0.62
    draw.rounded_rectangle(
        [badge_cx - stem_w / 2, stem_top, badge_cx + stem_w / 2, stem_top + stem_h],
        radius=stem_w / 2,
        fill=SCREEN + (255,),
    )
    dot_r = stem_w * 0.62
    dot_cy = cy + badge_r * 0.52
    draw.ellipse(
        [badge_cx - dot_r, dot_cy - dot_r, badge_cx + dot_r, dot_cy + dot_r],
        fill=SCREEN + (255,),
    )


def build():
    s = int(CANVAS * 0.82) * SS
    icon = body(s)

    rect = tuple(int(s * f) for f in SCREEN_RECT)
    layer = screen_layer(s, rect)
    draw_glyph(layer, rect)
    icon.alpha_composite(layer)

    # Re-apply the silhouette so nothing painted outside the body.
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
