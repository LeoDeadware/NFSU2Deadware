#!/usr/bin/env python3
"""Runs a heavy command and freezes it while the owner plays a game from the Desktop.

  tools/owner_pause.py -- <cmd> [args...]
  tools/owner_pause.py --wait            block until no game from ~/Desktop runs (before a step that cannot be frozen)

The command runs in its own process group. Every POLL seconds the watcher looks for a game started from
~/Desktop (pattern below, Head of Deadware 2026-11-07): when one appears, SIGSTOP goes to the whole group plus
any descendant that left it; when no game is left, SIGCONT. The owner can start a game at any time without
heavy work spoiling a measurement. SIGINT/SIGTERM to the watcher resume the group and pass the signal on.
Exit status is the command's. If a game already runs, the command does not start until it closes.
Nested calls pass through (DEADWARE_OWNER_PAUSE is set for the command): lock.py heavy/perf, make_dmg.sh and
install_dmg.sh's e2e all use it, so no session has to remember it (Head of Deadware 2026-11-07, from BFME d45357e).
A game the job runs itself never pauses it: its descendants are ignored, and a game started via `open -n`
(launchd's child) is registered before launch with `owner_pause.py --mine <app path>` (or a PID; no-op outside a watcher). Better still, keep
app_smoke and the install onto the Desktop out of heavy.sh: they ARE the owner's game / wait for it themselves.

Env: DEADWARE_GAME_PATTERN (pgrep -f regex), DEADWARE_PAUSE_POLL (seconds, default 3),
DEADWARE_PAUSE_ALSO (pgrep -f regex of processes the command started outside its family, e.g. a game `open -n` hands
to launchd: frozen too), DEADWARE_PAUSE_MARK (file: one line per pause, so a timed run knows its numbers are not
evidence) — both from NFSU2Port 50e803c. A nested call passes through unless it brings its own ALSO/MARK (then it
watches too). The child gets DEADWARE_OWNER_PAUSE=<pid> and DEADWARE_OWNER_PAUSED=1.
Standalone (stdlib only) so other ports can copy it as is.
"""
import os
import signal
import subprocess
import sys
import time

PATTERN = os.environ.get("DEADWARE_GAME_PATTERN",
                         r"^" + os.path.expanduser("~") + r"/Desktop/[^/]*\.app/Contents/MacOS/")
POLL = float(os.environ.get("DEADWARE_PAUSE_POLL", "3"))


def mine_files():
    """Every watcher above this process keeps one; --mine writes to all of them."""
    return [f for f in os.environ.get("DEADWARE_OWNER_PAUSE_MINE", "").split(os.pathsep) if f]


def mine_file():
    return (mine_files() or [""])[-1]


apps = []   # app bundles registered with --mine <path>: any process running from them is this job's


def own_games(root):
    """Games this job started itself: its descendants, plus PIDs it registered with --mine (a game started
    through `open -n` is launchd's child, not ours). They never pause the job that runs them."""
    own = {os.getpid()}
    apps.clear()
    if root:
        own |= family(root)
    try:
        for x in open(mine_file()).read().split("\n"):
            x = x.strip()
            if x.isdigit():
                own.add(int(x))
            elif x:
                apps.append(x.rstrip("/") + "/")
    except OSError:
        pass
    return own


def game_running(root=None):
    r = subprocess.run(["pgrep", "-lf", PATTERN], capture_output=True, text=True)
    procs = [l.split(" ", 1) for l in r.stdout.splitlines() if l.strip()]
    if not procs:
        return False
    own = own_games(root)
    return any(int(p) not in own and not any(c.startswith(a) for a in apps) for p, c in procs)


def family(root):
    """root's process group plus every descendant (some tools call setsid)."""
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,pgid="], capture_output=True, text=True).stdout
    rows = [tuple(int(x) for x in l.split()) for l in out.splitlines() if len(l.split()) == 3]
    kids, pids = {}, set()
    for pid, ppid, pgid in rows:
        kids.setdefault(ppid, []).append(pid)
        if pgid == root:
            pids.add(pid)
    todo = [root]
    while todo:
        p = todo.pop()
        pids.add(p)
        todo.extend(kids.get(p, []))
    return pids


