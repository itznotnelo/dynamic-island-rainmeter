"""PC state for the Dynamic Island. Runs in the background (pythonw, one copy, quits with Rainmeter)
and writes PcState.inc every 2 seconds:
    Game        1 while a fullscreen app (game, fullscreen video) is in front: the island hides
    MicApp      the app using the microphone right now (Discord, Teams, ...) and MicSince (epoch s)
    MicMuted    the default microphone's mute
    Screen*     today's screen time (only while you're at the PC) and the top 3 apps
    Gpu*        temperature and load from nvidia-smi
    Net, Ping   internet reachable, and the time to connect to 1.1.1.1 in ms
    Rec         1 while Mixxx records a set (its newest recording is still growing), RecSince
Usage:  pythonw pcstate.py          the loop
        python pcstate.py micmute   toggle the microphone's mute
Needs pycaw for the microphone (pip install pycaw); everything else is the standard library.
"""
import ctypes
import json
import os
import socket
import subprocess
import sys
import time
import winreg
from ctypes import wintypes
from datetime import date
from pathlib import Path

HERE = Path(__file__).parent
OUT = HERE / 'PcState.inc'
SCREEN = HERE / 'ScreenTime.json'
RECORDINGS = Path.home() / 'Music' / 'Mixxx' / 'Recordings'
KEYS = ['Game', 'MicApp', 'MicSince', 'MicMuted', 'ScreenToday', 'ScreenTop', 'GpuTemp', 'GpuLoad', 'Net', 'Ping',
        'Rec', 'RecSince']
NICE = {'code': 'VS Code', 'chrome': 'Chrome', 'msedge': 'Edge', 'firefox': 'Firefox', 'windowsterminal': 'Terminal',
        'mixxx': 'Mixxx', 'discord': 'Discord', 'explorer': 'Explorer', 'spotify': 'Spotify', 'winword': 'Word',
        'excel': 'Excel', 'powerpnt': 'PowerPoint', 'osu!': 'osu!', 'helium': 'Helium', 'ms-teams': 'Teams',
        'claude': 'Claude'}
NO_WINDOW = 0x08000000

k32, u32, shell32 = ctypes.windll.kernel32, ctypes.windll.user32, ctypes.windll.shell32
k32.OpenProcess.restype = wintypes.HANDLE
k32.CloseHandle.argtypes = [wintypes.HANDLE]
k32.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]


class PE(ctypes.Structure):
    _fields_ = [('dwSize', wintypes.DWORD), ('cntUsage', wintypes.DWORD), ('th32ProcessID', wintypes.DWORD),
                ('th32DefaultHeapID', ctypes.c_void_p), ('th32ModuleID', wintypes.DWORD),
                ('cntThreads', wintypes.DWORD), ('th32ParentProcessID', wintypes.DWORD),
                ('pcPriClassBase', ctypes.c_long), ('dwFlags', wintypes.DWORD), ('szExeFile', ctypes.c_wchar * 260)]


class LASTINPUT(ctypes.Structure):
    _fields_ = [('cbSize', wintypes.UINT), ('dwTime', wintypes.DWORD)]


k32.CreateToolhelp32Snapshot.restype = ctypes.c_void_p
k32.Process32FirstW.argtypes = k32.Process32NextW.argtypes = [ctypes.c_void_p, ctypes.POINTER(PE)]


def rainmeter_running():
    snap = k32.CreateToolhelp32Snapshot(2, 0)
    pe = PE()
    pe.dwSize = ctypes.sizeof(PE)
    ok, found = k32.Process32FirstW(snap, ctypes.byref(pe)), False
    while ok and not found:
        found = pe.szExeFile.lower() == 'rainmeter.exe'
        ok = k32.Process32NextW(snap, ctypes.byref(pe))
    k32.CloseHandle(ctypes.c_void_p(snap))
    return found


def game_mode():
    """SHQueryUserNotificationState: 2 busy (fullscreen app), 3 Direct3D fullscreen, 4 presentation."""
    state = ctypes.c_int(0)
    shell32.SHQueryUserNotificationState(ctypes.byref(state))
    return int(state.value in (2, 3, 4))


def idle_seconds():
    li = LASTINPUT()
    li.cbSize = ctypes.sizeof(LASTINPUT)
    u32.GetLastInputInfo(ctypes.byref(li))
    return (k32.GetTickCount() - li.dwTime) / 1000


def foreground_app():
    pid = wintypes.DWORD()
    u32.GetWindowThreadProcessId(u32.GetForegroundWindow(), ctypes.byref(pid))
    h = k32.OpenProcess(0x1000, False, pid.value)         # PROCESS_QUERY_LIMITED_INFORMATION
    if not h:
        return ''
    try:
        buf, n = ctypes.create_unicode_buffer(520), wintypes.DWORD(520)
        return Path(buf.value).stem.lower() if k32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(n)) else ''
    finally:
        k32.CloseHandle(h)


