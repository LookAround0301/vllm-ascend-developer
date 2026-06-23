#!/usr/bin/env python3
"""
clawd-term — 终端版桌宠，直接渲染 CodeNoNo 精灵图（ANSI 真彩色 + ▀ 半块）。
把 awesome-codex-pet 的 spritesheet.webp 按状态动画行，逐帧转成终端字符画，
保持原图样子。状态由 ~/.claude/pet/state（Claude Code hooks 写入）驱动。

env:
  CODENONO_SPRITE  精灵图路径
  PET_W            渲染宽度（列），默认 26，越大越清晰也越占宽
  PET_FPS          帧率，默认 8
  PET_NOLABEL=1    不显示底部状态文字
"""
import os
import sys
import time
import shutil

STATE_FILE = os.path.expanduser("~/.claude/pet/state")
TS_FILE = os.path.expanduser("~/.claude/pet/ts")
IDLE_SLEEP_SEC = 60
PET_DEV_PATHS = {
    "codenono": "/home/l00889328/dev/awesome-codex-pet/pets/codenono--dq02/spritesheet.webp",
    "bubu": "/home/l00889328/dev/awesome-codex-pet/pets/bubu--gbn666/spritesheet.webp",
    "yier": "/home/l00889328/dev/awesome-codex-pet/pets/yier--gbn666/spritesheet.webp",
}


def _sprite_path():
    """选宠物：PET_PET=codenono|bubu|yier（默认 codenono）。
    解析顺序：env 显式路径 > ~/.claude/pet/<pet>.webp > dev 仓库 > codenono 兜底。"""
    pet = os.environ.get("PET_PET", "codenono").lower()
    for p in (
        os.environ.get("PET_SPRITE") or os.environ.get("CODENONO_SPRITE"),
        os.path.expanduser(f"~/.claude/pet/{pet}.webp"),
        PET_DEV_PATHS.get(pet),
        os.path.expanduser("~/.claude/pet/codenono.webp"),
    ):
        if p and os.path.exists(p):
            return p
    return os.path.expanduser("~/.claude/pet/codenono.webp")
PET_W = int(os.environ.get("PET_W", "40"))
PET_FPS = float(os.environ.get("PET_FPS", "8"))

# 精灵图网格（来自 awesome-codex-pet/scripts/generate-pet-previews.py）
COLS, ROWS, CELL_W, CELL_H = 8, 9, 192, 208
# 每个 codex 动画行的帧数
ROW_FRAMES = {0: 6, 1: 8, 2: 8, 3: 4, 4: 5, 5: 8, 6: 6, 7: 6, 8: 6}
# 我的桌宠状态 -> codex 动画行
STATE_ROW = {
    "idle": 0,         # idle
    "thinking": 6,     # waiting
    "working": 7,      # running
    "done": 4,         # jumping
    "error": 5,        # failed
    "notification": 8, # review
    "subagent": 3,     # waving
    "sleeping": 0,     # idle
}
LABEL = {
    "idle": ("idle", "\033[90m"), "thinking": ("thinking", "\033[35m"),
    "working": ("working", "\033[33m"), "done": ("done!", "\033[32m"),
    "error": ("error", "\033[31m"), "notification": ("attention", "\033[1;33m"),
    "subagent": ("subagents", "\033[34m"), "sleeping": ("sleeping", "\033[90m"),
}

_cache = {}   # state -> list[list[str]]  （每帧 = 若干 ANSI 行）
_imgsize = {} # state -> (width_cols, height_rows)


def _pil():
    from PIL import Image
    return Image.open(_sprite_path()).convert("RGBA")


def _extract(im, row, col):
    return im.crop((col * CELL_W, row * CELL_H, (col + 1) * CELL_W, (row + 1) * CELL_H)).convert("RGBA")


def _clean(im):
    """去描边底色（半透明边缘）：洋红/紫色边，以及暗红色底色。
    只动半透明像素，不误伤不透明本体；暗红判据限低亮度，保留暖色本体的抗锯齿。"""
    px = im.load()
    w, h = im.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0 or a >= 230:
                continue
            magenta = r > g + 20 and b > g + 20
            darkred = (r + g + b < 150) and r > g + 10 and r > b + 10
            if magenta or darkred:
                px[x, y] = (0, 0, 0, 0)
    return im


