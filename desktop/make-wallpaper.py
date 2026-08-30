#!/usr/bin/env python3
"""
make-wallpaper.py - generate the desktop background at build time.

Generated rather than committed: a repo of shell, Dockerfiles and one Python
script has no business carrying a 2 MB binary blob, and both numpy and Pillow
are already in the image as ultralytics dependencies.

numpy rather than a pixel loop -- two million iterations of Python is fifteen
seconds of build time for an image nobody will look at closely.

Written to an absolute path under /app because the .sif is read-only and this
is a baked-in asset, like the model weights.
"""

import sys

import numpy as np
from PIL import Image

WIDTH, HEIGHT = 1920, 1080
TOP = (18, 26, 38)        # near-black navy
BOTTOM = (44, 62, 84)     # slate
VIGNETTE = 0.55           # how much the corners darken


def render():
    # Vertical gradient: one column of colours, broadcast across the width.
    t = np.linspace(0.0, 1.0, HEIGHT, dtype=np.float32)[:, None]
    top = np.array(TOP, dtype=np.float32)
    bottom = np.array(BOTTOM, dtype=np.float32)
    column = top + (bottom - top) * t                     # (H, 3)
    img = np.repeat(column[:, None, :], WIDTH, axis=1)     # (H, W, 3)

    # Radial falloff: 1.0 at the centre, dimmer towards the corners.
    ys = (np.arange(HEIGHT, dtype=np.float32) - HEIGHT / 2.0)[:, None]
    xs = (np.arange(WIDTH, dtype=np.float32) - WIDTH / 2.0)[None, :]
    d2 = xs * xs + ys * ys
    shade = 1.0 - VIGNETTE * (d2 / d2.max())

    return np.clip(img * shade[:, :, None], 0, 255).astype(np.uint8)


def main(out_path):
    Image.fromarray(render(), "RGB").save(out_path, "PNG", optimize=True)
    print(f"wrote {out_path} ({WIDTH}x{HEIGHT})")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "wallpaper.png")
