import Foundation

/// 账号快照库：~/Library/Application Support/Codeer/accounts/<uid>.info
/// 文件内容 = 主进程 auth session 的 JSON 原样结构（含 accessToken/refreshToken）
/// 安全：目录 0700、文件 0600、原子写；日志永不打印 token
final class AccountStore {
    static let shared = AccountStore()

    struct AccountInfo {
        let uid: String
        let nickname: String
        let savedAt: Date
        let fileURL: URL
    }

    private var dir: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Codeer/accounts", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        return base
    }

    /// 保存（或覆盖）一个账号快照
    func save(_ session: AuthSession) throws {
        var json = session.json
        json["__codeerSavedAt"] = Date().timeIntervalSince1970
        json["__codeerNickname"] = session.nickname
        let target = dir.appendingPathComponent("\(session.uid).info")
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let tmp = target.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        _ = try? FileManager.default.replaceItemAt(target, withItemAt: tmp)
        // replaceItemAt 在目标不存在时可能失败，兜底 rename
        if !FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.moveItem(at: tmp, to: target)
        }
        NSLog("[AccountStore] 已保存账号快照 %@（%@）", session.uid, session.nickname)
    }

    /// 列出全部快照（按保存时间倒序）
    func list() -> [AccountInfo] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return files.compactMap { url -> AccountInfo? in
            guard url.pathExtension == "info" else { return nil }
            let uid = url.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let account = json["account"] as? [String: Any],
                  account["uid"] as? String == uid else { return nil }
            let nickname = (json["__codeerNickname"] as? String)
                ?? (account["nickname"] as? String)
                ?? (account["label"] as? String) ?? uid
            let savedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return AccountInfo(uid: uid, nickname: nickname, savedAt: savedAt, fileURL: url)
        }
        .sorted { $0.savedAt > $1.savedAt }
    }

    /// 读取某个快照的完整会话
    func load(uid: String) throws -> AuthSession? {
        let url = dir.appendingPathComponent("\(uid).info")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var clean = json
        clean.removeValue(forKey: "__codeerSavedAt")
        let nick = clean.removeValue(forKey: "__codeerNickname") as? String
        guard var account = clean["account"] as? [String: Any] else { return nil }
        if let nick, !nick.isEmpty { account["nickname"] = nick }
        clean["account"] = account
        return AuthSession(json: clean)
    }

    /// 当前已保存账号数
    var count: Int { list().count }
}
