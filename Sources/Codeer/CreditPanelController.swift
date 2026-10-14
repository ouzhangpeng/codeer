import AppKit
import SwiftUI

// MARK: - 面板控制器（会话同步同款：独立 NSPanel、失焦不关、浅色圆角、⌘W）

final class CreditPanelController: NSObject {
    private let panel: NSPanel
    private let model: CreditPanelModel

    init(model: CreditPanelModel) {
        self.model = model
        let initialSize = NSSize(width: 560, height: 520)
        self.panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .resizable, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.title = "积分看板"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.minSize = NSSize(width: 480, height: 400)
        let host = NSHostingView(rootView: CreditPanelView(model: model))
        host.wantsLayer = true
        host.layer?.cornerRadius = 10
        host.layer?.masksToBounds = true
        host.layer?.backgroundColor = NSColor(white: 0.97, alpha: 1.0).cgColor
        panel.contentView = host
        model.onClose = { [weak self] in self?.panel.orderOut(nil) }
    }

    func show() {
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.visibleFrame.maxY - size.height - screen.visibleFrame.height / 4,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        // 面板复用（关闭只是 orderOut），onAppear 只在首次触发 → 每次打开都主动刷新
        model.reload(force: true)
    }
}

// MARK: - 面板数据模型

final class CreditPanelModel: ObservableObject {
    struct Row: Identifiable {
        let id: String            // uid
        let nickname: String
        let credits: Double
        let totalDosage: Double
        let segments: [CreditSegment]
        let error: String?
    }

    struct ExpiringItem: Identifiable {
        let id: String            // uid|source|date
        let nickname: String
        let source: String
        let remaining: Double
        let date: Date
    }

    @Published var rows: [Row] = []
    @Published var expiring: [ExpiringItem] = []
    @Published var totalCredits: Double = 0
    @Published var usageDays: [UsageDay] = []
    @Published var usageModels: [(model: String, credit: Double)] = []
    @Published var usageTotal: Double = 0
    @Published var usageDaysWindow: Int = 7
    @Published var loading = false
    @Published var statusText = "正在加载…"
    var onClose: (() -> Void)?

    private var cache: (accounts: [CreditSummary], usage: [String: UsageAggregate])?

    func reload(force: Bool) {
        guard !loading else { return }
        loading = true
        statusText = "正在查询各账号积分…"
        let window = usageDaysWindow
        Task { [weak self] in
            guard let self else { return }
            let startedAt = Date()
            let (accounts, usage) = await CreditService.shared.fetchAll(days: window)
            await MainActor.run { [weak self] in
                guard let self else { return }
                var rows: [Row] = []
                var expiring: [ExpiringItem] = []
                var total = 0.0
                let threshold = Date().addingTimeInterval(30 * 24 * 3600)
                for acc in accounts {
                    rows.append(Row(
                        id: acc.uid, nickname: acc.nickname,
                        credits: acc.credits, totalDosage: acc.totalDosage,
                        segments: acc.segments, error: acc.error
                    ))
                    total += acc.credits
                    for seg in acc.segments {
                        guard let date = seg.expiresAt, date <= threshold, seg.remaining > 0 else { continue }
                        expiring.append(ExpiringItem(
                            id: "\(acc.uid)|\(seg.source)|\(date.timeIntervalSince1970)",
                            nickname: acc.nickname, source: seg.source,
                            remaining: seg.remaining, date: date
                        ))
                    }
                }
                expiring.sort { $0.date < $1.date }
                self.rows = rows
                // 只展示最近过期的 3 条
                self.expiring = Array(expiring.prefix(3))
                self.totalCredits = (total * 100).rounded() / 100
                // 用量：多账号合并展示（各账号日聚合求和）
                var dayMap: [String: (credit: Double, count: Int)] = [:]
                var modelMap: [String: Double] = [:]
                var usageTotal = 0.0
                for acc in accounts {
                    guard let agg = usage[acc.uid] else { continue }
                    for day in agg.days {
                        let cur = dayMap[day.date] ?? (0, 0)
                        dayMap[day.date] = (cur.credit + day.credit, cur.count + day.requests)
                    }
                    for m in agg.models { modelMap[m.model, default: 0] += m.credit }
                    usageTotal += agg.total
                }
                self.usageDays = dayMap.keys.sorted().map {
                    UsageDay(date: $0, credit: (dayMap[$0]!.credit * 100).rounded() / 100, requests: dayMap[$0]!.count)
                }
                self.usageModels = modelMap.map { (model: $0.key, credit: $0.value) }.sorted { $0.credit > $1.credit }
                self.usageTotal = (usageTotal * 100).rounded() / 100
                self.loading = false
                let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
                self.statusText = "已查询 \(rows.count) 个账号（\(elapsed)ms）"
            }
        }
    }

    func setWindow(_ days: Int) {
        guard usageDaysWindow != days else { return }
        usageDaysWindow = days
        reload(force: true)
    }
}

// MARK: - SwiftUI 视图

struct CreditPanelView: View {
    @ObservedObject var model: CreditPanelModel

