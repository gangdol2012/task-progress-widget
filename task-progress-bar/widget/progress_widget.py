"""Floating Claude progress widget, warm look (Claude design template).

Reads one JSON file per session in STATE_DIR: <session>.json from the
task-progress-bar mod (Claude desktop app) and cli-<session>.json from the
terminal hook (Claude Code in a terminal). One row per session that is
working or waiting for the person, kept green for a moment after it
finishes. Click a desktop-app row to open that session; right-click for
settings. Frameless, draggable, resizable, one copy at a time.
"""

import glob
import json
import math
import os
import sys
import time
import tkinter as tk

CLAUDE_HOME = os.path.join(os.path.expanduser("~"), ".claude")
STATE_DIR = os.path.join(CLAUDE_HOME, "task-progress")
if len(sys.argv) > 1 and os.path.isdir(sys.argv[1]):
    STATE_DIR = sys.argv[1]

FRESH_MS = 5000                 # desktop sessions heartbeat every second
CLI_FRESH_MS = 15 * 60 * 1000   # terminal sessions only report on events
SHOW_DONE_MS = 15000
SHOW_WAITING_MS = 3 * 3600 * 1000
CLEANUP_MS = 2 * 24 * 3600 * 1000
DEFAULT_STEP_MS = 20000

# Claude design template. Dark: surface-dark family; light: cream canvas.
THEMES = {
    "dark": dict(card="#1f1e1b", border="#5c574e", edge="#33302b",
                 track="#2e2b27", ink="#faf9f5", soft="#a09d96",
                 coral="#cc785c", coral_hi="#e8a58c", success="#5db872",
                 amber="#e8a55a"),
    "light": dict(card="#faf9f5", border="#d6cdbf", edge="#e6dfd8",
                  track="#ebe6df", ink="#141413", soft="#6c6a64",
                  coral="#cc785c", coral_hi="#e9b09b", success="#3f9a55",
                  amber="#c7822e"),
}
KEY = "#010203"  # made transparent: gives the card rounded corners

TITLE = "Claude progress"
VERSION = "0.3.1"  # keep in step with .claude-plugin/plugin.json
AUTHOR = "OhMyGodItIsMe"
PROJECT_URL = "https://github.com/OhMyGodItIsMe/task-progress-widget"
W = 320
PAD = 16
RADIUS = 14
BAR_H = 6
HEADER_H = 40
ROW_H = 62
EMPTY_H = 34
MAX_ROWS = 8
CLICK_SLOP = 4  # px the pointer may move and still count as a click

GRIP = 18                # corner area that resizes, at scale 1
MIN_SCALE, MAX_SCALE = 0.75, 2.0
# After Claude's computer control last minimized us, stay invisible to
# screenshots and click-through this long.
CONTROL_QUIET_S = 60
ERROR_LOG = os.path.join(CLAUDE_HOME, "task-progress-widget.log")
# Where the Claude desktop app keeps its session files (titles live there):
# %LOCALAPPDATA%\Claude-Data\claude_<account>\claude-code-sessions
APP_SESSIONS_GLOB = os.path.join(os.environ.get("LOCALAPPDATA", ""),
                                 "Claude-Data", "claude_*",
                                 "claude-code-sessions")
SESSION_LINK = "claude://claude.ai/epitaxy/{}"
TITLE_REFRESH_S = 10
SETTINGS_FILE = os.path.join(CLAUDE_HOME, "task-progress-widget.json")
DEFAULTS = {"scale": 1.0, "x": None, "y": None, "sound": True,
            "theme": "auto"}

WAITING_TEXT = {
    "permission": "Waiting for your permission",
    "question": "Claude asked you something",
    "answer": "Your turn: Claude asked a question",
}

SERIF = ("Georgia", 11)
SANS = "Segoe UI"


def fmt_eta(ms: float) -> str:
    s = max(0, int(ms / 1000))
    if s < 2:
        return "almost done"
    if s < 60:
        return f"~{s}s left"
    m, r = divmod(s, 60)
    return f"~{m}m {r:02d}s left"


def clip(text: str, n: int) -> str:
    return text if len(text) <= n else text[: n - 1] + "…"


