"""DJ mode for the Dynamic Island (optional): while Mixxx runs, ask its ClaudeDJ controller mapping
for both decks every 2 seconds over the ClaudeDJ MIDI port and write DjState.inc for the skin.

The mapping answers "STATUS" with: deck, loaded, duration, position, play, bpm, crossfader, volume.
Track names come from Mixxx's own library (matched by duration). Started by the skin with pythonw;
one copy at a time, and it quits when Rainmeter does. Needs: pip install mido python-rtmidi
"""
import ctypes
import os
import sqlite3
import sys
import time
from ctypes import wintypes
from pathlib import Path

HERE = Path(__file__).parent
OUT = HERE / 'DjState.inc'
PORT = 'ClaudeDJ'
LIBRARY = Path(os.environ.get('LOCALAPPDATA', '')) / 'Mixxx' / 'mixxxdb.sqlite'
KEYS = ['DjOn', 'Xf'] + [f'{d}{k}' for d in 'AB' for k in ('Loaded', 'Title', 'Artist', 'Bpm', 'Play', 'Pos', 'Vol')]

k32 = ctypes.windll.kernel32


class PE(ctypes.Structure):
    _fields_ = [('dwSize', wintypes.DWORD), ('cntUsage', wintypes.DWORD), ('th32ProcessID', wintypes.DWORD),
                ('th32DefaultHeapID', ctypes.c_void_p), ('th32ModuleID', wintypes.DWORD),
                ('cntThreads', wintypes.DWORD), ('th32ParentProcessID', wintypes.DWORD),
                ('pcPriClassBase', ctypes.c_long), ('dwFlags', wintypes.DWORD), ('szExeFile', ctypes.c_wchar * 260)]


k32.CreateToolhelp32Snapshot.restype = ctypes.c_void_p
k32.Process32FirstW.argtypes = k32.Process32NextW.argtypes = [ctypes.c_void_p, ctypes.POINTER(PE)]
k32.CloseHandle.argtypes = [ctypes.c_void_p]


def processes():
    snap = k32.CreateToolhelp32Snapshot(2, 0)
    pe, names = PE(), set()
    pe.dwSize = ctypes.sizeof(PE)
    ok = k32.Process32FirstW(snap, ctypes.byref(pe))
    while ok:
        names.add(pe.szExeFile.lower())
        ok = k32.Process32NextW(snap, ctypes.byref(pe))
    k32.CloseHandle(snap)
    return names


_last = None


def write(state):
    global _last
    text = ''.join(f"{k}={' '.join(str(state.get(k, '')).split())}\n" for k in KEYS)
    if text == _last:
        return                         # unchanged: no disk write
    tmp = OUT.with_suffix('.tmp')
    tmp.write_text(text, encoding='utf-8-sig')
    try:
        os.replace(tmp, OUT)
        _last = text
    except PermissionError:            # the skin is reading it right now: next round
        pass


names_cache = {}


def track(duration):
    """(artist, title) of the library track with this duration, or blanks."""
    key = round(duration, 1)
    if key not in names_cache:
        names_cache[key] = ('', '')
        try:
            with sqlite3.connect(f'file:{LIBRARY}?mode=ro', uri=True, timeout=1) as db:
                row = db.execute('SELECT artist, title FROM library WHERE abs(duration - ?) < 0.06 AND mixxx_deleted = 0 '
                                 'ORDER BY timesplayed DESC LIMIT 1', (duration,)).fetchone()
            if row:
                names_cache[key] = (row[0] or '', row[1] or '')
        except sqlite3.Error:
            pass
    return names_cache[key]


def poll(mido, seq):
    """One round: open the port, ask for STATUS, read the replies for 0.5 s, close it again.
    The port is never held between rounds (dj live opens it when a show starts), and only
    STATUS is ever sent on it."""
    pin = next((n for n in mido.get_input_names() if n.startswith(PORT)), None)
    pout = next((n for n in mido.get_output_names() if n.startswith(PORT)), None)
    if not pin or not pout:
        return None
    try:
        inp, out = mido.open_input(pin), mido.open_output(pout)
    except (OSError, IOError):
        return None                             # busy: skip this round
    try:
        out.send(mido.Message('sysex', data=[0x7D, 0x01] + [ord(c) & 0x7F for c in f'i{seq} STATUS']))
        state, end = {'DjOn': 1}, time.time() + 0.5
        while time.time() < end:
            m = inp.poll()
            if m is None:
                time.sleep(0.01)
                continue
            if m.type != 'sysex' or list(m.data[:2]) != [0x7D, 0x02]:
                continue
            f = bytes(m.data[2:]).decode('ascii', 'replace').split()
            if len(f) >= 7 and f[0] == 'STATUS' and f[1] in ('1', '2'):
                d = 'A' if f[1] == '1' else 'B'
                loaded, dur, pos = float(f[2]) > 0, float(f[3]), float(f[4])
                artist, title = track(dur) if loaded and dur > 0 else ('', '')
                state.update({f'{d}Loaded': int(loaded), f'{d}Title': title, f'{d}Artist': artist,
                              f'{d}Bpm': round(float(f[6])), f'{d}Play': int(float(f[5]) > 0),
                              f'{d}Pos': round(pos / dur, 4) if dur > 0 else 0,
                              f'{d}Vol': f[8] if len(f) > 8 else ''})
                if len(f) > 7:
                    state['Xf'] = f[7]
        return state if ('ALoaded' in state or 'BLoaded' in state) else None
    finally:
        inp.close()
        out.close()


def main():
    k32.CreateMutexW(None, False, 'DynamicIsland-djstate')
    if ctypes.GetLastError() == 183:          # ERROR_ALREADY_EXISTS: another copy runs
        return
    import mido
    seq, last = 0, None
    while True:
        procs = processes()
        if 'rainmeter.exe' not in procs:
            return
        state = None
        if 'mixxx.exe' in procs:
            seq += 1                            # "i" seqs never equal dj live's numeric ones
            try:
                state = poll(mido, seq)
            except (OSError, IOError, ValueError):
                state = None
        state = state or {'DjOn': 0}            # Mixxx closed, or its ClaudeDJ mapping didn't answer
        if state != last:
            write(state)
            last = state
        time.sleep(2 if 'mixxx.exe' in procs else 3)


if __name__ == '__main__':
    try:
        main()
    except Exception:
        sys.exit(1)
