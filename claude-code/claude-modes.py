"""Claude Code hook: "Claude modes" for the Dynamic Island and the GAM-075 keyboard.

Every hook event updates one file per session, then one combined status file:
    ~/.claude/claude-modes/status.json
        state       idle | working | needs_you | done   (the most urgent of all sessions)
        mode        permission mode of that session (default, plan, acceptEdits, auto, ...)
        change      needs_you | done | mode              (last transition worth a popup)
        changed_ms  when that happened
        until_ms    after this the status counts as idle (a session that died silently)
The island's poller (NowPlaying.ps1) reads it every second.

The keyboard only hears about transitions (needs_you, done, clear), because every
lighting change is a write to its flash memory; the GAM-075 app decides what to show.

Never prints anything: stdout of SessionStart/UserPromptSubmit hooks lands in Claude's context.
"""
import json
import os
import sys
import time
import urllib.request
from pathlib import Path

STARTED = time.time()
DIR =Path.home() / '.claude' / 'claude-modes'
SESSIONS = DIR / 'sessions'
STATUS = DIR / 'status.json'
KEYBOARD = 'http://127.0.0.1:7075/api/claude'

RANK = {'idle': 0, 'done': 1, 'working': 2, 'needs_you': 3}
STALE = {'idle': 0, 'done': 10 * 60, 'working': 30 * 60, 'needs_you': 4 * 3600}  # seconds
ASKS_USER = ('AskUserQuestion', 'ExitPlanMode')
PROMPTS = ('permission_prompt', 'elicitation_dialog', 'elicitation_url_dialog', 'agent_needs_input')


def event_state(inp):
    ev = inp.get('hook_event_name')
    if ev == 'SessionStart':
        return 'idle'
    if ev in ('UserPromptSubmit', 'PostToolUse'):
        return 'working'
    if ev == 'PreToolUse':
        return 'needs_you' if inp.get('tool_name') in ASKS_USER else 'working'
    if ev == 'Notification':
        return 'needs_you' if inp.get('notification_type') in PROMPTS else None
    if ev == 'PermissionRequest':
        return 'needs_you'
    if ev == 'Stop':
        return 'done'
    if ev == 'SessionEnd':
        return 'end'
    return None


def read(path, default):
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return default


def write(path, obj):
    tmp = path.with_name(f'{path.name}.{os.getpid()}.tmp')  # sessions can write at once
    tmp.write_text(json.dumps(obj), encoding='utf-8')
    for _ in range(10):
        try:
            return tmp.replace(path)
        except PermissionError:  # Windows: the island is reading it right now
            time.sleep(0.02)
    tmp.replace(path)


def combined(now, keep):
    """Most urgent live session; a tie keeps the session shown so far (`keep`), so two
    sessions working side by side don't make the island flip between them. Stale
    session files are removed."""
    top, best = None, None
    for f in SESSIONS.glob('*.json'):
        s = read(f, None)
        if not s or now - s.get('ts', 0) > STALE.get(s.get('state'), 0):
            f.unlink(missing_ok=True)
            continue
        s['sid'] = f.stem
        key = (RANK[s['state']], f.stem == keep, s['ts'])
        if best is None or key > best:
            top, best = s, key
    return top


def keyboard(event):
    req = urllib.request.Request(KEYBOARD, json.dumps({'event': event}).encode(),
                                 {'Content-Type': 'application/json'})
    try:
        urllib.request.urlopen(req, timeout=0.5).close()
    except OSError:
        pass  # app not running: the island still shows it


def main():
    inp = json.loads(sys.stdin.buffer.read() or b'{}')
    state = event_state(inp)
    sid = ''.join(c for c in str(inp.get('session_id', '')) if c.isalnum() or c == '-')
    if state is None or not sid:
        return
    now = time.time()
    SESSIONS.mkdir(parents=True, exist_ok=True)
    f = SESSIONS / f'{sid}.json'
    old = read(f, {})
    if state == 'end':
        f.unlink(missing_ok=True)
    elif old.get('ts', 0) > STARTED:
        return  # async hooks can finish out of order: a later event already wrote this session
    else:
        mode = inp.get('permission_mode') or old.get('mode') or 'default'
        write(f, {'state': state, 'mode': mode, 'ts': now})

    prev = read(STATUS, {})
    top = combined(now, prev.get('session')) or {'state': 'idle', 'mode': 'default', 'ts': now, 'sid': ''}
    cur = {
        'state': top['state'],
        'mode': top['mode'],
        'session': top['sid'],
        'change': prev.get('change', ''),
        'changed_ms': prev.get('changed_ms', 0),
        'until_ms': int((top['ts'] + STALE[top['state']]) * 1000),
    }
    was = prev.get('state', 'idle')
    change = ''
    if cur['state'] != was and cur['state'] in ('needs_you', 'done'):
        change = cur['state']
    elif (cur['mode'] != prev.get('mode', cur['mode']) and cur['state'] != 'idle'
          and cur['session'] == prev.get('session')):  # a real switch, not another session
        change = 'mode'
    if change:
        cur['change'], cur['changed_ms'] = change, int(now * 1000)
    if cur != prev:
        write(STATUS, cur)

    if cur['state'] != was:
        if cur['state'] in ('needs_you', 'done'):
            keyboard(cur['state'])
        elif was == 'needs_you':
            keyboard('clear')


if __name__ == '__main__':
    try:
        main()
    except Exception:  # a broken widget must never break Claude
        pass
