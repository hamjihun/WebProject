"""프로그램 아이콘(app.ico) 생성."""
from pathlib import Path

from PIL import Image, ImageDraw

S = 256
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
d.rounded_rectangle((8, 8, S - 8, S - 8), 56, fill=(47, 91, 211))
d.polygon([(72, 52), (150, 52), (186, 88), (186, 204), (72, 204)], fill="white")
d.polygon([(150, 52), (150, 88), (186, 88)], fill=(200, 212, 245))
for y in (112, 140, 168):
    d.rounded_rectangle((94, y, 164, y + 10), 5, fill=(47, 91, 211))
out = Path(__file__).with_name("app.ico")
img.save(out, sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
print(out)