def _state_images(state):
    """返回某状态的所有帧（已 clean、按 union bbox 裁齐，位置稳定）。"""
    if state in _cache:
        return _cache[state]
    from PIL import Image
    im = _pil()
    row = STATE_ROW[state]
    n = ROW_FRAMES[row]
    frames = [_clean(_extract(im, row, c)) for c in range(n)]
    bboxes = [f.getbbox() for f in frames]
    bboxes = [b for b in bboxes if b]
    if bboxes:
        u = list(bboxes[0])
        for b in bboxes[1:]:
            u[0] = min(u[0], b[0]); u[1] = min(u[1], b[1])
            u[2] = max(u[2], b[2]); u[3] = max(u[3], b[3])
        # 加 2px 内边距
        u = (max(0, u[0] - 2), max(0, u[1] - 2), u[2] + 2, u[3] + 2)
        frames = [f.crop(u) for f in frames]
    cw = frames[0].width
    ch = frames[0].height
    tw = PET_W
    th = max(2, round(tw * ch / cw))
    # 保证偶数高（半块成对）
    if th % 2:
        th += 1
    rendered = [_frame_to_ansi(f.resize((tw, th), Image.LANCZOS), tw, th) for f in frames]
    _cache[state] = rendered
    _imgsize[state] = (tw, len(rendered[0]))
    return rendered


def _frame_to_ansi(im, tw, th):
    px = im.convert("RGBA").load()
    lines = []
    for y in range(0, th, 2):
        out = []
        pfg = pbg = None
        for x in range(tw):
            top = px[x, y]
            bot = px[x, y + 1] if y + 1 < th else (0, 0, 0, 0)
            ta = top[3] > 128
            ba = bot[3] > 128
            if not ta and not ba:
                if pfg is not None or pbg is not None:
                    out.append("\033[0m"); pfg = pbg = None
                out.append(" ")
                continue
            if ta and ba:
                fg = (top[0], top[1], top[2]); bg = (bot[0], bot[1], bot[2])
                if fg != pfg:
                    out.append(f"\033[38;2;{fg[0]};{fg[1]};{fg[2]}m"); pfg = fg
                if bg != pbg:
                    out.append(f"\033[48;2;{bg[0]};{bg[1]};{bg[2]}m"); pbg = bg
                out.append("▀")
            elif ta:
                fg = (top[0], top[1], top[2])
                if fg != pfg or pbg is not None:
                    out.append(f"\033[38;2;{fg[0]};{fg[1]};{fg[2]}m\033[49m"); pfg = fg; pbg = None
                out.append("▀")
            else:
                fg = (bot[0], bot[1], bot[2])
                if fg != pfg or pbg is not None:
                    out.append(f"\033[38;2;{fg[0]};{fg[1]};{fg[2]}m\033[49m"); pfg = fg; pbg = None
                out.append("▄")
        out.append("\033[0m")
        lines.append("".join(out))
    return lines


def read_state():
    try:
        s = (open(STATE_FILE).read().strip() or "idle")
    except Exception:
        s = "idle"
    try:
        ts = float(open(TS_FILE).read().strip())
    except Exception:
        ts = 0.0
    if s in ("idle", "done") and ts and (time.time() - ts) > IDLE_SLEEP_SEC:
        s = "sleeping"
    return s if s in STATE_ROW else "idle"


def render(tick, cols=None, rows=None):
    if cols is None or rows is None:
        sz = shutil.get_terminal_size((80, 24))
        cols = cols or sz.columns
        rows = rows or sz.lines
    s = read_state()
    frames = _state_images(s)
    fr = frames[tick % len(frames)]
    w, h = _imgsize[s]
    pad_h = " " * max(0, (cols - w) // 2)
    body = [pad_h + ln for ln in fr]
    if not os.environ.get("PET_NOLABEL"):
        label, col = LABEL[s]
        spin = "·"  # 不用 unicode spinner 避免和图像抢眼
        body.append(pad_h + f"{spin} \033[2m{label}\033[0m")
    pad_top = max(0, (rows - len(body)) // 2)
    return "\n".join([""] * pad_top + body)


def tight_size():
    s = read_state()
    _state_images(s)
    w, h = _imgsize[s]
    extra = 0 if os.environ.get("PET_NOLABEL") else 1
    return w, h + extra


def main():
    if os.environ.get("PET_SIZE_ONLY"):
        w, h = tight_size()
        print(f"{w} {h}")
        return
    # 预热所有状态帧（一次性，~1-2s）
    for st in STATE_ROW:
        try:
            _state_images(st)
        except Exception as e:
            print(f"load {st} failed: {e}", file=sys.stderr)
    if os.environ.get("PET_DEMO"):
        s = read_state()
        for i, fr in enumerate(_state_images(s)[:2]):
            print(f"-- {s} frame {i} --")
            for ln in fr:
                print(ln)
            print()
        return
    sys.stdout.write("\033[?25l")
    sys.stdout.flush()
    tick = 0
    try:
        while True:
            sys.stdout.write("\033[2J\033[H" + render(tick))
            sys.stdout.flush()
            tick += 1
            time.sleep(1.0 / PET_FPS)
    finally:
        sys.stdout.write("\033[?25h\033[0m")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