    private static let bgDeep   = Color(white: 0.97)
    private static let bgRow    = Color.white
    private static let textMain = Color(white: 0.10)
    private static let textSub  = Color(white: 0.40)
    private static let textMuted = Color(white: 0.55)
    private static let divider  = Color(white: 0.85)
    private static let accent   = Color(red: 40 / 255, green: 184 / 255, blue: 148 / 255)   // CodeBuddy 品牌绿
    private static let warn     = Color.orange

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd"; return f
    }()
    private static let fullFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Self.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    accountSection
                    if !model.expiring.isEmpty { expiringSection }
                    usageSection
                }
                .padding(14)
            }
            Divider().background(Self.divider)
            footer
        }
        .frame(minWidth: 480, minHeight: 400)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Self.bgDeep)
        )
        .preferredColorScheme(.light)
        .background(
            Button("") { model.onClose?() }
                .keyboardShortcut("w", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        )
    }

    // 刷新按钮
    private var refreshButton: some View {
        Button {
            model.reload(force: true)
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(model.loading ? Self.textMuted : Self.textSub)
        }
        .buttonStyle(.plain)
        .disabled(model.loading)
        .help("刷新")
    }

    // 标题栏
    private var header: some View {
        HStack(spacing: 8) {
            MacCloseButton { model.onClose?() }.help("关闭（⌘W）")
            Text("积分看板")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Self.textMain)
            Spacer()
            Text(model.loading ? "查询中…" : model.statusText)
                .font(.system(size: 11))
                .foregroundStyle(Self.textSub)
            refreshButton
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Self.bgDeep)
    }

    // 账号积分区
    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("账号积分")
            ForEach(model.rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(row.nickname)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Self.textMain)
                        Spacer()
                        if let err = row.error {
                            Text("查询失败：\(err)")
                                .font(.system(size: 11))
                                .foregroundStyle(Self.warn)
                                .lineLimit(1)
                        } else {
                            Text("\(row.credits, specifier: "%.2f")")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(Self.accent)
                            Text("/ 已用 \(row.totalDosage, specifier: "%.0f")")
                                .font(.system(size: 11))
                                .foregroundStyle(Self.textMuted)
                        }
                    }
                    if row.error == nil {
                        // 用量进度条（已用占比）
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Self.divider)
                                let ratio = row.totalDosage > 0 ? min(row.totalDosage / max(row.credits + row.totalDosage, 1), 1) : 0
                                Capsule().fill(Self.accent.opacity(0.7)).frame(width: geo.size.width * ratio)
                            }
                        }
                        .frame(height: 5)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Self.bgRow))
            }
            if !model.rows.isEmpty {
                HStack {
                    Text("总积分")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Self.textMain)
                    Spacer()
                    Text("\(model.totalCredits, specifier: "%.2f")")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Self.accent)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    // 过期提醒区
    private var expiringSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("即将过期（30 天内）")
            ForEach(model.expiring) { item in
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Self.warn)
                    Text("\(item.nickname) · \(item.source)")
                        .font(.system(size: 12))
                        .foregroundStyle(Self.textMain)
                        .lineLimit(1)
                    Spacer()
                    Text("\(item.remaining, specifier: "%.0f") 分")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Self.warn)
                    Text(Self.fullFmt.string(from: item.date))
                        .font(.system(size: 11))
                        .foregroundStyle(Self.textSub)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Self.warn.opacity(0.08)))
            }
        }
    }

    // 用量统计区
    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("用量统计")
                Spacer()
                Picker("", selection: Binding(
                    get: { model.usageDaysWindow },
                    set: { model.setWindow($0) }
                )) {
                    Text("近 7 天").tag(7)
                    Text("近 30 天").tag(30)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 130)
                .controlSize(.small)
            }
            if model.usageDays.isEmpty {
                Text("所选时间范围内无用量记录")
                    .font(.system(size: 12))
                    .foregroundStyle(Self.textMuted)
                    .padding(.vertical, 8)
            } else {
                // 按日柱状图
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(model.usageDays, id: \.date) { day in
                        VStack(spacing: 2) {
                            Text("\(day.credit, specifier: "%.0f")")
                                .font(.system(size: 8))
                                .foregroundStyle(Self.textMuted)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Self.accent.opacity(0.75))
                                .frame(height: max(4, barHeight(day.credit)))
                            Text(String(day.date.suffix(5)))
                                .font(.system(size: 7))
                                .foregroundStyle(Self.textMuted)
                        }
                        .frame(maxWidth: .infinity)
                        .help("\(day.date)：\(day.credit, specifier: "%.2f") 积分 / \(day.requests) 次请求")
                    }
                }
                .frame(height: 96)
                // 按模型 Top
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.usageModels, id: \.model) { m in
                        HStack {
                            Text(m.model)
                                .font(.system(size: 11))
                                .foregroundStyle(Self.textSub)
                                .lineLimit(1)
                            Spacer()
                            Text("\(m.credit, specifier: "%.2f")")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Self.textMain)
                        }
                    }
                }
                Text("合计：\(model.usageTotal, specifier: "%.2f") 积分")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Self.textSub)
            }
        }
    }

    private func barHeight(_ credit: Double) -> CGFloat {
        let maxCredit = model.usageDays.map(\.credit).max() ?? 0
        guard maxCredit > 0 else { return 4 }
        return CGFloat(credit / maxCredit) * 62
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Self.textSub)
    }

    // 底部（预留）
    private var footer: some View {
        HStack {
            Spacer()
            Text("数据源：workbuddy 积分接口 · 各账号凭快照 token 直查，无需切换")
                .font(.system(size: 10))
                .foregroundStyle(Self.textMuted)
            Spacer()
        }
        .padding(.vertical, 8)
        .background(Self.bgDeep)
    }
}
