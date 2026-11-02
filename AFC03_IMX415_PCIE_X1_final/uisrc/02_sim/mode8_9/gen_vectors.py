"""Independent integer RGB reference; no third-party dependencies."""
from pathlib import Path
import argparse
import math
import random


def generate(width, height, frames, output, fixed_mode=None, t0=40, omega_pct=85, brightness_bias=8):
    output.mkdir(parents=True, exist_ok=True)
    rng = random.Random(20261018)
    modes = [0, 8, 9, 8, 9, 0, 7, 9]
    gamma = [min(range(256), key=lambda g: abs(g*g-255*v)) for v in range(256)]
    source, expected = [], []
    previous = 4
    for f in range(frames):
        requested = fixed_mode if fixed_mode is not None else modes[f % len(modes)]
        mode = previous if requested == 7 else requested
        previous = mode
        image = []
        for y in range(height):
            row = []
            for x in range(width):
                if f == 4:
                    # Hazy mid-high gray region exercises the T0 transmission clamp.
                    b, g, r = 195+x % 40, 200+y % 35, 205+(x+y) % 30
                elif f == 1:
                    b, g, r = x % 96, y % 96, (x+y) % 96
                else:
                    b, g, r = [rng.randrange(256) for _ in range(3)]
                row.append((b, g, r, (x*13+y*19+f) % 256))
            image.append(row)
        dark = [[min(px[:3]) for px in row] for row in image]
        result = []
        for y in range(height):
            row = []
            for x in range(width):
                b, g, r, pad = image[y][x]
                if mode == 8:
                    b, g, r = [gamma[v] for v in (b, g, r)]
                elif mode == 9:
                    d = min(dark[max(0, min(height-1, y+dy))][max(0, min(width-1, x+dx))]
                            for dy in (-1, 0, 1) for dx in (-1, 0, 1))
                    transmission = max(t0, 255-omega_pct*255*d//22000)
                    scale = 255*256//transmission
                    b, g, r = [max(0, min(255, 220+((v-220)*scale >> 8)+brightness_bias)) for v in (b, g, r)]
                row.append((b, g, r, pad))
            result.append(row)
        for image_data, dest in ((image, source), (result, expected)):
            for row in image_data:
                for x in range(0, width, 4):
                    word = sum(sum(v << (8*c) for c, v in enumerate(row[x+k])) << (32*k)
                               for k in range(4))
                    dest.append(f'{word:032x}')
    (output/'input.hex').write_text('\n'.join(source)+'\n', encoding='ascii')
    (output/'expected.hex').write_text('\n'.join(expected)+'\n', encoding='ascii')
    print(f'Generated {frames} frames {width}x{height}: color bypass, gamma, dehaze, bright clamp, mode7 hold')


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--width', type=int, default=64)
    ap.add_argument('--height', type=int, default=40)
    ap.add_argument('--frames', type=int, default=8)
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--mode', type=int, choices=(0,8,9))
    ap.add_argument('--t0', type=int, default=40, choices=range(1,256), help='mode9 transmission floor (v32 default 40)')
    ap.add_argument('--omega', type=int, default=85, choices=range(1,101), help='mode9 haze-removal strength in percent (v32 default 85)')
    ap.add_argument('--brightness-bias', type=int, default=8, choices=range(0,33), help='mode9 saturating output lift (v32 default 8)')
    a = ap.parse_args()
    generate(a.width, a.height, a.frames, a.output, a.mode, a.t0, a.omega, a.brightness_bias)
