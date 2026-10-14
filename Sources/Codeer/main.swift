import AppKit

// 自检：验证请求文件解析逻辑（无需 GUI / XCTest）
func runSelfTest() -> Bool {
    var failed = false
    func check(_ cond: Bool, _ name: String) {
        print(cond ? "  ok  \(name)" : "FAIL  \(name)")
        if !cond { failed = true }
    }

    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("codeer-selftest-\(UUID().uuidString)", isDirectory: true)
    let reqDir = base.appendingPathComponent("requests")
    try? FileManager.default.createDirectory(at: reqDir, withIntermediateDirectories: true)

    let sample: [String: Any] = [
        "id": "abc123", "kind": "confirm", "tool": "Bash",
        "command": "rm -rf /tmp/x", "cwd": "/Users/u/work/demo",
        "session_id": "s1", "deadline": Date().addingTimeInterval(60).timeIntervalSince1970,
    ]
    let data = try! JSONSerialization.data(withJSONObject: sample)
    try? data.write(to: reqDir.appendingPathComponent("abc123.json"))

    let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    check(obj["id"] as? String == "abc123", "请求 id 解析")
    check((obj["cwd"] as? String == "/Users/u/work/demo"), "cwd 解析")
    check(((obj["cwd"] as? String ?? "") as NSString).lastPathComponent == "demo", "项目名取 cwd 尾段")
    check((obj["deadline"] as? NSNumber)?.doubleValue ?? 0 > Date().timeIntervalSince1970, "deadline 在未来")

    check(TranscriptParserLike.safeCommand("ls -la"), "ls 识别为安全命令")
    check(!TranscriptParserLike.safeCommand("rm -rf /tmp/x"), "rm 非安全命令")
    check(!TranscriptParserLike.safeCommand("echo hi && rm -rf /tmp/x"), "复合命令不视为安全")

    try? FileManager.default.removeItem(at: base)
    return !failed
}

/// 与 nudge_hook.py 的 SAFE_PATTERN 保持一致的安全命令判断（仅用于自检对照）
enum TranscriptParserLike {
    static func safeCommand(_ cmd: String) -> Bool {
        guard cmd.range(of: #"^\s*(ls|cat|head|tail|pwd|echo|which|whoami|date|uname|wc|du|df|ps|file|stat|grep|find|printenv|sw_vers|git\s+(status|log|diff|show|branch|remote|stash\s+list))\b"#, options: .regularExpression) != nil else {
            return false
        }
        return cmd.range(of: "[;&|`$><]", options: .regularExpression) == nil
    }
}

if CommandLine.arguments.contains("--selftest") {
    exit(runSelfTest() ? 0 : 1)
}

/// M0 验收：发现端口 → 连 webview target → 读聊天 DOM 摘要
if CommandLine.arguments.contains("--cdp-probe") {
    Task {
        do {
            guard let endpoint = await CDPDiscovery.discover() else {
                print("FAIL 未发现 CDP 端口")
                exit(2)
            }
            print("端口 \(endpoint.port)：webview=\(endpoint.webviewTargets.count) main=\(endpoint.mainTarget != nil)")
            let (target, client) = try await CDPDiscovery.connectChat(endpoint: endpoint)
            guard let summary = CDPProbe.ChatSummary.parse(try await client.evaluate(expression: CDPProbe.chatSummary)) else {
                print("FAIL 聊天摘要解析失败")
                exit(2)
            }
            print("命中 target \(target.id.prefix(8))")
            print("chat=\(summary.chat) textLen=\(summary.textLen) btnCount=\(summary.btnCount)")
            print("btns: \(summary.btnSample.joined(separator: " / "))")
            client.close()
            exit(summary.chat && summary.btnCount > 0 ? 0 : 3)
        } catch {
            print("FAIL \(error)")
            exit(2)
        }
    }
    dispatchMain()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
