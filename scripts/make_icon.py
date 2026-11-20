"""Draws the xray-oh app icon: a woven "X" crossed by a light ray over a deep
blue-to-teal tunnel. Writes HarmonyOS layered-icon parts plus flat icons.

Usage (needs Pillow):  python3 scripts/make_icon.py <out_dir>
Then copy into the project:
  background.png, foreground.png      -> AppScope/resources/base/media/
  app_icon_square.png  (no alpha)     -> AppScope/resources/base/media/app_icon.png
  app_icon_rounded.png (rounded, alpha) -> entry/src/main/resources/base/media/app_icon.png
preview.png shows the result on light and dark backgrounds and at small sizes."""
import math
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SIZE = 1024
SS = 4  # supersampling factor
N = SIZE * SS
OUT = Path(sys.argv[1])
OUT.mkdir(parents=True, exist_ok=True)


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def linear_gradient(size, c0, c1, angle_deg):
    """RGBA gradient from c0 to c1 along angle (0 = left->right, 45 = top-left->bottom-right)."""
    w, h = size
    g = Image.new("RGBA", (256, 1))
    for x in range(256):
        g.putpixel((x, 0), lerp(c0, c1, x / 255) + (255,))
    diag = int(math.hypot(w, h)) + 2
    g = g.resize((diag, diag))
    g = g.rotate(-angle_deg, resample=Image.BICUBIC)
    left = (diag - w) // 2
    top = (diag - h) // 2
    return g.crop((left, top, left + w, top + h))


def stroke_mask(p0, p1, width):
    m = Image.new("L", (N, N), 0)
    d = ImageDraw.Draw(m)
    d.line([p0, p1], fill=255, width=width)
    r = width // 2
    for (x, y) in (p0, p1):
        d.ellipse([x - r, y - r, x + r, y + r], fill=255)
    return m


def s(v):
    return int(v * SS)


# ---------- background ----------
bg = linear_gradient((N, N), (14, 22, 58), (6, 104, 118), 45)
# Faint concentric rings: a tunnel seen head-on.
rings = Image.new("L", (N, N), 0)
rd = ImageDraw.Draw(rings)
cx = cy = N // 2
for i, r in enumerate((150, 235, 330, 435, 550, 680)):
    rd.ellipse([cx - s(r), cy - s(r), cx + s(r), cy + s(r)], outline=int(34 - i * 4), width=s(5))
rings = rings.filter(ImageFilter.GaussianBlur(s(1.5)))
bg = Image.composite(Image.new("RGBA", (N, N), (170, 240, 255, 255)), bg, rings)
# Soft glow behind the centre.
glow = Image.new("L", (N, N), 0)
ImageDraw.Draw(glow).ellipse([cx - s(300), cy - s(300), cx + s(300), cy + s(300)], fill=90)
glow = glow.filter(ImageFilter.GaussianBlur(s(140)))
bg = Image.composite(Image.new("RGBA", (N, N), (60, 200, 220, 255)), bg, glow)

# ---------- foreground ----------
fg = Image.new("RGBA", (N, N), (0, 0, 0, 0))
a, b = s(330), s(694)  # X spans the central ~36% of the canvas (inside the mask's safe zone)
w = s(118)
back = stroke_mask((b, a), (a, b), w)   # "/" goes underneath
front = stroke_mask((a, a), (b, b), w)  # "\" goes on top
# Weave: cut a gap into the lower stroke around the upper one.
gap = front.filter(ImageFilter.MaxFilter(s(28) | 1))
back = ImageChops.subtract(back, gap)

back_fill = linear_gradient((N, N), (64, 232, 214), (150, 200, 255), 135)
front_fill = linear_gradient((N, N), (255, 255, 255), (214, 246, 255), 45)
fg = Image.composite(back_fill, fg, back)
fg = Image.composite(front_fill, fg, front)

# The ray: a thin horizontal beam through the crossing, fading at both ends.
beam_alpha = Image.new("L", (N, N), 0)
bd = ImageDraw.Draw(beam_alpha)
half = s(360)
for x in range(cx - half, cx + half):
    t = abs(x - cx) / half
    v = int(255 * (1 - t) ** 1.6)
    bd.line([(x, cy - s(6)), (x, cy + s(6))], fill=v)
beam_glow = beam_alpha.filter(ImageFilter.GaussianBlur(s(18)))
fg = Image.alpha_composite(fg, Image.merge("RGBA", (
    Image.new("L", (N, N), 140), Image.new("L", (N, N), 245), Image.new("L", (N, N), 255),
    beam_glow.point(lambda v: int(v * 0.8)))))
fg = Image.alpha_composite(fg, Image.merge("RGBA", (
    Image.new("L", (N, N), 255), Image.new("L", (N, N), 255), Image.new("L", (N, N), 255), beam_alpha)))
# Small bright core where beam and X meet.
core = Image.new("L", (N, N), 0)
ImageDraw.Draw(core).ellipse([cx - s(26), cy - s(26), cx + s(26), cy + s(26)], fill=255)
core = core.filter(ImageFilter.GaussianBlur(s(16)))
fg = Image.alpha_composite(fg, Image.merge("RGBA", (
    Image.new("L", (N, N), 255), Image.new("L", (N, N), 255), Image.new("L", (N, N), 255), core)))


def down(img):
    return img.resize((SIZE, SIZE), Image.LANCZOS)


bg_out, fg_out = down(bg), down(fg)
bg_out.save(OUT / "background.png")
fg_out.save(OUT / "foreground.png")

flat = Image.alpha_composite(bg_out, fg_out)
flat.convert("RGB").save(OUT / "app_icon_square.png")  # full bleed, no alpha (AppScope)

# Rounded-square version with alpha (start window, extension icon).
mask = Image.new("L", (N, N), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, N - 1, N - 1], radius=s(230), fill=255)
mask = down(mask)
rounded = flat.copy()
rounded.putalpha(mask)
rounded.save(OUT / "app_icon_rounded.png")

# Preview: rounded icon on light and dark backdrops, plus small sizes.
prev = Image.new("RGB", (SIZE * 2 + 60, SIZE + 300), (245, 246, 248))
ImageDraw.Draw(prev).rectangle([SIZE + 30, 0, SIZE * 2 + 60, SIZE + 300], fill=(28, 30, 34))
prev.paste(rounded, (15, 15), rounded)
prev.paste(rounded, (SIZE + 45, 15), rounded)
x = 15
for sz in (192, 96, 48, 24):
    small = rounded.resize((sz, sz), Image.LANCZOS)
    prev.paste(small, (x, SIZE + 40), small)
    prev.paste(small, (x + SIZE + 30, SIZE + 40), small)
    x += sz + 30
prev.save(OUT / "preview.png")
print("ok")
