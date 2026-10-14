import subprocess
import re
#!/usr/bin/env python3
import json
import os
import sys

data = json.load(sys.stdin)
with open(os.path.expanduser("~/.codebuddy/hooks/entry.log"), "a") as f:
    f.write(data.get("hook_event_name", "UNKNOWN") + " " + data.get("tool_name", "") + "\\n")

with open(
    os.path.expanduser("~/.codebuddy/hooks/entry.log"), "a"
) as f:
    f.write(
        data.get("hook_event_name", "UNKNOWN")
        + " "
        + data.get("tool_name", "")
        + "\n"
    )

event = data.get("hook_event_name", "")
tool_input = data.get("tool_input", {})
command = str(tool_input.get("command", ""))

def notify(message):
    import os
    import subprocess
    import datetime

    script = (
        'display notification '
        + json.dumps(message, ensure_ascii=False)
        + ' with title "CodeBuddy" sound name "Ping"'
    )

    uid = str(os.getuid())
    cmd = [
        "/bin/launchctl", "asuser", uid,
        "/usr/bin/osascript", "-e", script
    ]

    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=5
        )
        log = (
            f"{datetime.datetime.now().isoformat()} "
            f"uid={uid} rc={result.returncode} "
            f"stdout={result.stdout!r} stderr={result.stderr!r}\n"
        )
    except Exception as e:
        log = f"{datetime.datetime.now().isoformat()} error={e!r}\n"

    with open(
        os.path.expanduser("~/.codebuddy/hooks/notify.log"), "a"
    ) as f:
        f.write(log)

if event == "PreToolUse":
    patterns = [
        r"\brm\b",                          # 删除文件
        r"\bgit\s+push\b.*--force",         # 强制推送
        r"\bgit\s+reset\s+--hard\b",        # 强制重置
        r"\bgit\s+clean\b",                 # 清理未跟踪文件
        r"\bDROP\s+(DATABASE|TABLE)\b",     # 删除数据库或表
        r"\bTRUNCATE\s+TABLE\b",            # 清空数据表
    ]
    dangerous = any(
        re.search(pattern, command, re.I)
        for pattern in patterns
    )

    with open(os.path.expanduser("~/.codebuddy/hooks/debug.log"), "a") as f:
        f.write(f"command={command!r} dangerous={dangerous!r}\\n")
    if dangerous:
        with open(os.path.expanduser("~/.codebuddy/hooks/entry.log"), "a") as f:
            f.write(f"COMMAND={command!r} DANGEROUS={dangerous}\n")
        notify("检测到危险命令，请查看 CodeBuddy 并确认")
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "ask",
                "permissionDecisionReason":
                    "检测到高风险命令，请确认后执行"
            }
        }, ensure_ascii=False))
    else:
        print(json.dumps({"continue": True}))

elif event == "Stop":
    notify("CodeBuddy 已完成一轮响应，请检查是否需要你继续操作")
    print(json.dumps({"continue": True}))

else:
    print(json.dumps({"continue": True}))
