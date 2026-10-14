#!/bin/bash
#
# 以调试模式启动 CodeBuddy CN（供 nudge 监视与账号切换使用）
#
# 说明：
#   调试端口 = CDP 9224（聊天面板监视）+ Node inspector 9244（主进程账号切换）。
#   CodeBuddy 正常运行时不会带这些端口，所以要用本命令启动，
#   或在已跑着一个「无端口实例」时由本命令拒绝重复启动（避免开两个实例）。
#
# 用法：
#   codebuddy            # 启动（已在运行则提示，不做任何破坏性操作）
#   codebuddy --stop     # 退出 CodeBuddy（正常退出超时 8s 自动强杀）
#   codebuddy --status   # 查看运行状态与端口

set -u

APP="/Applications/CodeBuddy CN.app/Contents/MacOS/Electron"
CDP_PORT=9224
LOG=/tmp/codebuddy-launch.log

is_running() {
  # pgrep -f 对含空格的长路径在本机表现不稳定，用 ps+grep
  ps -axo command | grep -v grep | grep -q "CodeBuddy CN.app/Contents/MacOS/Electron"
}

is_cdp_up() {
  curl --noproxy '*' -s --max-time 2 "http://127.0.0.1:${CDP_PORT}/json/version" 2>/dev/null | grep -q '"Browser"'
}

case "${1:-}" in
  --stop)
    if ! is_running; then
      echo "CodeBuddy 未在运行"
      exit 0
    fi
    osascript -e 'tell application "CodeBuddy CN" to quit' 2>/dev/null
    for i in $(seq 1 8); do
      sleep 1
      if ! is_running; then
        echo "✅ CodeBuddy 已正常退出"
        exit 0
      fi
    done
    echo "⚠️ 正常退出超时（8s），强制结束…"
    pkill -f "CodeBuddy CN.app/Contents/MacOS/Electron"
    sleep 1
    is_running && { echo "❌ 强制结束失败，请手动强退"; exit 1; } || echo "✅ 已强制结束"
    exit 0
    ;;
  --status)
    if is_running; then
      echo "✅ CodeBuddy 正在运行"
      if is_cdp_up; then
        echo "✅ 调试端口 ${CDP_PORT} 正常（nudge 可用）"
      else
        echo "❌ 调试端口 ${CDP_PORT} 不通（这次不是用 codebuddy 命令启动的）"
        echo "   修复：nudge --relaunch 重启一次（会话自动恢复）"
      fi
    else
      echo "❌ CodeBuddy 未运行（执行 codebuddy 以调试模式启动）"
    fi
    exit 0
    ;;
  "")
    ;;
  *)
    echo "未知参数：$1（可用：--status）"
    exit 1
    ;;
esac

if is_running; then
  echo "✅ CodeBuddy 已在运行。"
  if is_cdp_up; then
    echo "   调试端口正常，nudge 可用。"
  else
    echo "   ⚠️ 但当前实例没有调试端口（可能是手动启动的）。"
    echo "      需要调试端口时：退出 CodeBuddy 后重新执行 codebuddy，"
    echo "      或直接 nudge --relaunch（自动重启并保留会话）。"
  fi
  exit 0
fi

nohup "$APP" \
  --remote-debugging-port="${CDP_PORT}" \
  --inspect=127.0.0.1:9244 \
  > "$LOG" 2>&1 &

echo "正在以调试模式启动 CodeBuddy…"
for i in $(seq 1 20); do
  sleep 1
  if is_cdp_up; then
    echo "✅ 启动成功（CDP ${CDP_PORT} + inspector 9244）"
    echo "   日志：tail -20 $LOG"
    exit 0
  fi
done
echo "⚠️ 20 秒端口仍未就绪，看日志：tail -20 $LOG"
exit 1
