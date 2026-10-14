import AppKit
import ApplicationServices

/// codeer 用户偏好（UserDefaults 持久化）
enum CodeerPrefs {
    private static let focusKey = "codeer.focusAfterAction"

    /// codeer 卡上操作完成后是否自动跳回对应工作区（默认 false——用户点了开关才跳）
    static var focusAfterAction: Bool {
        get { UserDefaults.standard.bool(forKey: focusKey) }
        set { UserDefaults.standard.set(newValue, forKey: focusKey) }
    }
}

enum WindowFocus {
    /// 精确进入需要确认的 CodeBuddy 对话（后台线程执行 AX 遍历，避免阻塞 UI）：
    /// 1. 按项目名匹配窗口，按「最后活跃时间 ≈ pending 时刻」选中侧栏对话并 AXPress
    /// 2. 无匹配时退化为仅激活 CodeBuddy 应用
    static func focusAsync(projectName: String, projectPath: String, activityDate: Date) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let match = AXInspector.bestMatch(
                forProject: projectPath,
                projectName: projectName,
                activityDate: activityDate
            ) else {
                let titles = AXInspector.allWindows().map { "\($0.title)|" }.joined()
                NSLog("[focus] no match project=\(projectName), windows=\(titles)")
                DispatchQueue.main.async {
                    AXInspector.codebuddyApps().first?.activate()
                }
                return
            }
            if let btn = match.conversationButton {
                let result = AXUIElementPerformAction(btn, kAXPressAction as CFString)
                NSLog("[focus] press conversation (result \(result.rawValue)): \(match.conversationLabel ?? "?")")
            }
            DispatchQueue.main.async {
                AXUIElementPerformAction(match.window.axWindow, kAXRaiseAction as CFString)
                match.window.app.activate()
                NSLog("[focus] raised window: \(match.window.title) (score \(match.score))")
            }
        }
    }

    static func isAccessibilityGranted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
