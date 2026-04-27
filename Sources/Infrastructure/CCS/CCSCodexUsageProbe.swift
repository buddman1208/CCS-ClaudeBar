import Foundation
import Domain

/// Fetches Codex (ChatGPT backend) usage data for a single CCS-managed account.
///
/// Mirrors `CodexAPIUsageProbe`'s parsing of `/backend-api/wham/usage` but reads
/// the bearer token + account id from a `CCSToken` instead of `~/.codex/auth.json`.
/// Token refresh remains the responsibility of CCS.
public struct CCSCodexUsageProbe: Sendable {
    private let networkClient: any NetworkClient
    private let timeout: TimeInterval

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public init(
        networkClient: any NetworkClient = URLSession.shared,
        timeout: TimeInterval = 15
    ) {
        self.networkClient = networkClient
        self.timeout = timeout
    }

    public func probe(token: CCSToken, account: CCSAccount) async throws -> UsageSnapshot {
        if token.disabled {
            throw ProbeError.sessionExpired(hint: "Re-enable this account via `ccs auth resume \(account.email)`.")
        }
        if token.isExpired {
            throw ProbeError.sessionExpired(hint: "Run `ccs auth refresh \(account.email)` (or any CCS command) to refresh.")
        }

        let (data, http) = try await fetchUsage(token: token)
        return try parse(data: data, httpResponse: http, account: account)
    }

    // MARK: - HTTP

    private func fetchUsage(token: CCSToken) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeBar-CCS", forHTTPHeaderField: "User-Agent")
        if let accountId = token.accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.timeoutInterval = timeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await networkClient.request(request)
        } catch {
            AppLog.probes.error("CCS Codex API: Network error: \(error.localizedDescription)")
            throw ProbeError.executionFailed("Network error: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProbeError.executionFailed("Invalid response")
        }

        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw ProbeError.sessionExpired(hint: "Token rejected by ChatGPT — run `ccs auth login` to refresh.")
        case 429:
            let retryAfter = Self.parseRetryAfter(http) ?? 60
            AppLog.probes.warning("CCS Codex API: HTTP 429 (retry in \(Int(retryAfter))s)")
            throw ProbeError.rateLimited(retryAfter: retryAfter)
        default:
            AppLog.probes.error("CCS Codex API: HTTP \(http.statusCode)")
            throw ProbeError.executionFailed("HTTP error: \(http.statusCode)")
        }

        return (data, http)
    }

    // MARK: - Parsing

    private func parse(data: Data, httpResponse: HTTPURLResponse, account: CCSAccount) throws -> UsageSnapshot {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProbeError.parseFailed("Failed to parse usage response as JSON")
        }

        var quotas: [UsageQuota] = []
        let now = Date().timeIntervalSince1970
        let rateLimit = dict["rate_limit"] as? [String: Any]
        let primary = rateLimit?["primary_window"] as? [String: Any]
        let secondary = rateLimit?["secondary_window"] as? [String: Any]

        let headerPrimary = Self.headerDouble(httpResponse, "x-codex-primary-used-percent")
        let headerSecondary = Self.headerDouble(httpResponse, "x-codex-secondary-used-percent")

        if let used = headerPrimary {
            quotas.append(Self.makeQuota(used: used, type: .session, window: primary, now: now))
        } else if let used = primary?["used_percent"] as? Double {
            quotas.append(Self.makeQuota(used: used, type: .session, window: primary, now: now))
        }
        if let used = headerSecondary {
            quotas.append(Self.makeQuota(used: used, type: .weekly, window: secondary, now: now))
        } else if let used = secondary?["used_percent"] as? Double {
            quotas.append(Self.makeQuota(used: used, type: .weekly, window: secondary, now: now))
        }

        var costUsage: CostUsage?
        let creditsHeader = Self.headerDouble(httpResponse, "x-codex-credits-balance")
        let creditsBody = (dict["credits"] as? [String: Any])?["balance"] as? Double
        if let remaining = creditsHeader ?? creditsBody {
            let limit: Decimal = 1000
            let used = max(0, min(limit, limit - Decimal(remaining)))
            costUsage = CostUsage(
                totalCost: used,
                budget: limit,
                apiDuration: 0,
                providerId: "ccs-codex",
                capturedAt: Date(),
                resetsAt: nil,
                resetText: nil
            )
        }

        var tier: AccountTier?
        if let planType = dict["plan_type"] as? String, !planType.isEmpty {
            tier = .custom(planType.uppercased())
        }

        return UsageSnapshot(
            providerId: "ccs-codex",
            quotas: quotas,
            capturedAt: Date(),
            accountEmail: account.email,
            accountOrganization: nil,
            loginMethod: "ccs",
            accountTier: tier,
            costUsage: costUsage
        )
    }

    // MARK: - Helpers

    private static func makeQuota(
        used: Double,
        type: QuotaType,
        window: [String: Any]?,
        now: TimeInterval
    ) -> UsageQuota {
        let resetsAt = resetsAtDate(window: window, now: now)
        return UsageQuota(
            percentRemaining: max(0, 100 - used),
            quotaType: type,
            providerId: "ccs-codex",
            resetsAt: resetsAt,
            resetText: formatResetText(resetsAt)
        )
    }

    private static func headerDouble(_ response: HTTPURLResponse, _ key: String) -> Double? {
        guard let raw = response.value(forHTTPHeaderField: key), let value = Double(raw), value.isFinite else { return nil }
        return value
    }

    private static func resetsAtDate(window: [String: Any]?, now: TimeInterval) -> Date? {
        guard let window else { return nil }
        if let resetAt = window["reset_at"] as? Double {
            return Date(timeIntervalSince1970: resetAt)
        }
        if let after = window["reset_after_seconds"] as? Double {
            return Date(timeIntervalSince1970: now + after)
        }
        return nil
    }

    /// See `CCSClaudeUsageProbe.parseRetryAfter` — same contract.
    static func parseRetryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(raw), seconds.isFinite, seconds >= 0 {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        if let date = formatter.date(from: raw) {
            return max(0, date.timeIntervalSinceNow)
        }
        return nil
    }

    private static func formatResetText(_ date: Date?) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return nil }
        let hours = Int(seconds / 3600)
        let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        if hours > 0 { return "Resets in \(hours)h \(minutes)m" }
        if minutes > 0 { return "Resets in \(minutes)m" }
        return "Resets soon"
    }
}
