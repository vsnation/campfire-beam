#!/usr/bin/env python3
"""Put the Beam girl into Campfire's default theme in place of Firo's Sparky.

    python3 -I scripts/beam/theme/beam_girl_theme.py

Reads asset_sources/default_themes/campfire/light.zip, adds 512 px PNGs made from
the bundled stickers (assets/beam/stickers/static/*.webp) under assets/png/beam_girl/,
points theme.json at them, and rewrites the zip deterministically: existing entries
keep their order, bytes and timestamps; new entries get a fixed timestamp, so running
it twice gives the same file. PNG, not WebP: Campfire's theme widgets render theme
images with Image.file only for paths ending in .png (SVG otherwise).

Where Sparky was, and what replaces him:
  persona_easy       (Choose your experience: Easy)       -> thumbs_up
  persona_incognito  (Choose your experience: Incognito)  -> dont_talk
  stack              (empty wallets / already running)    -> welcome
  stack_icon, coin_placeholder (wallet with coins)        -> send_me_beams
  coins.images/secondaries.beam (Add Beam wallet screen)  -> received_beams
  colors.coin.beam                                        -> Campfire's coin colour (firo)
"""
import io
import json
import pathlib
import zipfile

from PIL import Image

REPO = pathlib.Path(__file__).resolve().parents[3]
ZIP = REPO / 'asset_sources/default_themes/campfire/light.zip'
STICKERS = REPO / 'assets/beam/stickers/static'
FIXED_TIME = (2026, 10, 6, 0, 0, 0)

PLACES = {
    'persona_easy': 'thumbs_up',
    'persona_incognito': 'dont_talk',
    'stack': 'welcome',
    'stack_icon': 'send_me_beams',
    'coin_placeholder': 'send_me_beams',
}
COIN_IMAGE = 'received_beams'


def png_bytes(name: str) -> bytes:
    im = Image.open(STICKERS / f'{name}.webp').convert('RGBA')
    buf = io.BytesIO()
    im.save(buf, format='PNG', optimize=True)
    return buf.getvalue()


def main() -> None:
    src = zipfile.ZipFile(ZIP)
    infos = src.infolist()
    theme = json.loads(src.read('theme.json'))
    assets = theme['assets']
    for key, sticker in PLACES.items():
        assets[key] = f'png/beam_girl/{sticker}.png'
    assets['coins']['images']['beam'] = f'png/beam_girl/{COIN_IMAGE}.png'
    assets['coins']['secondaries']['beam'] = f'png/beam_girl/{COIN_IMAGE}.png'
    # Keep Campfire's own look. BEAM's brand teal clashed with
    # Campfire's warm palette on the balance card and everything else tinted by
    # the coin colour, so BEAM takes the colour Campfire gives its own coin.
    theme['colors']['coin']['beam'] = theme['colors']['coin']['firo']

    needed = sorted(set(PLACES.values()) | {COIN_IMAGE})
    new_files = {f'assets/png/beam_girl/{n}.png': png_bytes(n) for n in needed}

    out = io.BytesIO()
    with zipfile.ZipFile(out, 'w') as dst:
        for info in infos:
            if info.filename in new_files:
                continue
            data = (json.dumps(theme, indent=2, ensure_ascii=False) + '\n').encode() \
                if info.filename == 'theme.json' else src.read(info)
            dst.writestr(info, data, compress_type=info.compress_type)
        for name in sorted(new_files):
            zi = zipfile.ZipInfo(name, FIXED_TIME)
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = 0o644 << 16
            dst.writestr(zi, new_files[name])
    src.close()
    ZIP.write_bytes(out.getvalue())
    print(f'{ZIP.relative_to(REPO)}: {len(new_files)} Beam girl images, '
          f'{len(out.getvalue()) // 1024} KB')


if __name__ == '__main__':
    main()
