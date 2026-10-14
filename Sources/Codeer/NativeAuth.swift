import Foundation
import os

/// CodeBuddy 主进程认证服务的访问层（对齐 WorkDaddy codebuddy-native.js 的机制）
///
/// 前提：CodeBuddy 以 --inspect=127.0.0.1:9244 启动（codeer 的重启脚本自带）。
/// 通过 Node inspector 在主进程上下文 evaluate：
///   process.getBuiltinModule('module').createRequire(process.execPath)('electron')
/// 拿到 ipcMain._invokeHandlers 里的 'vscode:genie:auth:getSession' 处理函数，
/// 沿闭包链找到同时具备 getCurrentSessionAsync/storeSession/scheduleRefresh/
/// _onDidChangeSession 的官方认证服务对象，只借官方方法读写会话，不碰文件。
enum NativeAuthError: Error, LocalizedError, CustomStringConvertible {
    case notConnected
    case noNodeTarget
    case identityMismatch
    case serviceNotFound
    case evalFailed(String)
    case invalidSession(String)

    var errorDescription: String? { description }
    var description: String {
        switch self {
        case .notConnected: return "未连接主进程调试口"
        case .noNodeTarget: return "未发现 CodeBuddy 主进程调试入口（需 --inspect=9244 启动）"
        case .identityMismatch: return "主进程不属于当前 CodeBuddy 安装"
        case .serviceNotFound: return "当前 CodeBuddy 版本的认证服务结构不兼容"
        case .evalFailed(let m): return "主进程调用失败：\(m)"
        case .invalidSession(let m): return m
        }
    }
}

/// 一个账号的登录会话（主进程 auth session 的 JSON 原样结构）
struct AuthSession {
    let uid: String
    let nickname: String
    let json: [String: Any]

    init?(json: [String: Any]) {
        guard let account = json["account"] as? [String: Any],
              let uid = account["uid"] as? String, !uid.isEmpty,
              let auth = json["auth"] as? [String: Any],
              let token = auth["accessToken"] as? String, !token.isEmpty else { return nil }
        self.uid = uid
        self.nickname = (account["nickname"] as? String) ?? (account["label"] as? String) ?? uid
        self.json = json
    }
}

final class NativeAuth {
    static let shared = NativeAuth()
    static let debugPort = 9244

    private var client: CDPClient?
    /// 认证服务对象在主进程堆里的 objectId（连接断开即失效）
    private var serviceObjectId: String?
    private let lock = NSLock()

    // MARK: - 连接与身份校验

    /// 连接主进程 inspector 并定位认证服务；幂等
    func ensureConnected() async throws {
        lock.lock()
        let connected = client != nil && serviceObjectId != nil
        lock.unlock()
        if connected { return }

        NSLog("[NativeAuth] 连接主进程：发现 node target…")
        guard let target = try await Self.findNodeTarget() else { throw NativeAuthError.noNodeTarget }
        guard let ws = target["webSocketDebuggerUrl"] as? String,
              let url = URL(string: ws) else { throw NativeAuthError.noNodeTarget }

        let client = CDPClient()
        do {
            try await client.connect(wsURL: url)
            NSLog("[NativeAuth] 主进程 ws 已连接")

            // 身份校验：exe 与 userData 必须是当前 CodeBuddy 安装
            let identityExpr = """
            (()=>{const e=process.getBuiltinModule('module').createRequire(process.execPath)('electron');
            return {exe:process.execPath,userData:e.app.getPath('userData')};})()
            """
            guard let identity = try await client.evaluate(expression: identityExpr) as? [String: Any],
                  let exe = identity["exe"] as? String,
                  exe.hasPrefix("/Applications/CodeBuddy CN.app/Contents/MacOS/"),
                  let userData = identity["userData"] as? String,
                  userData.hasSuffix("/CodeBuddy CN") else {
                client.close()
                NSLog("[NativeAuth] 身份校验失败（exe/userData 不匹配）")
                throw NativeAuthError.identityMismatch
            }

            NSLog("[NativeAuth] 身份校验通过，查找认证服务…")
            let objectId = try await Self.findAuthService(client: client)
            lock.lock()
            self.client = client
            self.serviceObjectId = objectId
            lock.unlock()
            NSLog("[NativeAuth] 已连接主进程认证服务")
        } catch {
            client.close()
            throw error
        }
    }

