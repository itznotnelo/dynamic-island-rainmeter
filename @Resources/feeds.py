"""Slow feeds for the Dynamic Island.
    pythonw feeds.py loop     what the skin starts: one copy, refreshes every 30 s, quits with Rainmeter
    python feeds.py           one refresh
Actions from the island (then the feed is refreshed at once):
    python feeds.py act answer <question id> <option index>
    python feeds.py act pomo <minutes>
    python feeds.py act toggle <entity id>
    python feeds.py act media <play_pause|next|previous>     music playing on the phone
    python feeds.py act chore <id>                            today's chore done
    python feeds.py act push                                  the clipboard's text to the phone

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
TEST = HERE / 'FeedsTest.json'      # `feeds.py test`: made-up alerts for 5 minutes, to try them on the island
STATE = HERE / 'FeedsState.json'     # what was already handled: phone-music cover, shop alarm flash
KEYS = ['HqOk', 'Approvals', 'Approval', 'Questions', 'Question', 'Incidents', 'Incident', 'Down',
        'DownNames', 'Todo', 'TodoDue', 'TodoOverdue', 'Temp', 'WxIcon', 'HqUrl', 'Leave', 'LeaveFor',
        'LeaveIn', 'NextDep', 'Bill', 'BillIn', 'Birthday', 'BirthdayIn', 'Countdowns', 'FocusWeek',
        'QuestionId', 'QuestionOptions', 'Home', 'Shift', 'ShiftIn', 'Wear', 'Tomorrow', 'SpotifyTitle',
        'SpotifyArtist', 'SpotifyState', 'SpotifyArt', 'SpotifyPos', 'SpotifyDur', 'SpotifyDevice', 'Money',
        'ShopAlarm', 'ShopAlarmAt', 'Upload', 'UploadAt', 'Word', 'WordMeaning', 'PRs', 'PR', 'Followers',
        'FollowersDelta', 'Chore', 'ChoreId', 'Briefing', 'BriefingDate', 'Events', 'PiholeBlocked', 'RainIn',
        'SpotifySlot']


def get(url, timeout=6, method='GET'):
    req = urllib.request.Request(url, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode('utf-8', 'replace')


def clipboard_text():
    """The clipboard's text (Windows, no extra packages)."""
    import ctypes
    from ctypes import wintypes
    u32, k32 = ctypes.windll.user32, ctypes.windll.kernel32
    u32.GetClipboardData.restype = k32.GlobalLock.restype = ctypes.c_void_p
    k32.GlobalLock.argtypes = k32.GlobalUnlock.argtypes = [ctypes.c_void_p]
    if not u32.OpenClipboard(None):
        return ''
    try:
        h = u32.GetClipboardData(13)                     # CF_UNICODETEXT
        if not h:
            return ''
        p = k32.GlobalLock(h)
        try:
            return ctypes.wstring_at(p) if p else ''
        finally:
            k32.GlobalUnlock(h)
    finally:
        u32.CloseClipboard()


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
    elif what == 'media' and args[0] in ('play_pause', 'next', 'previous'):
        q.update(do='media', cmd=args[0])
    elif what == 'chore':
        q.update(do='chore', id=args[0])
    elif what == 'push':
        text = clipboard_text().strip()[:1000]
        if not text:
            return
        q.update(do='push', text=text)
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


