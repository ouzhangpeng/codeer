import Foundation
import os

/// 审批检测器（M1 检测层）——多窗口版
/// 每个含聊天面板的 webview target 一条独立 CDP 连接，PendingItem 按窗口（target）归属；
/// 代点必须派发到该 target 所属父窗口的 page 会话（跨窗口坐标不通用）。
/// 父窗口解析：iframe target URL 的 ?id= 参数 == 父页面 iframe.name 属性。
final class ApprovalMonitor {
    private let panel: PanelController
    private let stateLock = NSLock()

    struct ChatTarget {
        let targetId: String
        let parentEventId: String   // iframe target URL ?id= 参数
        var parentPageId: String?   // 已解析的父窗口 page targetId
        let client: CDPClient
        var projectName: String = "CodeBuddy"
    }

    private var targets: [String: ChatTarget] = [:]      // webviewTargetId → ChatTarget
    private var pageClients: [String: CDPClient] = [:]   // pageTargetId → client（代点派发用）
    private var pendings: [String: [PendingItem]] = [:]  // webviewTargetId → 该窗口待办
    private var itemTargets: [String: String] = [:]      // item.id → webviewTargetId
    /// 用户点「忽略」的后台对话 tab（targetId8|tabName）；该 tab 的 question 状态消失后自动移除
    private var ignoredBackgroundTabs: Set<String> = []
    private var loop: Task<Void, Never>?
    private var lastScan = Date.distantPast