def mix(a: str, b: str, t: float) -> str:
    """Blend two #rrggbb colors; t=0 gives a, t=1 gives b."""
    ca = [int(a[i:i + 2], 16) for i in (1, 3, 5)]
    cb = [int(b[i:i + 2], 16) for i in (1, 3, 5)]
    return "#" + "".join(f"{round(x + (y - x) * t):02x}" for x, y in zip(ca, cb))


def log_error(where: str, ex: Exception) -> None:
    try:
        with open(ERROR_LOG, "a", encoding="utf-8") as f:
            f.write(f"{time.ctime()} {where}: {ex!r}\n")
    except OSError:
        pass


def load_settings() -> dict:
    cfg = dict(DEFAULTS)
    try:
        with open(SETTINGS_FILE, "r", encoding="utf-8") as f:
            saved = json.load(f)
        if isinstance(saved, dict):
            cfg.update({k: saved[k] for k in DEFAULTS if k in saved})
    except (OSError, ValueError):
        pass
    try:
        cfg["scale"] = max(MIN_SCALE, min(MAX_SCALE, float(cfg["scale"])))
    except (TypeError, ValueError):
        cfg["scale"] = 1.0
    if cfg["theme"] not in ("auto", "dark", "light"):
        cfg["theme"] = "auto"
    return cfg


def save_settings(cfg: dict) -> None:
    try:
        with open(SETTINGS_FILE, "w", encoding="utf-8") as f:
            json.dump({k: cfg.get(k) for k in DEFAULTS}, f)
    except OSError:
        pass


def windows_uses_light_theme() -> bool:
    if sys.platform != "win32":
        return False
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                            r"Software\Microsoft\Windows\CurrentVersion"
                            r"\Themes\Personalize") as k:
            return winreg.QueryValueEx(k, "AppsUseLightTheme")[0] == 1
    except OSError:
        return False


def point_on_a_screen(x: int, y: int) -> bool:
    if sys.platform != "win32":
        return True
    import ctypes
    import ctypes.wintypes as wt
    u32 = ctypes.windll.user32
    u32.MonitorFromPoint.restype = ctypes.c_void_p
    return bool(u32.MonitorFromPoint(wt.POINT(int(x), int(y)), 0))


def beep(kind: str) -> None:
    if sys.platform != "win32":
        return
    import winsound
    # Asterisk for "finished", exclamation for "needs you".
    winsound.MessageBeep(0x30 if kind == "waiting" else 0x40)


def already_running() -> bool:
    if sys.platform != "win32":
        return False
    import ctypes
    k32 = ctypes.windll.kernel32
    u32 = ctypes.windll.user32
    k32.CreateMutexW.restype = ctypes.c_void_p
    main.mutex = k32.CreateMutexW(None, False, "Local\\ClaudeProgressWidget")
    if k32.GetLastError() != 183:  # ERROR_ALREADY_EXISTS
        return False
    hwnd = u32.FindWindowW(None, TITLE)
    if hwnd:
        u32.ShowWindow(hwnd, 9)
        u32.SetForegroundWindow(hwnd)
    return True


_sessions = {"at": 0.0, "map": {}}


def app_sessions() -> dict:
    """Session id -> (title, app session id), from the Claude app's files.

    The app keeps one JSON file per session (local_*.json) with its title,
    its own id (for the claude:// link) and the id the mod writes under
    (cliSessionId). This is the app's private format, so anything missing
    just means falling back to the request text and no link.
    Re-read at most every TITLE_REFRESH_S seconds.
    """
    now = time.time()
    if now - _sessions["at"] < TITLE_REFRESH_S:
        return _sessions["map"]
    _sessions["at"] = now
    found = {}
    walks = (w for top in glob.glob(APP_SESSIONS_GLOB) for w in os.walk(top))
    for dirpath, _dirs, files in walks:
        for name in files:
            if not (name.startswith("local_") and name.endswith(".json")):
                continue
            try:
                with open(os.path.join(dirpath, name), "r",
                          encoding="utf-8") as f:
                    d = json.load(f)
            except (OSError, ValueError):
                continue
            title = str(d.get("title") or "").strip()
            app_id = str(d.get("sessionId") or name[:-5])
            for key in ("cliSessionId", "lastAssistantCliSessionId"):
                sid = d.get(key)
                if sid:
                    found[str(sid)] = (title, app_id)
    _sessions["map"] = found
    return found


