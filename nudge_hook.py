#!/usr/bin/env python3
"""CodeBuddyNudge hook：Stop 完成通知
PreToolUse 已验证不可用于确认提醒（它在 IDE 批准之后才触发，会造成双重确认），
因此本脚本只处理 Stop 事件：Agent 每轮响应结束 → nudge 弹「任务完成」卡。
"""
import json
import os
import sys
import time
import uuid

NUDGE_DIR = os.path.expanduser("~/.codebuddy-nudge")
REQ_DIR = os.path.join(NUDGE_DIR, "requests")


def out(obj):
    print(json.dumps(obj, ensure_ascii=False))


def main():
    os.makedirs(REQ_DIR, exist_ok=True)
    try:
        data = json.loads(sys.stdin.read())
    except Exception:
        out({"continue": True})
        return 0

    if data.get("hook_event_name") != "Stop":
        out({"continue": True})
        return 0

    rid = "stop-" + uuid.uuid4().hex[:8]
    req = {
        "id": rid, "kind": "stop", "tool": "", "command": "",
        "cwd": data.get("cwd", ""), "session_id": data.get("session_id", ""),
        "deadline": time.time() + 30,   # 卡片显示 30s 后自动消失
    }
    with open(os.path.join(REQ_DIR, rid + ".json"), "w") as f:
        json.dump(req, f, ensure_ascii=False)

    out({"continue": True})
    return 0


sys.exit(main())
