"""Slow feeds for the Dynamic Island, run by the skin once a minute: python feeds.py

Reads Feeds.local.json next to this file (not in git, every key optional):
    hq_island_url   a Key=Value status endpoint (the author's agent company "HQ"): approvals and
                    questions waiting, incidents, monitors down, the next to-do
    hq_open_url     what the HQ bubble's "Open" button opens
    lat, lon        weather from Open-Meteo (no key needed), refreshed every 15 minutes
Writes Feeds.inc, one Key=Value per line in a fixed order for the skin's WebParser.
"""
import json
import os
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).parent
OUT = HERE / 'Feeds.inc'
WEATHER = HERE / 'Weather.json'
KEYS = ['HqOk', 'Approvals', 'Approval', 'Questions', 'Question', 'Incidents', 'Incident', 'Down',
        'DownNames', 'Todo', 'TodoDue', 'TodoOverdue', 'Temp', 'WxIcon', 'HqUrl']


def get(url, timeout=6):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return r.read().decode('utf-8', 'replace')


def hq(cfg, out):
    url = cfg.get('hq_island_url')
    if not url:
        return
    try:
        for line in get(url).splitlines():
            k, _, v = line.partition('=')
            if k in out:
                out[k] = v
        out['HqOk'] = '1'
    except Exception:
        out['HqOk'] = '0'          # the island hides the HQ bubble instead of showing stale numbers
    out['HqUrl'] = cfg.get('hq_open_url', '')


def icon(code, day):
    """WMO weather code -> one of the island's weather glyphs"""
    if code in (0, 1):
        return 'sun' if day else 'moon'
    if code in (45, 48):
        return 'fog'
    if 51 <= code <= 67 or 80 <= code <= 82:
        return 'rain'
    if 71 <= code <= 77 or code in (85, 86):
        return 'snow'
    if code >= 95:
        return 'bolt'
    return 'cloud'


def weather(cfg, out):
    if 'lat' not in cfg or 'lon' not in cfg:
        return
    try:
        cached = json.loads(WEATHER.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        cached = {}
    if time.time() - cached.get('at', 0) > 15 * 60:
        try:
            url = (f"https://api.open-meteo.com/v1/forecast?latitude={cfg['lat']}&longitude={cfg['lon']}"
                   "&current=temperature_2m,weather_code,is_day&timezone=auto")
            cur = json.loads(get(url))['current']
            cached = {'at': time.time(), 'temp': round(cur['temperature_2m']),
                      'icon': icon(int(cur['weather_code']), cur.get('is_day', 1))}
            WEATHER.write_text(json.dumps(cached), encoding='utf-8')
        except Exception:
            pass                   # keep the last reading
    if 'temp' in cached:
        out['Temp'], out['WxIcon'] = str(cached['temp']), cached['icon']


def main():
    try:
        cfg = json.loads((HERE / 'Feeds.local.json').read_text(encoding='utf-8'))
    except (OSError, ValueError):
        cfg = {}
    out = dict.fromkeys(KEYS, '')
    hq(cfg, out)
    weather(cfg, out)
    text = ''.join(f"{k}={' '.join(out[k].split())}\n" for k in KEYS)
    tmp = OUT.with_suffix('.tmp')
    tmp.write_text(text, encoding='utf-8-sig')
    os.replace(tmp, OUT)


if __name__ == '__main__':
    main()
