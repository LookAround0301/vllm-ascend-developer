#!/usr/bin/env bash
# Claude Code 状态栏一键安装脚本
# ---------------------------------------------------------------
# 用法: 在新机器上执行
#     bash install_statusline.sh
#
# 它会:
#   1. 把状态栏脚本写入 ~/.claude/statusline.py
#   2. 自动检测 python3 的绝对路径
#   3. 把 statusLine 配置合并进 ~/.claude/settings.json (保留你已有的其它配置)
#
# 前提: 机器上装了 python3 (脚本只用标准库, 无需 pip 安装任何包)
# ---------------------------------------------------------------
set -euo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
mkdir -p "$CLAUDE_DIR"
TARGET="$CLAUDE_DIR/statusline.py"

echo ">> 写入状态栏脚本到 $TARGET"
cat > "$TARGET" <<'STATUSLINE_PY'
#!/usr/bin/env python3
"""Claude Code 状态栏: 模型名 | [上下文进度条] | 累计花费 | 输出速度(tok/s)

上下文用量优先用状态栏 JSON 里的 context_window 对象,渲染成进度条;
输出速度用 transcript 里最近一轮的瞬时值(超出合理范围则回退会话平均)。
"""
import sys
import json
import os
import re
from datetime import datetime

# 进度条的 1/8 块字符
EIGHTHS = [" ", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]
FULL = "█"
EMPTY = "░"


def humanize(n):
    """145000 -> '145k', 1200000 -> '1.2M'"""
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}".rstrip("0").rstrip(".") + "M"
    if n >= 1_000:
        return f"{round(n / 1000)}k"
    return str(n)


def progress_bar(pct, width=10):
    """返回 (已填充段, 空白段), 用 1/8 块做亚字符精度。"""
    pct = max(0, min(100, pct))
    total = width * 8
    filled = round(pct / 100 * total)
    whole = filled // 8
    frac = filled % 8
    n_cells = min(whole + (1 if frac else 0), width)
    filled_part = FULL * whole
    if frac and whole < width:
        filled_part += EIGHTHS[frac]
    empty_part = EMPTY * (width - n_cells)
    return filled_part, empty_part


