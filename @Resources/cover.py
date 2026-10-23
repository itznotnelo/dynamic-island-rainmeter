"""Album art for the Dynamic Island.

PowerShell 5.1 can read the track title from Windows' media session but not its
thumbnail stream, so NowPlaying.ps1 calls this on every track change:

    python cover.py <@Resources folder> <slot> [--title T --artist A --duration MS] [--url IMAGE_URL]

For slot 0 or 1 (two slots, so Rainmeter loads the new image instead of its cached one):
    Art<slot>S.png   compact art, 24 px with radius 6 and a soft glow behind it (56x56)
    Art<slot>L.png   expanded art, 96 px with radius 12, drop shadow and hairline ring (144x144)
    Glow<slot>.png   background glow of the expanded view (340x120): the art blown up,
                     blurred and saturated, fading into the notch colour at the edges
    Color<slot>.txt  the notch's adaptive tint, Bloom-style: the art's hue at 50 % saturation, 15 % light
    Lyrics<slot>.txt synced lyrics from LRCLIB (free, no key) as "ms<TAB>line", empty when there are none
--url reads the art from an image URL (music playing on the phone) instead of Windows' media session.
Exit code 0: art written. 1: no art (yet), placeholder tiles written instead.
Sizes and filters follow Bloom's island (github.com/SehajveerSingh2005/bloom).
"""
import argparse
import asyncio
import colorsys
import io
import json
import math
import os
import re
import sys
import urllib.parse
import urllib.request
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageFilter

SS = 4                      # supersampling for smooth corners
GLOW_W, GLOW_H = 340, 120   # expanded island
NOTCH_A = 0.92              # notch background opacity while expanded


async def thumbnail():
    from winrt.windows.media.control import \
        GlobalSystemMediaTransportControlsSessionManager as Manager
    from winrt.windows.storage.streams import Buffer, DataReader, InputStreamOptions

    session = (await Manager.request_async()).get_current_session()
    if session is None:
        return None
    ref = (await session.try_get_media_properties_async()).thumbnail
    if ref is None:
        return None
    stream = await ref.open_read_async()
    if not stream.size:
        return None
    buf = Buffer(stream.size)
    await stream.read_async(buf, stream.size, InputStreamOptions.READ_AHEAD)
    data = bytearray(buf.length)
    DataReader.from_buffer(buf).read_bytes(data)
    return Image.open(io.BytesIO(bytes(data))).convert('RGB')


def cover_crop(img, w, h):
    """object-fit: cover"""
    s = max(w / img.width, h / img.height)
    img = img.resize((max(w, round(img.width * s)), max(h, round(img.height * s))), Image.LANCZOS)
    x, y = (img.width - w) // 2, (img.height - h) // 2
    return img.crop((x, y, x + w, y + h))


def rounded_mask(w, h, r):
    m = Image.new('L', (w * SS, h * SS), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, w * SS - 1, h * SS - 1), r * SS, fill=255)
    return m.resize((w, h), Image.LANCZOS)


def tile(art, size, r):
    """Rounded art, or Bloom's empty tile (white at 15 %) when there is none."""
    if art is None:
        img = Image.new('RGBA', (size, size), (255, 255, 255, 38))
    else:
        img = cover_crop(art, size, size).convert('RGBA')
    img.putalpha(ImageChops.multiply(img.getchannel('A'), rounded_mask(size, size, r)))
    return img


def blur(img, radius):
    """Gaussian blur that lets transparent edges bleed in, like CSS blur()."""
    return img.convert('RGBa').filter(ImageFilter.GaussianBlur(radius)).convert('RGBA')


def filters(img, saturate=1.0, contrast=1.0, brightness=1.0):
    a = img.getchannel('A')
    rgb = img.convert('RGB')
    rgb = ImageEnhance.Color(rgb).enhance(saturate)
    rgb = ImageEnhance.Contrast(rgb).enhance(contrast)
    rgb = ImageEnhance.Brightness(rgb).enhance(brightness)
    out = rgb.convert('RGBA')
    out.putalpha(a)
    return out


def opacity(img, a):
    img = img.copy()
    img.putalpha(img.getchannel('A').point(lambda v: round(v * a)))
    return img


def compact(art):
    """24 px art r6 at (16,16); behind it the art inset -4 (32 px r10), blur 6, saturate 2.5,
    brightness .8, opacity .6"""
    canvas = Image.new('RGBA', (56, 56), (0, 0, 0, 0))
    if art is not None:
        glow = filters(blur_pad(tile(art, 32, 10), 12, 6), saturate=2.5, brightness=0.8)
        canvas.alpha_composite(opacity(glow, 0.6), (0, 0))
    canvas.alpha_composite(tile(art, 24, 6), (16, 16))
    return canvas


def blur_pad(img, pad, radius):
    big = Image.new('RGBA', (img.width + 2 * pad, img.height + 2 * pad), (0, 0, 0, 0))
    big.alpha_composite(img, (pad, pad))
    return blur(big, radius)


def expanded(art):
    """96 px art r12 at (24,24), shadow 0 4px 16px rgba(0,0,0,.4), 0.5 px ring rgba(255,255,255,.1)"""
    canvas = Image.new('RGBA', (144, 144), (0, 0, 0, 0))
    shadow = Image.new('RGBA', (144, 144), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 102), (24, 28, 120, 124), rounded_mask(96, 96, 12))
    canvas.alpha_composite(blur(shadow, 8))
    canvas.alpha_composite(tile(art, 96, 12), (24, 24))
    ring = Image.new('RGBA', (144 * SS, 144 * SS), (0, 0, 0, 0))
    ImageDraw.Draw(ring).rounded_rectangle((24 * SS - 2, 24 * SS - 2, 120 * SS + 1, 120 * SS + 1),
                                           12 * SS + 2, outline=(255, 255, 255, 26), width=2)
    canvas.alpha_composite(ring.resize((144, 144), Image.LANCZOS))
    return canvas


