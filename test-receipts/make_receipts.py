#!/usr/bin/env python3
"""Generate 2 fake French thermal receipts (PNG) for the end-to-end test."""
from pathlib import Path
import random
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).resolve().parent
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
FONT_B = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"
W, COLS = 576, 38  # 80 mm thermal paper at 203 dpi

RECEIPTS = {
    "amazon-receipt.png": {
        "header": ["AMAZON.CA", "Amazon.com.ca ULC", "40 King St W, Toronto ON",
                   "TPS/GST 85730 5932 RT0001", "TVQ/QST 1220234567 TQ0001"],
        "meta": ["Commande / Order: 702-9031562-1182230", "Date: 2026-11-20  14:32"],
        "items": [("Câble XLR 10 pi (x4)", "60,00"), ("Câble XLR 25 pi (x2)", "40,00")],
        "sub": "100,00", "tps": "5,00", "tvq": "9,98", "total": "114,98",
        "card": "VISA **** **** **** 4417",
        "footer": ["Merci de magasiner chez Amazon!"],
    },
    "costco-receipt.png": {
        "header": ["COSTCO WHOLESALE", "Entrepôt #503 Marché Central",
                   "9430 boul. de l'Acadie, Montréal QC", "TPS 12134 0567 RT", "TVQ 1006223344 TQ"],
        "meta": ["Membre: 111 222 333 444", "Date: 2026-11-21  10:05   Caisse 7"],
        "items": [("GLACE EN CUBES 8KG x3", "23,97"), ("VERRES PLAST. 16OZ x2", "26,03")],
        "sub": "50,00", "tps": "2,50", "tvq": "4,99", "total": "57,49",
        "card": "MASTERCARD ************8823",
        "footer": ["APPROUVÉ - MERCI", "Conservez votre reçu"],
    },
}


def line(left, right=""):
    return left + " " * max(1, COLS - len(left) - len(right)) + right


def render(spec):
    rows = []  # (text, bold, centered)
    rows += [(h, i == 0, True) for i, h in enumerate(spec["header"])]
    rows += [("-" * COLS, False, False)] + [(m, False, False) for m in spec["meta"]]
    rows += [("-" * COLS, False, False)]
    rows += [(line(name, f"{amt} $"), False, False) for name, amt in spec["items"]]
    rows += [("-" * COLS, False, False),
             (line("SOUS-TOTAL", spec["sub"] + " $"), False, False),
             (line("TPS 5%", spec["tps"] + " $"), False, False),
             (line("TVQ 9,975%", spec["tvq"] + " $"), False, False),
             (line("TOTAL", spec["total"] + " $"), True, False),
             ("", False, False),
             (spec["card"], False, False),
             (line("MONTANT PAYÉ", spec["total"] + " $"), False, False),
             ("-" * COLS, False, False)]
    rows += [(f, False, True) for f in spec["footer"]]

    font, bold = ImageFont.truetype(FONT, 22), ImageFont.truetype(FONT_B, 24)
    lh, margin = 31, 30
    img = Image.new("L", (W, margin * 2 + lh * len(rows)), 250)
    d = ImageDraw.Draw(img)
    y = margin
    for text, is_bold, center in rows:
        f = bold if is_bold else font
        x = (W - d.textlength(text, font=f)) / 2 if center else 14
        d.text((x, y), text, font=f, fill=35)
        y += lh
    # a little thermal-print texture: speckle + slight blur + tiny rotation
    rnd = random.Random(7)
    px = img.load()
    for _ in range(img.width * img.height // 60):
        x, yy = rnd.randrange(img.width), rnd.randrange(img.height)
        px[x, yy] = min(255, px[x, yy] + rnd.randint(-40, 40))
    img = img.filter(ImageFilter.GaussianBlur(0.6)).rotate(0.6, expand=True, fillcolor=250)
    return img


if __name__ == "__main__":
    for name, spec in RECEIPTS.items():
        render(spec).save(HERE / name)
        print("wrote", HERE / name)
