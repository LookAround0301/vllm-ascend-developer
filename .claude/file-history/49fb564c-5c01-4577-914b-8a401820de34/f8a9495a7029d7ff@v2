#!/usr/bin/env bash
# clawd-term hook：把 Claude Code 事件映射成桌宠状态，写入 state 文件。
# 在 ~/.claude/settings.json 里，每个事件的 hook command 形如：
#   bash ~/.claude/pet/hook.sh <EventName>
set -euo pipefail
STATE_DIR="${HOME}/.claude/pet"
mkdir -p "$STATE_DIR"
EVENT="${1:-}"
case "$EVENT" in
    SessionStart)     echo idle > "$STATE_DIR/state" ;;
    SessionEnd)       echo sleeping > "$STATE_DIR/state" ;;
    UserPromptSubmit) echo thinking > "$STATE_DIR/state" ;;
    PreToolUse)       echo working > "$STATE_DIR/state" ;;
    PostToolUse)      echo working > "$STATE_DIR/state" ;;
    Stop)             echo done > "$STATE_DIR/state" ;;
    SubagentStop)     echo subagent > "$STATE_DIR/state" ;;
    Notification)     echo notification > "$STATE_DIR/state" ;;
    *)                echo idle > "$STATE_DIR/state" ;;
esac
date +%s > "$STATE_DIR/ts"
