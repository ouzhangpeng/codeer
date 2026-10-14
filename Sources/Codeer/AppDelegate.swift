import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var cdpStatusMenuItem: NSMenuItem?
    private var accountStatusMenuItem: NSMenuItem?
    private var activity: NSObjectProtocol?
    private let panel = PanelController()
    private var monitor: ApprovalMonitor?

    // M2 会话同步状态
    private var sessionSelection = Set<String>()
    private var cachedSessionEntries: [SessionSync.SessionEntry] = []
    private var cachedSessionRawValues: [String: [String: Any]] = [:]
    private var sessionListLoading = false
    private var sessionListLoaded = false
    private var syncInFlight = false
    private var sessionSyncPanel: SessionSyncPanelController?
    private lazy var sessionSyncModel = SessionSyncPanelModel()
    // M3 积分看板
    private var creditPanel: CreditPanelController?
    private lazy var creditModel = CreditPanelModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated],
            reason: "Codeer 需要持续监视确认请求"
        )
        migrateLegacyDataDir()
        if !WindowFocus.isAccessibilityGranted(prompt: false) {
            NSLog("[Codeer] 未授予辅助功能权限，部分跳转能力退化")
        }

        setupStatusItem()

        let monitor = ApprovalMonitor(panel: panel)
        panel.onDecide = { [weak monitor] item, allow in
            _ = item
            monitor?.decide(allow: allow, item: item)
        }
        panel.onSkip = { [weak monitor] item in
            _ = item
            monitor?.decideSkip(item: item)
        }
        panel.onPickOption = { [weak monitor] item, option in
            _ = item
            monitor?.decide(option: option, item: item)
        }
        panel.onPickMulti = { [weak monitor] item, options in
            _ = item
            monitor?.decideMulti(options: options, item: item)
        }
        panel.onCustomInput = { [weak monitor] item in
            monitor?.decideCustomInput(item: item)
        }
        self.monitor = monitor
        monitor.start()

        NSLog("[Codeer] started (CDP edition)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    // MARK: - 菜单栏

    /// 一次性迁移旧目录名（CodeBuddyNudge → Codeer）：账号快照/会话备份整体搬过来
    private func migrateLegacyDataDir() {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let legacy = base.appendingPathComponent("CodeBuddyNudge", isDirectory: true)
        let target = base.appendingPathComponent("Codeer", isDirectory: true)
        guard FileManager.default.fileExists(atPath: legacy.path), !FileManager.default.fileExists(atPath: target.path) else { return }
        do {
            try FileManager.default.moveItem(at: legacy, to: target)
            NSLog("[Codeer] 已迁移旧数据目录 CodeBuddyNudge → Codeer")
        } catch {
            NSLog("[Codeer] 旧数据目录迁移失败：%@", error.localizedDescription)
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = deerAssetIcon()
        // 关键：固定 autosaveName，让 macOS 把 codeer 图标当作稳定 item。
        // 没设的话，NSStatusBar 不会把它的位置写进 user defaults，重启后回到默认位置（左），
        // HiddenBar 也无法识别它属于"右侧白名单"——结果就是拖到右边也会被折回去。
        item.autosaveName = "com.codeer.app.statusItem"
        let menu = NSMenu()
        menu.delegate = self
        rebuild(menu: menu)
        item.menu = menu
        statusItem = item
    }

    /// 每次打开菜单时重建（账号列表/状态保持最新）
    func menuWillOpen(_ menu: NSMenu) {
        rebuild(menu: menu)
    }

    private func rebuild(menu: NSMenu) {
        menu.removeAllItems()

        // M1：CDP 监视状态
        let statusLine = NSMenuItem(title: "CDP：监视中", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        // M2：账号区
        let accountLine = NSMenuItem(title: "账号：读取中…", action: nil, keyEquivalent: "")
        accountLine.isEnabled = false
        menu.addItem(accountLine)
        accountStatusMenuItem = accountLine
        refreshAccountStatus(menu: menu)

        menu.addItem(.separator())

        let backup = NSMenuItem(
            title: "备份当前账号",
            action: #selector(backupCurrentAccount(_:)),
            keyEquivalent: ""
        )
        backup.target = self
        menu.addItem(backup)

        let accounts = AccountStore.shared.list()
        if !accounts.isEmpty {
            let listTitle = NSMenuItem(title: "已保存账号：", action: nil, keyEquivalent: "")
            listTitle.isEnabled = false
            menu.addItem(listTitle)
            for account in accounts {
                let line = NSMenuItem(
                    title: "  切换到 \(account.nickname)",
                    action: #selector(switchAccount(_:)),
                    keyEquivalent: ""
                )
                line.target = self
                line.representedObject = account.uid
                menu.addItem(line)
            }
        }

        menu.addItem(.separator())

        // M2：会话同步（点击直接弹浮窗，不再走 submenu 中转）
        let syncItem = NSMenuItem(
            title: "会话同步",
            action: #selector(openSessionSyncPanel(_:)),
            keyEquivalent: ""
        )
        menu.addItem(syncItem)

        // M3：积分看板（各账号积分/用量统计/过期提醒）
        let creditItem = NSMenuItem(
            title: "积分看板",
            action: #selector(openCreditPanel(_:)),
            keyEquivalent: ""
        )
        menu.addItem(creditItem)

        // 偏好：卡上操作完成后是否自动跳回对应工作区（默认关）
        let focusToggle = NSMenuItem(
            title: "操作后自动跳回工作区",
            action: #selector(toggleFocusAfterAction(_:)),
            keyEquivalent: ""
        )
        focusToggle.target = self
        focusToggle.state = CodeerPrefs.focusAfterAction ? .on : .off
        menu.addItem(focusToggle)

        menu.addItem(.separator())

        let restart = NSMenuItem(title: "重启监视", action: #selector(restartMonitor(_:)), keyEquivalent: "")
        restart.target = self
        menu.addItem(restart)

        let relaunch = NSMenuItem(title: "以调试模式重启 CodeBuddy", action: #selector(relaunchDebug(_:)), keyEquivalent: "")
        relaunch.target = self
        menu.addItem(relaunch)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 Codeer", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// 异步刷新「当前账号」状态行（CodeBuddy 重启空档会失败，重试几次）
    private func refreshAccountStatus(menu: NSMenu) {
        Task {
            for attempt in 1...4 {
                do {
                    if let session = try await NativeAuth.shared.readSession() {
                        await MainActor.run {
                            self.accountStatusMenuItem?.title = "账号：\(session.nickname)"
                        }
                        return
                    }
                    await MainActor.run {
                        self.accountStatusMenuItem?.title = "账号：未登录"
                    }
                    return
                } catch {
                    NSLog("[M2] 账号状态读取失败（第 %d 次）：%@", attempt, String(describing: error))
                    if attempt == 4 {
                        let reason = String(error.localizedDescription.prefix(40))
                        await MainActor.run {
                            self.accountStatusMenuItem?.title = "账号：不可用（\(reason)）"
                        }
                        return
                    }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
    }

    // MARK: - M2 会话同步

    private var cachedCurrentUid: String?

    /// 同步目标：用户面板上选的目标账号（按 uid 查）
    private func targetAccount() -> AccountStore.AccountInfo? {
        if let uid = sessionSyncModel.selectedTargetUid,
           let acc = AccountStore.shared.list().first(where: { $0.uid == uid }) {
            return acc
        }
        // 兼容：未选时回退到第一个非当前账号
        guard let currentUid = cachedCurrentUid else { return nil }
        return AccountStore.shared.list().first { $0.uid != currentUid }
    }

    private func loadSessionList(force: Bool) {
        guard !sessionListLoading else { return }
        sessionListLoading = true
        Task {
            do {
                let (entries, raw) = try await SessionSync.shared.listSessions()
                let current = try await NativeAuth.shared.readSession()
                cachedSessionEntries = entries
                cachedSessionRawValues = raw
                cachedCurrentUid = current?.uid
                // 清掉已不存在的勾选
                let ids = Set(entries.map { $0.storageId })
                sessionSelection.formIntersection(ids)
                sessionListLoaded = true
                // 同步到浮窗 model（如果已打开或缓存过 model）
                let panelEntries = entries.map { e in
                    SessionSyncPanelModel.Entry(
                        id: e.storageId,
                        title: e.title,
                        updatedAt: e.updatedAt,
                        userId: e.userId,
                        isBusy: e.isBusy
                    )
                }
                let targetList = AccountStore.shared.list().filter { $0.uid != current?.uid }
                sessionSyncModel.entries = panelEntries
                sessionSyncModel.currentUid = current?.uid
                sessionSyncModel.currentNickname = current?.nickname
                sessionSyncModel.targets = targetList
                // 自动选中第一个目标（仅在当前选中失效时）
                if sessionSyncModel.selectedTargetUid == nil
                    || !targetList.contains(where: { $0.uid == sessionSyncModel.selectedTargetUid }) {
                    sessionSyncModel.selectedTargetUid = targetList.first?.uid
                }
                sessionSyncModel.statusText = "已加载 \(entries.count) 条"
            } catch {
                NSLog("[M2] 会话列表读取失败：%@", String(describing: error))
                NativeAuth.shared.invalidate()
                SessionSync.shared.invalidate()
            }
            sessionListLoading = false
            await MainActor.run {
                if let item = statusItem, let menu = item.menu {
                    rebuild(menu: menu)
                }
            }
        }
    }

    @objc private func reloadSessionList(_ sender: NSMenuItem) {
        sessionListLoaded = false
        loadSessionList(force: true)
    }

    /// 打开会话同步浮窗（替代原 NSMenu 子菜单——点选条目不再自动收起）
    @objc private func openSessionSyncPanel(_ sender: NSMenuItem) {
        ensureSessionSyncPanel()
        if !sessionListLoaded && !sessionListLoading { loadSessionList(force: false) }
        sessionSyncPanel?.show()
    }

    /// 切换「操作后自动跳回工作区」开关（UserDefaults 持久化，默认关）
    @objc private func toggleFocusAfterAction(_ sender: NSMenuItem) {
        CodeerPrefs.focusAfterAction.toggle()
        sender.state = CodeerPrefs.focusAfterAction ? .on : .off
    }

    /// 打开积分看板浮窗（各账号积分 / 用量统计 / 过期提醒）
    @objc private func openCreditPanel(_ sender: NSMenuItem) {
        if creditPanel == nil {
            creditPanel = CreditPanelController(model: creditModel)
        }
        creditPanel?.show()
    }

    private func ensureSessionSyncPanel() {
        if sessionSyncPanel != nil { return }
        sessionSyncModel.onSync = { [weak self] storageIds, completion in
            self?.syncSessionsByIds(storageIds, completion: completion)
        }
        sessionSyncModel.onReload = { [weak self] in
            guard let self else { return }
            self.sessionListLoaded = false
            self.loadSessionList(force: true)
        }
        sessionSyncPanel = SessionSyncPanelController(model: sessionSyncModel)
    }

    /// 按 storageId 集合执行同步（被浮窗的"同步"按钮调用）
    private func syncSessionsByIds(_ storageIds: Set<String>, completion: @escaping (String) -> Void) {
        guard let target = targetAccount(), !syncInFlight else {
            completion("同步被拒：目标账号不可用或正在同步")
            return
        }
        let selected = cachedSessionEntries.filter { storageIds.contains($0.storageId) && !$0.isBusy }
        guard !selected.isEmpty else {
            completion("没有可同步的会话")
            return
        }
        syncInFlight = true

        Task {
            var message: String
            do {
                // 同步前备份会话库
                let dbPath = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/CodeBuddy CN/codebuddy-sessions.vscdb")
                let backupDir = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/Codeer/backups", isDirectory: true)
                try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
                let stamp = Int(Date().timeIntervalSince1970)
                _ = try? FileManager.default.copyItem(at: dbPath, to: backupDir.appendingPathComponent("codebuddy-sessions-\(stamp).vscdb"))

                let pairs = try await SessionSync.shared.copySessions(
                    rawValues: cachedSessionRawValues,
                    entries: selected,
                    to: target.uid
                )
                // 会话文件树复制（history/messages 等内容，按账号目录树）
                if let sourceUid = cachedCurrentUid {
                    try SessionSync.shared.copySessionFiles(
                        sourceUid: sourceUid,
                        targetUid: target.uid,
                        pairs: pairs
                    )
                }
                message = "已写入 \(pairs.count) 条到 \(target.nickname)"
                sessionSelection.removeAll()
                sessionListLoaded = false
                // 重新加载并刷新面板
                self.loadSessionList(force: true)
            } catch {
                NSLog("[M2] 会话同步失败：%@", String(describing: error))
                SessionSync.shared.invalidate()
                message = "同步失败：\(error.localizedDescription)"
            }
            syncInFlight = false
            await MainActor.run {
                notify(message)
                if let item = statusItem, let menu = item.menu { rebuild(menu: menu) }
                completion(message)
            }
        }
    }

    // MARK: - M2 动作

    /// 备份当前登录账号
    @objc private func backupCurrentAccount(_ sender: NSMenuItem) {
        Task {
            do {
                guard let session = try await NativeAuth.shared.readSession() else {
                    NSLog("[M2] 当前未登录，无可备份")
                    await MainActor.run { notify("当前未登录，无可备份") }
                    return
                }
                try AccountStore.shared.save(session)
                await MainActor.run { notify("已备份：\(session.nickname)") }
            } catch {
                NSLog("[M2] 备份失败：\(error)")
                await MainActor.run { notify("备份失败：\(error.localizedDescription)") }
            }
            // 关键：inspector 连接挂着会导致 CodeBuddy 退出卡死（uv_cond_wait 等前端断开），
            // 账号操作完成后立即断开，平时不占用
            NativeAuth.shared.invalidate()
        }
    }

    /// 切换到指定账号（无感切换：官方服务内换会话，不重启 IDE）
    @objc private func switchAccount(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        Task {
            defer { NativeAuth.shared.invalidate() }
            do {
                // 1) 先把当前登录态刷新备份（幂等，覆盖同 uid 快照）
                if let current = try await NativeAuth.shared.readSession() {
                    try AccountStore.shared.save(current)
                }
                // 2) 载入目标快照
                guard let target = try AccountStore.shared.load(uid: uid) else {
                    await MainActor.run { notify("未找到账号快照") }
                    return
                }
                // 3) 官方服务内换会话
                try await NativeAuth.shared.replaceSession(with: target)
                // 4) 验证
                if let now = try await NativeAuth.shared.readSession(), now.uid == uid {
                    NSLog("[M2] 已切换到 %@（%@）", now.uid, now.nickname)
                    await MainActor.run { notify("已切换到 \(now.nickname)") }
                } else {
                    await MainActor.run { notify("切换结果未确认，请查看菜单状态") }
                }
            } catch {
                NSLog("[M2] 切换失败：\(error)")
                await MainActor.run { notify("切换失败：\(error.localizedDescription)") }
            }
        }
    }

    private func notify(_ text: String) {
        let n = NSUserNotification()
        n.title = "Codeer"
        n.informativeText = text
        NSUserNotificationCenter.default.deliver(n)
    }

    // MARK: - M1 动作

    @objc private func restartMonitor(_ sender: NSMenuItem) {
        cdpStatusMenuItem?.title = "CDP：重启监视…"
        monitor?.start()
    }

    /// 以调试模式重启 CodeBuddy。执行者可能就是 CodeBuddy 子进程，
    /// relaunchWithDebugPort 内部以 detached 脚本执行，不受影响；
    /// 重启后 ApprovalMonitor 的重连循环会自动发现并重新注入
    @objc private func relaunchDebug(_ sender: NSMenuItem) {
        cdpStatusMenuItem?.title = "CDP：重启 CodeBuddy…"
        Task {
            do {
                _ = try await CDPDiscovery.relaunchWithDebugPort()
                await MainActor.run { self.cdpStatusMenuItem?.title = "CDP：监视中" }
            } catch {
                NSLog("[relaunch] 失败: \(error)")
                await MainActor.run { self.cdpStatusMenuItem?.title = "CDP：重启失败" }
            }
        }
    }

    /// 菜单栏图标：白色铃铛（当前使用）
    private func whiteBellIcon() -> NSImage? {
        guard let symbol = NSImage(
            systemSymbolName: "bell.badge.fill",
            accessibilityDescription: "Codeer"
        ) else { return nil }
        let size = symbol.size
        let tinted = NSImage(size: size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }

    /// 「鹿」字图标方案（当前使用）：方块 + 「鹿」字镂空（alpha 蒙版）+ template 着色。
    /// 镂空处透出菜单栏背景色（背景什么颜色鹿就什么颜色）。
    /// 素材：DeerPNGAsset.pngBase64（256×256 RGBA 透明底「鹿」字 PNG）
    private func deerAssetIcon() -> NSImage? {
        guard let data = Data(base64Encoded: DeerPNGAsset.pngBase64),
              let src = NSImage(data: data),
              let srcCG = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            // 方块（template 着色）
            NSColor.black.setFill()
            ctx.addPath(CGPath(roundedRect: CGRect(x: 1, y: 1, width: 16, height: 16),
                               cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.fillPath()
            // 「鹿」字镂空（destinationOut：dst *= (1-srcA)，只擦鹿字笔画）
            // 实锤：此处用 .clear 会把整个绘制矩形连底擦穿（空心方块），必须用 .destinationOut
            // flipped 上下文里 ctx.draw 会垂直翻转位图 → 先在绘制矩形中心 scale(1,-1) 翻回来
            let rect = CGRect(x: 2.5, y: 2.5, width: 13, height: 13)
            ctx.saveGState()
            ctx.setBlendMode(.destinationOut)
            ctx.interpolationQuality = .high
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(srcCG, in: CGRect(x: -rect.width / 2, y: -rect.height / 2,
                                       width: rect.width, height: rect.height))
            ctx.restoreGState()
            return true
        }
        img.isTemplate = true
        return img
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}