def rain(cfg, out):
    """Minutes until rain starts, when it's dry now and rain comes within 45 minutes (15-min steps)."""
    try:
        cached = json.loads(WEATHER.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        cached = {}
    if time.time() - cached.get('rain_at', 0) > 5 * 60:
        try:
            url = (f"https://api.open-meteo.com/v1/forecast?latitude={cfg['lat']}&longitude={cfg['lon']}"
                   "&minutely_15=precipitation&forecast_minutely_15=4&current=precipitation&timezone=auto")
            d = json.loads(get(url))
            now_wet = (d.get('current') or {}).get('precipitation', 0) >= 0.1
            slots = (d.get('minutely_15') or {}).get('precipitation') or []
            first = next((i for i, v in enumerate(slots) if v and v >= 0.1), None)
            cached.update(rain_at=time.time(), rain_in='' if now_wet or first is None else str(first * 15))
            WEATHER.write_text(json.dumps(cached), encoding='utf-8')
        except Exception:
            pass
    out['RainIn'] = cached.get('rain_in', '')


def phone_music(out, state):
    """Cover, tint and lyrics for music playing on the phone (Spotify through HQ), once per track."""
    if out.get('SpotifyState') != 'playing' or not out.get('SpotifyTitle'):
        out['SpotifySlot'] = state.get('phone_slot', '')
        return
    key = out['SpotifyTitle'] + '|' + out['SpotifyArtist']
    if state.get('phone_key') != key:
        slot = 'P1' if state.get('phone_slot') == 'P0' else 'P0'
        import subprocess
        subprocess.run([sys.executable, str(HERE / 'cover.py'), str(HERE), slot, '--url', out.get('SpotifyArt', ''),
                        '--title', out['SpotifyTitle'], '--artist', out['SpotifyArtist'],
                        '--duration', out.get('SpotifyDur', '')], timeout=40, creationflags=0x08000000)
        state.update(phone_key=key, phone_slot=slot)
    out['SpotifySlot'] = state['phone_slot']


def shop_flash(out, state):
    """A new shop alarm also flashes the keyboard red (the GAM-075 app on this PC)."""
    at = out.get('ShopAlarmAt', '')
    if at and at != state.get('shop_at'):
        if state.get('shop_at') is not None:     # not on the very first run
            try:
                req = urllib.request.Request('http://127.0.0.1:7075/api/test-notify', b'{"color": "#ff0000"}',
                                             {'Content-Type': 'application/json'})
                urllib.request.urlopen(req, timeout=2).close()
            except Exception:
                pass
        state['shop_at'] = at
    state.setdefault('shop_at', at)


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


def config():
    try:
        return json.loads((HERE / 'Feeds.local.json').read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return {}


def refresh(cfg):
    out = dict.fromkeys(KEYS, '')
    hq(cfg, out)
    weather(cfg, out)
    if 'lat' in cfg and 'lon' in cfg:
        rain(cfg, out)
    try:
        state = json.loads(STATE.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        state = {}
    try:
        phone_music(out, state)
    except Exception:
        pass
    shop_flash(out, state)
    try:
        test = json.loads(TEST.read_text(encoding='utf-8'))
        if time.time() < test['until']:
            out.update(test['values'])
        else:
            TEST.unlink()
    except (OSError, ValueError, KeyError):
        pass
    STATE.write_text(json.dumps(state), encoding='utf-8')
    text = ''.join(f"{k}={' '.join(out[k].split())}\n" for k in KEYS)
    try:
        if OUT.read_text(encoding='utf-8-sig') == text:
            return                     # unchanged: no disk write
    except OSError:
        pass
    tmp = OUT.with_suffix(f'.{os.getpid()}.tmp')
    tmp.write_text(text, encoding='utf-8-sig')
    for _ in range(10):
        try:
            return os.replace(tmp, OUT)
        except PermissionError:        # the skin is reading it right now
            time.sleep(0.05)
    tmp.unlink(missing_ok=True)


def rainmeter_running():
    import subprocess
    out = subprocess.run(['tasklist', '/FI', 'IMAGENAME eq Rainmeter.exe', '/NH'], capture_output=True, text=True,
                         creationflags=0x08000000).stdout             # CREATE_NO_WINDOW
    return 'rainmeter.exe' in out.lower()


def loop():
    import ctypes
    k32 = ctypes.windll.kernel32
    k32.CreateMutexW(None, False, 'DynamicIsland-feeds')
    if k32.GetLastError() == 183:      # ERROR_ALREADY_EXISTS: another copy runs
        return
    n = 0
    while n % 10 or rainmeter_running():    # ask about Rainmeter every 5 minutes
        n += 1
        try:
            refresh(config())
        except Exception:
            pass                       # a network hiccup: the next round tries again
        time.sleep(30)


def home_state(entity):
    """A Home tile's state as Feeds.inc has it right now ('' when it isn't there)."""
    try:
        for line in OUT.read_text(encoding='utf-8-sig').splitlines():
            if line.startswith('Home='):
                for item in line[5:].split(';'):
                    e, _, rest = item.partition('|')
                    if e == entity:
                        return rest.rpartition('|')[2]
    except OSError:
        pass
    return ''


def test_mode():
    """Shift, shop and upload alerts at once, plus a question and a chore to tap (fake ids: HQ ignores them)."""
    now = time.strftime('%Y-%m-%dT%H:%M:%S')
    TEST.write_text(json.dumps({'until': time.time() + 300, 'values': {
        'Shift': 'TEST shift 17:00', 'ShiftIn': '30', 'Wear': 'black shirt',
        'ShopAlarm': 'TEST order waiting', 'ShopAlarmAt': now,
        'Upload': 'TEST photo.jpg -> Nextcloud', 'UploadAt': now,
        'Questions': '1', 'Question': 'TEST: does answering work?', 'QuestionId': 'test', 'QuestionOptions': 'Yes || No',
        'Chore': 'TEST chore', 'ChoreId': 'test'}}), encoding='utf-8')


def main():
    if sys.argv[1:2] == ['loop']:
        return loop()
    if sys.argv[1:2] == ['test']:
        test_mode()
    cfg = config()
    if sys.argv[1:2] == ['act'] and len(sys.argv) > 2:
        toggled = sys.argv[3] if sys.argv[2] == 'toggle' and len(sys.argv) > 3 else None
        before = home_state(toggled) if toggled else None
        try:
            act(cfg, sys.argv[2], sys.argv[3:])
        except Exception:
            toggled = None             # the refreshed feed shows whether it worked
        if toggled:                    # a switch takes a moment: look again until it flipped (at most ~6 s)
            for _ in range(8):
                refresh(cfg)
                if home_state(toggled) != before:
                    return
                time.sleep(0.75)
            return
    refresh(cfg)


if __name__ == '__main__':
    main()