def load_sessions(now_ms: float) -> list:
    rows = []
    try:
        names = os.listdir(STATE_DIR)
    except OSError:
        return rows
    desktop_fresh = set()
    parsed = []
    flags = {}  # desktop session id -> waiting reason, from <sid>.waiting.json
    for name in names:
        if not name.endswith(".json"):
            continue
        path = os.path.join(STATE_DIR, name)
        if name.endswith(".waiting.json"):
            # Written by the hook while a permission prompt is on screen.
            try:
                with open(path, "r", encoding="utf-8") as f:
                    flag = json.load(f)
                if now_ms - int(flag.get("ts", 0) or 0) < SHOW_WAITING_MS:
                    flags[name[:-len(".waiting.json")]] = str(flag.get("waiting") or "permission")
                else:
                    os.remove(path)
            except (OSError, ValueError, AttributeError):
                pass
            continue
        try:
            with open(path, "r", encoding="utf-8") as f:
                d = json.load(f)
        except (OSError, ValueError):
            continue  # missing, or caught mid-write; next tick will get it
        age = now_ms - int(d.get("ts", 0) or 0)
        if age > CLEANUP_MS:
            try:
                os.remove(path)
            except OSError:
                pass
            continue
        cli = name.startswith("cli-")
        sid = name[4:-5] if cli else name[:-5]
        if not cli and age < CLI_FRESH_MS:
            desktop_fresh.add(sid)
        parsed.append((name, sid, cli, age, d))

    known = app_sessions()
    for name, sid, cli, age, d in parsed:
        if cli and sid in desktop_fresh:
            continue  # the desktop mod already reports this session
        running = bool(d.get("running"))
        waiting = str(d.get("waiting") or "") or ("" if cli else flags.get(sid, ""))
        started = int(d.get("stepStartedAt", 0) or 0)
        working = running and age < (CLI_FRESH_MS if cli else FRESH_MS)
        if waiting and age < SHOW_WAITING_MS and (working or not running):
            status = "waiting"
        elif working:
            status = "working"
        elif started > 0 and age < SHOW_DONE_MS:
            status = "finished"
        else:
            continue
        title, app_id = known.get(sid, ("", ""))
        if cli:
            title = str(d.get("title") or "")
        rows.append({
            "status": status,
            "waiting": waiting,
            "cli": cli,
            "total": int(d.get("total", 0) or 0),
            "completed": int(d.get("completed", 0) or 0),
            "label": str(d.get("label", "") or ""),
            "prompt": str(d.get("prompt", "") or ""),
            "title": title,
            "link": SESSION_LINK.format(app_id) if app_id else "",
            "started": started,
            "avg": float(d.get("avgStepMs", 0) or 0) or DEFAULT_STEP_MS,
            "id": name,
        })
    rows.sort(key=lambda r: r["id"])
    return rows[:MAX_ROWS]


def round_rect(c: tk.Canvas, x1, y1, x2, y2, r, **kw):
    pts = [x1 + r, y1, x2 - r, y1, x2, y1, x2, y1 + r, x2, y2 - r, x2, y2,
           x2 - r, y2, x1 + r, y2, x1, y2, x1, y2 - r, x1, y1 + r, x1, y1]
    return c.create_polygon(pts, smooth=True, **kw)


def pill(c: tk.Canvas, x1, y, x2, h, color):
    """A bar with round ends from x1 to x2, centered on y."""
    if x2 - x1 < h:
        x2 = x1 + h
    c.create_line(x1 + h / 2, y, x2 - h / 2, y, width=h, fill=color,
                  capstyle=tk.ROUND)


