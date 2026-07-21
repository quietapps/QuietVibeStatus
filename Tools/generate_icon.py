#!/usr/bin/env python3
"""Quiet Vibe Status app icon generator.

Follows the Quiet Apps icon rules: true n=5 superellipse on a 1024x1024 canvas with a 9%
transparent safe-area ring, and a single vertical gradient on the icon body.

Colour deviates from the Quiet Apps blue on request, and is picked to stay clear of its siblings —
Quiet Notch is mauve, Quiet Lens is indigo, Quiet Keys is graphite and amber. Slate indigo is open,
and reads as "signal at night" rather than as the brand accent.

Mark: three activity waves, fading from pale to mint as they travel, breaking into a single glowing
dot — the agent's activity settling into the one thing that needs your attention. No notch, no
frame: just the signal and where it lands.
"""

import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

CANVAS = 1024
SS = 4  # supersample factor

BODY_TOP = (42, 54, 96)       # #2A3660 slate indigo
BODY_BOTTOM = (15, 18, 36)    # #0F1224 near-black navy

WAVE_START = (240, 244, 255)  # near-white — the wave as it begins
WAVE_END = (94, 234, 212)     # #5EEAD4 mint — the wave as it settles
DOT_COLOR = (110, 240, 200)   # mint — where the signal lands

WAVE_SPAN = 0.62        # each line's width, of body width
WAVE_SPACING = 0.15      # vertical spacing between lines, of body height
WAVE_STROKE = 0.028      # stroke width, of body height
GLOW_RADIUS = 0.028      # of body width

DOT_RADIUS = 0.045       # of body width
DOT_GLOW_RADIUS = 0.05   # of body width


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


def wave_points(cx, cy, width, amplitude, wavelength, n=64):
    xs = np.linspace(cx - width / 2, cx + width / 2, n)
    ys = cy + amplitude * np.sin((xs - xs[0]) / wavelength * 2 * np.pi - np.pi * 0.5)
    return list(zip(xs.tolist(), ys.tolist()))


def draw_gradient_wave(s, points, stroke, alpha_scale=1.0):
    """A single smooth stroke, blended from pale (start) to mint (end) with a
    horizontal alpha mask — one continuous line, no seams between colour bands."""
    cap = stroke / 2

    pale = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    draw = ImageDraw.Draw(pale)
    draw.line(points, fill=WAVE_START + (255,), width=stroke, joint="curve")
    for px, py in (points[0], points[-1]):
        draw.ellipse([px - cap, py - cap, px + cap, py + cap], fill=WAVE_START + (255,))

    mint = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    draw = ImageDraw.Draw(mint)
    draw.line(points, fill=WAVE_END + (255,), width=stroke, joint="curve")
    for px, py in (points[0], points[-1]):
        draw.ellipse([px - cap, py - cap, px + cap, py + cap], fill=WAVE_END + (255,))

    x0, x1 = points[0][0], points[-1][0]
    t = np.clip((np.arange(s) - x0) / (x1 - x0), 0, 1)
    mask = Image.fromarray(np.tile((t * 255).astype(np.uint8), (s, 1)), "L")

    blended = Image.composite(mint, pale, mask)
    arr = np.array(blended)
    arr[..., 3] = (arr[..., 3].astype(np.float32) * alpha_scale).astype(np.uint8)
    return Image.fromarray(arr, "RGBA")


def signal_layer(s):
    """Three waves stacked and fading toward the dot where the signal settles."""
    layer = Image.new("RGBA", (s, s), (0, 0, 0, 0))

    # The dot sits past the top wave's crest, both to the right and above it, so shift the
    # wave center by half the dot's radius on each axis to keep the whole mark — waves plus
    # dot — centered in the box rather than the waves alone.
    cx = s * 0.5 - (s * DOT_RADIUS) / 2
    cy = s * 0.5 + (s * DOT_RADIUS) / 2
    stroke = max(int(s * WAVE_STROKE), 2)
    spacing = s * WAVE_SPACING
    top_y = cy - spacing

    end_point = None
    for i in range(3):
        width = s * WAVE_SPAN * (1 - i * 0.10)
        amplitude = spacing * 0.34
        wavelength = width * 0.5
        wave_y = top_y + i * spacing
        alpha_scale = 1.0 - i * 0.22
        points = wave_points(cx, wave_y, width, amplitude, wavelength)
        wave_img = draw_gradient_wave(s, points, stroke, alpha_scale)
        layer.alpha_composite(wave_img)
        if i == 0:
            end_point = points[-1]

    return layer, end_point


def draw_dot(layer, center, s):
    """The glowing dot where the signal lands — the one thing that needs you."""
    draw = ImageDraw.Draw(layer, "RGBA")
    cx, cy = center
    r = s * DOT_RADIUS
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=DOT_COLOR + (255,))


def build():
    s = int(CANVAS * 0.82) * SS
    icon = body(s)

    signal, dot_center = signal_layer(s)
    draw_dot(signal, dot_center, s)

    glow = signal.filter(ImageFilter.GaussianBlur(radius=s * GLOW_RADIUS))
    glow_arr = np.array(glow)
    glow_arr[..., 3] = (glow_arr[..., 3].astype(np.float32) * 0.9).astype(np.uint8)
    glow_img = Image.fromarray(glow_arr, "RGBA")

    icon.alpha_composite(glow_img)
    icon.alpha_composite(signal)

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
