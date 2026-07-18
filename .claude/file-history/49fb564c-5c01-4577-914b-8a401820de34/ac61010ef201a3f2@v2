#!/usr/bin/env python3
"""
把 clawd-term 的 pet hooks 合并进 ~/.claude/settings.json。
- 保留所有原有内容（env / API key / 已有 hooks），只追加；
- 每个 Claude Code 事件追加一条 `bash ~/.claude/pet/hook.sh <Event>`，幂等（重复跑不堆积）；
- 先备份 settings.json -> settings.json.bak-pet。
"""
import json
import os
import pathlib
import shutil

PATH = os.path.expanduser("~/.claude/settings.json")
EVENTS = [
    "SessionStart", "SessionEnd", "UserPromptSubmit",
    "PreToolUse", "PostToolUse", "Stop",
    "SubagentStop", "Notification",
]
HOOK = 'bash ~/.claude/pet/hook.sh'

shutil.copy(PATH, PATH + ".bak-pet")
cfg = json.loads(pathlib.Path(PATH).read_text())
hooks = cfg.setdefault("hooks", {})
added = []
for ev in EVENTS:
    cmd = f"{HOOK} {ev}"
    lst = hooks.setdefault(ev, [])
    already = any(
        "pet/hook.sh" in h.get("command", "")
        for ent in lst for h in ent.get("hooks", [])
    )
    if not already:
        lst.append({"matcher": "", "hooks": [{"type": "command", "command": cmd, "timeout": 5, "async": True}]})
        added.append(ev)

pathlib.Path(PATH).write_text(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")
print("backed up ->", PATH + ".bak-pet")
print("pet hooks present for:", [ev for ev in EVENTS if any("pet/hook.sh" in h.get("command","") for ent in hooks.get(ev,[]) for h in ent.get("hooks",[]))])