def main() -> None:
    if already_running():
        return
    root = tk.Tk()
    root.title(TITLE)
    root.overrideredirect(True)
    root.attributes("-topmost", True)
    root.configure(bg=KEY)
    try:
        root.attributes("-transparentcolor", KEY)
    except tk.TclError:
        pass

    cfg = load_settings()
    # Everything is laid out at scale 1 and multiplied by cfg["scale"], so
    # text, bars and spacing all grow and shrink together.

    def s(v: float) -> float:
        return v * cfg["scale"]

    def font(size: float, *style: str) -> tuple:
        return (SANS, max(6, round(size * cfg["scale"])), *style)

    def width() -> int:
        return round(W * cfg["scale"])

    theme = {"at": 0.0, "c": THEMES["dark"]}

    def colors() -> dict:
        if cfg["theme"] != "auto":
            return THEMES[cfg["theme"]]
        if time.time() - theme["at"] > 5:  # follow Windows, checked lazily
            theme["at"] = time.time()
            theme["c"] = THEMES["light" if windows_uses_light_theme() else "dark"]
        return theme["c"]

    def default_xy() -> tuple:
        return max(0, root.winfo_screenwidth() - width() - 24), 48

    x, y = cfg["x"], cfg["y"]
    h0 = round(s(HEADER_H + EMPTY_H))
    if not (isinstance(x, int) and isinstance(y, int)
            and point_on_a_screen(x + 10, y + 10)
            and point_on_a_screen(x + width() - 10, y + 10)):
        x, y = default_xy()  # unset, or that monitor is gone
    root.geometry(f"{width()}x{h0}+{x}+{y}")

    canvas = tk.Canvas(root, bg=KEY, highlightthickness=0)
    canvas.pack(fill="both", expand=True)

    state = {"h": 0, "mode": "", "x": 0, "y": 0, "px": 0, "py": 0,
             "hits": [], "seen": {}}

    def on_grip(e: "tk.Event") -> bool:
        return e.x >= width() - s(GRIP) and e.y >= state["h"] - s(GRIP)

    def row_link(e: "tk.Event") -> str:
        for y0, y1, link in state["hits"]:
            if y0 <= e.y < y1:
                return link
        return ""

    def set_scale(v: float) -> None:
        v = max(MIN_SCALE, min(MAX_SCALE, v))
        if abs(v - cfg["scale"]) > 0.001:
            cfg["scale"] = v
            state["h"] = 0  # force a resize on the next draw
            draw()

    def press(e: "tk.Event") -> None:
        if e.x >= width() - s(34) and e.y <= s(HEADER_H):
            root.destroy()
            return
        state["mode"] = "resize" if on_grip(e) else "move"
        state["x"], state["y"] = e.x, e.y
        state["px"], state["py"] = root.winfo_pointerx(), root.winfo_pointery()

    def motion(e: "tk.Event") -> None:
        if state["mode"] == "resize":
            set_scale((root.winfo_pointerx() - root.winfo_rootx()) / W)
        elif state["mode"] == "move":
            root.geometry(f"+{root.winfo_pointerx() - state['x']}"
                          f"+{root.winfo_pointery() - state['y']}")

    def release(e: "tk.Event") -> None:
        mode, state["mode"] = state["mode"], ""
        moved = (abs(root.winfo_pointerx() - state["px"])
                 + abs(root.winfo_pointery() - state["py"]))
        if mode == "resize":
            save_settings(cfg)
        elif mode == "move" and moved <= CLICK_SLOP:
            link = row_link(e)  # a click, not a drag: open that session
            if link and sys.platform == "win32":
                try:
                    os.startfile(link)
                except OSError as ex:
                    log_error("open session", ex)
        elif mode == "move":
            cfg["x"], cfg["y"] = root.winfo_x(), root.winfo_y()
            save_settings(cfg)

    def hover(e: "tk.Event") -> None:
        if on_grip(e):
            canvas.config(cursor="size_nw_se")
        else:
            canvas.config(cursor="hand2" if row_link(e) else "")

    def wheel(e: "tk.Event") -> None:
        set_scale(cfg["scale"] + (0.1 if e.delta > 0 else -0.1))
        save_settings(cfg)

    # Right-click menu: settings.
    sound_var = tk.BooleanVar(value=bool(cfg["sound"]))
    theme_var = tk.StringVar(value=cfg["theme"])

    def apply_sound() -> None:
        cfg["sound"] = bool(sound_var.get())
        save_settings(cfg)

    def apply_theme() -> None:
        cfg["theme"] = theme_var.get()
        theme["at"] = 0.0
        save_settings(cfg)

    def reset_place() -> None:
        cfg["scale"], cfg["x"], cfg["y"] = 1.0, None, None
        save_settings(cfg)
        state["h"] = 0
        draw()
        nx, ny = default_xy()
        root.geometry(f"+{nx}+{ny}")

    menu = tk.Menu(root, tearoff=0)
    menu.add_checkbutton(label="Sound when a session finishes or needs you",
                         variable=sound_var, command=apply_sound)
    themes = tk.Menu(menu, tearoff=0)
    for label, value in (("Match Windows", "auto"), ("Dark", "dark"),
                         ("Light", "light")):
        themes.add_radiobutton(label=label, value=value, variable=theme_var,
                               command=apply_theme)
    menu.add_cascade(label="Theme", menu=themes)
    menu.add_separator()
    menu.add_command(label="Reset size and position", command=reset_place)
    menu.add_command(label="Close widget", command=root.destroy)
    menu.add_separator()

    def open_project() -> None:
        try:
            import webbrowser
            webbrowser.open(PROJECT_URL)
        except Exception as ex:
            log_error("open project page", ex)

    menu.add_command(label=f"About: Task progress widget v{VERSION} by {AUTHOR}",
                     command=open_project)

    def context(e: "tk.Event") -> None:
        try:
            menu.tk_popup(e.x_root, e.y_root)
        finally:
            menu.grab_release()

    canvas.bind("<Button-1>", press)
    canvas.bind("<B1-Motion>", motion)
    canvas.bind("<ButtonRelease-1>", release)
    canvas.bind("<Motion>", hover)
    canvas.bind("<Control-MouseWheel>", wheel)
    canvas.bind("<Button-3>", context)

    def draw_row(y: float, r: dict, now_ms: float, c: dict) -> None:
        total, completed = r["total"], r["completed"]
        elapsed = (now_ms - r["started"]) if r["started"] > 0 else 0
        pad, bar_w, bar_h = s(PAD), s(W - 2 * PAD), s(BAR_H)
        w = width()
        status = r["status"]

        # Status dot: breathing coral while working, slow amber pulse while
        # waiting on the person, green when done.
        cy = y + s(11)
        if status == "finished":
            canvas.create_oval(pad, cy - s(3.5), pad + s(7), cy + s(3.5),
                               fill=c["success"], width=0)
        else:
            amber = status == "waiting"
            t = (math.sin(now_ms / (520.0 if amber else 260.0)) + 1) / 2
            rad, cx = s(3 + 1.2 * t), pad + s(3)
            canvas.create_oval(cx - rad, cy - rad, cx + rad, cy + rad, width=0,
                               fill=mix(c["card"], c["amber" if amber else "coral"],
                                        0.55 + 0.45 * t))

        # The session's title as the app shows it; the request text if the
        # app's files don't have one.
        name = r["title"] or r["prompt"] or "(untitled session)"
        if r["cli"]:
            name = "› " + name  # terminal session
        canvas.create_text(pad + s(14), cy, text=clip(name, 34), fill=c["ink"],
                           anchor="w", font=font(9))

        by = y + s(30)
        pill(canvas, pad, by, pad + bar_w, bar_h, c["track"])
        frac = 0.0
        if total:
            within = 0.0
            if status == "working" and r["avg"] > 0:
                within = max(0.0, min(0.95, elapsed / r["avg"]))
            frac = min(1.0, (completed + within) / total)

        if status == "finished":
            pill(canvas, pad, by, pad + bar_w, bar_h, c["success"])
            right, right_c = "done", c["success"]
            info, info_c = "Finished", c["success"]
        elif status == "waiting":
            if total:
                pill(canvas, pad, by, pad + max(bar_h, bar_w * frac), bar_h,
                     c["amber"])
            right, right_c = "needs you", c["amber"]
            info = WAITING_TEXT.get(r["waiting"], "Waiting for you")
            info_c = c["amber"]
        elif total == 0:
            seg = bar_w / 4
            phase = (now_ms % 2400) / 1200.0
            pos = phase if phase <= 1 else 2 - phase
            # ease in/out so it glides instead of bouncing
            pos = 0.5 - 0.5 * math.cos(pos * math.pi)
            left = pad + (bar_w - seg) * pos
            pill(canvas, left, by, left + seg, bar_h, c["coral"])
            right, right_c = f"{int(elapsed / 1000)}s", c["soft"]
            info, info_c = "Working, no task list", c["soft"]
        else:
            fill_x = pad + max(bar_h, bar_w * frac)
            pill(canvas, pad, by, fill_x, bar_h, c["coral"])
            # Soft highlight drifting across the filled part.
            span = fill_x - pad - bar_h
            if span > s(24):
                gx = pad + bar_h / 2 + ((now_ms % 1600) / 1600.0) * span
                for k, gw in enumerate((18, 10, 4)):
                    col = mix(c["coral"], c["coral_hi"], (k + 1) / 3)
                    a = max(pad + bar_h / 2, gx - s(gw) / 2)
                    b = min(fill_x - bar_h / 2, gx + s(gw) / 2)
                    if b > a:
                        canvas.create_line(a, by, b, by,
                                           width=max(1, bar_h - s(2)),
                                           fill=col, capstyle=tk.ROUND)
            right, right_c = f"{int(frac * 100)}%", c["coral"]
            eta = fmt_eta(r["avg"] * (total - completed) - elapsed)
            step = f"  ·  {r['label']}" if r["label"] else ""
            info = clip(f"{completed} of {total}  ·  {eta}{step}", 50)
            info_c = c["soft"]

        canvas.create_text(w - pad, cy, text=right, fill=right_c, anchor="e",
                           font=font(9, "bold"))
        canvas.create_text(pad, by + s(15), text=info, fill=info_c,
                           anchor="w", font=font(8))

    def notify(rows: list) -> None:
        """Beep when a session finishes or starts waiting on the person."""
        seen, now = state["seen"], {r["id"]: r["status"] for r in rows}
        if cfg["sound"] and seen is not None:
            for rid, st in now.items():
                before = seen.get(rid)
                if st == "waiting" and before != "waiting":
                    beep("waiting")
                    break
                if st == "finished" and before in ("working", "waiting"):
                    beep("finished")
                    break
        state["seen"] = now

    def draw() -> int:
        """Draw everything once; returns how many rows are animating."""
        now_ms = time.time() * 1000
        rows = load_sessions(now_ms)
        c = colors()
        w = width()
        pad = s(PAD)

        h = round(s(HEADER_H + (len(rows) * ROW_H if rows else EMPTY_H) + 6))
        if h != state["h"]:
            state["h"] = h
            root.geometry(f"{w}x{h}")

        canvas.delete("all")
        # Card with a 1px soft border.
        round_rect(canvas, 0, 0, w - 1, h - 1, s(RADIUS), fill=c["border"],
                   outline="")
        round_rect(canvas, 1, 1, w - 2, h - 2, s(RADIUS) - 1, fill=c["card"],
                   outline="")

        working = sum(1 for r in rows if r["status"] == "working")
        waiting = sum(1 for r in rows if r["status"] == "waiting")
        canvas.create_text(pad, s(21), text="Claude", fill=c["ink"], anchor="w",
                           font=(SERIF[0], max(7, round(SERIF[1] * cfg["scale"]))))
        parts = []
        if working:
            parts.append(f"{working} working")
        if waiting:
            parts.append(f"{waiting} needs you")
        sub = "  ·  ".join(parts) if parts else ("idle" if not rows else "")
        if sub:
            canvas.create_text(pad + s(60), s(22), text=sub, fill=c["soft"],
                               anchor="w", font=font(8))
        canvas.create_text(w - pad - s(2), s(21), text="✕", fill=c["soft"],
                           font=font(9))
        canvas.create_line(pad, s(HEADER_H - 2), w - pad, s(HEADER_H - 2),
                           fill=c["edge"])

        hits = []
        if not rows:
            canvas.create_text(pad, s(HEADER_H + 14), text="Nothing running",
                               fill=c["soft"], anchor="w", font=font(8))
        for i, r in enumerate(rows):
            y = s(HEADER_H + 4 + i * ROW_H)
            if i:
                canvas.create_line(pad, y - s(4), w - pad, y - s(4),
                                   fill=c["track"])
            draw_row(y, r, now_ms, c)
            if r["link"]:
                hits.append((y - s(4), y + s(ROW_H - 4), r["link"]))
        state["hits"] = hits

        # Resize grip: three short diagonal strokes in the bottom-right corner.
        gx, gy = w - s(6), h - s(6)
        for n in (4, 8, 12):
            canvas.create_line(gx - s(n), gy, gx, gy - s(n), fill=c["edge"],
                               width=max(1, s(1.2)))
        notify(rows)
        return working + waiting

    # Claude's computer control minimizes every window it wasn't given, this
    # one included, and leaves it minimized. Our window can't be minimized any
    # other way (it has no title bar or taskbar button), so a minimize means
    # Claude is controlling the screen: come straight back, but hidden from
    # screenshots and letting clicks pass through, so Claude never sees or
    # clicks it. Back to normal once no minimize has happened for a while.
    ctl = {"top": 0, "until": 0.0, "on": False}

    def guard() -> None:
        if sys.platform != "win32":
            return
        import ctypes
        u32 = ctypes.windll.user32
        vp = ctypes.c_void_p
        if not ctl["top"]:
            u32.FindWindowW.restype = vp
            u32.GetWindowThreadProcessId.argtypes = [vp, vp]
            for fn in ("IsIconic", "IsWindowVisible"):
                getattr(u32, fn).argtypes = [vp]
            u32.ShowWindow.argtypes = [vp, ctypes.c_int]
            u32.SetWindowDisplayAffinity.argtypes = [vp, ctypes.c_uint]
            u32.GetWindowLongW.argtypes = [vp, ctypes.c_int]
            u32.SetWindowLongW.argtypes = [vp, ctypes.c_int, ctypes.c_long]
            u32.SetWindowPos.argtypes = [vp, vp, ctypes.c_int, ctypes.c_int,
                                         ctypes.c_int, ctypes.c_int,
                                         ctypes.c_uint]
            # The widget's real window: the titled "TkTopLevel" one in this
            # process. Tk keeps another, hidden helper window; never touch it.
            top = u32.FindWindowW(None, TITLE)
            pid = ctypes.c_ulong()
            if top:
                u32.GetWindowThreadProcessId(top, ctypes.byref(pid))
            if not top or pid.value != os.getpid():
                return  # not created yet; try again next tick
            ctl["top"] = top
        top = ctl["top"]
        now = time.time()
        if u32.IsIconic(top):
            ctl["until"] = now + CONTROL_QUIET_S
            if not ctl["on"]:
                ctl["on"] = True
                u32.SetWindowDisplayAffinity(top, 0x11)  # hide from capture
                ex = u32.GetWindowLongW(top, -20)
                # click-through (needs layered, which it already is)
                u32.SetWindowLongW(top, -20, ex | 0x20 | 0x80000)
            u32.ShowWindow(top, 4)  # SW_SHOWNOACTIVATE: back, no focus steal
            # HWND_TOPMOST, without moving, resizing or taking focus
            u32.SetWindowPos(top, vp(-1), 0, 0, 0, 0, 0x13)
        elif ctl["on"] and now > ctl["until"]:
            ctl["on"] = False
            u32.SetWindowDisplayAffinity(top, 0)
            ex = u32.GetWindowLongW(top, -20)
            u32.SetWindowLongW(top, -20, ex & ~0x20)

    def refresh() -> None:
        try:
            guard()
        except Exception as ex:  # never let this stop the widget drawing
            if not ctl.get("logged"):
                ctl["logged"] = True
                log_error("guard", ex)
        try:
            busy = draw()
        except Exception as ex:
            log_error("draw", ex)
            busy = 0
        root.after(50 if busy or state["mode"] else 500, refresh)

    state["seen"] = None  # first draw only records, never beeps
    refresh()
    root.mainloop()


if __name__ == "__main__":
    main()
