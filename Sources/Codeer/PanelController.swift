import SwiftUI
import AppKit

// MARK: - Apple HIG 深色模式色板（纯色背景，无毛玻璃）
// 依据 apple-hig-designer skill：深色模式默认纯色背景保证可读性；文字对比度 ≥ 4.5:1

/// 面板底/标题条（--bg-secondary）
private let bgPanel = Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255)
/// 卡片主体（--bg-tertiary）
private let bgCard = Color(red: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255)
/// 内嵌块（回到 bg-secondary，形成层级）
private let bgInset = Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255)
/// 主标签（深色模式 label）
private let labelPrimary = Color.white
/// 次级标签（rgba(235,235,245,0.6)）
private let labelSecondary = Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255, opacity: 0.6)
/// 分割线
private let separatorColor = Color(red: 84 / 255, green: 84 / 255, blue: 88 / 255, opacity: 0.6)
/// CodeBuddy 品牌色（从 IDE 主按钮 .cb-button--primary 实测提取：rgb(40,184,148) 配白字）
private let brandGreen = Color(red: 40 / 255, green: 184 / 255, blue: 148 / 255)
/// 语义色保持语义：拒绝红 / 成功绿
private let sysRed = Color(red: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255)

private let hudAccent = brandGreen
private let allowColor = brandGreen
private let denyColor = sysRed

/// 工具类型 → SF Symbol 图标
private func toolIcon(_ tool: String) -> String {
    switch tool.lowercased() {
    case "bash", "shell", "terminal", "execute_command":
        return "terminal"
    case "write", "write_to_file", "edit", "replace_in_file":
        return "square.and.pencil"
    case "read", "read_file":
        return "doc.text"
    case "grep", "glob", "search_files":
        return "magnifyingglass"
    case "askuserquestion", "question":
        return "questionmark.bubble"
    default:
        return "wrench.and.screwdriver"
    }
}

// MARK: - 按钮（HIG：胶囊形；主=蓝底白字 / 次=蓝字浅蓝底 / 破坏性=红字）

private enum ButtonStyleKind { case primary, secondary, destructive }

private func higButtonLabel(_ title: String, icon: String, kind: ButtonStyleKind) -> some View {
    let fg: Color
    let bg: Color
    switch kind {
    case .primary: fg = .white; bg = brandGreen
    case .secondary: fg = brandGreen; bg = brandGreen.opacity(0.12)
    case .destructive: fg = sysRed; bg = bgCard.opacity(0.5)
    }
    return HStack(spacing: 4) {
        Image(systemName: icon).font(.system(size: 9, weight: .bold))
        Text(title).font(.system(size: 12, weight: .semibold))
    }
    .foregroundStyle(fg)
    .frame(maxWidth: .infinity, minHeight: 28)
    .background(Capsule().fill(bg))
    .contentShape(Capsule())
}

/// 面板共享状态
final class PendingModel: ObservableObject {
    @Published var items: [PendingItem] = []
    @Published var collapsed = false
    /// 顶部留白（有刘海 = menu bar 高度；无刘海 = 浮动边距）
    @Published var topInset: CGFloat = 32
    @Published var hasNotch = true
    /// 每秒跳一次，驱动倒计时刷新
    @Published var tick = 0
    var onDecide: ((PendingItem, Bool) -> Void)?
    var onSkip: ((PendingItem) -> Void)?
    var onPickOption: ((PendingItem, String) -> Void)?
    var onCustomInput: ((PendingItem) -> Void)?
    var onCloseAll: (() -> Void)?
    var onOpen: ((PendingItem) -> Void)?
}

