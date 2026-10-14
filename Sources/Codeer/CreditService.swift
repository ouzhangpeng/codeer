import Foundation

// MARK: - 数据模型

/// 单个积分段（资源包/月度周期），expiresAt = 扣费窗口 ∩ 计费周期的最早到期点
struct CreditSegment {
    let remaining: Double
    let total: Double
    let expiresAt: Date?
    let source: String
}

/// 单账号积分汇总
struct CreditSummary {
    let uid: String
    let nickname: String
    var credits: Double = 0          // 剩余（周期剩余口径，WorkDaddy 同款）
    var totalDosage: Double = 0      // 累计用量
    var segments: [CreditSegment] = []
    var error: String?
}

/// 单账号用量聚合
struct UsageAggregate {
    var days: [UsageDay] = []        // 按日积分消耗（升序）
    var models: [(model: String, credit: Double)] = []  // 按模型 Top（降序）
    var error: String?
    var total: Double = 0
}

struct UsageDay {
    let date: String                 // yyyy-MM-dd
    let credit: Double
    let requests: Int
}

// MARK: - 积分服务（照抄 WorkDaddy 的数据源与解析口径）

final class CreditService {
    static let shared = CreditService()
    static let apiHost = "https://www.workbuddy.cn"

    private init() {}

    // MARK: 字段候选链（与 WorkDaddy credit-segments.js 一致）

    private static let remainingFields = [
        "SlicePeriodCapacityRemainPrecise", "SlicePeriodCapacityRemain",
        "CycleCapacityRemainPrecise", "CycleCapacityRemain",
        "CapacityRemainPrecise", "CapacityRemain",
        "RemainPrecise", "Remain", "Remaining", "Balance",
    ]
    private static let totalFields = [
        "SlicePeriodCapacitySizePrecise", "SlicePeriodCapacitySize",
        "CycleCapacitySizePrecise", "CycleCapacitySize",
        "CycleCapacityPrecise", "CycleCapacity",
        "CapacityPrecise", "Capacity",
        "TotalCapacityPrecise", "TotalCapacity",
        "PackageCapacity", "Quota", "Amount",
    ]
    /// 到期点取候选中「最早」的非空值（扣费窗口 ∩ 计费周期，见 WorkDaddy 积分段到期修正注释）
    private static let expiryFields = [
        "DeductionEndTime", "ExpiredTime", "SlicePeriodEndTime", "PackageEndTime",
        "EndTime", "CycleEndTime", "ExpireTime", "ExpirationTime",
        "ValidEndTime", "ValidPeriodEndTime", "EndAt", "ExpireAt",
    ]
    private static let labelFields = [
        "PackageName", "PackageTypeName", "AccountName", "ProductName",
        "Name", "RuleName", "Description",
    ]

    // MARK: 账号集合（当前登录 + 已备份快照，按 uid 去重）

    struct AccountCred {
        let uid: String
        let nickname: String
        let token: String
    }

    private var currentSessionCache: AccountCred?

    /// 当前登录账号（NativeAuth 读取，失败则只返回已备份账号）
    private func currentAccount() async -> AccountCred? {
        if let c = currentSessionCache { return c }
        guard let session = try? await NativeAuth.shared.readSession() else { return nil }
        guard let token = session.json["auth"] as? [String: Any], let token = token["accessToken"] as? String, !token.isEmpty else { return nil }
        let cred = AccountCred(uid: session.uid, nickname: session.nickname, token: token)
        currentSessionCache = cred
        return cred
    }

    func invalidateCurrentSession() { currentSessionCache = nil }

    /// 全部账号（当前在前），按 uid 去重
    func allAccounts() async -> [AccountCred] {
        var result: [AccountCred] = []
        var seen = Set<String>()
        if let cur = await currentAccount() {
            result.append(cur); seen.insert(cur.uid)
        }
        for info in AccountStore.shared.list() where !seen.contains(info.uid) {
            guard let session = try? AccountStore.shared.load(uid: info.uid),
                  let auth = session.json["auth"] as? [String: Any],
                  let token = auth["accessToken"] as? String, !token.isEmpty else { continue }
            result.append(AccountCred(uid: session.uid, nickname: session.nickname, token: token))
            seen.insert(session.uid)
        }
        return result
    }

    // MARK: 余额 + 积分段（过期情况的数据源）