def mic_user():
    """(app, since) of the app holding the microphone, from Windows' privacy records."""
    base = r'Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone'
    best = ('', 0)

    def check(key, name):
        nonlocal best
        try:
            stop = winreg.QueryValueEx(key, 'LastUsedTimeStop')[0]
            start = winreg.QueryValueEx(key, 'LastUsedTimeStart')[0]
        except OSError:
            return
        if stop == 0 and start > 0:
            since = start / 1e7 - 11644473600
            if since > best[1]:
                best = (name, since)

    try:
        root = winreg.OpenKey(winreg.HKEY_CURRENT_USER, base)
    except OSError:
        return best
    with root:
        for i in range(winreg.QueryInfoKey(root)[0]):
            sub = winreg.EnumKey(root, i)
            with winreg.OpenKey(root, sub) as k:
                if sub == 'NonPackaged':
                    for j in range(winreg.QueryInfoKey(k)[0]):
                        path = winreg.EnumKey(k, j)
                        with winreg.OpenKey(k, path) as kk:
                            stem = path.split('#')[-1].rsplit('.', 1)[0].lower()
                            check(kk, NICE.get(stem, stem.title()))
                else:
                    check(k, 'Teams' if 'teams' in sub.lower() else sub.split('.')[1] if '.' in sub else sub)
    return best


def mic_volume():
    from ctypes import POINTER, cast
    import comtypes
    from comtypes import CLSCTX_ALL
    from pycaw.pycaw import AudioUtilities, IAudioEndpointVolume
    comtypes.CoInitialize()
    mic = AudioUtilities.GetMicrophone()
    return cast(mic.Activate(IAudioEndpointVolume._iid_, CLSCTX_ALL, None), POINTER(IAudioEndpointVolume))


def gpu():
    try:
        out = subprocess.run(['nvidia-smi', '--query-gpu=temperature.gpu,utilization.gpu',
                              '--format=csv,noheader,nounits'], capture_output=True, text=True, timeout=5,
                             creationflags=NO_WINDOW).stdout.split(',')
        return out[0].strip(), out[1].strip()
    except (OSError, IndexError, subprocess.SubprocessError):
        return '', ''


def internet():
    for host, port in (('1.1.1.1', 443), ('8.8.8.8', 53)):
        t = time.perf_counter()
        try:
            socket.create_connection((host, port), timeout=2).close()
            return 1, round((time.perf_counter() - t) * 1000)
        except OSError:
            continue
    return 0, ''


def recording():
    try:
        wav = max(RECORDINGS.glob('*.wav'), key=lambda p: p.stat().st_mtime)
    except (ValueError, OSError):
        return 0, ''
    st = wav.stat()
    return (1, int(st.st_ctime)) if time.time() - st.st_mtime < 4 else (0, '')


def fmt(seconds):
    m = int(seconds // 60)
    return f'{m // 60} h {m % 60:02d}' if m >= 60 else f'{m} min'


def write(state):
    text = ''.join(f"{k}={' '.join(str(state.get(k, '')).split())}\n" for k in KEYS)
    tmp = OUT.with_suffix('.tmp')
    tmp.write_text(text, encoding='utf-8-sig')
    os.replace(tmp, OUT)


def main():
    k32.CreateMutexW(None, False, 'DynamicIsland-pcstate')
    if ctypes.GetLastError() == 183:          # ERROR_ALREADY_EXISTS: another copy runs
        return
    try:
        screen = json.loads(SCREEN.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        screen = {}
    try:
        vol = mic_volume()
    except Exception:
        vol = None
    tick, gpu_t, net, last = 0, ('', ''), (1, ''), None
    while rainmeter_running():
        today = date.today().isoformat()
        if screen.get('day') != today:
            screen = {'day': today, 'apps': {}}
        if idle_seconds() < 120:              # only while someone is at the PC
            app = foreground_app()
            if app:
                screen['apps'][app] = screen['apps'].get(app, 0) + 2
        if tick % 5 == 0:
            gpu_t = gpu()
        if tick % 8 == 0:
            net = internet()
        if tick % 30 == 0:
            SCREEN.write_text(json.dumps(screen), encoding='utf-8')
        app, since = mic_user()
        top = sorted(screen['apps'].items(), key=lambda kv: -kv[1])[:3]
        try:
            muted = int(vol.GetMute()) if vol else ''
        except Exception:
            muted = ''
        rec, rec_since = recording()
        state = {'Game': game_mode(), 'MicApp': app, 'MicSince': int(since) if since else '', 'MicMuted': muted,
                 'ScreenToday': int(sum(screen['apps'].values()) // 60),
                 'ScreenTop': ', '.join(f'{NICE.get(a, a.title())} {fmt(s)}' for a, s in top),
                 'GpuTemp': gpu_t[0], 'GpuLoad': gpu_t[1], 'Net': net[0], 'Ping': net[1],
                 'Rec': rec, 'RecSince': rec_since}
        if state != last:
            write(state)
            last = state
        tick += 1
        time.sleep(2)
    SCREEN.write_text(json.dumps(screen), encoding='utf-8')


if __name__ == '__main__':
    if sys.argv[1:2] == ['micmute']:
        v = mic_volume()
        v.SetMute(0 if v.GetMute() else 1, None)
    else:
        try:
            main()
        except Exception:
            sys.exit(1)