def ambient(art):
    """Bloom's .notch-ambient-glow: the art as object-fit cover, blur 52, saturate 3.5,
    contrast 1.1, brightness 1.4, then scaled 1.8 from the centre (CSS applies the filter
    before the transform), opacity .85, under a radial gradient that fades to the notch
    colour: transparent 20 %, black 25 % at 50 %, notch background at 85 %."""
    if art is None:
        return Image.new('RGBA', (GLOW_W, GLOW_H), (0, 0, 0, 0))
    el = cover_crop(art, GLOW_W, GLOW_H).convert('RGBA')
    el = filters(blur_pad(el, 120, 52), saturate=3.5, contrast=1.1, brightness=1.4)
    k = 1.8
    big = el.resize((round(el.width * k), round(el.height * k)), Image.LANCZOS)
    x, y = (big.width - GLOW_W) // 2, (big.height - GLOW_H) // 2
    glow = opacity(big.crop((x, y, x + GLOW_W, y + GLOW_H)), 0.85)

    over = Image.new('L', (GLOW_W, GLOW_H), 0)
    rx, ry = GLOW_W / 2 * math.sqrt(2), GLOW_H / 2 * math.sqrt(2)   # farthest-corner ellipse
    px = over.load()
    for j in range(GLOW_H):
        for i in range(GLOW_W):
            s = math.hypot((i + 0.5 - GLOW_W / 2) / rx, (j + 0.5 - GLOW_H / 2) / ry)
            if s <= 0.20:
                a = 0.0
            elif s <= 0.50:
                a = 0.25 * (s - 0.20) / 0.30
            elif s <= 0.85:
                a = 0.25 + (NOTCH_A - 0.25) * (s - 0.50) / 0.35
            else:
                a = NOTCH_A
            px[i, j] = round(a * 255)
    shade = Image.new('RGBA', (GLOW_W, GLOW_H), (0, 0, 0, 0))
    shade.putalpha(over)
    glow.alpha_composite(shade)
    return glow


def tint(art):
    """Bloom's adaptive colour: hue of the art's colourful pixels, saturation 50 %, lightness 15 %."""
    if art is None:
        return ''
    x = y = n = 0.0
    for r, g, b in art.resize((24, 24)).convert('RGB').getdata():
        h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
        if s > 0.25 and v > 0.2:
            x, y, n = x + s * math.cos(h * 2 * math.pi), y + s * math.sin(h * 2 * math.pi), n + s
    if n < 3:
        return ''                                    # black and white art: no tint
    r, g, b = colorsys.hls_to_rgb((math.atan2(y, x) / (2 * math.pi)) % 1, 0.15, 0.5)
    return f'{round(r * 255)},{round(g * 255)},{round(b * 255)}'


def lyrics(title, artist, duration_ms):
    """[(ms, line)] from LRCLIB's synced lyrics, best match first; [] when it has none."""
    if not title:
        return []
    ua = {'User-Agent': 'DynamicIsland-Rainmeter (github.com/itznotnelo/dynamic-island-rainmeter)'}
    q = {'track_name': title, 'artist_name': artist}
    if duration_ms:
        q['duration'] = round(int(duration_ms) / 1000)
    found = None
    for url in ('https://lrclib.net/api/get?' + urllib.parse.urlencode(q),
                'https://lrclib.net/api/search?' + urllib.parse.urlencode({'track_name': title, 'artist_name': artist})):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=ua), timeout=6) as r:
                data = json.loads(r.read())
        except Exception:
            continue
        for d in data if isinstance(data, list) else [data]:
            if isinstance(d, dict) and d.get('syncedLyrics'):
                found = d['syncedLyrics']
                break
        if found:
            break
    out = []
    for line in (found or '').splitlines():
        for m, sec, text in re.findall(r'\[(\d+):(\d+(?:\.\d+)?)\]([^\[]*)$', line) or []:
            out.append((round((int(m) * 60 + float(sec)) * 1000), text.strip()))
    return sorted(out)


def save(img, path):
    tmp = path.with_suffix('.tmp.png')
    img.save(tmp)
    os.replace(tmp, path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('out')
    ap.add_argument('slot')
    ap.add_argument('--title', default='')
    ap.add_argument('--artist', default='')
    ap.add_argument('--duration', default='')
    ap.add_argument('--url', default='')
    a = ap.parse_args()
    out, slot = Path(a.out), a.slot
    try:
        if a.url:
            with urllib.request.urlopen(a.url, timeout=8) as r:
                art = Image.open(io.BytesIO(r.read())).convert('RGB')
        else:
            art = asyncio.run(thumbnail())
    except Exception:
        art = None
    save(compact(art), out / f'Art{slot}S.png')
    save(expanded(art), out / f'Art{slot}L.png')
    save(ambient(art), out / f'Glow{slot}.png')
    (out / f'Color{slot}.txt').write_text(tint(art), encoding='utf-8')
    if a.title:
        lines = lyrics(a.title, a.artist, a.duration)
        (out / f'Lyrics{slot}.txt').write_text(''.join(f'{ms}\t{t}\n' for ms, t in lines), encoding='utf-8')
    return 0 if art is not None else 1


if __name__ == '__main__':
    sys.exit(main())
