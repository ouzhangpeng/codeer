import Foundation
import os

/// 会话同步（M2）：通过主进程官方会话服务复制会话到目标账号
/// 机制照 WorkDaddy codebuddy-native.js：
/// - 服务发现：'codebuddy:getSession' handler 闭包里只有转发箭头函数（V8 省略词法 this），
///   用 Debugger.setBreakpointOnFunctionCall 断点 + callFunctionOn 主动触发，
///   暂停时 evaluateOnCallFrame('this') 拿到会话服务对象，立即 resume
/// - 读：服务内存 Map（_sessions）
/// - 写：enqueueV2Write → _db.updateItems → broadcastV2 + notifyAgentManager（官方通道，乐观锁）
final class SessionSync {
    static let shared = SessionSync()

    struct SessionEntry {
        let storageId: String      // ItemTable key 的 id（_sessions 的 key）
        let conversationId: String
        let userId: String
        let title: String
        let cwd: String
        let status: String
        let updatedAt: Date

        var isBusy: Bool { status == "Working" || status == "Planning" }
    }

    struct Change {
        let id: String
        let before: [String: Any]?   // nil = 新条目
        let after: [String: Any]?    // nil = 删除
    }

    private var sessionObjectId: String?
    private var client: CDPClient?
    private let lock = NSLock()

    private func currentObjectId() -> String? {
        lock.lock(); defer { lock.unlock() }
        return sessionObjectId
    }

    // MARK: - 服务发现（断点技巧）

    /// 连接并定位会话服务；幂等
    func ensureConnected() async throws {
        lock.lock()
        let connected = client != nil && sessionObjectId != nil
        lock.unlock()
        if connected { return }

        guard let target = try await findNodeTarget() else { throw NativeAuthError.noNodeTarget }
        guard let ws = target["webSocketDebuggerUrl"] as? String,
              let url = URL(string: ws) else { throw NativeAuthError.noNodeTarget }

        let client = CDPClient()
        do {
            try await client.connect(wsURL: url)
            let objectId = try await Self.findSessionService(client: client)
            lock.lock()
            self.client = client
            self.sessionObjectId = objectId
            lock.unlock()
            NSLog("[SessionSync] 已连接主进程会话服务")
        } catch {
            client.close()
            throw error
        }
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        client?.close()
        client = nil
        sessionObjectId = nil
    }

