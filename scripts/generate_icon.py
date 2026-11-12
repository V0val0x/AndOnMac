#!/usr/bin/env python3
import os
import math
from PIL import Image, ImageDraw, ImageFilter

def create_mac_icon():
    size = 1024
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # 1. macOS Squircle Shape (radius ~ 225 at 1024)
    margin = 80
    rect = [margin, margin, size - margin, size - margin]
    radius = 190

    # Draw shadow first
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    s_draw = ImageDraw.Draw(shadow)
    s_draw.rounded_rectangle([margin + 4, margin + 20, size - margin - 4, size - margin + 24], radius=radius, fill=(0, 0, 0, 110))
    shadow = shadow.filter(ImageFilter.GaussianBlur(24))
    img.alpha_composite(shadow)

    # Main Squircle Background - Deep Sleek Dark Gradient
    base = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    b_draw = ImageDraw.Draw(base)
    
    # Gradient filling
    for y in range(rect[1], rect[3]):
        ratio = (y - rect[1]) / (rect[3] - rect[1])
        # Dark Space Gray / Midnight Blue gradient
        r = int(24 + 16 * (1 - ratio))
        g = int(28 + 24 * (1 - ratio))
        b = int(44 + 40 * (1 - ratio))
        b_draw.line([(rect[0], y), (rect[2], y)], fill=(r, g, b, 255))
    
    # Mask to squircle
    mask = Image.new("L", (size, size), 0)
    m_draw = ImageDraw.Draw(mask)
    m_draw.rounded_rectangle(rect, radius=radius, fill=255)
    
    # Outer bezel border
    base.putalpha(mask)
    img.alpha_composite(base)
    
    # Border highlight
    overlay = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    o_draw = ImageDraw.Draw(overlay)
    o_draw.rounded_rectangle(rect, radius=radius, outline=(255, 255, 255, 45), width=4)
    img.alpha_composite(overlay)

    # 2. Draw Beaming Waves / Wireless Rings in background
    rings = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    r_draw = ImageDraw.Draw(rings)
    cx, cy = 512, 450
    for r in [220, 290, 360]:
        r_draw.arc([cx - r, cy - r, cx + r, cy + r], start=210, end=330, fill=(0, 195, 255, 40), width=10)
    rings = rings.filter(ImageFilter.GaussianBlur(3))
    img.alpha_composite(rings)

    # 3. Draw Modern Smartphone Body (Pixel / Modern Phone)
    phone_w, phone_h = 320, 580
    px0 = (size - phone_w) // 2
    py0 = 220
    px1 = px0 + phone_w
    py1 = py0 + phone_h
    p_radius = 56

    # Phone Shadow
    p_shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ps_draw = ImageDraw.Draw(p_shadow)
    ps_draw.rounded_rectangle([px0 - 6, py0 + 12, px1 + 6, py1 + 22], radius=p_radius, fill=(0, 0, 0, 160))
    p_shadow = p_shadow.filter(ImageFilter.GaussianBlur(18))
    img.alpha_composite(p_shadow)

    # Phone Outer Titanium Rim
    phone_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    p_draw = ImageDraw.Draw(phone_layer)
    p_draw.rounded_rectangle([px0, py0, px1, py1], radius=p_radius, fill=(50, 55, 65, 255), outline=(130, 140, 160, 255), width=6)
    
    # Phone OLED Screen
    scr_m = 12
    sx0, sy0, sx1, sy1 = px0 + scr_m, py0 + scr_m, px1 - scr_m, py1 - scr_m
    s_radius = 46
    
    # Screen Gradient: Neon Android Green & Mac Blue
    scr_img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sc_draw = ImageDraw.Draw(scr_img)
    for y in range(sy0, sy1):
        ratio = (y - sy0) / (sy1 - sy0)
        # Vibrant Cyan to Electric Emerald / Lime gradient
        r = int(10 + ratio * 40)
        g = int(140 + ratio * 80)
        b = int(240 - ratio * 150)
        sc_draw.line([(sx0, y), (sx1, y)], fill=(r, g, b, 255))
        
    scr_mask = Image.new("L", (size, size), 0)
    scm_draw = ImageDraw.Draw(scr_mask)
    scm_draw.rounded_rectangle([sx0, sy0, sx1, sy1], radius=s_radius, fill=255)
    scr_img.putalpha(scr_mask)
    phone_layer.alpha_composite(scr_img)

    # Camera Punch Hole
    cam_size = 18
    cx0, cy0 = 512 - cam_size // 2, sy0 + 16
    p_draw.ellipse([cx0, cy0, cx0 + cam_size, cy0 + cam_size], fill=(15, 18, 22, 255), outline=(70, 75, 85, 255), width=2)

    # Glowing Mac Mirror Icon / Window Glyphs on Screen
    # Mac Window frame on the phone screen
    wx0, wy0, wx1, wy1 = 512 - 95, 390, 512 + 95, 520
    p_draw.rounded_rectangle([wx0, wy0, wx1, wy1], radius=16, fill=(255, 255, 255, 45), outline=(255, 255, 255, 180), width=4)
    # Traffic lights in tiny window
    p_draw.ellipse([wx0 + 14, wy0 + 12, wx0 + 22, wy0 + 20], fill=(255, 95, 87, 240))
    p_draw.ellipse([wx0 + 28, wy0 + 12, wx0 + 36, wy0 + 20], fill=(254, 187, 43, 240))
    p_draw.ellipse([wx0 + 42, wy0 + 12, wx0 + 50, wy0 + 20], fill=(39, 201, 63, 240))
    # Lightning / Play sync symbol in center of screen
    p_draw.polygon([(504, 440), (524, 440), (510, 460), (526, 460), (500, 485), (506, 466), (496, 466)], fill=(255, 255, 255, 240))

    # Bottom Home Indicator Bar on Phone
    bar_w, bar_h = 110, 8
    bx0, by0 = 512 - bar_w // 2, sy1 - 22
    p_draw.rounded_rectangle([bx0, by0, bx0 + bar_w, by0 + bar_h], radius=4, fill=(255, 255, 255, 210))

    img.alpha_composite(phone_layer)

    return img

def main():
    icon_img = create_mac_icon()
    iconset_dir = "AppIcon.iconset"
    os.makedirs(iconset_dir, exist_ok=True)

    sizes = [
        (16, "16x16"),
        (32, "16x16@2x"),
        (32, "32x32"),
        (64, "32x32@2x"),
        (128, "128x128"),
        (256, "128x128@2x"),
        (256, "256x256"),
        (512, "256x256@2x"),
        (512, "512x512"),
        (1024, "512x512@2x")
    ]

    for px, name in sizes:
        resized = icon_img.resize((px, px), Image.Resampling.LANCZOS)
        out_path = os.path.join(iconset_dir, f"icon_{name}.png")
        resized.save(out_path, "PNG")

    # Generate ICNS
    os.system("iconutil -c icns AppIcon.iconset -o Sources/AndOnMac/Resources/AppIcon.icns")
    os.system("rm -rf AppIcon.iconset")
    print("✅ AppIcon.icns successfully generated!")

if __name__ == "__main__":
    main()
