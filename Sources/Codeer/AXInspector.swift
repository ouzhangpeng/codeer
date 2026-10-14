import AppKit
import ApplicationServices

/// 一个 CodeBuddy 窗口（app + AX 窗口 + 标题）
struct CodeBuddyWindow {
    let app: NSRunningApplication
    let axWindow: AXUIElement
    let title: String
}

enum ConfirmProbe {
    case confirmed    // 发现确认类按钮
    case notFound     // AX 树可达，但没有确认按钮 → 抑制误报
    case unreachable  // AX 树不可读 → 退回启发式
}

enum AXInspector {
    /// 确认类按钮的候选文案（匹配 AXButton 的 title/desc/value）
    static let confirmKeywords = [
        "允许", "允许一次", "总是允许", "接受", "确认", "同意", "批准", "继续", "执行", "运行", "拒绝",
        "allow", "accept", "confirm", "approve", "continue", "proceed", "run", "reject",
    ]

    // MARK: - 进程与窗口枚举

    static func codebuddyApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular else { return false }
            // 主进程可执行文件名为 Electron，必须用 bundle 路径识别
            if let path = app.bundleURL?.path.lowercased(), path.contains("codebuddy") { return true }
            if let path = app.executableURL?.path.lowercased(), path.contains("codebuddy") { return true }
            return (app.localizedName ?? "").lowercased().contains("codebuddy")
        }
    }

    /// Electron/Chromium 需要显式开启辅助功能，web 内容才会暴露到 AX 树
    static func enableWebAccessibility(_ app: NSRunningApplication) {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    static func allWindows() -> [CodeBuddyWindow] {
        codebuddyApps().flatMap { app -> [CodeBuddyWindow] in
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
                  let wins = ref as? [AXUIElement] else { return [] }
            return wins.map { win in
                var titleRef: CFTypeRef?
                let title = AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef) == .success
                    ? (titleRef as? String) ?? "" : ""
                return CodeBuddyWindow(app: app, axWindow: win, title: title)
            }
        }
    }

    // MARK: - 窗口 ↔ 项目匹配

    struct WindowMatch {
        let window: CodeBuddyWindow
        /// 侧栏里匹配到的对话入口按钮（AXPress 可直接打开该对话）
        let conversationButton: AXUIElement?
        let conversationLabel: String?
        let score: Int
    }

    /// 收集窗口侧栏的「对话入口」按钮（label 以相对时间结尾），并解析出近似最后活跃时间
    static func conversationEntries(in window: CodeBuddyWindow) -> [(element: AXUIElement, label: String, date: Date?)] {
        var result: [(AXUIElement, String, Date?)] = []
        var visited = 0
        let timePattern = try! NSRegularExpression(pattern: "(刚刚|[0-9]+\\s*(秒|分钟|小时|天|周|个月)前)$")

        func labelText(_ el: AXUIElement) -> String {
            var parts: [String] = []
            for attr in [kAXTitleAttribute as String, kAXDescriptionAttribute as String, kAXValueAttribute as String] {
                var ref: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success,
                   let s = ref as? String, !s.isEmpty {
                    parts.append(s)
                }
            }
            return parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        }

        func walk(_ el: AXUIElement, _ depth: Int) {
            guard result.count < 40, depth <= 14, visited < 1500 else { return }
            visited += 1
            var roleRef: CFTypeRef?
            let role = AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success
                ? (roleRef as? String) ?? "" : ""
            if role == "AXButton" {
                let label = labelText(el)
                if label.count <= 120,
                   timePattern.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) != nil {
                    result.append((el, label, parseRelativeTime(label)))
                }
            }
            var kidsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kidsRef) == .success,
                  let kids = kidsRef as? [AXUIElement] else { return }
            for kid in kids { walk(kid, depth + 1) }
        }

        walk(window.axWindow, 0)
        return result
    }

    /// "3分钟前" / "2天前" / "刚刚" → 近似日期（侧栏 UI 渲染时刻起算，有少量滞后误差）
    static func parseRelativeTime(_ label: String) -> Date? {
        let now = Date()
        if label.contains("刚刚") { return now }
        let regex = try! NSRegularExpression(pattern: "([0-9]+)\\s*(秒|分钟|小时|天|周|个月)前")
        guard let m = regex.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)),
              let range = Range(m.range(at: 1), in: label),
              let value = TimeInterval(label[range]),
              let unitRange = Range(m.range(at: 2), in: label) else { return nil }
        let unit = String(label[unitRange])
        let seconds: TimeInterval
        switch unit {
        case "秒": seconds = value
        case "分钟": seconds = value * 60
        case "小时": seconds = value * 3600
        case "天": seconds = value * 86400
        case "周": seconds = value * 604800
        case "个月": seconds = value * 2592000
        default: return nil
        }
        return now.addingTimeInterval(-seconds)
    }

    /// 项目 → 窗口/对话匹配：
    /// 窗口选择：对话标题以项目名开头（95）> 窗口标题含项目名（100）> 工作区名匹配（80/60）
    /// 对话选择：解析侧栏相对时间，取「最后活跃时间最接近 pending 发生时刻」的对话——
    ///          等待确认的会话最后写入的就是那次 function_call，其侧栏时间 ≈ pending.since
    static func bestMatch(forProject projectPath: String, projectName: String, activityDate: Date) -> WindowMatch? {
        let windows = allWindows()
        guard !windows.isEmpty else { return nil }
        let comps = projectPath.lowercased().split(separator: "/").map(String.init)
        let name = projectName.lowercased()

        var best: WindowMatch?
        for win in windows {
            var score = 0

            if !name.isEmpty, win.title.lowercased().contains(name) {
                score = max(score, 100)
            }
            let head = win.title.split(separator: "—").first
                .map { $0.replacingOccurrences(of: "\\(.*?\\)", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            if head.count >= 3 {
                if comps.contains(head) {
                    score = max(score, 80)
                } else if comps.contains(where: { $0.hasPrefix(head) }) {
                    score = max(score, 60)
                }
            }

            let entries = conversationEntries(in: win)
            if !name.isEmpty, entries.contains(where: { $0.label.lowercased().hasPrefix(name) }) {
                score = max(score, 95)
            }

            var conv: AXUIElement?
            var convLabel: String?
            if score > 0 {
                let dated = entries.compactMap { entry -> (AXUIElement, String, Date)? in
                    guard let date = entry.date else { return nil }
                    return (entry.element, entry.label, date)
                }
                // 允许 5 分钟误差：取「不晚于 pending 时刻」里最近的；都不满足则取时间最接近的
                let tolerance: TimeInterval = 300
                let before = dated
                    .filter { $0.2 <= activityDate.addingTimeInterval(tolerance) }
                    .max { $0.2 < $1.2 }
                let chosen = before ?? dated.min {
                    abs($0.2.timeIntervalSince(activityDate)) < abs($1.2.timeIntervalSince(activityDate))
                }
                if let chosen {
                    conv = chosen.0
                    convLabel = chosen.1
                } else if let first = entries.first {
                    // 无可解析时间的兜底
                    conv = first.element
                    convLabel = first.label
                }
            }

            if score > 0, best == nil || score > best!.score {
                best = WindowMatch(window: win, conversationButton: conv, conversationLabel: convLabel, score: score)
            }
        }
        return best
    }

    static func bestWindow(forProject projectPath: String, projectName: String, activityDate: Date) -> CodeBuddyWindow? {
        bestMatch(forProject: projectPath, projectName: projectName, activityDate: activityDate)?.window
    }

    // MARK: - 确认按钮探测

    /// 确认按钮探测结果 + 弹窗上下文文本（作为卡片摘要）
    static func probeConfirmationDetailed(_ window: CodeBuddyWindow) -> (probe: ConfirmProbe, summary: String?) {
        enableWebAccessibility(window.app)
        var found = false
        var webReachable = false
        var visited = 0
        var buttonSamples: [String] = []
        var contextTexts: [String] = []

        func text(_ el: AXUIElement, _ attr: String) -> String {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return "" }
            return (ref as? String) ?? ""
        }

        func walk(_ el: AXUIElement, _ depth: Int) {
            guard !found, depth <= 14, visited < 1200 else { return }
            visited += 1
            let role = text(el, kAXRoleAttribute as String)
            if role == "AXWebArea" { webReachable = true }
            if role == "AXButton" {
                let label = [text(el, kAXTitleAttribute as String),
                             text(el, kAXDescriptionAttribute as String),
                             text(el, kAXValueAttribute as String)]
                    .joined(separator: " ").trimmingCharacters(in: .whitespaces)
                let lowered = label.lowercased()
                if !lowered.isEmpty {
                    if buttonSamples.count < 15 { buttonSamples.append(String(label.prefix(40))) }
                    if lowered.count <= 40,
                       confirmKeywords.contains(where: { lowered.hasPrefix($0) }) {
                        found = true
                        NSLog("[probe] 确认按钮: \(label) @ \(window.title)")
                    }
                }
            } else if role == "AXStaticText" {
                let value = text(el, kAXValueAttribute as String)
                if value.count >= 8, value.count <= 120, contextTexts.count < 6 {
                    contextTexts.append(value)
                }
            }
            var kidsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kidsRef) == .success,
                  let kids = kidsRef as? [AXUIElement] else { return }
            for kid in kids { walk(kid, depth + 1) }
        }

        walk(window.axWindow, 0)
        if found {
            return (.confirmed, contextTexts.last)
        }
        if webReachable {
            if shouldLogProbeMiss(window.title) {
                NSLog("[probe] notFound @ \(window.title), 按钮样本: \(buttonSamples.joined(separator: " | "))")
            }
            return (.notFound, nil)
        }
        return (.unreachable, nil)
    }

    static func probeConfirmation(_ window: CodeBuddyWindow) -> ConfirmProbe {
        probeConfirmationDetailed(window).probe
    }

    private static var lastProbeMissLog: [String: Date] = [:]
    private static func shouldLogProbeMiss(_ title: String) -> Bool {
        let last = lastProbeMissLog[title]
        guard let last, Date().timeIntervalSince(last) < 60 else {
            lastProbeMissLog[title] = Date()
            return true
        }
        return false
    }

    /// AX 主检测：轮询所有 CodeBuddy 窗口，发现确认按钮的窗口生成待确认项。
    /// （IDE 面板的转录是事后才写的，等待状态只能靠 AX 实时探测）
    struct AXConfirmation {
        let window: CodeBuddyWindow
        let projectName: String
        let summary: String?
    }

    static func detectConfirmations() -> [AXConfirmation] {
        var out: [AXConfirmation] = []
        for win in allWindows() {
            let (probe, summary) = probeConfirmationDetailed(win)
            guard case .confirmed = probe else { continue }
            // 项目名 = 窗口标题 "—" 前的工作区名（去括号注释）
            let name = win.title.split(separator: "—").first
                .map { $0.replacingOccurrences(of: "\\(.*?\\)", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces) } ?? ""
            out.append(AXConfirmation(window: win, projectName: name, summary: summary))
        }
        return out
    }

    /// 调试：列出所有窗口标题和按钮文本（--axdump）
    static func dump() -> String {
        var out = ""
        for win in allWindows() {
            out += "=== \(win.title) (app: \(win.app.localizedName ?? "?")) ===\n"
            var visited = 0
            func walk(_ el: AXUIElement, _ depth: Int) {
                guard depth <= 14, visited < 1500 else { return }
                visited += 1
                var ref: CFTypeRef?
                let role = AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &ref) == .success
                    ? (ref as? String) ?? "" : ""
                if role == "AXButton" || role == "AXStaticText" {
                    var parts: [String] = []
                    for attr in [kAXTitleAttribute as String, kAXValueAttribute as String, kAXDescriptionAttribute as String] {
                        var v: CFTypeRef?
                        if AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
                           let s = v as? String, !s.isEmpty {
                            parts.append(String(s.prefix(80)))
                        }
                    }
                    if !parts.isEmpty { out += "[\(role)] \(parts.joined(separator: " | "))\n" }
                }
                var kidsRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kidsRef) == .success,
                      let kids = kidsRef as? [AXUIElement] else { return }
                for kid in kids { walk(kid, depth + 1) }
            }
            walk(win.axWindow, 0)
        }
        if out.isEmpty { out = "未找到 CodeBuddy 窗口（应用未运行？）" }
        return out
    }

    /// 调试：全量 dump——所有角色元素 + 系统级窗口清单（CGWindowList），
    /// 用于排查「审批 UI 不在 AXButton/AXWindows 里」的情况（--axdumpall）
    static func dumpAll() -> String {
        var out = ""
        for win in allWindows() {
            out += "=== AX窗口: \(win.title) (app: \(win.app.localizedName ?? "?")) ===\n"
            var visited = 0
            func text(_ el: AXUIElement, _ attr: String) -> String {
                var ref: CFTypeRef?
                guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return "" }
                return (ref as? String) ?? ""
            }
            func walk(_ el: AXUIElement, _ depth: Int) {
                guard depth <= 16, visited < 3000 else { return }
                visited += 1
                let role = text(el, kAXRoleAttribute as String)
                var parts: [String] = []
                for attr in [kAXTitleAttribute as String, kAXValueAttribute as String, kAXDescriptionAttribute as String] {
                    let v = text(el, attr)
                    if !v.isEmpty { parts.append(String(v.prefix(60))) }
                }
                if role != "AXGroup" || !parts.isEmpty {
                    out += String(repeating: " ", count: depth) + "[\(role)] \(parts.joined(separator: " | "))\n"
                }
                var kidsRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kidsRef) == .success,
                      let kids = kidsRef as? [AXUIElement] else { return }
                for kid in kids { walk(kid, depth + 1) }
            }
            walk(win.axWindow, 0)
        }

        // 系统级窗口清单（含 AX 可能不暴露的覆盖层小窗）
        out += "=== CGWindowList (CodeBuddy 进程的窗口) ===\n"
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
            for w in list {
                guard let owner = w[kCGWindowOwnerName as String] as? String,
                      owner.lowercased().contains("codebuddy") || owner == "Electron" else { continue }
                let name = (w[kCGWindowName as String] as? String) ?? "(无标题)"
                let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
                let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
                out += "layer=\(layer) title=\(String(name.prefix(40))) bounds=\(bounds)\n"
            }
        }
        return out
    }
}
