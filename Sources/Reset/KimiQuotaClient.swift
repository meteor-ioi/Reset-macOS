import Foundation

struct KimiQuotaClient: Sendable {
    private static let defaultBaseURL = "https://api.kimi.com/coding/v1"
    private static let defaultOAuthHost = "https://auth.kimi.com"
    private static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"

    func fetch() async throws -> ProviderUsage {
        var credential = try readCredential()
        if credential.shouldRefresh {
            credential = try await refreshCredential(credential)
        }

        do {
            return try await fetchUsage(accessToken: credential.accessToken)
        } catch UsageReadError.unauthorized {
            credential = try await refreshCredential(credential, force: true)
            return try await fetchUsage(accessToken: credential.accessToken)
        }
    }

    private func fetchUsage(accessToken: String) async throws -> ProviderUsage {
        let base = ProcessInfo.processInfo.environment["KIMI_CODE_BASE_URL"] ?? Self.defaultBaseURL
        guard let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/usages") else {
            throw UsageReadError.invalidResponse("Kimi Code 额度地址无效")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageReadError.unavailable("Kimi Code 返回了无效网络响应")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw UsageReadError.unauthorized("Kimi Code 登录已失效，请运行 kimi login")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UsageReadError.unavailable(Self.apiError(in: data) ?? "Kimi Code 额度接口 HTTP \(http.statusCode)")
        }
        return try Self.parseUsage(data)
    }

    static func parseUsage(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageReadError.invalidResponse("Kimi Code 额度响应格式异常")
        }

        var rows: [UsageRow] = []
        if let summary = root["usage"] as? [String: Any],
           let row = usageRow(from: summary, label: "一周额度", fallbackSeconds: 7 * 86_400, now: now) {
            rows.append(row)
        }
        if let limits = root["limits"] as? [[String: Any]] {
            for (index, item) in limits.enumerated() {
                let detail = item["detail"] as? [String: Any] ?? item
                let window = item["window"] as? [String: Any] ?? [:]
                let seconds = durationSeconds(item: item, detail: detail, window: window)
                let label = string(item["name"])
                    ?? string(detail["name"])
                    ?? string(item["title"])
                    ?? string(detail["title"])
                    ?? inferredLabel(seconds: seconds, index: index)
                let resolvedSeconds = seconds > 0 ? seconds : inferredWindowSeconds(label: label)
                if let row = usageRow(
                    from: detail,
                    label: label,
                    fallbackSeconds: resolvedSeconds,
                    resetContainer: item,
                    now: now
                ) {
                    rows.append(row)
                }
            }
        }

        var fiveHour: QuotaWindow?
        var sevenDay: QuotaWindow?
        var monthly: QuotaWindow?
        for row in rows {
            let lower = row.label.lowercased()
            let isFiveHourLabel = lower.contains("5h") || lower.contains("5 小时")
            let isWeeklyLabel = lower.contains("week") || lower.contains("周")
            let isMonthlyLabel = lower.contains("month") || lower.contains("月")
            if isFiveHourLabel || (!isWeeklyLabel && !isMonthlyLabel && row.window.windowSeconds <= 6 * 3_600) {
                fiveHour = moreConstrained(fiveHour, row.window)
            } else if isWeeklyLabel || (!isMonthlyLabel && row.window.windowSeconds <= 10 * 86_400) {
                sevenDay = moreConstrained(sevenDay, row.window)
            } else {
                monthly = moreConstrained(monthly, row.window)
            }
        }

        guard fiveHour != nil || sevenDay != nil || monthly != nil else {
            throw UsageReadError.invalidResponse("Kimi Code 额度响应没有可用的额度窗口")
        }

        let wallet = root["boosterWallet"] as? [String: Any]
        let balance = extraUsageBalance(from: wallet)
        let currency = extraUsageCurrency(from: wallet)
        return ProviderUsage(
            provider: .kimiCode,
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            monthly: monthly,
            capturedAt: now,
            extraUsageBalance: balance,
            extraUsageCurrency: balance == nil ? nil : currency
        )
    }

    private func readCredential() throws -> KimiCredential {
        guard let data = try? Data(contentsOf: credentialURL) else {
            throw UsageReadError.notLoggedIn("Kimi Code 未登录，请运行 kimi login")
        }
        do {
            let credential = try JSONDecoder().decode(KimiCredential.self, from: data)
            guard !credential.accessToken.isEmpty else {
                throw UsageReadError.notLoggedIn("Kimi Code 本地凭据缺少 access_token")
            }
            return credential
        } catch let error as UsageReadError {
            throw error
        } catch {
            throw UsageReadError.invalidResponse("Kimi Code 本地凭据格式异常")
        }
    }

    private func refreshCredential(_ current: KimiCredential, force: Bool = false) async throws -> KimiCredential {
        guard force || current.shouldRefresh else { return current }
        guard !current.refreshToken.isEmpty else {
            throw UsageReadError.unauthorized("Kimi Code 登录已过期，请运行 kimi login")
        }

        let lock = try await acquireRefreshLock()
        defer { try? FileManager.default.removeItem(at: lock) }

        let latest = (try? readCredential()) ?? current
        if !force, !latest.shouldRefresh { return latest }
        guard !latest.refreshToken.isEmpty else {
            throw UsageReadError.unauthorized("Kimi Code 登录已过期，请运行 kimi login")
        }

        let host = ProcessInfo.processInfo.environment["KIMI_CODE_OAUTH_HOST"]
            ?? ProcessInfo.processInfo.environment["KIMI_OAUTH_HOST"]
            ?? Self.defaultOAuthHost
        guard let url = URL(string: host.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/oauth/token") else {
            throw UsageReadError.invalidResponse("Kimi Code OAuth 地址无效")
        }
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: latest.refreshToken)
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageReadError.unavailable("Kimi Code 登录刷新返回了无效响应")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw UsageReadError.unauthorized("Kimi Code 登录已失效，请运行 kimi login")
        }
        guard http.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = Self.string(root["access_token"]),
              let refreshToken = Self.string(root["refresh_token"]),
              let expiresIn = Self.number(root["expires_in"]),
              expiresIn > 0 else {
            throw UsageReadError.unavailable(Self.apiError(in: data) ?? "Kimi Code 登录刷新失败（HTTP \(http.statusCode)）")
        }

        let refreshed = KimiCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().timeIntervalSince1970 + expiresIn,
            scope: Self.string(root["scope"]) ?? latest.scope,
            tokenType: Self.string(root["token_type"]) ?? "Bearer",
            expiresIn: expiresIn
        )
        try saveCredential(refreshed)
        return refreshed
    }

    private func acquireRefreshLock() async throws -> URL {
        let manager = FileManager.default
        let oauthDirectory = kimiHome.appendingPathComponent("oauth", isDirectory: true)
        try manager.createDirectory(at: oauthDirectory, withIntermediateDirectories: true)
        let lock = oauthDirectory.appendingPathComponent("kimi-code.lock", isDirectory: true)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            do {
                try manager.createDirectory(at: lock, withIntermediateDirectories: false)
                return lock
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                throw UsageReadError.unavailable("无法协调 Kimi Code 登录刷新：\(error.localizedDescription)")
            }
        }
        throw UsageReadError.unavailable("Kimi Code 正在刷新登录，请稍后重试")
    }

    private func saveCredential(_ credential: KimiCredential) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: credentialURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(credential)
        try data.write(to: credentialURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialURL.path)
    }

    private var kimiHome: URL {
        if let override = ProcessInfo.processInfo.environment["KIMI_CODE_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code", isDirectory: true)
    }

    private var credentialURL: URL {
        kimiHome.appendingPathComponent("credentials/kimi-code.json")
    }

    private struct UsageRow {
        let label: String
        let window: QuotaWindow
    }

    private static func usageRow(
        from raw: [String: Any],
        label: String,
        fallbackSeconds: Int,
        resetContainer: [String: Any]? = nil,
        now: Date
    ) -> UsageRow? {
        guard let limit = number(raw["limit"]), limit > 0 else { return nil }
        let used = number(raw["used"]) ?? number(raw["remaining"]).map { limit - $0 }
        guard let used else { return nil }
        let utilization = max(0, min(100, used / limit * 100))
        let reset = resetDate(from: raw, now: now) ?? resetContainer.flatMap { resetDate(from: $0, now: now) }
        return UsageRow(
            label: label,
            window: QuotaWindow(
                utilization: utilization,
                resetsAt: reset,
                windowSeconds: max(1, fallbackSeconds)
            )
        )
    }

    private static func durationSeconds(
        item: [String: Any],
        detail: [String: Any],
        window: [String: Any]
    ) -> Int {
        let duration = number(window["duration"] ?? item["duration"] ?? detail["duration"]).map(Int.init) ?? 0
        let unit = string(window["timeUnit"] ?? item["timeUnit"] ?? detail["timeUnit"])?.uppercased() ?? ""
        if unit.contains("MINUTE") { return max(1, duration * 60) }
        if unit.contains("HOUR") { return max(1, duration * 3_600) }
        if unit.contains("DAY") { return max(1, duration * 86_400) }
        return max(0, duration)
    }

    private static func inferredLabel(seconds: Int, index: Int) -> String {
        if seconds > 0, seconds % 3_600 == 0 { return "\(seconds / 3_600)h limit" }
        return "额度 #\(index + 1)"
    }

    private static func inferredWindowSeconds(label: String) -> Int {
        let lower = label.lowercased()
        if lower.contains("5h") || lower.contains("5 小时") { return 5 * 3_600 }
        if lower.contains("week") || lower.contains("周") { return 7 * 86_400 }
        if lower.contains("month") || lower.contains("月") { return 30 * 86_400 }
        return 5 * 3_600
    }

    private static func resetDate(from raw: [String: Any], now: Date) -> Date? {
        for key in ["reset_at", "resetAt", "reset_time", "resetTime"] {
            if let value = raw[key] {
                if let timestamp = number(value) {
                    return Date(timeIntervalSince1970: timestamp > 10_000_000_000 ? timestamp / 1_000 : timestamp)
                }
                if let text = string(value) {
                    let fractional = ISO8601DateFormatter()
                    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    let plain = ISO8601DateFormatter()
                    plain.formatOptions = [.withInternetDateTime]
                    if let date = fractional.date(from: text) ?? plain.date(from: text) { return date }
                }
            }
        }
        for key in ["reset_in", "resetIn", "ttl"] {
            if let seconds = number(raw[key]), seconds > 0 {
                return now.addingTimeInterval(seconds)
            }
        }
        return nil
    }

    private static func moreConstrained(_ current: QuotaWindow?, _ candidate: QuotaWindow) -> QuotaWindow {
        guard let current else { return candidate }
        return candidate.remaining < current.remaining ? candidate : current
    }

    private static func extraUsageBalance(from wallet: [String: Any]?) -> Double? {
        guard let balance = wallet?["balance"] as? [String: Any],
              string(balance["type"]) == "BOOSTER",
              let raw = number(balance["amountLeft"]) else { return nil }
        return max(0, raw / 100_000_000)
    }

    private static func extraUsageCurrency(from wallet: [String: Any]?) -> String {
        let monthlyLimit = wallet?["monthlyChargeLimit"] as? [String: Any]
        let monthlyUsed = wallet?["monthlyUsed"] as? [String: Any]
        return string(monthlyLimit?["currency"]) ?? string(monthlyUsed?["currency"]) ?? "USD"
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func apiError(in data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return string(root["message"])
            ?? (root["error"] as? [String: Any]).flatMap { string($0["message"]) }
    }
}

private struct KimiCredential: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Double
    let scope: String
    let tokenType: String
    let expiresIn: Double

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case scope
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }

    init(
        accessToken: String,
        refreshToken: String,
        expiresAt: Double,
        scope: String,
        tokenType: String,
        expiresIn: Double
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.tokenType = tokenType
        self.expiresIn = expiresIn
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken) ?? ""
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken) ?? ""
        expiresAt = try container.decodeIfPresent(Double.self, forKey: .expiresAt) ?? 0
        scope = try container.decodeIfPresent(String.self, forKey: .scope) ?? ""
        tokenType = try container.decodeIfPresent(String.self, forKey: .tokenType) ?? "Bearer"
        expiresIn = try container.decodeIfPresent(Double.self, forKey: .expiresIn) ?? 0
    }

    var shouldRefresh: Bool {
        expiresAt > 0 && expiresAt - Date().timeIntervalSince1970 < max(300, expiresIn * 0.5)
    }
}
