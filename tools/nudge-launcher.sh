#!/bin/bash
#
# 启动 codebuddy-nudge（CodeBuddy 等待确认 → 刘海弹卡 → 卡上直接运行/拒绝/选选项）
#
# 依赖关系：
#   nudge 通过 CDP（端口 9224）监视 CodeBuddy CN 的聊天面板，
#   所以 CodeBuddy 必须带 --remote-debugging-port=9224 启动。
#   手动重启过 IDE 后端口会丢，用 `nudge --relaunch` 以调试模式重启 CodeBuddy。
#
# 用法：
#   nudge                 # 启动 nudge（已在运行则提示）
#   nudge --stop          # 关闭 nudge
#   nudge --status        # nudge 进程 + CDP 端口状态 + 最近日志
#   nudge --log           # 实时跟踪 nudge 日志
#   nudge --relaunch      # 以调试模式重启 CodeBuddy（会关闭并重开 IDE，会话自动恢复）
#   nudge --rebuild       # 重新编译（改了 Swift 代码后用）并重启 nudge
#
# 日志：/tmp/nudge-run.log

set -u

BIN="$HOME/workspace/codebuddy-nudge/.build/debug/CodeBuddyNudge"
LOG=/tmp/nudge-run.log
CDP_PORT=9224
RELAUNCH_SCRIPT=/tmp/codebuddy-nudge-relaunch.sh

is_nudge_running() {
  pgrep -f "debug/CodeBuddyNudge" > /dev/null 2>&1
}

is_cdp_up() {
  curl --noproxy '*' -s --max-time 2 "http://127.0.0.1:${CDP_PORT}/json/version" 2>/dev/null | grep -q '"Browser"'
}

start_nudge() {
  if [ ! -x "$BIN" ]; then
    echo "❌ 找不到 nudge 可执行文件：$BIN"
    echo "   先编译：cd ~/workspace/codebuddy-nudge && swift build"
    exit 1
  fi

  if is_nudge_running; then
    echo "✅ nudge 已在运行（pid $(pgrep -f "debug/CodeBuddyNudge")），无需重复启动。"
    echo "   状态：nudge --status   日志：nudge --log"
    return 0
  fi

  if ! is_cdp_up; then
    echo "⚠️  CodeBuddy CDP 端口 ${CDP_PORT} 不通，nudge 能启动但连不上 IDE。"
    echo "    先执行 nudge --relaunch 重启 CodeBuddy（会话自动恢复），或稍后自行重启。"
  fi

  nohup "$BIN" > "$LOG" 2>&1 &
  echo "正在启动 nudge…"
  sleep 3
  if is_nudge_running; then
    echo "✅ nudge 已启动（pid $(pgrep -f "debug/CodeBuddyNudge")，菜单栏白色铃铛）"
    echo "   日志：nudge --log"
  else
    echo "❌ 启动失败，看日志：tail -20 $LOG"
    exit 1
  fi
}

case "${1:-}" in
  --stop)
    if is_nudge_running; then
      pkill -f "debug/CodeBuddyNudge" && echo "已关闭 nudge"
    else
      echo "nudge 未在运行"
    fi
    exit 0
    ;;
  --status)
    if is_nudge_running; then
      echo "✅ nudge 正在运行（pid $(pgrep -f "debug/CodeBuddyNudge"))"
    else
      echo "❌ nudge 未运行（终端执行 nudge 启动）"
    fi
    if is_cdp_up; then
      echo "✅ CodeBuddy CDP 端口 ${CDP_PORT} 正常"
    else
      echo "❌ CodeBuddy CDP 端口 ${CDP_PORT} 不通 → nudge 连不上 IDE"
      echo "   处理：执行 nudge --relaunch 以调试模式重启 CodeBuddy（会话自动恢复）"
    fi
    echo
    echo "最近日志："
    tail -5 "$LOG" 2>/dev/null || echo "  （无日志）"
    exit 0
    ;;
  --log)
    tail -f "$LOG"
    exit 0
    ;;
  --relaunch)
    cat > "$RELAUNCH_SCRIPT" <<'EOF'
#!/bin/zsh
sleep 0.5
osascript -e 'tell application "CodeBuddy CN" to quit' 2>/dev/null
sleep 2
pkill -f "CodeBuddy CN.app/Contents/MacOS/Electron" 2>/dev/null
sleep 1
nohup "/Applications/CodeBuddy CN.app/Contents/MacOS/Electron" --remote-debugging-port=9224 --inspect=127.0.0.1:9244 >/dev/null 2>&1 &
for i in {1..60}; do
  curl -s -m 1 "http://127.0.0.1:9224/json/version" >/dev/null 2>&1 && exit 0
  sleep 0.5
done
exit 1
EOF
    nohup /bin/zsh "$RELAUNCH_SCRIPT" > /tmp/nudge-relaunch.log 2>&1 &
    echo "正在以调试模式重启 CodeBuddy（约 10 秒，会话自动恢复）…"
    for i in $(seq 1 40); do
      sleep 1
      if is_cdp_up; then
        echo "✅ CodeBuddy 已带调试端口重启（nudge 会自动重连）"
        exit 0
      fi
    done
    echo "⚠️ 40 秒端口仍未就绪，看 /tmp/nudge-relaunch.log"
    exit 1
    ;;
  --rebuild)
    echo "重新编译 nudge…"
    (cd "$HOME/workspace/codebuddy-nudge" && swift build 2>&1 | grep -E "error|Build complete" | head -5)
    if is_nudge_running; then
      pkill -f "debug/CodeBuddyNudge"
      sleep 1
    fi
    start_nudge
    exit 0
    ;;
  "")
    start_nudge
    exit 0
    ;;
  *)
    echo "未知参数：$1（可用：--stop --status --log --relaunch --rebuild）"
    exit 1
    ;;
esac