    private func findNodeTarget() async throws -> [String: Any]? {
        let url = URL(string: "http://127.0.0.1:\(NativeAuth.debugPort)/json/list")!
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NativeAuthError.noNodeTarget
        }
        return arr.first { ($0["type"] as? String) == "node" }
    }

    /// 断点技巧发现会话服务（照 WorkDaddy findSessionService）
    private static func findSessionService(client: CDPClient) async throws -> String {
        let rootResult = Self.unwrap(try await client.send(method: "Runtime.evaluate", params: [
            "expression": "process.getBuiltinModule('module').createRequire(process.execPath)('electron').ipcMain._invokeHandlers.get('codebuddy:getSession')",
            "objectGroup": "codeer-sessions",
        ]))
        guard let root = rootResult["result"] as? [String: Any],
              root["type"] as? String == "function",
              let rootId = root["objectId"] as? String else {
            throw NativeAuthError.evalFailed("未找到会话服务入口")
        }

        // 闭包里找恰好一个 function 成员的 scope（即转发箭头函数）
        let props = Self.unwrap(try await client.send(method: "Runtime.getProperties", params: ["objectId": rootId, "ownProperties": true]))
        guard let internalProps = props["internalProperties"] as? [[String: Any]],
              let scopes = internalProps.first(where: { ($0["name"] as? String) == "[[Scopes]]" }),
              let scopesVal = scopes["value"] as? [String: Any],
              let scopesId = scopesVal["objectId"] as? String else {
            throw NativeAuthError.evalFailed("会话服务入口不兼容")
        }
        let scopeList = Self.unwrap(try await client.send(method: "Runtime.getProperties", params: ["objectId": scopesId, "ownProperties": true]))
        var callbackId: String?
        for scope in scopeList["result"] as? [[String: Any]] ?? [] {
            guard let scopeVal = scope["value"] as? [String: Any],
                  (scopeVal["description"] as? String)?.contains("Closure") == true,
                  let scopeObjectId = scopeVal["objectId"] as? String else { continue }
            let members = Self.unwrap(try await client.send(method: "Runtime.getProperties", params: ["objectId": scopeObjectId, "ownProperties": true]))
            guard let memberResults = members["result"] as? [[String: Any]], memberResults.count <= 8 else { continue }
            let functions = memberResults.filter { ($0["value"] as? [String: Any])?["type"] as? String == "function" }
            if functions.count == 1, let fv = functions[0]["value"] as? [String: Any], let fid = fv["objectId"] as? String {
                callbackId = fid
                break
            }
        }
        guard let callbackId else { throw NativeAuthError.evalFailed("会话服务回调不兼容") }

        // 断点技巧：V8 从箭头函数 scope 省略词法 this，
        // 在 callback 被调用时暂停，于 call frame 上取 this（= 会话服务），立即恢复。
        // 绝不暂停任意应用代码、不扫堆、不改原型。
        _ = try await client.send(method: "Debugger.enable", params: [:])
        let bp = Self.unwrap(try await client.send(method: "Debugger.setBreakpointOnFunctionCall", params: ["objectId": callbackId]))
        guard let breakpointId = bp["breakpointId"] as? String else {
            throw NativeAuthError.evalFailed("断点设置失败")
        }

        // 在 continuation 内完成：装监听 → 触发探针 → 等暂停（1s 超时）→ 取 this
        let callFrameId: String = try await withCheckedThrowingContinuation { cont in
            let box = PauseBox { result in
                Task { try? await client.send(method: "Debugger.resume", params: [:]) }
                Task { try? await client.send(method: "Debugger.removeBreakpoint", params: ["breakpointId": breakpointId]) }
                Task { try? await client.send(method: "Debugger.disable", params: [:]) }
                switch result {
                case .success(let params):
                    if let callFrames = params["callFrames"] as? [[String: Any]],
                       let frameId = callFrames.first?["callFrameId"] as? String {
                        cont.resume(returning: frameId)
                    } else {
                        cont.resume(throwing: NativeAuthError.evalFailed("暂停帧异常"))
                    }
                case .failure(let error):
                    cont.resume(throwing: error)
                }
            }
            client.onEvent = { method, params in
                if method == "Debugger.paused" { box.deliver(.success(params)) }
            }
            // 超时守护
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                box.deliver(.failure(NativeAuthError.evalFailed("会话服务发现超时")))
            }
            // 主动触发一次（探针只读，不产生副作用）
            Task {
                _ = try? await client.send(method: "Runtime.callFunctionOn", params: [
                    "objectId": callbackId,
                    "functionDeclaration": "function(){return this(null,'__codeer_readonly_probe__');}",
                    "awaitPromise": false,
                ])
            }
        }

        // 在暂停帧上取 this
        let ownerResult = Self.unwrap(try await client.send(method: "Debugger.evaluateOnCallFrame", params: [
            "callFrameId": callFrameId, "expression": "this", "objectGroup": "codeer-sessions",
        ]))

        guard let owner = ownerResult["result"] as? [String: Any],
              let objectId = owner["objectId"] as? String else {
            throw NativeAuthError.evalFailed("会话服务对象不可用")
        }
        // 签名校验
        let check = Self.unwrap(try await client.send(method: "Runtime.callFunctionOn", params: [
            "objectId": objectId,
            "functionDeclaration": "function(){return this._sessions instanceof Map && this._newSessions instanceof Set && typeof this.enqueueV2Write === 'function' && typeof this.notifyAgentManager === 'function';}",
            "returnByValue": true,
        ]))
        guard (check["result"] as? [String: Any])?["value"] as? Bool == true else {
            throw NativeAuthError.evalFailed("会话服务版本不兼容")
        }
        return objectId
    }

    // MARK: - 会话读写

    /// 读取全部会话条目（元数据 + 原始 JSON，原始值作复制基底与乐观锁 before）
    func listSessions() async throws -> (entries: [SessionEntry], rawValues: [String: [String: Any]]) {
        try await ensureConnected()
        guard let client, let objectId = currentObjectId() else { throw NativeAuthError.notConnected }
        let raw = try await callOnService(
            client: client, objectId: objectId,
            fn: "function(){return Array.from(this._sessions, ([id,value]) => ({key:'session:'+id, value: JSON.stringify(value)}));}",
            awaitPromise: false
        )
        guard let items = raw as? [[String: Any]] else { return ([], [:]) }
        var entries: [SessionEntry] = []
        var rawValues: [String: [String: Any]] = [:]
        for item in items {
            guard let key = item["key"] as? String, key.hasPrefix("session:"),
                  let valueJson = item["value"] as? String,
                  let data = valueJson.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let storageId = String(key.dropFirst("session:".count))
            rawValues[storageId] = value
            let conversationId = (value["conversationId"] as? String) ?? storageId
            entries.append(SessionEntry(
                storageId: storageId,
                conversationId: conversationId,
                userId: (value["userId"] as? String) ?? "",
                title: (value["title"] as? String) ?? "(无标题)",
                cwd: (value["cwd"] as? String) ?? "",
                status: (value["status"] as? String) ?? "",
                updatedAt: Date(timeIntervalSince1970: (value["updatedAt"] as? Double ?? 0) / 1000)
            ))
        }
        return (entries.sorted { $0.updatedAt > $1.updatedAt }, rawValues)
    }

    /// 复制会话到目标账号
    /// - 首次复制：生成新 conversationId，副本记 originalId = 源 conversationId
    /// - 重复复制（目标已有同源副本）：**走更新**（用副本现有 conversationId + 当前 rawValue 作乐观锁 before，
    ///   之后用新内容覆盖），避免无限新增副本。甲乙互相同步会因 originalId 命中而原地更新同一副本
    /// 返回（源 conversationId → 副本 conversationId）映射，供会话文件树复制使用
    /// - Parameters:
    ///   - entries: 要复制的会话
    ///   - rawValues: storageId → 原始 value JSON（用于乐观锁 before 与复制基底；_sessions 全量，含目标账号现有副本）
    ///   - targetUserId: 目标账号 uid
    func copySessions(rawValues: [String: [String: Any]], entries: [SessionEntry], to targetUserId: String) async throws -> [(source: String, new: String)] {
        try await ensureConnected()
        guard let client, let objectId = currentObjectId() else { throw NativeAuthError.notConnected }

        // 在 rawValues（_sessions 全量）里建索引：目标账号下 originalId -> (copyId, rawValue)
        // 目标账号的副本条目我们之前不再 strip originalId（保留血缘），所以同一源会话只可能有一份副本
        var existingCopies: [String: (copyId: String, raw: [String: Any])] = [:]
        for (cid, v) in rawValues {
            guard (v["userId"] as? String) == targetUserId,
                  let originalId = v["originalId"] as? String, !originalId.isEmpty else { continue }
            existingCopies[originalId] = (cid, v)
        }

        let now = Date().timeIntervalSince1970
        var pairs: [(source: String, new: String)] = []
        let changes: [[String: Any]] = entries.compactMap { entry in
            guard var value = rawValues[entry.storageId] else { return nil }
            let targetId: String
            let before: Any
            if let existing = existingCopies[entry.conversationId] {
                // 已有副本：走更新（保留副本 conversationId，用其当前 rawValue 作乐观锁 before）
                targetId = existing.copyId
                before = existing.raw
            } else {
                // 首次复制：新 conversationId，before 置 null
                targetId = UUID().uuidString.lowercased()
                before = NSNull()
            }
            value["conversationId"] = targetId
            value["userId"] = targetUserId
            value["originalId"] = entry.conversationId   // 记血缘：所有副本（无论新建/更新）都标 originalId
            value["title"] = entry.title
            value["cwd"] = entry.cwd
            value["status"] = "Completed"
            value["createdAt"] = (rawValues[entry.storageId]?["createdAt"] as? Double) ?? now
            value["updatedAt"] = now
            value.removeValue(forKey: "deletedAt")
            pairs.append((source: entry.conversationId, new: targetId))
            return ["id": targetId, "before": before, "after": value] as [String: Any]
        }
        guard !changes.isEmpty else { return [] }

        let value = try await callOnService(
            client: client, objectId: objectId,
            fn: Self.writeNativeSessionsSource,
            arguments: [changes], awaitPromise: true
        )
        guard let dict = value as? [String: Any], let changed = dict["changed"] as? Int else {
            throw NativeAuthError.evalFailed("会话写入未确认")
        }
        let newCount = changes.filter { ($0["before"] as? NSNull) != nil }.count
        let updatedCount = changes.count - newCount
        NSLog("[SessionSync] 已写入 %d 条会话到 %@（新建 %d，更新 %d）", changed, targetUserId, newCount, updatedCount)
        return pairs
    }

    // MARK: - 会话文件树复制（CodeBuddyExtension/Data/<uid>/CodeBuddyIDE/<uid>/…）

    /// 会话内容目录（history/plan-task/check-point/file-tree）+ genie-cache
    private static let contentDirs = ["history", "plan-task", "check-point", "file-tree"]

    private static func ideRoot(_ uid: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodeBuddyExtension/Data/\(uid)/CodeBuddyIDE/\(uid)")
    }

    /// 把源会话的内容目录复制到目标账号树（新 conversationId），JSON 内 sessionId/conversationId 重绑
    func copySessionFiles(sourceUid: String, targetUid: String, pairs: [(source: String, new: String)]) throws {
        let fm = FileManager.default
        let srcRoot = Self.ideRoot(sourceUid)
        let dstRoot = Self.ideRoot(targetUid)
        var copiedFiles = 0

        for pair in pairs {
            for dir in Self.contentDirs {
                // 在源树的各 project 目录下定位源会话目录
                let projectRoot = srcRoot.appendingPathComponent(dir)
                let projectDirs = (try? fm.contentsOfDirectory(at: projectRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
                for projectDir in projectDirs where ((try? projectDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) == true {
                    let srcConv = projectDir.appendingPathComponent(pair.source)
                    guard fm.fileExists(atPath: srcConv.path) else { continue }
                    let dstConv = dstRoot
                        .appendingPathComponent(dir)
                        .appendingPathComponent(projectDir.lastPathComponent)
                        .appendingPathComponent(pair.new)
                    try fm.createDirectory(at: dstConv, withIntermediateDirectories: true)
                    copiedFiles += try Self.copyTree(from: srcConv, to: dstConv, rebindOld: pair.source, rebindNew: pair.new)
                    // 登记进项目级 index.json（UI 历史列表的数据源，缺了列表不显示）
                    Self.registerInProjectIndex(
                        sourceIndexURL: projectDir.appendingPathComponent("index.json"),
                        targetIndexURL: dstConv.deletingLastPathComponent().appendingPathComponent("index.json"),
                        sourceId: pair.source, newId: pair.new
                    )
                }
            }
        }
        NSLog("[SessionSync] 会话文件树复制完成：%d 个文件", copiedFiles)
    }

    /// 把副本条目登记进目标账号项目级 index.json 的 conversations 数组（UI 历史列表的数据源）
    /// - 条目内容从源项目 index.json 找 sourceId 条目，仅替换 id（其余字段照抄）
    /// - 主动设 originalId = sourceId（与 DB 写入一致，UI 列表能识别副本血缘）
    /// - 目标 index.json 不存在则新建；幂等（已登记同 id 跳过）；不动 current
    static func registerInProjectIndex(sourceIndexURL: URL, targetIndexURL: URL, sourceId: String, newId: String) {
        let fm = FileManager.default
        // 从源 index 找源条目
        guard let srcData = try? Data(contentsOf: sourceIndexURL),
              let srcObj = (try? JSONSerialization.jsonObject(with: srcData)) as? [String: Any],
              let convs = srcObj["conversations"] as? [[String: Any]] else {
            NSLog("[SessionSync] 源项目 index 缺失或无 conversations：%@", sourceIndexURL.path)
            return
        }
        guard var item = convs.first(where: { ($0["id"] as? String) == sourceId }) else {
            NSLog("[SessionSync] 源 index 无条目 %@", sourceId)
            return
        }
        item["id"] = newId
        // 不再 strip 源条目的 originalId：源条目若有 originalId（也是副本），保持链路；否则主动标 sourceId
        if (item["originalId"] as? String) == nil {
            item["originalId"] = sourceId
        }

        // 目标 index：不存在新建骨架
        var dstObj: [String: Any]
        if let dstData = try? Data(contentsOf: targetIndexURL),
           let obj = try? JSONSerialization.jsonObject(with: dstData) as? [String: Any] {
            dstObj = obj
        } else {
            dstObj = ["conversations": [[String: Any]](), "current": NSNull()]
        }
        var dstConvs = (dstObj["conversations"] as? [[String: Any]]) ?? []
        guard !dstConvs.contains(where: { ($0["id"] as? String) == newId }) else { return }
        dstConvs.append(item)
        dstObj["conversations"] = dstConvs

        guard let out = try? JSONSerialization.data(withJSONObject: dstObj, options: [.prettyPrinted]) else { return }
        try? fm.createDirectory(at: targetIndexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try out.write(to: targetIndexURL, options: .atomic)
            NSLog("[SessionSync] 已登记副本 %@ → %@", newId, targetIndexURL.path)
        } catch {
            NSLog("[SessionSync] 登记 index 失败 %@: %@", targetIndexURL.path, error.localizedDescription)
        }
    }

    /// 递归复制目录；.json 文件解析后重绑 sessionId/conversationId/ownerConversationId 中的旧 id，解析失败原样复制
    static func copyTree(from src: URL, to dst: URL, rebindOld: String, rebindNew: String) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        var count = 0
        for item in try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey]) {
            let dstItem = dst.appendingPathComponent(item.lastPathComponent)
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                count += try copyTree(from: item, to: dstItem, rebindOld: rebindOld, rebindNew: rebindNew)
                continue
            }
            var data = try Data(contentsOf: item)
            if item.pathExtension.lowercased() == "json",
               let obj = try? JSONSerialization.jsonObject(with: data) {
                let rebound = rebindIds(obj, old: rebindOld, new: rebindNew)
                if let out = try? JSONSerialization.data(withJSONObject: rebound, options: [.sortedKeys]) {
                    data = out
                }
            }
            try data.write(to: dstItem, options: .atomic)
            count += 1
        }
        return count
    }

    /// 深度遍历：sessionId/conversationId/ownerConversationId 键的值若等于旧 id 则替换为新 id
    static func rebindIds(_ value: Any, old: String, new: String) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                let keyLower = k.lowercased()
                if let s = v as? String, s == old,
                   keyLower.contains("session") || keyLower.contains("conversation") || keyLower.contains("owner") {
                    out[k] = new
                } else {
                    out[k] = rebindIds(v, old: old, new: new)
                }
            }
            return out
        }
        if let arr = value as? [Any] {
            return arr.map { rebindIds($0, old: old, new: new) }
        }
        return value
    }

    /// 写入方法本体（照 WorkDaddy writeNativeSessions：乐观锁 + 官方写通道 + 广播）
    private static let writeNativeSessionsSource = """
    async function(changes) {
      return this.enqueueV2Write(async () => {
        if (!this._db || !(this._sessions instanceof Map)) throw new Error('会话存储尚未就绪');
        const updates = new Map();
        for (const change of changes) {
          const current = this._sessions.get(change.id);
          if (current && ['Working','Planning'].includes(current.status)) throw new Error('会话正在运行，请完成后重试');
          if (JSON.stringify(current || null) !== JSON.stringify(change.before || null)) throw new Error('会话已变化，请刷新后重试');
          const value = change.after ? {...current, ...change.after} : {...current, deletedAt:Date.now(), updatedAt:Date.now()};
          if (change.after && change.after.deletedAt == null) delete value.deletedAt;
          value.conversationId = change.id;
          if (typeof this.nextV2Revision === 'function') value.revision = this.nextV2Revision();
          updates.set('session:' + change.id, JSON.stringify(value));
        }
        await this._db.updateItems({insert:updates});
        for (const change of changes) {
          const value = JSON.parse(updates.get('session:' + change.id));
          this._sessions.set(change.id,value);
          this._newSessions.delete(change.id);
          try { if (typeof this.broadcastV2 === 'function') this.broadcastV2(value.deletedAt == null ? 'upsert' : 'delete', value, 'codeer', value.revision); } catch (_) {}
          try { this.notifyAgentManager(value.deletedAt == null ? 'upsert' : 'delete', value.deletedAt == null ? value : {conversationId:change.id}); } catch (_) {}
        }
        return {changed:changes.length};
      });
    }
    """

    // MARK: - 工具

    private func callOnService(client: CDPClient, objectId: String, fn: String, arguments: [Any] = [], awaitPromise: Bool) async throws -> Any? {
        let args = arguments.map { ["value": $0] }
        let inner = Self.unwrap(try await client.send(method: "Runtime.callFunctionOn", params: [
            "objectId": objectId,
            "functionDeclaration": fn,
            "arguments": args,
            "returnByValue": true,
            "awaitPromise": awaitPromise,
        ]))
        if inner["exceptionDetails"] != nil {
            throw NativeAuthError.evalFailed("会话服务调用被拒绝")
        }
        guard let resultObj = inner["result"] as? [String: Any] else { return nil }
        return resultObj["value"]
    }

    private static func unwrap(_ msg: [String: Any]) -> [String: Any] {
        msg["result"] as? [String: Any] ?? msg
    }
}

/// 暂停事件的一次性投递盒（先到先得，后续投递忽略）
final class PauseBox {
    enum Outcome {
        case success([String: Any])
        case failure(Error)
    }

    private var delivered = false
    private let lock = NSLock()
    private let handler: (Outcome) -> Void

    init(handler: @escaping (Outcome) -> Void) {
        self.handler = handler
    }

    func deliver(_ outcome: Outcome) {
        lock.lock()
        guard !delivered else { lock.unlock(); return }
        delivered = true
        lock.unlock()
        handler(outcome)
    }
}
