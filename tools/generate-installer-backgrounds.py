"""Render the PulseCanvas drag installer layout in each app's palette."""

import argparse
import math
import subprocess
from pathlib import Path

from PIL import Image, ImageColor, ImageDraw, ImageFont

PALETTES = {
    "Inkspring": {
        "base": "#ece4d7", "glow": "#fbf8f1", "ink": "#24251f",
        "secondary": "#63584a", "line": "#c9bca9", "well": "#fdfaf5",
        "accent": "#a6482d", "dot": "#b75635",
    },
    "OpenTalon": {
        "base": "#141518", "glow": "#292e38", "ink": "#f1f1f3",
        "secondary": "#c4cad5", "line": "#535d6e", "well": "#dfe7f2",
        "accent": "#b8d8f9", "dot": "#91bdea",
    },
}


def render(app: str, scale: int, target: Path) -> None:
    palette = PALETTES[app]
    size = (720 * scale, 460 * scale)
    image = Image.new("RGB", size)
    base = ImageColor.getrgb(palette["base"])
    glow = ImageColor.getrgb(palette["glow"])
    image.putdata([
        tuple(round(start + (end - start) * amount) for start, end in zip(base, glow))
        for y in range(size[1])
        for x in range(size[0])
        for amount in [math.exp(-(((x / scale - 360) / 410) ** 2
                                  + ((y / scale - 230) / 300) ** 2))]
    ])
    draw = ImageDraw.Draw(image)

    def points(*values: float) -> tuple[int, ...]:
        return tuple(round(value * scale) for value in values)

    def text(value: str, y: int, size: int, color: str, bold: bool = False) -> None:
        font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size * scale)
        font.set_variation_by_name("Bold" if bold else "Regular")
        if draw.textlength(value, font=font) > 632 * scale:
            raise ValueError(f"Installer text exceeds the safe width: {value}")
        draw.text(points(360, y), value, font=font, fill=palette[color], anchor="mt")

    draw.rounded_rectangle(points(18, 18, 702, 442), radius=22 * scale,
                           outline=palette["line"], width=scale)
    text(f"Install {app}", 48, 30, "ink", bold=True)
    text(f"Drag {app} to Applications to get started.", 95, 16, "secondary")

    for left in (109, 439):
        draw.rounded_rectangle(points(left, 154, left + 172, 320), radius=22 * scale,
                               fill=palette["well"])

    # Finder draws the two actual icons and labels over the artwork.
    left, top, right, bottom, radius = 102, 147, 288, 327, 29
    dots = []
    for start, end, fixed, horizontal in (
        (left + radius, right - radius, top, True),
        (left + radius, right - radius, bottom, True),
        (top + radius, bottom - radius, left, False),
        (top + radius, bottom - radius, right, False),
    ):
        count = round((end - start) / 9)
        for index in range(count + 1):
            value = start + (end - start) * index / count
            dots.append((value, fixed) if horizontal else (fixed, value))
    for cx, cy, start in ((left + radius, top + radius, 180),
                          (right - radius, top + radius, 270),
                          (right - radius, bottom - radius, 0),
                          (left + radius, bottom - radius, 90)):
        for angle in range(start + 15, start + 90, 20):
            dots.append((cx + radius * math.cos(math.radians(angle)),
                         cy + radius * math.sin(math.radians(angle))))
    for x, y in dots:
        draw.ellipse(points(x - 1.15, y - 1.15, x + 1.15, y + 1.15), fill=palette["dot"])

    draw.line(points(321, 230, 397, 230), fill=palette["accent"], width=3 * scale)
    draw.line(points(381, 215, 397, 230, 381, 245), fill=palette["accent"], width=3 * scale)
    draw.line(points(88, 355, 632, 355), fill=palette["line"], width=scale)
    text("Eject the disk image when copying is complete.", 378, 15, "ink")
    text(f"Open {app} from your Applications folder.", 410, 14, "secondary")
    image.save(target, dpi=(72 * scale, 72 * scale))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    for app in PALETTES:
        folder = args.output / app.lower()
        folder.mkdir(parents=True, exist_ok=True)
        standard = folder / "background.png"
        retina = folder / "background@2x.png"
        render(app, 1, standard)
        render(app, 2, retina)
        subprocess.run(["tiffutil", "-cathidpicheck", str(standard), str(retina),
                        "-out", str(folder / "installer-background.tiff")], check=True)


if __name__ == "__main__":
    main()
