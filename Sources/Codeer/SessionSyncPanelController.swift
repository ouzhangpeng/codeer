import AppKit
import SwiftUI

/// 会话同步浮窗（替代原 NSMenu 子菜单）
/// - 独立 NSPanel：勾选 / 取消 / 同步操作期间不消失（解决 NSMenu 点选即收起的体验问题）
/// - 失焦不关：用户切到 IDE 操作也保持面板开启；点底部"取消"或同步完成才关闭
final class SessionSyncPanelController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let model: SessionSyncPanelModel

    init(model: SessionSyncPanelModel) {
        self.model = model
        let initialSize = NSSize(width: 520, height: 420)
        self.panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .resizable, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.title = "会话同步"
        panel.isOpaque = false
        panel.backgroundColor = .clear                            // 透明，让 SwiftUI 自己画圆角背景
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.delegate = self
        panel.minSize = NSSize(width: 420, height: 320)
        // NSHostingView 启用 layer，圆角 + 裁剪，SwiftUI 内部 RoundedRectangle 背景被正确剪到圆角内
        let host = NSHostingView(rootView: SessionSyncPanelView(model: model))
        host.wantsLayer = true
        host.layer?.cornerRadius = 10
        host.layer?.masksToBounds = true
        host.layer?.backgroundColor = NSColor(white: 0.97, alpha: 1.0).cgColor
        panel.contentView = host
        model.onClose = { [weak self] in
            self?.panel.orderOut(nil)
        }
    }

    /// 在屏幕中上区域显示（屏幕中央横向、距顶部 1/4 处纵向）
    func show() {
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        // 优先用面板自己记录的尺寸（用户可拖动），否则初始尺寸
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.visibleFrame.maxY - size.height - screen.visibleFrame.height / 4,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    // 失焦不关：用户切到 IDE 操作过程中面板仍可见
    func windowDidResignKey(_ notification: Notification) {
        // 不关闭——保留用户勾选状态
    }
}

/// 面板数据模型（ObservableObject，让 SwiftUI 视图随状态变化更新）
final class SessionSyncPanelModel: ObservableObject {
    struct Entry: Identifiable, Hashable {
        let id: String           // storageId
        let title: String
        let updatedAt: Date
        let userId: String
        let isBusy: Bool
    }

    @Published var entries: [Entry] = []
    @Published var selection: Set<String> = []
    @Published var currentUid: String? = nil
    @Published var currentNickname: String? = nil
    /// 可选目标账号列表（uid != currentUid）
    @Published var targets: [AccountStore.AccountInfo] = []
    /// 当前选中的目标账号 uid
    @Published var selectedTargetUid: String? = nil
    @Published var syncing: Bool = false
    @Published var statusText: String = "正在加载…"
    var onClose: (() -> Void)?
    /// 同步动作（AppDelegate 注入：把勾选 + 目标账号交给 SessionSync）
    var onSync: ((Set<String>, @escaping (String) -> Void) -> Void)?
    /// 重新加载列表
    var onReload: (() -> Void)?

    /// 当前选中的目标账号
    var selectedTarget: AccountStore.AccountInfo? {
        guard let uid = selectedTargetUid else { return nil }
        return targets.first { $0.uid == uid }
    }

    func sync() {
        guard !selection.isEmpty, let target = selectedTarget else { return }
        syncing = true
        statusText = "正在同步到 \(target.nickname)…"
        onSync?(selection) { [weak self] result in
            DispatchQueue.main.async {
                self?.syncing = false
                self?.statusText = result
                if result.hasPrefix("已") {
                    self?.selection.removeAll()
                    // 同步成功后 1.2s 自动关闭，给用户看结果
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        self?.onClose?()
                    }
                }
            }
        }
    }

    func cancel() {
        onClose?()
    }

    func reload() {
        onReload?()
    }
}

/// macOS 风格的窗口关闭按钮（左上角红圆 + 悬停叉号）
/// 浅色模式：normal 纯红圆，hover 同色 + 黑色 xmark（系统行为）
struct MacCloseButton: View {
    let action: () -> Void
    @State private var hover = false

    // macOS 系统红（浅色模式）：normal #FF5F57 / hover 同色 + 黑 xmark
    private static let redNormal = Color(red: 1.00, green: 0.37, blue: 0.34)

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Self.redNormal)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle().strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5)
                    )
                if hover {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(Color(red: 0.40, green: 0.00, blue: 0.00))
                }
            }
            .frame(width: 18, height: 18)   // 比红圆大一圈，保证点击热区 ≥ 18pt
            .contentShape(Rectangle())      // 空白处也响应 hover
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// SwiftUI 面板视图
struct SessionSyncPanelView: View {
    @ObservedObject var model: SessionSyncPanelModel