    func fetchCredits(accessToken: String) async throws -> (credits: Double, totalDosage: Double, segments: [CreditSegment]) {
        let body: [String: Any] = [
            "PageNumber": 1,
            "PageSize": 100,
            "ProductCode": "p_tcaca",
            "Status": [0, 3],
            "PackageEndTimeRangeBegin": Self.localDateTime(Date()),
            "PackageEndTimeRangeEnd": Self.localDateTime(Date().addingTimeInterval(101 * 365 * 24 * 3600)),
        ]
        let json = try await Self.post(path: "/v2/billing/meter/get-user-resource", token: accessToken, body: body)

        // data：o.data.Response.Data（兼容小写变体；实测 2026-10-14 即此结构）
        let dataLayer = json["data"] as? [String: Any] ?? [:]
        let respLayer = (dataLayer["Response"] as? [String: Any]) ?? (dataLayer["response"] as? [String: Any]) ?? [:]
        let data = (respLayer["Data"] as? [String: Any]) ?? (respLayer["data"] as? [String: Any]) ?? [:]
        let accounts = (data["Accounts"] as? [[String: Any]])
            ?? ((json["data"] as? [String: Any])?["accounts"] as? [[String: Any]])
            ?? []

        // credits = Σ 候选字段首个可解析值（周期剩余优先，WorkDaddy 同款口径）
        var credits = 0.0
        for a in accounts { credits += Self.firstNumber(a, Self.remainingFields) ?? 0 }

        let totalDosage = (data["TotalDosage"] as? NSNumber).map { $0.doubleValue } ?? 0

        // segments：SlicePeriodUsageDetails 非空则每 detail 合并 account 展开，否则 account 本身
        var rawSegments: [(remaining: Double, total: Double, expiresAt: Date?, source: String)] = []
        for a in accounts {
            let details = (a["SlicePeriodUsageDetails"] as? [[String: Any]]) ?? []
            let items: [[String: Any]] = details.isEmpty ? [a] : details.map { d in
                var merged = a; for (k, v) in d { merged[k] = v }; return merged
            }
            for item in items {
                guard let remaining = Self.firstNumber(item, Self.remainingFields), remaining > 0 else { continue }
                let total = Self.firstNumber(item, Self.totalFields) ?? 0
                let expiresAt = Self.earliestDate(item, Self.expiryFields)
                let source = Self.firstText(item, Self.labelFields)
                rawSegments.append((remaining, total, expiresAt, source))
            }
        }
        // 合并相同 (source, expiresAt)
        var merged: [CreditSegment] = []
        for seg in rawSegments.sorted(by: { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }) {
            if let idx = merged.firstIndex(where: { $0.source == seg.source && $0.expiresAt == seg.expiresAt }) {
                merged[idx] = CreditSegment(
                    remaining: merged[idx].remaining + seg.remaining,
                    total: merged[idx].total + seg.total,
                    expiresAt: seg.expiresAt,
                    source: seg.source
                )
            } else {
                merged.append(CreditSegment(remaining: seg.remaining, total: seg.total, expiresAt: seg.expiresAt, source: seg.source))
            }
        }
        // API 新增字段未识别时补「其他积分」段，保证总额与分段条一致
        let visible = merged.reduce(0.0) { $0 + $1.remaining }
        if credits > visible + 0.01 {
            merged.append(CreditSegment(remaining: credits - visible, total: credits - visible, expiresAt: nil, source: "其他积分"))
        }
        return (credits: (credits * 100).rounded() / 100, totalDosage: totalDosage, segments: merged)
    }

    // MARK: 用量（近 N 天，按日 + 按模型聚合）

    func fetchUsage(accessToken: String, days: Int) async throws -> UsageAggregate {
        let cal = Calendar.current
        let end = Date()
        let start = cal.startOfDay(for: cal.date(byAdding: .day, value: -(days - 1), to: end) ?? end)

        var rows: [(time: Date, credit: Double, model: String)] = []
        var pageNum = 1
        let pageSize = 100
        while pageNum <= 20 {
            let body: [String: Any] = [
                "startTime": Self.localDateTime(start),
                "endTime": Self.localDateTime(end),
                "pageNum": pageNum,
                "pageSize": pageSize,
            ]
            let json = try await Self.post(path: "/billing/meter/get-user-request-usage", token: accessToken, body: body)
            let data = json["data"] as? [String: Any] ?? [:]
            let total = (data["total"] as? NSNumber)?.intValue ?? 0
            let list = data["data"] as? [[String: Any]] ?? []
            for row in list {
                guard let t = Self.parseTime(row["requestTime"]),
                      let n = (row["credit"] as? NSNumber)?.doubleValue, n >= 0 else { continue }
                rows.append((time: t, credit: n, model: Self.usageModel(row)))
            }
            if rows.count >= total || list.isEmpty { break }
            pageNum += 1
        }

        // 按日聚合（本地日期）
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        var byDay: [String: (credit: Double, count: Int)] = [:]
        var byModel: [String: Double] = [:]
        var totalCredit = 0.0
        for r in rows {
            let day = fmt.string(from: r.time)
            let cur = byDay[day] ?? (0, 0)
            byDay[day] = (cur.credit + r.credit, cur.count + 1)
            if !r.model.isEmpty { byModel[r.model, default: 0] += r.credit }
            totalCredit += r.credit
        }
        let dayList = byDay.keys.sorted().map { UsageDay(date: $0, credit: (byDay[$0]!.credit * 100).rounded() / 100, requests: byDay[$0]!.count) }
        let modelList = byModel.map { (model: $0.key, credit: $0.value) }.sorted { $0.credit > $1.credit }
        return UsageAggregate(days: dayList, models: Array(modelList.prefix(8)), error: nil, total: (totalCredit * 100).rounded() / 100)
    }

