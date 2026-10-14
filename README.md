# CodeBuddyNudge（已归档）

> **项目状态：已归档放弃（2026-10-10）。** 最初的「等待确认时刘海弹卡 + 直接运行/拒绝」目标经全面实测**不可实现**（原因见下文踩坑记录）。最终可交付的只有基于 **Stop 钩子**的「任务完成」刘海提醒。本仓库保留全部代码与踩坑结论，供未来 CodeBuddy 补齐能力后复活。

## 最终形态：Stop 完成通知

通过 CodeBuddy 官方 Hooks（兼容 Claude Code Hooks 规范），在 Agent 每轮响应结束时于刘海处弹出「任务完成」卡片（深色毛玻璃、Face ID 风格、含项目名，30 秒自动消失，跨 Space/全屏可见）。

```
CodeBuddy Stop 钩子（Agent 每轮响应结束）
  → hook 脚本写事件文件 ~/.codebuddy-nudge/requests/stop-<id>.json
  → nudge 监视该目录弹出卡片，30s 后自动移入 done/
```

### 安装

1. 用户级 `~/.codebuddy/settings.json` 配置 Stop 钩子（matcher 留空匹配全部）：

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/usr/bin/python3 <路径>/nudge_hook.py",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

2. 构建运行：

```bash
swift build
swift run CodeBuddyNudge --selftest   # 自检
swift run CodeBuddyNudge &            # 菜单栏白色铃铛，菜单可开关开机自启（LaunchAgent）
```

## 踩坑记录（实测结论，防止重复走弯路）

### 1. PreToolUse 钩子无法做「确认弹卡」（方向性失败）

**PreToolUse 的真实触发时机：IDE 权限批准之后、命令执行之前——它不是确认事件。** 用户实测三铁证：

| 命令类型 | IDE 行为 | hook 表现 | 结论 |
|---|---|---|---|
| `rm`（IDE 拦截类） | 弹「运行/拒绝」 | 用户在 IDE 点拒绝 → hook 根本不触发 → 无卡片 | 被 IDE 拒绝的命令走不到 hook |
| `kill`（IDE 拦截类） | 弹「运行/拒绝」，用户点运行 | 批准之后 hook 才触发 → 卡片弹出 | 卡片变成多余的第二道确认，且 hook 等待决策期间命令挂起 90s |
| `grep ... \| ...`（IDE 不拦） | 直接执行 | hook 触发 → 卡片弹出 | 对 IDE 认为安全的命令强行加确认，纯噪音 |

若用 hook 输出 `permissionDecision: "ask"` 期望接管确认，只会让 IDE 再弹一次（双重/三重确认）。

### 2. 其他已排除的实时检测路线

- **会话转录**（`~/.codebuddy/projects/*/*.jsonl`）：事后才写，等待确认期间 `~/.codebuddy` 下没有任何落盘信号（traces/jobs 仅覆盖后台任务，且均为静态旧数据）
- **AX 树按钮级检测**：聊天面板 webview 完全未做无障碍暴露——Agents 模式、code 模式、屏幕阅读器模式（`editor.accessibilitySupport: "on"`，按窗口生效）均验证过，审批按钮对 AX 树和 CGWindowList 不可见（工作台壳/编辑器/侧栏可读，聊天区不可读）
- **侧栏对话状态字段**（屏幕阅读器模式下可读，如「等待回复」）：语义未验证且仅 Agents 窗口暴露

### 3. 平台琐碎结论

- CodeBuddy 主进程可执行名是 `Electron`（进程/AX 匹配须用 bundleURL 含 "CodeBuddy" 判断）；`~/.codebuddy/bin/buddycn` 只是 IDE 启动器
- 用户级配置在 `~/.codebuddy/settings.json`，hooks 与 Claude Code 规范兼容，matcher 支持别名（IDE 的 `execute_command` 可被 `"Bash"` 匹配）
- hook 脚本内发 macOS 通知需 `launchctl asuser <uid> osascript ...`（见归档 python-bak/attention.py）

## 代码结构

```
Sources/CodeBuddyNudge/
├── main.swift               入口 + --selftest
├── HookWatcher.swift        hook 事件文件监视 + 心跳 + 决策回写（确认卡路线的协议层，当前仅消费 Stop）
├── PanelController.swift    刘海卡片 UI（确认卡/完成卡两种、倒计时、3 张上限、menu bar 点击穿透）
├── AppDelegate.swift        菜单栏（白色铃铛、开机自启 LaunchAgent、防 App Nap）
├── AXInspector.swift        AX 树遍历/窗口匹配（跳转窗口用；按钮级检测已证伪但代码保留）
└── WindowFocus.swift        按项目名+活跃时间聚焦对话窗口
```

`python-bak/`（位于 buddy 仓库归档）为最初的 hook 验证脚本与日志。

## 调试

- `swift run CodeBuddyNudge --selftest` — 无 GUI 自检
- `swift run CodeBuddyNudge --axdump` / `--axdumpall` — AX 树 / CGWindowList 排查
- 运行日志：`tail -f /tmp/codebuddy-nudge.log`（标签 `[merge] / [ui]`）
- hook 事件文件：`ls ~/.codebuddy-nudge/requests/`