    // HIG：浅色背景（白底黑字），跟系统 NSMenu 风格统一
    private static let bgDeep    = Color(white: 0.97)            // 主背景（接近白）
    private static let bgRow     = Color.white                    // 列表行
    private static let bgRowSel  = Color.accentColor.opacity(0.18) // 选中行（浅蓝）
    private static let textMain  = Color(white: 0.10)             // 主文字（深黑）
    private static let textSub   = Color(white: 0.40)             // 次级文字（中灰）
    private static let textMuted = Color(white: 0.55)             // 弱化文字（浅灰）
    private static let divider   = Color(white: 0.85)             // 分隔线

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏（HIG：左侧 macOS 红圆关闭按钮 → 标题 → 目标账号 Picker → 状态行）
            HStack(spacing: 8) {
                MacCloseButton {
                    model.onClose?()
                }
                .help("关闭（⌘W）")
                Text("会话同步")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Self.textMain)
                Spacer()
                Text(statusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(Self.textSub)
                if !model.targets.isEmpty {
                    HStack(spacing: 4) {
                        Text("目标：")
                            .font(.system(size: 11))
                            .foregroundStyle(Self.textSub)
                        TargetAccountPicker(
                            targets: model.targets,
                            currentUid: model.currentUid,
                            selectedUid: Binding(
                                get: { model.selectedTargetUid },
                                set: { model.selectedTargetUid = $0 }
                            )
                        )
                        .frame(maxWidth: 160)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(Self.bgDeep)

            Divider().background(Self.divider)

            // 列表
            if model.entries.isEmpty {
                VStack(spacing: 8) {
                    Text("没有会话可同步")
                        .font(.system(size: 13))
                        .foregroundStyle(Self.textSub)
                    Text(model.statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(Self.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Self.bgDeep)
            } else {
                List(selection: $model.selection) {
                    ForEach(model.entries) { entry in
                        HStack(spacing: 8) {
                            if entry.userId != model.currentUid {
                                Text("［另］")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Self.textMuted)
                            }
                            if entry.isBusy {
                                Text("⏳")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Self.textSub)
                            }
                            Text(entry.title)
                                .font(.system(size: 13))
                                .foregroundStyle(Self.textMain)   // 显式白字，避免默认黑色
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            Text(Self.dateFormatter.string(from: entry.updatedAt))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Self.textMuted)
                        }
                        .padding(.vertical, 4)
                        .tag(entry.id)
                        .listRowBackground(
                            model.selection.contains(entry.id)
                                ? Self.bgRowSel
                                : Self.bgRow
                        )
                        .listRowSeparatorTint(Self.divider)
                    }
                }
                .listStyle(.sidebar)                  // macOS 原生行高 + selection 风格
                .scrollContentBackground(.hidden)     // 隐藏 list 默认白底
                .background(Self.bgDeep)
            }

            Divider().background(Self.divider)

            // 底部按钮栏
            HStack(spacing: 8) {
                Button {
                    model.reload()
                } label: {
                    Text("刷新")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Self.textMain)

                Spacer()

                Text("已选 \(model.selection.count) 条")
                    .font(.system(size: 11))
                    .foregroundStyle(Self.textSub)

                Spacer()

                Button {
                    model.cancel()
                } label: {
                    Text("取消")
                        .font(.system(size: 12))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.bordered)
                .tint(Self.textSub)

                Button {
                    model.sync()
                } label: {
                    HStack(spacing: 4) {
                        if model.syncing {
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                        }
                        Text(model.syncing
                             ? "同步中…"
                             : "同步到 \(model.selectedTarget?.nickname ?? "无目标")")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .disabled(model.syncing || model.selection.isEmpty || model.selectedTarget == nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Self.bgDeep)
        }
        .frame(minWidth: 420, minHeight: 320)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Self.bgDeep)
        )
        .preferredColorScheme(.light)                 // 强制浅色，跟系统 NSMenu 风格统一
        .background(                                  // 不可见按钮：承接 ⌘W 关闭快捷键
            Button("") { model.onClose?() }
                .keyboardShortcut("w", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
    }

    private var statusLine: String {
        let nickname = model.currentNickname ?? "未登录"
        let uidMark = model.currentUid.map { String($0.prefix(8)) } ?? ""
        return uidMark.isEmpty
            ? "当前：\(nickname)"
            : "当前：\(nickname) (\(uidMark))"
    }
}

/// 目标账号下拉选择器（macOS 系统风格）
/// - 使用 SwiftUI Picker 配 .menu 样式，跟 NSMenu 视觉一致
/// - 选项格式：nickname（uid 前 8 位）
struct TargetAccountPicker: View {
    let targets: [AccountStore.AccountInfo]
    let currentUid: String?
    @Binding var selectedUid: String?

    var body: some View {
        Picker("", selection: $selectedUid) {
            ForEach(targets, id: \.uid) { acc in
                HStack(spacing: 4) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 10))
                    Text("\(acc.nickname) (\(String(acc.uid.prefix(8)))")
                        .lineLimit(1)
                }
                .tag(acc.uid as String?)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
    }
}
