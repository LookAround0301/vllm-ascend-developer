# clawd-term（终端版桌宠）

在 tmux 窗格里随 Claude Code 状态动的终端桌宠，由 HyperScript 的
`install_clawd_pet()` 安装到 `~/.claude/pet/`。内置 3 个形象，用 `PET_PET`
环境变量切换：`codenono`（默认）/ `bubu` / `yier`。

## 文件

| 文件 | 说明 |
|------|------|
| `pet.py` | 渲染器：读状态 → 把精灵图帧渲染成 ANSI 真彩色 + ▀ 半块的终端字符画 |
| `hook.sh` | Claude Code hook 处理器：事件 → 状态词（写入 `~/.claude/pet/state`） |
| `merge_hooks.py` | 把 hooks 写进 `~/.claude/settings.json`（幂等，备份 `.bak-pet`） |
| `start.sh` | tmux 启动器：`col`/`bottom`/`mid`/`big`；读 `PET_PET` 选形象 |
| `codenono.webp` | CodeNoNo 精灵图（见归属） |
| `bubu.webp` | Bubu 精灵图（见归属） |
| `yier.webp` | Yi Er 精灵图（见归属） |

## 切换形象

```bash
PET_PET=bubu  bash ~/.claude/pet/start.sh col   # 或 yier / codenono
```

## 归属 / 许可

脚本（`pet.py` / `hook.sh` / `start.sh` / `merge_hooks.py`）为本项目自带。
精灵图均来自 [awesome-codex-pet](https://github.com/rullerzhou-afk/awesome-codex-pet) 画廊，
此处为离线安装**内置副本**，版权与许可归各自原作者所有：

| 文件 | 形象 | 作者 | 画廊路径 |
|------|------|------|----------|
| `codenono.webp` | CodeNoNo | Dqd02 ([github.com/Dqd02](https://github.com/Dqd02)) | `pets/codenono--dq02/` |
| `bubu.webp` | Bubu | Guo Beining (gbn666) | `pets/bubu--gbn666/` |
| `yier.webp` | Yi Er | Guo Beining (gbn666) | `pets/yier--gbn666/` |

如作者有异议请移除对应文件，安装器会回退到本地 `awesome-codex-pet` 路径。

## 运行时依赖（安装时自动装，非文件）

- `tmux`（apt）、`python3` + `Pillow`（pip）