    init(panel: PanelController) {
        self.panel = panel
    }

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in await self?.run() }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        stateLock.lock()
        var toClose: [CDPClient] = []
        for t in targets.values { toClose.append(t.client) }
        for c in pageClients.values { toClose.append(c) }
        targets.removeAll()
        pageClients.removeAll()
        pendings.removeAll()
        itemTargets.removeAll()
        stateLock.unlock()
        for c in toClose { c.close() }
        Task { @MainActor in panel.update(items: []) }
    }

    // MARK: - 锁内快照 / 修改

    private func snapshotTargets() -> [(String, ChatTarget)] {
        stateLock.lock(); defer { stateLock.unlock() }
        return targets.map { ($0.key, $0.value) }
    }

    private func snapshotPageClients() -> [(String, CDPClient)] {
        stateLock.lock(); defer { stateLock.unlock() }
        return pageClients.map { ($0.key, $0.value) }
    }

    private func snapshotAllItems() -> [PendingItem] {
        stateLock.lock(); defer { stateLock.unlock() }
        return pendings.values.flatMap { $0 }
    }

    private func removeTargetLocked(_ tid: String) {
        if let t = targets.removeValue(forKey: tid) { t.client.close() }
        if let items = pendings.removeValue(forKey: tid) {
            for item in items { itemTargets.removeValue(forKey: item.id) }
        }
    }

    private func removeTarget(_ tid: String) {
        stateLock.lock()
        let old = targets[tid]
        removeTargetLocked(tid)
        stateLock.unlock()
        old?.client.close()
    }

    // MARK: - 决策入口（AppDelegate 转发 item 以定位窗口）

    func decide(allow: Bool, item: PendingItem) {
        dispatchClick(item: item, text: allow ? "运行" : "拒绝", label: "代点「\(allow ? "运行" : "拒绝")」")
    }

    func decideSkip(item: PendingItem) {
        dispatchClick(item: item, text: "跳过", label: "代点「跳过」")
    }

    func decide(option: String, item: PendingItem) {
        if item.kind == "background" {
            handleBackgroundAction(option: option, item: item)
            return
        }
        dispatchClick(item: item, text: option, matchOwnText: false, label: "代点选项「\(String(option.prefix(20)))」")
    }

    /// 多选题提交：把 IDE 侧勾选集合对齐到用户所选，再点 continueBtn 提交
    func decideMulti(options: [String], item: PendingItem) {
        let pair: (String, ChatTarget)? = stateLock.withLock {
            guard let tid = itemTargets[item.id], let target = targets[tid] else { return nil }
            return (tid, target)
        }
        guard let (_, target) = pair else {
            NSLog("[ApprovalMonitor] 多选代点：找不到对应窗口 target")
            return
        }
        Task { [weak self] in
            await self?.dispatchMulti(item: item, wants: options, target: target)
        }
    }

    /// 多选派发：勾选是 toggle，不能盲点——先探现场已选集合，差集逐个点，复查后点提交
    private func dispatchMulti(item: PendingItem, wants: [String], target: ChatTarget) async {
        let chatClient = target.client
        let label = "多选代点「\(wants.joined(separator: ",").prefix(30))」"
        let wantSet = Set(wants)

        // 1. 对齐勾选集合（最多 2 轮，覆盖点击未生效的补点）
        for round in 1...2 {
            guard let current = await probeSelected(client: chatClient, blockIndex: item.blockIndex) else {
                NSLog("[ApprovalMonitor] %@：探测已选集合失败（第 %d 轮）", label, round)
                return
            }
            let curSet = Set(current)
            let toSelect = wants.filter { !curSet.contains($0) }
            let toDeselect = current.filter { !wantSet.contains($0) }
            if toSelect.isEmpty && toDeselect.isEmpty { break }
            for text in toSelect + toDeselect {
                guard let pos = try? await rectOf(
                    client: chatClient,
                    expr: item.blockIndex >= 0
                        ? CDPProbe.optionRectInBlock(blockIndex: item.blockIndex, text: text)
                        : CDPProbe.findRect(selector: CDPProbe.actionSelector, text: text, matchOwnText: false)
                ) else {
                    NSLog("[ApprovalMonitor] %@：选项定位失败「%@」", label, String(text.prefix(20)))
                    continue
                }
                let rootOff = (try? await rectOf(client: chatClient, expr: CDPProbe.chatIframeRect)) ?? (x: 0, y: 0)
                try? await dispatchMouse(chatClient, x: pos.x + rootOff.x, y: pos.y + rootOff.y)
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        // 2. 终检：勾选集合未对齐则保留弹卡让用户手动处理
        if let current = await probeSelected(client: chatClient, blockIndex: item.blockIndex) {
            let curSet = Set(current)
            if !wantSet.isSubset(of: curSet) || !curSet.isSubset(of: wantSet) {
                NSLog("[ApprovalMonitor] %@：勾选未对齐（期望 %d 实际 %d），弹卡保留", label, wantSet.count, curSet.count)
                return
            }
        }

        // 3. 点「完成 ↩︎」提交（未答完其他题时它 disabled，点了无效——等待重试）
        for attempt in 1...6 {
            guard let state = await probeContinueBtn(client: chatClient) else {
                NSLog("[ApprovalMonitor] %@：无 continueBtn（第 %d 次）", label, attempt)
                return
            }
            let rootOff = (try? await rectOf(client: chatClient, expr: CDPProbe.chatIframeRect)) ?? (x: 0, y: 0)
            try? await dispatchMouse(chatClient, x: state.x + rootOff.x, y: state.y + rootOff.y)
            try? await Task.sleep(nanoseconds: 600_000_000)
            if (try? await targetGone(client: chatClient, kind: item.kind)) == true {
                NSLog("[ApprovalMonitor] %@：提交生效（第 %d 次）", label, attempt)
                if CodeerPrefs.focusAfterAction {
                    await MainActor.run {
                        WindowFocus.focusAsync(
                            projectName: item.projectName,
                            projectPath: item.projectPath,
                            activityDate: item.since
                        )
                    }
                }
                return
            }
            // disabled 说明还有其他题没答完（多题卡中间题）：勾选已对齐，安静退出等最后一题提交
            if state.disabled && attempt >= 3 {
                NSLog("[ApprovalMonitor] %@：continueBtn 仍 disabled（其他题未答完），勾选已生效", label)
                return
            }
        }
        NSLog("[ApprovalMonitor] %@：提交未生效，弹卡保留，请到 IDE 手动处理", label)
    }

    /// 探测某题当前已勾选集合
    private func probeSelected(client: CDPClient, blockIndex: Int) async -> [String]? {
        guard let raw = try? await client.evaluate(expression: CDPProbe.selectedOptions(blockIndex: blockIndex)) as? String,
              let data = raw.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              o["err"] == nil else { return nil }
        return o["selected"] as? [String] ?? []
    }

    /// 探测 continueBtn 坐标 + disabled 态
    private func probeContinueBtn(client: CDPClient) async -> (x: Int, y: Int, disabled: Bool)? {
        guard let raw = try? await client.evaluate(expression: CDPProbe.continueBtnState) as? String,
              let data = raw.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              o["err"] == nil,
              let x = (o["x"] as? NSNumber)?.intValue,
              let y = (o["y"] as? NSNumber)?.intValue else { return nil }
        return (x, y, (o["disabled"] as? Bool) ?? false)
    }

    /// 后台对话提示卡动作：「切过去处理」= trusted dispatch 点 session-tab（切对话后确认框
    /// 渲染，下轮 refresh 正常弹卡）；「忽略」= 本轮不再提醒
    private func handleBackgroundAction(option: String, item: PendingItem) {
        // id = "background:targetId8:tabName"（前缀固定 19 字符）
        guard item.id.hasPrefix("background:") else { return }
        let tabName = String(item.id.dropFirst("background:XXXXXXXX:".count))
        guard let tid = itemTargets[item.id], let target = targets[tid] else { return }
        if option == "忽略" {
            stateLock.withLock { ignoredBackgroundTabs.insert("\(tid.prefix(8))|\(tabName)") }
            removePending(item: item, targetId: tid)
            NSLog("[ApprovalMonitor] 后台对话已忽略：%@", tabName)
            return
        }
        // 切过去处理
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let pos = try await self.rectOf(
                    client: target.client,
                    expr: CDPProbe.sessionTabRect(name: tabName)
                ) else {
                    NSLog("[ApprovalMonitor] 后台对话切换：tab 定位失败（%@）", tabName)
                    return
                }
                let rootOff = (try? await self.rectOf(client: target.client, expr: CDPProbe.chatIframeRect)) ?? (x: 0, y: 0)
                try await self.dispatchMouse(target.client, x: pos.x + rootOff.x, y: pos.y + rootOff.y)
                NSLog("[ApprovalMonitor] 后台对话切换：dispatch(chat) ok @(%d,%d)（%@）", pos.x + rootOff.x, pos.y + rootOff.y, tabName)
                // 移除提示卡（切过去后确认框由常规检测接管）
                self.removePending(item: item, targetId: tid)
            } catch {
                NSLog("[ApprovalMonitor] 后台对话切换失败：%@", error.localizedDescription)
            }
        }
    }

    /// 从弹卡队列移除单个 PendingItem 并刷新面板
    private func removePending(item: PendingItem, targetId: String) {
        var remain: [PendingItem] = []
        stateLock.lock()
        pendings[targetId]?.forEach { if $0.id != item.id { remain.append($0) } }
        pendings[targetId] = remain
        itemTargets.removeValue(forKey: item.id)
        stateLock.unlock()
        let all = snapshotAllItems()
        Task { @MainActor in panel.update(items: all) }
    }

    /// 选项卡「自定义输入」→ 远程聚焦 IDE 输入框并跳转窗口（卡片保留）
    func decideCustomInput(item: PendingItem) {
        let pair: (String, ChatTarget)? = stateLock.withLock {
            guard let tid = itemTargets[item.id], let target = targets[tid] else { return nil }
            return (tid, target)
        }
        guard let (_, target) = pair else { return }
        Task {
            do {
                let r = try await target.client.evaluate(expression: CDPProbe.focusCustomInput) as? String
                NSLog("[ApprovalMonitor] 聚焦自定义输入：%@", r ?? "?")
            } catch {
                NSLog("[ApprovalMonitor] 聚焦自定义输入失败：%@", error.localizedDescription)
            }
            await MainActor.run {
                WindowFocus.focusAsync(projectName: item.projectName, projectPath: item.projectPath, activityDate: item.since)
            }
        }
    }

    // MARK: - 主循环

    private func run() async {
        while !Task.isCancelled {
            do {
                // 周期性扫描 target 集合（新窗口/关闭窗口）
                if Date().timeIntervalSince(lastScan) > 3 {
                    lastScan = Date()
                    try await syncTargets()
                }
                // 在锁内 snapshot target 列表后再遍历，避免跨 await 修改 Dictionary 迭代器导致
                // Dictionary._Variant.lookup use-after-free（实测 SIGSEGV，crash 栈 ApprovalMonitor.refresh）
                let snap = snapshotTargets()
                for (tid, target) in snap {
                    if Task.isCancelled { return }
                    do {
                        try await refresh(targetId: tid, target: target)
                    } catch {
                        NSLog("[ApprovalMonitor] target %@ 断开：%@", String(tid.prefix(8)), error.localizedDescription)
                        removeTarget(tid)
                    }
                }
                let items = snapshotAllItems()
                await MainActor.run { panel.update(items: items) }
                try await sleepSeconds(1)
            } catch is CancellationError {
                return
            } catch {
                NSLog("[ApprovalMonitor] 扫描失败：%@，3s 后重试", error.localizedDescription)
                try? await sleepSeconds(3)
            }
        }
    }

    /// 同步 target 集合：主页面连接（代点派发用）+ 聊天 webview 连接
    private func syncTargets() async throws {
        guard let endpoint = await CDPDiscovery.discover() else { return }

        // 锁内计算 main 页面连接差异：清理已不在的，新增未连的（client 在锁外异步 connect）
        let toCloseMain: [CDPClient] = stateLock.withLock {
            let mainIds = Set(endpoint.targets.filter { $0.kind == .main }.map { $0.id })
            var stale: [CDPClient] = []
            for (pid, c) in pageClients where !mainIds.contains(pid) {
                stale.append(c)
                pageClients.removeValue(forKey: pid)
            }
            return stale
        }
        for c in toCloseMain { c.close() }

        let needMain: [CDPTarget] = stateLock.withLock {
            endpoint.targets.filter { $0.kind == .main && pageClients[$0.id] == nil }
        }
        for page in needMain {
            guard let ws = page.wsURL, let url = URL(string: ws) else { continue }
            let c = CDPClient()
            do {
                try await c.connect(wsURL: url)
                stateLock.lock()
                pageClients[page.id] = c
                stateLock.unlock()
            } catch {
                c.close()
            }
        }

        // 聊天 webview targets：消失的清理，新增的连接
        let webviews = endpoint.targets.filter { $0.kind == .webview }
        let needConnect: [CDPTarget] = stateLock.withLock {
            let webviewIds = Set(webviews.map { $0.id })
            for (tid, t) in targets where !webviewIds.contains(tid) {
                NSLog("[ApprovalMonitor] target %@ 消失", String(tid.prefix(8)))
                removeTargetLocked(tid)
            }
            let existing = Set(targets.keys)
            return webviews.filter { !existing.contains($0.id) }
        }
        for t in needConnect {
            do { try await connectChatTarget(t) }
            catch { NSLog("[ApprovalMonitor] connect chat target 失败：%@", error.localizedDescription) }
        }
    }

    /// 连一个 webview target，确认是聊天面板后注入监视
    private func connectChatTarget(_ target: CDPTarget) async throws {
        guard let ws = target.wsURL, let url = URL(string: ws) else { return }
        let client = CDPClient()
        do {
            try await client.connect(wsURL: url)
            guard let summary = CDPProbe.ChatSummary.parse(try await client.evaluate(expression: CDPProbe.chatSummary)),
                  summary.chat else {
                client.close()
                return // 隐藏壳 webview，非聊天面板
            }
            client.onEvent = { [weak self] method, params in
                if method == "Runtime.bindingCalled",
                   (params["name"] as? String) == CDPProbe.bindingName {
                    Task { [weak self] in self?.refreshByTargetId(target.id) }
                }
            }
            _ = try await client.send(method: "Runtime.addBinding", params: ["name": CDPProbe.bindingName])
            _ = try await client.evaluate(expression: CDPProbe.injectMonitor)

            let eventId = Self.eventId(fromURL: target.url) ?? target.id
            var projectName = "CodeBuddy"
            var parentPageId: String?
            // 父窗口解析：父页面里存在 name == eventId 的 iframe（pageClients 锁内 snapshot）
            let pageSnap = snapshotPageClients()
            for (pageId, pageClient) in pageSnap {
                let expr = "!!document.querySelector('iframe[name=\"\(eventId)\"]')"
                if let hit = try? await pageClient.evaluate(expression: expr) as? Bool, hit {
                    parentPageId = pageId
                    if let title = try? await pageClient.evaluate(expression: "document.title") as? String {
                        let name = title.components(separatedBy: " — ").first ?? title
                        if !name.isEmpty { projectName = name }
                    }
                    break
                }
            }
            let chat = ChatTarget(
                targetId: target.id, parentEventId: eventId,
                parentPageId: parentPageId,
                client: client, projectName: projectName
            )
            stateLock.lock()
            targets[target.id] = chat
            stateLock.unlock()
            NSLog("[ApprovalMonitor] 已注入聊天 target %@（窗口：%@）", String(target.id.prefix(8)), projectName)
        } catch {
            client.close()
            throw error
        }
    }

    /// 从 iframe target URL 取 ?id= 参数
    private static func eventId(fromURL url: String) -> String? {
        guard let range = url.range(of: "id=") else { return nil }
        return String(url[range.upperBound...]).components(separatedBy: "&").first
    }

    /// 解析父窗口 page targetId：父页面里存在 name == eventId 的 iframe
    private func resolveParentPage(eventId: String) -> String? {
        // 先查缓存
        for (tid, t) in targets where t.parentEventId == eventId {
            if let pid = t.parentPageId { return pid }
        }
        return nil // 懒解析：refresh/dispatch 时再探测（pageClients 就绪后）
    }

    // MARK: - 快照刷新

    private func refreshByTargetId(_ targetId: String) {
        let target: ChatTarget? = stateLock.withLock { targets[targetId] }
        guard let target else { return }
        Task { try? await refresh(targetId: targetId, target: target) }
    }

    private func refresh(targetId: String, target: ChatTarget) async throws {
        var items: [PendingItem] = []

        // 确认（运行/跳过/拒绝）
        if let raw = try await target.client.evaluate(expression: CDPProbe.pendingSnapshot) as? String,
           let data = raw.data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if o["pending"] as? Bool == true {
                let text = o["text"] as? String ?? ""
                let id = "confirm:\(targetId.prefix(8)):\(text.prefix(120))"
                let existing = stateLock.withLock { pendings[targetId]?.first { $0.id == id } }
                if existing == nil {
                    NSLog("[ApprovalMonitor] 检测到确认请求（窗口 %@）：%@", target.projectName, String(text.prefix(80)))
                }
                items.append(existing ?? PendingItem(
                    id: id,
                    kind: "confirm",
                    toolName: "bash",
                    summary: text,
                    projectPath: "",
                    projectName: target.projectName,
                    since: Date(),
                    deadline: Date().addingTimeInterval(15 * 60)
                ))
            }
        }

        // 选项（question-floating 多选一）
        if let raw = try await target.client.evaluate(expression: CDPProbe.optionsSnapshot) as? String,
           let data = raw.data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if o["pending"] as? Bool == true {
                // 分题建卡：探针返回 questions 数组（每题 {question, options, blockIndex}），
                // 每题一个 PendingItem → 弹卡队列逐题显示/处理（点完一题再出下一题）
                let questions = o["questions"] as? [[String: Any]] ?? []
                for q in questions {
                    let question = q["question"] as? String ?? ""
                    let options = q["options"] as? [String] ?? []
                    guard options.count >= 2 else { continue }
                    let blockIdx = (q["blockIndex"] as? NSNumber)?.intValue ?? -1
                    let multi = (q["multi"] as? Bool) ?? false
                    let seed = q["selected"] as? [String] ?? []
                    // id 不含 multi：首检可能早于 multiBadge 渲染，标记翻转不能换 id（否则重复条目）
                    let id = "options:\(targetId.prefix(8)):\(question.prefix(100))|\(options.count)"
                    let existing = stateLock.withLock { pendings[targetId]?.first { $0.id == id } }
                    if existing == nil {
                        NSLog("[ApprovalMonitor] 检测到选项选择（窗口 \(target.projectName)）：\(String(question.prefix(60))) | 选项数=\(options.count)\(multi ? " 多选" : "") 内容：\(options.joined(separator: " §§ ").prefix(200))")
                    }
                    if var found = existing {
                        // 复用时同步多选标记：首检可能早于 badge 渲染（实测单题多选卡首检 multi=false）
                        if found.multiSelect != multi { found.multiSelect = multi }
                        items.append(found)
                    } else {
                        items.append(PendingItem(
                            id: id,
                            kind: "options",
                            toolName: "questionmark.bubble",
                            summary: question,
                            projectPath: "",
                            projectName: target.projectName,
                            since: Date(),
                            deadline: Date().addingTimeInterval(30 * 60),
                            options: options,
                            blockIndex: blockIdx,
                            multiSelect: multi,
                            seedSelected: seed
                        ))
                    }
                }
            }
        }

        // 后台对话等待检测：切走对话后确认框 DOM 被卸载，唯一信号是 tab 上的
        // agent-state-question 指示器 → 弹提示卡（切过去处理 / 忽略）
        if let raw = try await target.client.evaluate(expression: CDPProbe.backgroundQuestionSnapshot) as? String,
           let data = raw.data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           o["pending"] as? Bool == true {
            let tabs = o["tabs"] as? [[String: Any]] ?? []
            for tab in tabs {
                let name = tab["name"] as? String ?? ""
                guard !name.isEmpty else { continue }
                let key = "\(targetId.prefix(8))|\(name)"
                let ignored = stateLock.withLock { ignoredBackgroundTabs.contains(key) }
                guard !ignored else { continue }
                let id = "background:\(targetId.prefix(8)):\(name.prefix(80))"
                let existing = stateLock.withLock { pendings[targetId]?.first { $0.id == id } }
                if existing == nil {
                    NSLog("[ApprovalMonitor] 后台对话等待处理（窗口 %@）：%@", target.projectName, name)
                }
                items.append(existing ?? PendingItem(
                    id: id,
                    kind: "background",
                    toolName: "arrow.triangle.branch",
                    summary: "对话《\(name)》正在后台等待你的处理",
                    projectPath: "",
                    projectName: target.projectName,
                    since: Date(),
                    deadline: Date().addingTimeInterval(30 * 60),
                    options: ["切过去处理", "忽略"],
                    blockIndex: -1
                ))
            }
        }

        // 写回：itemTargets 清理过期 + 登记当前，pendings 整体替换
        stateLock.lock()
        if let old = pendings[targetId] {
            for item in old where !items.contains(where: { $0.id == item.id }) {
                itemTargets.removeValue(forKey: item.id)
            }
        }
        for item in items { itemTargets[item.id] = targetId }
        pendings[targetId] = items
        stateLock.unlock()
    }

    private func clearCurrent() {
        pendings.removeAll()
        itemTargets.removeAll()
        Task { @MainActor in panel.update(items: []) }
    }

    private func sleepSeconds(_ s: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
    }

    // MARK: - 代点（卡内直接操作）

    /// 主页面派发代点（客观实锤：iframe 会话派发无效；必须父窗口会话 + 全链偏移坐标）
    /// 自愈：派发后 0.6s 复查，仍在则重试（最多 3 次），再失败走 element.click() 兜底
    private func dispatchClick(item: PendingItem, text: String, matchOwnText: Bool = true, label: String) {
        let pair: (String, ChatTarget)? = stateLock.withLock {
            guard let tid = itemTargets[item.id], let target = targets[tid] else { return nil }
            return (tid, target)
        }
        guard let (_, target) = pair else {
            NSLog("[ApprovalMonitor] %@：找不到对应窗口 target", label)
            return
        }
        let chatClient = target.client
        Task { [weak self] in
            guard let self else { return }
            for attempt in 1...3 {
                do {
                    // 多题卡单选防抖（2026-10-14 实锤：多题卡勾选是 toggle）：
                    // 重试前查选中态，已选中不再重点选项（翻转会取消勾选）；
                    // continueBtn disabled = 其他题未答完，勾选已生效，安静退出等最后一题提交
                    if attempt > 1, item.kind == "options", item.blockIndex >= 0,
                       let sel = await self.probeSelected(client: chatClient, blockIndex: item.blockIndex),
                       sel.contains(text) {
                        if let st = await self.probeContinueBtn(client: chatClient), !st.disabled {
                            let off = (try? await self.rectOf(client: chatClient, expr: CDPProbe.chatIframeRect)) ?? (x: 0, y: 0)
                            try await self.dispatchMouse(chatClient, x: st.x + off.x, y: st.y + off.y)
                            try await Task.sleep(nanoseconds: 600_000_000)
                            if try await self.targetGone(client: chatClient, kind: item.kind) {
                                NSLog("[ApprovalMonitor] %@：第 %d 次重试提交生效", label, attempt)
                                if CodeerPrefs.focusAfterAction {
                                    await MainActor.run {
                                        WindowFocus.focusAsync(
                                            projectName: item.projectName,
                                            projectPath: item.projectPath,
                                            activityDate: item.since
                                        )
                                    }
                                }
                                return
                            }
                        } else {
                            NSLog("[ApprovalMonitor] %@：勾选已生效（多题卡其他题未答完），等最后一题提交", label)
                            return
                        }
                    }
                    // 元素坐标（内层 iframe 视口），每次重试都重新定位
                    // 多问题卡（blockIndex >= 0）：在对应 questionBlock 内定位，避免跨题误点
                    guard let pos = try await self.rectOf(
                        client: chatClient,
                        expr: item.blockIndex >= 0
                            ? CDPProbe.optionRectInBlock(blockIndex: item.blockIndex, text: text)
                            : CDPProbe.findRect(selector: CDPProbe.actionSelector, text: text, matchOwnText: matchOwnText)
                    ) else {
                        NSLog("[ApprovalMonitor] %@：定位失败（第 %d 次）", label, attempt)
                        continue
                    }
                    // 派发坐标与目标会话（2026-10-14 实锤）：
                    // - 选项卡：选项渲染在聊天 webview 文档内 → 在【聊天 target 会话】上用
                    //   「内层视口坐标 + 内层 iframe 偏移(rootOff)」派发（trusted 事件，
                    //   实验验证选中成功）；换算父页面坐标再在父页面派发会落点错误
                    // - 确认框：menu-item 浮层渲染在父页面文档 → 保持原「父页面会话派发」
                    let rootOff = (try? await self.rectOf(client: chatClient, expr: CDPProbe.chatIframeRect)) ?? (x: 0, y: 0)
                    var px = pos.x + rootOff.x
                    var py = pos.y + rootOff.y
                    if item.kind == "options" {
                        try await self.dispatchMouse(chatClient, x: px, y: py)
                        NSLog("[ApprovalMonitor] %@：dispatch(chat) ok @(%d,%d) 第 %d 次", label, px, py, attempt)
                        // 多问题卡：选中后需点「完成 ↩︎」(continueBtn) 提交；单问题卡点选项即提交
                        try await Task.sleep(nanoseconds: 400_000_000)
                        if try await self.targetGone(client: chatClient, kind: item.kind) {
                            // 已直接生效
                        } else if let cpos = try? await self.rectOf(client: chatClient, expr: CDPProbe.continueBtnRect()) {
                            try await self.dispatchMouse(chatClient, x: cpos.x + rootOff.x, y: cpos.y + rootOff.y)
                            NSLog("[ApprovalMonitor] %@：dispatch(continue) ok @(%d,%d)", label, cpos.x + rootOff.x, cpos.y + rootOff.y)
                        }
                    } else {
                        let parentSnap = self.snapshotPageClients()
                        guard let parentPageId = try await self.resolveParent(target: target),
                              let pageClient = parentSnap.first(where: { $0.0 == parentPageId })?.1,
                              let mainOff = try? await self.rectOf(
                                client: pageClient,
                                expr: CDPDiscovery.mainWebviewRect(matchName: target.parentEventId)
                              ) else {
                            NSLog("[ApprovalMonitor] %@：父页面不可用（第 %d 次）", label, attempt)
                            continue
                        }
                        px = pos.x + rootOff.x + mainOff.x
                        py = pos.y + rootOff.y + mainOff.y
                        try await self.dispatchMouse(pageClient, x: px, y: py)
                        NSLog("[ApprovalMonitor] %@：dispatch(main) ok @(%d,%d) 第 %d 次", label, px, py, attempt)
                    }

                    // 自检：目标消失即认为生效（按卡片类型选探针）
                    try await Task.sleep(nanoseconds: 600_000_000)
                    if try await self.targetGone(client: chatClient, kind: item.kind) {
                        if attempt > 1 { NSLog("[ApprovalMonitor] %@：第 %d 次重试生效", label, attempt) }
                        // 卡上处理完成 → 按开关决定是否自动跳回该窗口（默认不跳）
                        if CodeerPrefs.focusAfterAction {
                            await MainActor.run {
                                WindowFocus.focusAsync(
                                    projectName: item.projectName,
                                    projectPath: item.projectPath,
                                    activityDate: item.since
                                )
                            }
                        }
                        return
                    }
                    NSLog("[ApprovalMonitor] %@：第 %d 次派发后目标仍在，重试…", label, attempt)
                } catch {
                    NSLog("[ApprovalMonitor] %@：dispatch 异常（%@）", label, error.localizedDescription)
                }
            }
            if item.kind == "options" {
                // fire/dispatchEvent 事件被 IDE 组件按 isTrusted 过滤（2026-10-14 实锤），
                // 模拟点击必然无效 → 保留弹卡，提示用户去 IDE 手动处理
                NSLog("[ApprovalMonitor] %@：3 次派发均未生效，弹卡保留，请到 IDE 手动处理", label)
            } else {
                await self.fallbackClick(chatClient: chatClient, want: text, label: label, blockIndex: item.blockIndex)
            }
        }
    }

    /// 懒解析父窗口 page targetId：在各主页面里找 name == parentEventId 的 iframe
    private func resolveParent(target: ChatTarget) async throws -> String? {
        if let pid = target.parentPageId { return pid }
        let snap = snapshotPageClients()
        for (pageId, client) in snap {
            let expr = "!!document.querySelector('iframe[name=\"\(target.parentEventId)\"]')"
            if let hit = try? await client.evaluate(expression: expr) as? Bool, hit {
                stateLock.lock()
                if var t = targets[target.targetId] {
                    t.parentPageId = pageId
                    targets[target.targetId] = t
                }
                stateLock.unlock()
                return pageId
            }
        }
        return nil
    }

    private func dispatchMouse(_ client: CDPClient, x: Int, y: Int) async throws {
        for type in ["mouseMoved", "mousePressed", "mouseReleased"] {
            _ = try await client.send(method: "Input.dispatchMouseEvent", params: [
                "type": type, "x": x, "y": y, "button": "left", "clickCount": 1,
            ])
        }
    }

    private func rectOf(client: CDPClient, expr: String) async throws -> (x: Int, y: Int)? {
        guard let raw = try await client.evaluate(expression: expr) as? String,
              let data = raw.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              o["err"] == nil,
              let x = (o["x"] as? NSNumber)?.intValue,
              let y = (o["y"] as? NSNumber)?.intValue else { return nil }
        return (x, y)
    }

    /// 目标是否已消失（代点生效的客观判据：快照 pending == false）
    /// 按卡片类型选探针：选项卡必须用 optionsSnapshot——用 pendingSnapshot 会因确认框
    /// 本就不存在而恒判「已消失」，自愈机制（重试+fallback）永远不触发（2026-10-14 实锤）
    private func targetGone(client: CDPClient, kind: String) async throws -> Bool {
        let probe = kind == "options" ? CDPProbe.optionsSnapshot : CDPProbe.pendingSnapshot
        guard let raw = try await client.evaluate(expression: probe) as? String,
              let data = raw.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return true }
        return o["pending"] as? Bool != true
    }

    private func fallbackClick(chatClient: CDPClient, want: String, label: String, blockIndex: Int = -1) async {
        do {
            let expr = blockIndex >= 0
                ? CDPProbe.fallbackClickInBlock(blockIndex: blockIndex, text: want)
                : CDPProbe.fallbackClick(want)
            let r = try await chatClient.evaluate(expression: expr) as? String
            NSLog("[ApprovalMonitor] %@：%@", label, r ?? "?")
        } catch {
            NSLog("[ApprovalMonitor] %@兜底也失败：%@", label, error.localizedDescription)
        }
    }
}

extension CDPDiscovery {
    /// 主页面（workbench）webview 偏移——按 iframe.name 匹配（多窗口版）
    static func mainWebviewRect(matchName: String) -> String {
        """
        (() => {
          const f = [...document.querySelectorAll('iframe')].find(f => f.name === '\(matchName)');
          if (!f) return JSON.stringify({ err: 'no-webview' });
          const r = f.getBoundingClientRect();
          return JSON.stringify({ x: Math.round(r.left), y: Math.round(r.top) });
        })()
        """
    }
}
