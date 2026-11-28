"""Verify the approved portrait files, the native bundle, and Harness encoding."""

import argparse
import base64
import hashlib
import io
import json
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'Resources' / 'Pets'
WEB_SIDE = 560


def visible_bounds(image, threshold):
    return image.convert('RGBA').getchannel('A').point(
        lambda alpha: 255 if alpha >= threshold else 0
    ).getbbox()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check_pngs(directory, manifest):
    files = manifest['files']
    require({path.name for path in directory.glob('*.png')} == files.keys(),
            f'{directory}: portrait filenames do not match the manifest')
    for filename, approved in files.items():
        path = directory / filename
        fingerprint = hashlib.sha256(path.read_bytes()).hexdigest()
        require(fingerprint == approved['sha256'], f'{path}: differs from the approved hy portrait')
        with Image.open(path) as image:
            require(image.size == tuple(manifest['canvas_px']), f'{path}: wrong canvas size')
            bounds = visible_bounds(image, manifest['alpha_threshold_for_anchor'])
        require(bounds == tuple(approved['visible_bounds_px']), f'{path}: visible bounds changed')
        anchor_x, anchor_y = manifest['anchor_px']
        require(bounds[3] == anchor_y and abs((bounds[0] + bounds[2]) / 2 - anchor_x) <= 1,
                f'{path}: visible silhouette is off its anchor')
    print(f'{directory}: {len(files)} approved PNGs passed')


def check_harness(path, manifest):
    modes = {
        'duo': ('D', [f'duo_D{i:02}.png' for i in range(1, 22)]),
        'hua': ('H', [f'hua_H{i:02}.png' for i in range(1, 14)]),
        'sheng': ('S', [f'sheng_{i:02}.png' for i in range(1, 5)]),
    }
    generated = json.loads(path.read_text(encoding='utf-8'))
    require(generated.keys() == modes.keys(), f'{path}: missing or unexpected modes')
    size = (WEB_SIDE, WEB_SIDE)
    threshold = manifest['alpha_threshold_for_anchor']
    for mode, (prefix, filenames) in modes.items():
        poses = generated[mode]
        require([pose['id'] for pose in poses] == [f'{prefix}{i:02}' for i in range(1, len(filenames) + 1)],
                f'{path}: missing, duplicated or out-of-order {mode} portraits')
        for pose, filename in zip(poses, filenames):
            encoded = pose['src'].removeprefix('data:image/webp;base64,')
            with Image.open(io.BytesIO(base64.b64decode(encoded, validate=True))) as web:
                require(web.format == 'WEBP' and web.size == size, f'{pose["id"]}: web canvas changed')
                bounds = visible_bounds(web, threshold)
            with Image.open(SOURCE / filename) as png:
                expected = visible_bounds(png.convert('RGBA').resize(size, Image.Resampling.LANCZOS), threshold)
            require(bounds == expected, f'{pose["id"]}: web silhouette moved, resized or was cropped')
    print(f'{path}: all 38 Harness canvases and alpha bounds passed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native', type=Path, action='append', default=[],
                        help='Pets directory inside a built app or Windows publish output')
    parser.add_argument('--harness', type=Path, help='generated Harness portraits JSON')
    args = parser.parse_args()
    manifest = json.loads((SOURCE / 'portrait-layout.json').read_text(encoding='utf-8'))
    require((manifest['canvas_px'], manifest['anchor_px'], manifest['alpha_threshold_for_anchor'])
            == ([1728, 1728], [864, 1600], 12), 'hy canvas or anchor contract changed')
    expected = ({f'duo_D{i:02}.png' for i in range(1, 22)}
                | {f'hua_H{i:02}.png' for i in range(1, 14)}
                | {f'sheng_{i:02}.png' for i in range(1, 5)})
    require(manifest['files'].keys() == expected, 'portrait manifest must retain the 38 supported poses')
    check_pngs(SOURCE, manifest)
    for directory in args.native:
        check_pngs(directory, manifest)
    if args.harness:
        check_harness(args.harness, manifest)


if __name__ == '__main__':
    main()
