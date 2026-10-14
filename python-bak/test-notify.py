import os, subprocess
script = 'display notification "PreToolUse 测试通知" with title "CodeBuddy"'
r = subprocess.run(
    ["/usr/bin/osascript", "-e", script],
    capture_output=True, text=True, timeout=5
)
with open(os.path.expanduser("~/.codebuddy/hooks/test-notify.log"), "a") as f:
    f.write(f"rc={r.returncode} stdout={r.stdout!r} stderr={r.stderr!r}\n")