def parse_ts(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None


def read_last_usage(transcript_path):
    """回退用: transcript 里最后一条 usage dict。"""
    if not transcript_path or not os.path.isfile(transcript_path):
        return None
    last = None
    try:
        with open(transcript_path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                msg = obj.get("message") if isinstance(obj, dict) else None
                if isinstance(msg, dict) and isinstance(msg.get("usage"), dict):
                    last = msg["usage"]
    except Exception:
        return None
    return last


def last_turn_speed(transcript_path):
    """最近一轮 (output_tokens, 从触发该轮的 user 消息到 assistant 完成的秒数)。"""
    if not transcript_path or not os.path.isfile(transcript_path):
        return None
    last_user_ts = None
    result = None
    try:
        with open(transcript_path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                msg = obj.get("message") if isinstance(obj, dict) else None
                if not isinstance(msg, dict):
                    continue
                ts = parse_ts(obj.get("timestamp"))
                role = msg.get("role")
                usage = msg.get("usage")
                if role == "user" and ts:
                    last_user_ts = ts
                elif (role == "assistant" and isinstance(usage, dict)
                      and usage.get("output_tokens", 0) > 0
                      and last_user_ts and ts):
                    dur = (ts - last_user_ts).total_seconds()
                    if dur > 0:
                        result = (usage["output_tokens"], dur)
    except Exception:
        return None
    return result


def fmt_cost(cost):
    if cost is None:
        return "$0.00"
    if cost < 0.01:
        return f"${cost:.4f}"
    return f"${cost:.2f}"


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        print("")
        return

    # 模型名(去掉 [1m] 之类的上下文窗口后缀)
    model = (data.get("model") or {}).get("display_name") or "?"
    model = re.sub(r"\s*\[[^\]]*\]\s*$", "", model)

    # 上下文用量: 优先 context_window 对象, 否则回退 transcript
    cw = data.get("context_window") or {}
    used = cw.get("total_input_tokens")
    ctx_max = cw.get("context_window_size")
    pct = cw.get("used_percentage")
    if used is None or ctx_max is None:
        u = read_last_usage(data.get("transcript_path")) or {}
        used = (u.get("input_tokens", 0)
                + u.get("cache_creation_input_tokens", 0)
                + u.get("cache_read_input_tokens", 0))
        try:
            ctx_max = int(os.environ.get("CLAUDE_CODE_AUTO_COMPACT_WINDOW", "1000000"))
        except ValueError:
            ctx_max = 1_000_000
    if pct is None:
        pct = (used / ctx_max * 100) if ctx_max else 0

    # 累计花费
    cost_str = fmt_cost((data.get("cost") or {}).get("total_cost_usd"))

    # 输出速度: 瞬时(合理范围内)优先, 否则会话平均
    speed = None
    lt = last_turn_speed(data.get("transcript_path"))
    if lt:
        inst = lt[0] / lt[1]
        if 5 <= inst <= 500:
            speed = inst
    if not speed:
        out_tok = cw.get("total_output_tokens")
        api_ms = (data.get("cost") or {}).get("total_api_duration_ms")
        if out_tok and api_ms:
            avg = out_tok * 1000.0 / api_ms
            if avg > 0:
                speed = avg
    speed_str = f"{round(speed)} tok/s" if speed else "-- tok/s"

    # 配色
    CYAN = "\033[36m"; BLUE = "\033[34m"; MAGENTA = "\033[35m"
    BOLD = "\033[1m"; DIM = "\033[2m"; RESET = "\033[0m"

    # 思考强度: thinking 关闭显示 off, 否则显示 effort 等级
    thinking_on = (data.get("thinking") or {}).get("enabled")
    effort_level = (data.get("effort") or {}).get("level")
    if thinking_on is False:
        effort_display = "off"
    elif effort_level:
        effort_display = str(effort_level).lower()
    elif thinking_on is True:
        effort_display = "on"
    else:
        effort_display = "—"
    if pct >= 80:
        C_CTX = "\033[31m"   # 红
    elif pct >= 50:
        C_CTX = "\033[33m"   # 黄
    else:
        C_CTX = "\033[32m"   # 绿

    # 上下文进度条: 括号默认色, 已填充段着色, 空白段灰显
    fill, empt = progress_bar(pct, width=10)
    ctx_str = f"[{C_CTX}{fill}{RESET}{DIM}{empt}{RESET}] {pct:.0f}%"

    parts = [
        f"{CYAN}{model}{RESET}",
        f"{DIM}[EFFORT]{RESET} {BOLD}{effort_display}{RESET}",
        f"{DIM}[CTX]{RESET} {ctx_str}",
        f"{DIM}[COST]{RESET} {MAGENTA}{cost_str}{RESET}",
        f"{DIM}[SPEED]{RESET} {BLUE}{speed_str}{RESET}",
    ]
    print(f" {DIM}|{RESET} ".join(parts))


if __name__ == "__main__":
    main()
STATUSLINE_PY
chmod +x "$TARGET"
echo "   OK"

echo ">> 检测 python3"
PY="$(command -v python3 || command -v python || true)"
if [ -z "$PY" ]; then
  echo "错误: 未找到 python3, 请先安装 Python 3" >&2
  exit 1
fi
echo "   使用 $PY"

SETTINGS="$CLAUDE_DIR/settings.json"
echo ">> 合并 statusLine 配置到 $SETTINGS"
"$PY" - "$SETTINGS" "$PY" "$TARGET" <<'MERGE_PY'
import json, os, sys
settings_path, py, target = sys.argv[1], sys.argv[2], sys.argv[3]
data = {}
if os.path.isfile(settings_path):
    try:
        with open(settings_path, encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        print(f"   警告: {settings_path} 解析失败({e}), 将重建")
        data = {}
data["statusLine"] = {"type": "command", "command": f"{py} {target}"}
with open(settings_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
print("   OK")
MERGE_PY

echo ""
echo "=============================================="
echo " 安装完成 ✓"
echo "   脚本 : $TARGET"
echo "   命令 : $PY $TARGET"
echo " 重启 Claude Code 会话即可看到状态栏。"
echo "=============================================="
