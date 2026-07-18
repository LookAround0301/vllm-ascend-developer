---
name: clawd-term-pet
description: 终端版桌宠项目(clawd-term)：渲染 awesome-codex-pet 精灵图为字符画，集成进 HyperScript
metadata: 
  node_type: memory
  type: project
  originSessionId: 49fb564c-5c01-4577-914b-8a401820de34
---

`clawd-on-desk` 是 GUI 桌宠(需图形桌面)，在这台 headless 服务器看不到；于是做了**纯终端版桌宠 clawd-term**（~/.claude/pet/），headless SSH 终端可用。

- **架构**：Claude Code hooks(`~/.claude/pet/hook.sh`)把事件(SessionStart/UserPromptSubmit/PreToolUse/Stop/...)写成状态词到 `~/.claude/pet/state` → `pet.py` 读状态，把对应动画的精灵图帧渲染成 **ANSI 真彩色 + ▀ 半块**字符画，显示在 tmux 小窗格里，随状态动。
- **形象**：CodeNoNo / Bubu / Yi Er 三选一，用 `PET_PET=` 或启动菜单选；精灵图来自 `/home/l00889328/dev/awesome-codex-pet/pets/<slug>/spritesheet.webp`。
- **启动**：`bash ~/.claude/pet/start.sh`（不传参=菜单选形象+布局；或 `start.sh col/bottom/mid/big`）。布局=右侧窄列/底部窄条/居中小格/大尺寸。`PET_W`(默认40)调清晰度。
- **集成**：进了 `vllm-ascend-developer/HyperScript/HyperScript.sh`——`install_clawd_pet()`、装 Claude Code 末尾的 TUI 询问、`--install-clawd-pet` CLI、TUI 菜单第9项；伴生文件在 `HyperScript/clawd-term/`(pet.py/hook.sh/start.sh/merge_hooks.py + 3张webp + NOTICE)，git clone 后离线可装。
- **精灵图格式**(awesome-codex-pet 标准，所有宠物通用)：**8 列 × 9 行，每格 192×208**；状态行：idle=0、running-right=1、running-left=2、waving=3、jumping=4、failed=5、waiting=6、running=7、review=8。pet.py 映射：idle→0、thinking→6、working→7、done→4、error→5、notification→8、subagent→3、sleeping→0。
- **坑**：`_clean()` 要去掉精灵图边缘的**洋红+暗红半透明描边底色**（判据：半透明且 r,b 明显>g；或低亮度且 r>g,b），否则桌宠泛红/泛紫。`start.sh` 的贴合尺寸探测必须在选形象**之后**跑(否则按默认形象尺寸开格子会截断别的形象)。

**Why**: 这个项目代码在仓库里，但「终端版 vs GUI 版」「精灵图网格格式」「_clean 描边处理」「MITM 下取精灵图」这些非显然点值得记，避免下次重推导。
**How to apply**: 加新宠物=换精灵图(同网格)+加进 `PET_DEV_PATHS`/菜单；调形象用 PET_PET；泛红就查 `_clean`。环境网络见 [[dev-machine-network]]。
