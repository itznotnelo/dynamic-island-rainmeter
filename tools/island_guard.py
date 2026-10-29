"""Keeps the Dynamic Island running. Task Scheduler starts it with pythonw every 10 minutes and at logon
(install it once with install-guard.ps1):
  - Rainmeter isn't running: start it
  - the island isn't loaded (Rainmeter.ini says [DynamicIsland] Active=0): load it
  - it's loaded but its poller (NowPlaying.ps1) was gone at two checks in a row: refresh the skin,
    which starts its helpers again
A file named guard.off next to this script pauses it (for when you close Rainmeter on purpose).
Each fix is written to guard.log next to this script (the last 200 lines are kept).
"""
import ctypes
import os
import subprocess
import time
from pathlib import Path

HERE = Path(__file__).parent
LOG = HERE / 'guard.log'
STATE = HERE / 'guard.state'
INI = Path(os.environ.get('APPDATA', '')) / 'Rainmeter' / 'Rainmeter.ini'
EXE = Path(os.environ.get('ProgramFiles', r'C:\Program Files')) / 'Rainmeter' / 'Rainmeter.exe'
NO_WINDOW = 0x08000000


def log(text):
    lines = LOG.read_text(encoding='utf-8').splitlines()[-199:] if LOG.exists() else []
    lines.append(time.strftime('%Y-%m-%d %H:%M ') + text)
    LOG.write_text('\n'.join(lines) + '\n', encoding='utf-8')


def rainmeter_running():
    out = subprocess.run(['tasklist', '/FI', 'IMAGENAME eq Rainmeter.exe', '/NH'], capture_output=True, text=True,
                         creationflags=NO_WINDOW).stdout
    return 'rainmeter.exe' in out.lower()


def island_active():
    """Active= of [DynamicIsland] in Rainmeter.ini (UTF-16 or UTF-8); None when it can't be read."""
    try:
        raw = INI.read_bytes()
    except OSError:
        return None
    text = raw.decode('utf-16') if raw[:2] in (b'\xff\xfe', b'\xfe\xff') else raw.decode('utf-8', 'replace')
    section = None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith('['):
            section = line.strip('[]').lower()
        elif section == 'dynamicisland' and line.lower().startswith('active='):
            return line.split('=', 1)[1].strip() != '0'
    return False


def poller_running():
    k32 = ctypes.windll.kernel32
    h = k32.OpenMutexW(0x00100000, False, 'DynamicIsland-nowplaying')   # SYNCHRONIZE
    if h:
        k32.CloseHandle(h)
    return bool(h)


def bang(*args):
    subprocess.Popen([str(EXE), *args], creationflags=NO_WINDOW)


def main():
    if (HERE / 'guard.off').exists() or not EXE.exists():
        return
    if not rainmeter_running():
        log('Rainmeter was not running: started it')
        subprocess.Popen([str(EXE)], creationflags=NO_WINDOW)
        time.sleep(20)                 # let it load its skins before looking at the island
        if not rainmeter_running():
            return
    if island_active() is False:
        log('the island was not loaded: loaded it')
        bang('!ActivateConfig', 'DynamicIsland', 'DynamicIsland.ini')
        STATE.write_text('0', encoding='utf-8')
        return
    misses = int(STATE.read_text(encoding='utf-8') or 0) if STATE.exists() else 0
    misses = 0 if poller_running() else misses + 1
    if misses >= 2:
        log('the poller was gone twice in a row: refreshed the island')
        bang('!Refresh', 'DynamicIsland')
        misses = 0
    STATE.write_text(str(misses), encoding='utf-8')


if __name__ == '__main__':
    try:
        main()
    except Exception as e:             # never pop up anything: just note it
        log(f'guard error: {e.__class__.__name__}: {e}')
