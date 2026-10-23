"""Slow feeds for the Dynamic Island, run by the skin once a minute: python feeds.py
Actions from the island (then the feed is refreshed at once):
    python feeds.py act answer <question id> <option index>
    python feeds.py act pomo <minutes>
    python feeds.py act toggle <entity id>

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
import sys
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).parent
OUT = HERE / 'Feeds.inc'
WEATHER = HERE / 'Weather.json'
KEYS = ['HqOk', 'Approvals', 'Approval', 'Questions', 'Question', 'Incidents', 'Incident', 'Down',
        'DownNames', 'Todo', 'TodoDue', 'TodoOverdue', 'Temp', 'WxIcon', 'HqUrl', 'Leave', 'LeaveFor',
        'LeaveIn', 'NextDep', 'Bill', 'BillIn', 'Birthday', 'BirthdayIn', 'Countdowns', 'FocusWeek',
        'QuestionId', 'QuestionOptions', 'Home']


def get(url, timeout=6, method='GET'):
    req = urllib.request.Request(url, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode('utf-8', 'replace')


def act(cfg, what, args):
    """POST an island action to the status endpoint's /act sibling (same token)."""
    url = cfg.get('hq_island_url')
    if not url:
        return
    u = urllib.parse.urlsplit(url)
    q = {k: v for k, v in urllib.parse.parse_qsl(u.query) if k != 'fmt'}
    if what == 'answer':          # the option's full text comes from the JSON view, not the clipped feed line
        info = json.loads(get(urllib.parse.urlunsplit(u._replace(query=urllib.parse.urlencode(q)))))
        qq, opts = info.get('question') or {}, info.get('question_options') or []
        if str(qq.get('id')) != args[0] or not 0 <= int(args[1]) < len(opts):
            return                    # the question changed meanwhile: do nothing
        q.update(do='answer', id=args[0], answer=opts[int(args[1])])
    elif what == 'pomo':
        q.update(do='pomo', minutes=args[0])
    elif what == 'toggle':
        q.update(do='toggle', entity=args[0])
    else:
        return
    get(urllib.parse.urlunsplit(u._replace(path=u.path.rstrip('/') + '/act', query=urllib.parse.urlencode(q))),
        method='POST')


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
    if sys.argv[1:2] == ['act'] and len(sys.argv) > 3:
        try:
            act(cfg, sys.argv[2], sys.argv[3:])
        except Exception:
            pass                       # the refreshed feed shows whether it worked
    out = dict.fromkeys(KEYS, '')
    hq(cfg, out)
    weather(cfg, out)
    text = ''.join(f"{k}={' '.join(out[k].split())}\n" for k in KEYS)
    tmp = OUT.with_suffix('.tmp')
    tmp.write_text(text, encoding='utf-8-sig')
    os.replace(tmp, OUT)


if __name__ == '__main__':
    main()