/// 确认卡内容：完整命令（等宽、可多行）+ 拒绝/跳过/运行（外框由面板容器统一提供）
struct ConfirmCardView: View {
    let item: PendingItem
    let tick: Int
    let onDecide: (Bool) -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: toolIcon(item.toolName))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(brandGreen)
                Text(item.projectName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(labelPrimary)
                    .lineLimit(1)
                Spacer()
                Text("等待确认")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(labelSecondary)
            }
            Text(item.summary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.88))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(bgInset))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(separatorColor.opacity(0.5))
                )
            HStack(spacing: 8) {
                Button { onDecide(false) } label: {
                    higButtonLabel("拒绝", icon: "xmark", kind: .destructive)
                }
                .buttonStyle(.plain)
                Button { onSkip() } label: {
                    higButtonLabel("跳过", icon: "forward.end", kind: .secondary)
                }
                .buttonStyle(.plain)
                Button { onDecide(true) } label: {
                    higButtonLabel("运行", icon: "play.fill", kind: .primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 内容高度估算：标题行 20 + 命令块（按字数折行）+ 按钮 28 + 间距
    static func cardHeight(_ item: PendingItem) -> CGFloat {
        let charsPerLine = 40.0
        let lines = max(1, (Double(item.summary.count) / charsPerLine).rounded(.up))
        return 80 + CGFloat(lines) * 15
    }
}

/// 完成通知卡内容
struct StopCardView: View {
    let projectName: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(allowColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("任务完成")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(labelPrimary)
                Text("\(projectName) 的一轮响应已结束，回来看看")
                    .font(.system(size: 11))
                    .foregroundStyle(labelSecondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

/// 选项卡内容：问题 + 候选列表，点选项直接代点；末尾「自定义输入」聚焦 IDE 输入框
struct OptionCardView: View {
    let item: PendingItem
    let onPick: (String) -> Void
    let onCustom: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(brandGreen)
                Text(item.projectName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(labelPrimary)
                    .lineLimit(1)
                Spacer()
                Text("请选择")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(labelSecondary)
            }
            if !item.summary.isEmpty {
                Text(item.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(item.options.prefix(6).enumerated()), id: \.offset) { _, option in
                Button(action: { onPick(option) }) {
                    HStack(spacing: 8) {
                        Circle().fill(brandGreen).frame(width: 5, height: 5)
                        Text(option)
                            .font(.system(size: 12))
                            .foregroundStyle(labelPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(labelSecondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(bgInset))
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            if item.kind != "background" {
                Button(action: onCustom) {
                    HStack(spacing: 5) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 9, weight: .semibold))
                        Text("自定义输入（去 IDE）")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(labelSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(bgInset.opacity(0.6)))
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    static func cardHeight(_ item: PendingItem) -> CGFloat {
        let optionRows = CGFloat(min(item.options.count, 6))
        let base: CGFloat = 48
        let question: CGFloat = item.summary.isEmpty ? 0 : 34
        return base + question + optionRows * 33 + 30
    }
}

struct PanelContentView: View {
    @ObservedObject var model: PendingModel

    var body: some View {
        Group {
            if model.collapsed { collapsedPill } else { expandedCard }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var collapsedPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 12))
                .foregroundStyle(brandGreen)
            Text("\(model.items.count)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(labelPrimary)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(separatorColor.opacity(0.5)))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .padding(.top, model.topInset)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { model.collapsed = false }
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(brandGreen)
                Text("CodeBuddy")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(labelPrimary)
                Spacer()
                closeAllButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Rectangle()
                .fill(separatorColor.opacity(0.6))
                .frame(height: 1)
        }
    }

    private var closeAllButton: some View {
        Button { model.onCloseAll?() } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(labelSecondary)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    /// 标题条与内容合在一张卡里，零缝隙
    private var expandedCard: some View {
        VStack(spacing: 0) {
            header
            if let item = model.items.first {
                Group {
                    switch item.kind {
                    case "stop":
                        StopCardView(projectName: item.projectName)
                            .padding(12)
                    case "background", "options":
                        OptionCardView(
                            item: item,
                            onPick: { option in model.onPickOption?(item, option) },
                            onCustom: { model.onCustomInput?(item) }
                        )
                        .padding(12)
                    default:
                        ConfirmCardView(
                            item: item,
                            tick: model.tick,
                            onDecide: { allow in model.onDecide?(item, allow) },
                            onSkip: { model.onSkip?(item) }
                        )
                        .padding(12)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if item.kind == "confirm" { model.onOpen?(item) }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(bgCard))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(separatorColor.opacity(0.6))
        )
        .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .padding(.top, model.topInset)
    }
}

/// 托管视图：menu bar 重叠带内的点击穿透给下层（如状态栏图标），仅放行右上「全部关闭」按钮
final class NotchHostingView: NSHostingView<PanelContentView> {
    var menuBarBandHeight: CGFloat = 0
    var closeButtonFrame: NSRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        if menuBarBandHeight > 0 {
            let fromTop = frame.height - point.y
            if fromTop < menuBarBandHeight {
                if closeButtonFrame.insetBy(dx: -8, dy: -8).contains(point) {
                    return super.hitTest(point)
                }
                return nil
            }
        }
        return super.hitTest(point)
    }
}

/// 刘海处的置顶透明面板
final class PanelController {
    let model = PendingModel()
    private let panel: NSPanel
    private let hosting: NotchHostingView

    private var lastItems: [PendingItem] = []
    private var dismissed = Set<String>()
    private var tickTimer: Timer?
    /// 卡片决策回调（AppDelegate 接到 ApprovalMonitor.decide）
    var onDecide: ((PendingItem, Bool) -> Void)?
    /// 跳过回调
    var onSkip: ((PendingItem) -> Void)?
    /// 选项卡回调（AppDelegate 接到 ApprovalMonitor.decide(option:)）
    var onPickOption: ((PendingItem, String) -> Void)?
    /// 自定义输入回调（AppDelegate 接到 ApprovalMonitor.decideCustomInput）
    var onCustomInput: ((PendingItem) -> Void)?

    private static let expandedWidth: CGFloat = 440
    private static let collapsedWidth: CGFloat = 100
    /// 单卡模式：一次只处理一张卡，处理完自动弹下一张
    private static let maxVisibleCards = 1

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.expandedWidth, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // 用 .floating 而非 .statusBar：HiddenBar 折叠时只影响 status bar 那一行，
        // floating 面板锚定在 visibleFrame 顶部（status bar 下方），不受折叠影响
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = true
        panel.becomesKeyOnlyIfNeeded = true

        hosting = NotchHostingView(rootView: PanelContentView(model: model))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.model.tick += 1
        }

        model.onDecide = { [weak self] item, allow in
            self?.dismissed.insert(item.id)
            self?.onDecide?(item, allow)
        }
        model.onSkip = { [weak self] item in
            self?.dismissed.insert(item.id)
            self?.onSkip?(item)
        }
        model.onPickOption = { [weak self] item, option in
            self?.dismissed.insert(item.id)
            self?.onPickOption?(item, option)
        }
        model.onCustomInput = { [weak self] item in
            // 不 dismiss：用户还要回 IDE 输入，卡片保留
            self?.onCustomInput?(item)
        }
        model.onCloseAll = { [weak self] in
            self?.dismissed.formUnion(self?.model.items.map { $0.id } ?? [])
            self?.refresh()
        }
        model.onOpen = { [weak self] item in
            WindowFocus.focusAsync(projectName: item.projectName, projectPath: item.projectPath, activityDate: item.since)
        }
    }

    @discardableResult
    func update(items: [PendingItem]) -> Int {
        lastItems = items
        refresh()
        return model.items.count
    }

    private func refresh() {
        // 过滤：已处理 + 超时的 confirm
        dismissed = dismissed.filter { id in lastItems.contains(where: { $0.id == id }) }
        var visible = lastItems.filter { !dismissed.contains($0.id) }
        visible = Array(visible.prefix(Self.maxVisibleCards))

        let previous = model.items.count
        model.items = visible
        if visible.isEmpty {
            panel.orderOut(nil)
            return
        }
        if visible.count > previous {
            model.collapsed = false
            NSSound(named: "Ping")?.play()
        }
        relayout()
        panel.orderFrontRegardless()
    }

    private func relayout() {
        guard let screen = NSScreen.main else { return }
        let notchHeight = max(screen.safeAreaInsets.top, 0)
        model.hasNotch = notchHeight > 1
        let width: CGFloat
        let height: CGFloat
        if model.collapsed {
            model.topInset = notchHeight > 1 ? notchHeight : 8
            width = Self.collapsedWidth
            height = model.topInset + 36
        } else {
            model.topInset = notchHeight > 1 ? max(notchHeight - 26, 4) : 8
            // 高度 = 标题行(33) + 内容（按卡片类型与内容估算）+ 底部留白(10)
            let contentHeight: CGFloat
            if let item = model.items.first {
                switch item.kind {
                case "options", "background": contentHeight = OptionCardView.cardHeight(item)
                case "confirm": contentHeight = ConfirmCardView.cardHeight(item)
                default: contentHeight = 44
                }
            } else {
                contentHeight = 44
            }
            width = Self.expandedWidth
            height = model.topInset + 33 + contentHeight + 12 + 10
        }
        hosting.menuBarBandHeight = model.hasNotch ? notchHeight : 0
        hosting.closeButtonFrame = NSRect(
            x: width - 42, y: height - model.topInset - 30, width: 36, height: 32
        )
        // 锚定到 visibleFrame（不含 status bar / dock）顶部：HiddenBar 折叠只影响 status bar 那一行，
        // 面板贴在刘海下沿（visibleFrame.maxY == 刘海底），不受折叠影响
        let frame = NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.visibleFrame.maxY - height,
            width: width,
            height: height
        )
        panel.setFrame(frame, display: true)
    }
}
