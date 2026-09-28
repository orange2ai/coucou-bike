from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import math

ROOT = Path(__file__).resolve().parent / "zh-Hans"
SOURCE = ROOT / "source"
OUT = ROOT / "6.9-inch"
OUT.mkdir(parents=True, exist_ok=True)
W, H = 1320, 2868

FONT_HEAD = "/System/Library/Fonts/STHeiti Medium.ttc"
FONT_BODY = "/System/Library/Fonts/Hiragino Sans GB.ttc"
FONT_LATIN = "/System/Library/Fonts/SFNS.ttf"
ICON = Path(__file__).resolve().parents[1] / "icon-gugu-riding.png"

slides = [
    {
        "src": "01-home.png",
        "title": "骑行开始，按下 GO",
        "subtitle": "速度与距离，交给咕咕记录",
    },
    {
        "src": "02-ride-cue-later.png",
        "title": "速度、距离、心率，一眼看清",
        "subtitle": "连接 Apple Watch 体能训练后同步心率",
    },
    {
        "src": "03-cues.png",
        "title": "每公里，替你开口播报",
        "subtitle": "公里报数、心率提醒、音乐混音，按需开启",
    },
    {
        "src": "05-summary.png",
        "title": "骑完有仪式，也有完整记录",
        "subtitle": "骑行数据写入 Apple 健康，记录清晰完整",
    },
    {
        "src": "04-settings.png",
        "title": "无广告，不收集任何数据",
        "subtitle": "数据留在本机与 Apple 健康，可随时导出",
    },
]


def font(path, size, index=0):
    return ImageFont.truetype(path, size=size, index=index)


def fit_font(text, path, target_width, start_size, min_size=46):
    for size in range(start_size, min_size - 1, -1):
        f = font(path, size)
        box = f.getbbox(text)
        if box[2] - box[0] <= target_width:
            return f
    return font(path, min_size)


def make_background():
    base = Image.new("RGB", (W, H), (7, 9, 11))
    px = base.load()
    for y in range(H):
        t = y / H
        r = int(12 - 5 * t)
        g = int(14 - 5 * t)
        b = int(17 - 5 * t)
        for x in range(W):
            px[x, y] = (r, g, b)
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse((250, 380, 1120, 1420), fill=(242, 111, 29, 26))
    glow = glow.filter(ImageFilter.GaussianBlur(150))
    return Image.alpha_composite(base.convert("RGBA"), glow)


def crop_round(image, size, radius):
    image = image.resize(size, Image.Resampling.LANCZOS).convert("RGBA")
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size[0]-1, size[1]-1), radius=radius, fill=255)
    image.putalpha(mask)
    return image


def draw_tracking(draw, xy, text, f, fill, tracking=3):
    x, y = xy
    for ch in text:
        draw.text((x, y), ch, font=f, fill=fill)
        x += draw.textlength(ch, font=f) + tracking


def build_slide(i, slide):
    image = make_background()
    draw = ImageDraw.Draw(image)

    # Compact brand lockup
    icon = Image.open(ICON).convert("RGBA")
    icon = crop_round(icon, (72, 72), 18)
    image.alpha_composite(icon, (66, 54))
    draw.text((158, 57), "咕咕骑车", font=font(FONT_HEAD, 37), fill=(245, 245, 245, 255))
    draw_tracking(draw, (160, 106), "COUCOU BIKE", font(FONT_LATIN, 18), (164, 169, 175, 255), tracking=3)

    # Sequence badge
    badge = (1124, 68, 1254, 118)
    draw.rounded_rectangle(badge, radius=24, fill=(255, 151, 45, 24), outline=(255, 151, 45, 100), width=2)
    draw.text((1144, 78), f"{i:02d} / 05", font=font(FONT_LATIN, 25), fill=(255, 164, 68, 255))

    # Headline and subhead
    title_font = fit_font(slide["title"], FONT_HEAD, 1180, 88, 58)
    draw.text((70, 213), slide["title"], font=title_font, fill=(250, 250, 250, 255))
    subtitle_font = fit_font(slide["subtitle"], FONT_BODY, 1170, 39, 31)
    draw.text((74, 337), slide["subtitle"], font=subtitle_font, fill=(179, 185, 190, 255))

    # Device body and subtle shadow
    screen_w = 980
    screen_h = round(screen_w * 2868 / 1320)
    frame_pad = 22
    frame_w, frame_h = screen_w + frame_pad * 2, screen_h + frame_pad * 2
    frame_x = (W - frame_w) // 2
    frame_y = 610
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle((frame_x - 2, frame_y + 20, frame_x + frame_w + 2, frame_y + frame_h + 28), radius=142, fill=(0, 0, 0, 180))
    shadow = shadow.filter(ImageFilter.GaussianBlur(30))
    image = Image.alpha_composite(image, shadow)
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((frame_x, frame_y, frame_x + frame_w, frame_y + frame_h), radius=136,
                           fill=(24, 26, 29, 255), outline=(94, 98, 103, 210), width=3)

    screen = Image.open(SOURCE / slide["src"]).convert("RGB")
    screen = crop_round(screen, (screen_w, screen_h), 112)
    image.alpha_composite(screen, (frame_x + frame_pad, frame_y + frame_pad))

    # Small side button on the polished titanium edge
    draw = ImageDraw.Draw(image)
    button_y = frame_y + 450
    draw.rounded_rectangle((frame_x + frame_w - 1, button_y, frame_x + frame_w + 5, button_y + 154), radius=3, fill=(118, 122, 128, 210))

    out = OUT / f"{i:02d}.png"
    image.convert("RGB").save(out, format="PNG", optimize=True)
    return out


outputs = [build_slide(i, slide) for i, slide in enumerate(slides, 1)]

# Contact sheet for review, not for App Store upload.
thumb_w = 264
thumb_h = round(thumb_w * H / W)
margin = 36
cols = 5
sheet = Image.new("RGB", (cols * thumb_w + (cols + 1) * margin, thumb_h + margin * 2), (20, 22, 24))
for i, p in enumerate(outputs):
    im = Image.open(p).convert("RGB").resize((thumb_w, thumb_h), Image.Resampling.LANCZOS)
    sheet.paste(im, (margin + i * (thumb_w + margin), margin))
sheet.save(ROOT / "preview-contact-sheet.png", optimize=True)
print("Generated:")
for p in outputs:
    print(p)
print(ROOT / "preview-contact-sheet.png")