def also():
    pat = os.environ.get("DEADWARE_PAUSE_ALSO")
    if not pat:
        return []
    r = subprocess.run(["pgrep", "-f", pat], capture_output=True, text=True)
    return [int(p) for p in r.stdout.split() if p and int(p) != os.getpid()]


def signal_all(root, sig):
    try:
        os.killpg(root, sig)
    except ProcessLookupError:
        pass
    for p in family(root) | set(also()):
        try:
            os.kill(p, sig)
        except (ProcessLookupError, PermissionError):
            pass


def wait_no_game(what):
    said = False
    while game_running():
        if not said:
            print(f"[owner_pause] {time.strftime('%H:%M:%S')} game running: waiting before {what[:80]}",
                  file=sys.stderr, flush=True)
            said = True
        time.sleep(POLL)


def main():
    args = sys.argv[1:]
    if args[:1] == ["--mine"]:   # --mine <pid|app path>...: this job's own game run (app_smoke, install check);
        for m in mine_files():   # register the app path BEFORE `open -n` (a PID only exists after the race)
            with open(m, "a") as f:
                f.write("".join(a + "\n" for a in args[1:]))
        return 0
    if args[:1] == ["--wait"]:
        wait_no_game("the next step")
        return 0
    if args[:1] == ["--"]:
        args = args[1:]
    if not args:
        sys.exit(__doc__)
    cfg = os.environ.get("DEADWARE_PAUSE_ALSO", "") + "|" + os.environ.get("DEADWARE_PAUSE_MARK", "")
    if (os.environ.get("DEADWARE_OWNER_PAUSE") or os.environ.get("DEADWARE_OWNER_PAUSED")) \
            and os.environ.get("DEADWARE_OWNER_PAUSE_CFG", "|") == cfg:   # an outer watcher already does this
        os.execvp(args[0], args)
    wait_no_game(" ".join(args))
    mine = os.path.join(os.environ.get("TMPDIR", "/tmp"), f"owner_pause-{os.getpid()}.mine")
    open(mine, "w").close()
    os.environ["DEADWARE_OWNER_PAUSE_MINE"] = os.pathsep.join(mine_files() + [mine])
    child = subprocess.Popen(args, start_new_session=True, env=dict(
        os.environ, DEADWARE_OWNER_PAUSE=str(os.getpid()), DEADWARE_OWNER_PAUSED="1", DEADWARE_OWNER_PAUSE_CFG=cfg))
    mark = os.environ.get("DEADWARE_PAUSE_MARK")
    paused = False

    def forward(sig, _frame):
        signal_all(child.pid, signal.SIGCONT)
        signal_all(child.pid, sig)
    signal.signal(signal.SIGINT, forward)
    signal.signal(signal.SIGTERM, forward)

    while True:
        try:
            rc = child.wait(timeout=POLL)
            if paused:
                signal_all(child.pid, signal.SIGCONT)
            try:
                os.unlink(mine)
            except OSError:
                pass
            return rc
        except subprocess.TimeoutExpired:
            pass
        playing = game_running(child.pid)
        if playing and not paused:
            signal_all(child.pid, signal.SIGSTOP)
            paused = True
            if mark:
                with open(mark, "a") as f:
                    f.write(time.strftime("%H:%M:%S") + " paused: owner's game running\n")
            print(f"[owner_pause] {time.strftime('%H:%M:%S')} game running: paused {' '.join(args)[:80]}",
                  file=sys.stderr, flush=True)
        elif not playing and paused:
            signal_all(child.pid, signal.SIGCONT)
            paused = False
            print(f"[owner_pause] {time.strftime('%H:%M:%S')} game closed: resumed", file=sys.stderr, flush=True)


if __name__ == "__main__":
    sys.exit(main())