    private static func findNodeTarget() async throws -> [String: Any]? {
        let url = URL(string: "http://127.0.0.1:\(debugPort)/json/list")!
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NativeAuthError.noNodeTarget
        }
        return arr.first { ($0["type"] as? String) == "node" }
    }

    // MARK: - 会话读写

    /// 读取当前登录会话（未登录返回 nil）
    func readSession() async throws -> AuthSession? {
        try await ensureConnected()
        guard let client, let objectId = currentObjectId() else { throw NativeAuthError.notConnected }
        let value = try await callOnService(
            client: client, objectId: objectId,
            fn: "async function(){return (await this.getCurrentSessionAsync()) || null;}"
        )
        guard let dict = value as? [String: Any] else { return nil }
        guard let session = AuthSession(json: dict) else {
            throw NativeAuthError.evalFailed("当前会话结构异常")
        }
        return session
    }

    /// 替换当前登录会话（照 WorkDaddy replaceNativeSession：写回 + 广播 + 失败回滚都在官方服务内完成）
    func replaceSession(with session: AuthSession) async throws {
        try await ensureConnected()
        guard let client, let objectId = currentObjectId() else { throw NativeAuthError.notConnected }

        let fn = """
        async function(session){
          await this.initialized;
          if (this.refreshInFlight || this.loginInProgress || this.logoutInProgress) throw new Error('登录状态正在更新，请稍后重试');
          if (session !== null && (!session || !session.account || !session.account.uid || !session.auth || typeof session.auth.accessToken !== 'string' || !session.auth.accessToken)) throw new Error('账号备份无效');
          const previous = this.currentSession;
          let unlock;
          this.loginInProgress = new Promise(resolve => { unlock = resolve; });
          this.refreshInFlight = true;
          this.logoutInProgress = true;
          if (this.refreshTimer) { clearTimeout(this.refreshTimer); this.refreshTimer = undefined; }
          const persist = async value => {
            if (value) await this.storeSession(value);
            else await this.storageService.remove(this.getStorageKey(), -1);
          };
          let succeeded = false;
          let persistedNewSession = false;
          try {
            await persist(session);
            persistedNewSession = session !== null;
            this.currentSession = session || undefined;
            this.refreshFailureRetryCount = 0;
            this._onDidChangeSession.fire(this.currentSession);
            this.scheduleRefresh();
            succeeded = true;
            return {uid: session ? String(session.account.uid) : null};
          } catch (_) {
            try {
              if (previous) await persist(previous);
              else if (persistedNewSession) await persist(null);
              this.currentSession = previous;
              this._onDidChangeSession.fire(previous);
              this.scheduleRefresh();
            } catch (_) {
              throw new Error('账号切换失败，原登录态恢复未确认');
            }
            throw new Error('账号切换失败，已恢复原登录态');
          } finally {
            this.refreshInFlight = false;
            this.logoutInProgress = false;
            this.loginInProgress = undefined;
            unlock(succeeded);
          }
        }
        """
        // 传参会经 JSONSerialization 编码，token 等字符串安全
        let value = try await callOnService(
            client: client, objectId: objectId, fn: fn,
            arguments: [session.json], awaitPromise: true
        )
        if let dict = value as? [String: Any], let uid = dict["uid"] as? String {
            NSLog("[NativeAuth] 会话已切换到 %@" , uid)
        }
    }

    // MARK: - 认证服务发现（照 WorkDaddy：invokeHandler → 闭包链 → 谓词匹配）

    private func currentObjectId() -> String? {
        lock.lock(); defer { lock.unlock() }
        return serviceObjectId
    }

    private static func findAuthService(client: CDPClient) async throws -> String {
        let service = try await findNativeService(
            client: client,
            channel: "vscode:genie:auth:getSession",
            predicate: """
            function () {
              return typeof this.getCurrentSessionAsync === 'function' && typeof this.storeSession === 'function' &&
                typeof this.scheduleRefresh === 'function' && typeof this._onDidChangeSession?.fire === 'function';
            }
            """
        )
        guard let service else { throw NativeAuthError.serviceNotFound }
        return service
    }

    /// CDPClient.send 返回整条消息 {id, result: {...}}；取其中的 result 载荷
    private static func unwrap(_ msg: [String: Any]) -> [String: Any] {
        msg["result"] as? [String: Any] ?? msg
    }

    private static func findNativeService(client: CDPClient, channel: String, predicate: String) async throws -> String? {
        // 入口：ipcMain._invokeHandlers.get(channel) —— 一个函数对象
        let expression = "process.getBuiltinModule('module').createRequire(process.execPath)('electron').ipcMain._invokeHandlers.get(" + Self.jsString(channel) + ")"
        let rootResult = unwrap(try await client.send(method: "Runtime.evaluate", params: [
            "expression": expression,
            "objectGroup": "codeer-auth",
        ]))
        if rootResult["exceptionDetails"] != nil {
            NSLog("[NativeAuth] 认证入口 evaluate 异常：%@", String(describing: rootResult["exceptionDetails"]).prefix(300) as NSString)
            throw NativeAuthError.evalFailed("认证入口不存在")
        }
        guard let root = rootResult["result"] as? [String: Any],
              root["type"] as? String == "function",
              let rootId = root["objectId"] as? String else {
            NSLog("[NativeAuth] 认证入口类型异常，原始响应：%@", String(describing: rootResult).prefix(300) as NSString)
            throw NativeAuthError.evalFailed("认证入口类型异常")
        }

        var seen = Set<String>()
        return try await visit(client: client, objectId: rootId, depth: 0, seen: &seen, predicate: predicate)
    }

    /// 沿函数的 [[Scopes]] 闭包链递归找满足谓词的服务对象（深度 ≤4，扫描面 ≤24，不碰全局堆）
    private static func visit(client: CDPClient, objectId: String, depth: Int, seen: inout Set<String>, predicate: String) async throws -> String? {
        if depth > 4 || seen.contains(objectId) || seen.count > 24 { return nil }
        seen.insert(objectId)
        let props = unwrap(try await client.send(method: "Runtime.getProperties", params: ["objectId": objectId, "ownProperties": true]))
        guard let internalProps = props["internalProperties"] as? [[String: Any]],
              let scopes = internalProps.first(where: { ($0["name"] as? String) == "[[Scopes]]" }),
              let scopesVal = scopes["value"] as? [String: Any],
              let scopesId = scopesVal["objectId"] as? String else { return nil }
        let scopeList = unwrap(try await client.send(method: "Runtime.getProperties", params: ["objectId": scopesId, "ownProperties": true]))
        guard let scopeResults = scopeList["result"] as? [[String: Any]] else { return nil }
        for scope in scopeResults where (scope["name"] as? String)?.range(of: #"^\d+$"#, options: .regularExpression) != nil {
            guard let scopeVal = scope["value"] as? [String: Any],
                  (scopeVal["description"] as? String)?.contains("Closure") == true,
                  let scopeObjectId = scopeVal["objectId"] as? String else { continue }
            let members = unwrap(try await client.send(method: "Runtime.getProperties", params: ["objectId": scopeObjectId, "ownProperties": true]))
            guard let memberResults = members["result"] as? [[String: Any]], memberResults.count <= 24 else { continue }
            // 对象成员：直接用谓词检测
            for member in memberResults where (member["value"] as? [String: Any])?["type"] as? String == "object" {
                guard let mv = member["value"] as? [String: Any], let mId = mv["objectId"] as? String else { continue }
                let check = unwrap(try await client.send(method: "Runtime.callFunctionOn", params: [
                    "objectId": mId, "functionDeclaration": predicate, "returnByValue": true,
                ]))
                if (check["result"] as? [String: Any])?["value"] as? Bool == true { return mId }
            }
            // 函数成员：递归进其闭包
            for member in memberResults where (member["value"] as? [String: Any])?["type"] as? String == "function" {
                guard let mv = member["value"] as? [String: Any], let mId = mv["objectId"] as? String else { continue }
                if let found = try await visit(client: client, objectId: mId, depth: depth + 1, seen: &seen, predicate: predicate) {
                    return found
                }
            }
        }
        return nil
    }

    /// 在服务对象上调用函数（this = 服务），支持传参 / awaitPromise
    private func callOnService(client: CDPClient, objectId: String, fn: String, arguments: [Any] = [], awaitPromise: Bool = true) async throws -> Any? {
        let args = arguments.map { ["value": $0] }
        let inner = Self.unwrap(try await client.send(method: "Runtime.callFunctionOn", params: [
            "objectId": objectId,
            "functionDeclaration": fn,
            "arguments": args,
            "returnByValue": true,
            "awaitPromise": awaitPromise,
        ]))
        if inner["exceptionDetails"] != nil {
            // 不把可能含凭据的异常细节带出来
            throw NativeAuthError.evalFailed("服务调用被拒绝")
        }
        guard let resultObj = inner["result"] as? [String: Any] else { return nil }
        return resultObj["value"]
    }

    private static func jsString(_ s: String) -> String {
        // 通道名是固定常量（无引号/反斜杠等需转义字符），直接包裹即可
        return "\"" + s + "\""
    }

    /// 连接失效时由外部调用（如调用报 notConnected）
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        client?.close()
        client = nil
        serviceObjectId = nil
    }
}
