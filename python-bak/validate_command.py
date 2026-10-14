#!/usr/bin/env python3
import json
import sys

DANGEROUS_COMMANDS = ['rm', 'dd if=/dev/zero', 'mkfs']

def main():
    input_data = json.loads(sys.stdin.read())

    if input_data.get('tool_name') != 'Bash':
        print(json.dumps({"continue": True}))
        return 0

    command = input_data.get('tool_input', {}).get('command', '')

    for dangerous in DANGEROUS_COMMANDS:
        if dangerous in command:
            output = {
                "continue": False,
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": f"检测到危险命令: {dangerous}"
                }
            }
            print(json.dumps(output, ensure_ascii=False))
            return 0

    print(json.dumps({"continue": True}))
    return 0

if __name__ == "__main__":
    sys.exit(main())