    // MARK: 全账号并发查询（batch 3，WorkDaddy 同款节流）

    func fetchAll(days: Int) async -> (accounts: [CreditSummary], usage: [String: UsageAggregate]) {
        let accounts = await allAccounts()
        var summaries: [CreditSummary] = []
        var usage: [String: UsageAggregate] = [:]
        let batchSize = 3
        for batchStart in stride(from: 0, to: accounts.count, by: batchSize) {
            let batch = Array(accounts[batchStart..<min(batchStart + batchSize, accounts.count)])
            let results = await withTaskGroup(of: (Int, CreditSummary, UsageAggregate?).self) { group in
                for (i, acc) in batch.enumerated() {
                    group.addTask { [weak self] in
                        guard let self else { return (i, CreditSummary(uid: acc.uid, nickname: acc.nickname), nil) }
                        var summary = CreditSummary(uid: acc.uid, nickname: acc.nickname)
                        var agg: UsageAggregate?
                        do {
                            let r = try await self.fetchCredits(accessToken: acc.token)
                            summary.credits = r.credits
                            summary.totalDosage = r.totalDosage
                            summary.segments = r.segments
                        } catch {
                            summary.error = error.localizedDescription
                        }
                        do {
                            agg = try await self.fetchUsage(accessToken: acc.token, days: days)
                        } catch {
                            agg = UsageAggregate(error: error.localizedDescription)
                        }
                        return (i, summary, agg)
                    }
                }
                var out: [(Int, CreditSummary, UsageAggregate?)] = []
                for await r in group { out.append(r) }
                return out.sorted { $0.0 < $1.0 }
            }
            for (_, summary, agg) in results {
                summaries.append(summary)
                if let agg { usage[summary.uid] = agg }
            }
        }
        return (summaries, usage)
    }

    // MARK: HTTP

    private static func post(path: String, token: String, body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: apiHost + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "accept")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("web", forHTTPHeaderField: "x-client-platform")
        req.setValue(apiHost, forHTTPHeaderField: "origin")
        req.setValue("\(apiHost)/profile/plans-usage", forHTTPHeaderField: "referer")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36", forHTTPHeaderField: "user-agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if (resp as? HTTPURLResponse)?.statusCode == 401 {
            throw NSError(domain: "credit", code: 401, userInfo: [NSLocalizedDescriptionKey: "登录身份过期（token 失效）"])
        }
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "credit", code: -1, userInfo: [NSLocalizedDescriptionKey: "积分接口返回了无法解析的数据"])
        }
        if let code = (o["code"] as? NSNumber)?.intValue, code != 0 {
            throw NSError(domain: "credit", code: code, userInfo: [NSLocalizedDescriptionKey: (o["msg"] as? String) ?? "积分接口返回 code=\(code)"])
        }
        return o
    }

    // MARK: 解析辅助

    private static func firstNumber(_ dict: [String: Any], _ fields: [String]) -> Double? {
        for f in fields {
            if let n = (dict[f] as? NSNumber)?.doubleValue { return n }
            if let s = dict[f] as? String, let n = Double(s) { return n }
        }
        return nil
    }

    private static func firstText(_ dict: [String: Any], _ fields: [String]) -> String {
        for f in fields {
            if let s = dict[f] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty {
                return s.trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    private static func parseTime(_ value: Any?) -> Date? {
        guard let value else { return nil }
        if let n = (value as? NSNumber)?.doubleValue {
            return Date(timeIntervalSince1970: n < 1e12 ? n : n / 1000)
        }
        if let s = value as? String {
            if let n = Double(s), n > 0 {
                return Date(timeIntervalSince1970: n < 1e12 ? n : n / 1000)
            }
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
            fmt.locale = Locale(identifier: "en_US_POSIX")
            if let d = fmt.date(from: s) { return d }
            fmt.dateFormat = "yyyy-MM-dd"
            if let d = fmt.date(from: s) { return d }
            if let d = ISO8601DateFormatter().date(from: s) { return d }
        }
        return nil
    }

    private static func earliestDate(_ dict: [String: Any], _ fields: [String]) -> Date? {
        var earliest: Date?
        for f in fields {
            guard let d = parseTime(dict[f]) else { continue }
            if earliest == nil || d < earliest! { earliest = d }
        }
        return earliest
    }

    /// 用量行的模型字段（官方接口历史上换过多种形态，WorkDaddy 同款兼容）
    private static func usageModel(_ row: [String: Any]) -> String {
        for key in ["model", "modelName", "model_name", "modelId", "model_id", "modelInfo", "model_info"] {
            guard let v = row[key] else { continue }
            if let s = v as? String, !s.isEmpty { return s }
            if let n = v as? NSNumber { return n.stringValue }
            if let dict = v as? [String: Any] {
                for k in ["name", "modelName", "model_name", "id", "modelId", "model_id", "slug"] {
                    if let s = dict[k] as? String, !s.isEmpty { return s }
                    if let n = dict[k] as? NSNumber { return n.stringValue }
                }
            }
        }
        return ""
    }

    private static func localDateTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: date)
    }
}
