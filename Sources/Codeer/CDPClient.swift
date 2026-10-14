import Foundation
import os

/// 一条待办：确认请求、选项选择或完成通知（由检测层产出，驱动刘海卡片）
struct PendingItem: Identifiable, Equatable {
    let id: String
    let kind: String            // "confirm" | "options" | "stop"
    let toolName: String
    let summary: String
    let projectPath: String
    let projectName: String
    let since: Date
    let deadline: Date          // confirm: 决策/提醒截止；stop: 显示截止
    var options: [String] = []  // kind == "options" 时的候选（选项卡）
    var blockIndex: Int = -1    // 多问题卡的题序号（0 起，对应 IDE 卡的 questionBlock 序号）；-1 = 单问题卡/全局定位
    var multiSelect: Bool = false // 多选题（题头 multiBadge）：选项为 toggle，需点 continueBtn 提交
    var seedSelected: [String] = [] // 创建时 IDE 侧已勾选项（多选卡初始化勾选态用）
}

/// 极简 CDP 客户端：JSON-RPC over WebSocket（URLSessionWebSocketTask，零依赖）
/// 直接连接页面级 webSocketDebuggerUrl（M0 形态）；Runtime.evaluate 封装
final class CDPClient: NSObject, URLSessionWebSocketDelegate {
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private let lock = NSLock()
    private let nextId = OSAllocatedUnfairLock<Int>(initialState: 0)
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    /// 服务端事件（Runtime.bindingCalled / consoleAPICalled 等）回调
    var onEvent: ((String, [String: Any]) -> Void)?

    func connect(wsURL: URL) async throws {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = .infinity
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        task = session?.webSocketTask(with: wsURL)
        task?.resume()
        receiveLoop()
        _ = try await send(method: "Runtime.enable")
    }

    func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session = nil
        lock.lock()
        let waiters = pending
        pending.removeAll()
        lock.unlock()
        for (_, cont) in waiters { cont.resume(throwing: CDPError.wsClosed) }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message { self.handle(text: text) }
                self.receiveLoop()
            case .failure:
                self.failAll(CDPError.wsClosed)
            }
        }
    }

    private func handle(text: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        if let id = (obj["id"] as? NSNumber)?.intValue {
            lock.lock()
            let cont = pending.removeValue(forKey: id)
            lock.unlock()
            if let cont {
                if obj["error"] != nil {
                    cont.resume(throwing: CDPError.badPayload)
                } else {
                    cont.resume(returning: obj)
                }
            }
        } else if let method = obj["method"] as? String {
            onEvent?(method, (obj["params"] as? [String: Any]) ?? [:])
        }
    }

    private func failAll(_ error: Error) {
        lock.lock()
        let waiters = pending
        pending.removeAll()
        lock.unlock()
        for (_, cont) in waiters { cont.resume(throwing: error) }
    }

    /// 单请求超时（秒）。CDP 对端可能不回包（如页面冻结、target 未就绪），
    /// 无超时会挂死主循环
    private static let requestTimeout: UInt64 = 15_000_000_000

    func send(method: String, params: [String: Any]? = nil, sessionId: String? = nil) async throws -> [String: Any] {
        let id = nextId.withLock { state in state += 1; return state }
        var payload: [String: Any] = ["id": id, "method": method]
        if let params { payload["params"] = params }
        if let sessionId { payload["sessionId"] = sessionId }
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let task else { throw CDPError.wsClosed }

        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            pending[id] = cont
            lock.unlock()
            // 超时守护：到期未收到响应则抛 CDPError.timeout（迟到的响应因条目已移除而被忽略）
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.requestTimeout)
                guard let self else { return }
                self.lock.lock()
                let c = self.pending.removeValue(forKey: id)
                self.lock.unlock()
                c?.resume(throwing: CDPError.timeout)
            }
            task.send(.string(String(data: data, encoding: .utf8)!)) { [weak self] error in
                if let error {
                    self?.lock.lock()
                    let c = self?.pending.removeValue(forKey: id)
                    self?.lock.unlock()
                    c?.resume(throwing: error)
                }
            }
        }
    }

    /// Runtime.evaluate（returnByValue），返回结果 value
    func evaluate(expression: String, sessionId: String? = nil) async throws -> Any? {
        let result = try await send(
            method: "Runtime.evaluate",
            params: ["expression": expression, "returnByValue": true],
            sessionId: sessionId
        )
        guard
            let resultObj = result["result"] as? [String: Any],
            let inner = resultObj["result"] as? [String: Any]
        else { return nil }
        return inner["value"]
    }
}
