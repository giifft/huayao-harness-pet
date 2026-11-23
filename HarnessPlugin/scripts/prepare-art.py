"""Render lightweight web images from the artwork already used by the macOS pet."""
import base64
import io
import json
import re
from pathlib import Path

from PIL import Image

root = Path(__file__).resolve().parents[2]
assets = root / 'Resources' / 'Pets'
source = (root / 'Sources' / 'HuaYaoPet' / 'Assets.swift').read_text(encoding='utf-8')
titles = dict(re.findall(r'"([DHS]\d+)": "([^"]+)"', source))
modes = {'duo': 'D', 'hua': 'H', 'sheng': 'S'}
portraits = {}

for mode, prefix in modes.items():
    portraits[mode] = []
    for path in sorted(assets.glob(f'{mode}_*.png')):
        code = path.stem.split('_')[-1]
        pose_id = f'{prefix}{code[-2:]}'
        img = Image.open(path).convert('RGBA')
        img = img.crop(img.getbbox())
        img.thumbnail((380, 380), Image.Resampling.LANCZOS)
        buffer = io.BytesIO()
        img.save(buffer, format='WEBP', quality=88, method=6)
        src = 'data:image/webp;base64,' + base64.b64encode(buffer.getvalue()).decode('ascii')
        portraits[mode].append({'id': pose_id, 'title': titles[pose_id], 'src': src})

(root / 'HarnessPlugin' / 'src' / 'portraits.generated.json').write_text(
    json.dumps(portraits, ensure_ascii=False), encoding='utf-8')
