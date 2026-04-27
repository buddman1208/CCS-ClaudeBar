import Foundation
import Domain

/// Fetches Claude OAuth usage data for a single CCS-managed account.
///
/// Unlike `ClaudeAPIUsageProbe` this probe does NOT manage a credential file or
/// attempt token refresh — CCS owns that lifecycle. We just take the bearer
/// token CCS already issued (via `~/.ccs/cliproxy/auth/...`) and call
/// `https://api.anthropic.com/api/oauth/usage` directly.
///
/// On 401/403 we surface `ProbeError.sessionExpired` with a hint pointing to
/// `ccs auth` so the user knows to re-authenticate via CCS rather than via the
/// Claude CLI.
public struct CCSClaudeUsageProbe: Sendable {
    private let networkClient: any NetworkClient
    private let timeout: TimeInterval

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public init(
        networkClient: any NetworkClient = URLSession.shared,
        timeout: TimeInterval = 15
    ) {
        self.networkClient = networkClient
        self.timeout = timeout
    }

    /// Fetches the usage snapshot for a specific token. The caller is
    /// responsible for providing a valid Claude OAuth token from CCS.
    public func probe(token: CCSToken, account: CCSAccount) async throws -> UsageSnapshot {
        if token.disabled {
            throw ProbeError.sessionExpired(hint: "Re-enable this account via `ccs auth resume \(account.email)`.")
        }
        if token.isExpired {
            throw ProbeError.sessionExpired(hint: "Run `ccs auth refresh \(account.email)` (or any CCS command) to refresh.")
        }

        let response = try await fetchUsage(accessToken: token.accessToken)
        return parse(response: response, account: account)
    }

    // MARK: - HTTP

    private func fetchUsage(accessToken: String) async throws -> UsageResponse {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("ClaudeBar-CCS", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await networkClient.request(request)
        } catch {
            AppLog.probes.error("CCS Claude API: Network error: \(error.localizedDescription)")
            throw ProbeError.executionFailed("Network error: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProbeError.executionFailed("Invalid response")
        }

        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw ProbeError.sessionExpired(hint: "Token rejected by Anthropic — run `ccs auth login` to refresh.")
        default:
            AppLog.probes.error("CCS Claude API: HTTP \(http.statusCode)")
            throw ProbeError.executionFailed("HTTP error: \(http.statusCode)")
        }

        do {
            return try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            throw ProbeError.parseFailed("Failed to parse usage response: \(error.localizedDescription)")
        }
    }

    // MARK: - Parsing

    private func parse(response: UsageResponse, account: CCSAccount) -> UsageSnapshot {
        var quotas: [UsageQuota] = []

        if let fiveHour = response.fiveHour, let utilization = fiveHour.utilization {
            let resetsAt = Self.parseISO(fiveHour.resetsAt)
            quotas.append(UsageQuota(
                percentRemaining: max(0, 100 - utilization),
                quotaType: .session,
                providerId: "ccs-claude",
                resetsAt: resetsAt,
                resetText: Self.formatResetText(resetsAt)
            ))
        }
        if let sevenDay = response.sevenDay, let utilization = sevenDay.utilization {
            let resetsAt = Self.parseISO(sevenDay.resetsAt)
            quotas.append(UsageQuota(
                percentRemaining: max(0, 100 - utilization),
                quotaType: .weekly,
                providerId: "ccs-claude",
                resetsAt: resetsAt,
                resetText: Self.formatResetText(resetsAt)
            ))
        }
        if let sonnet = response.sevenDaySonnet, let utilization = sonnet.utilization {
            let resetsAt = Self.parseISO(sonnet.resetsAt)
            quotas.append(UsageQuota(
                percentRemaining: max(0, 100 - utilization),
                quotaType: .modelSpecific("sonnet"),
                providerId: "ccs-claude",
                resetsAt: resetsAt,
                resetText: Self.formatResetText(resetsAt)
            ))
        }
        if let opus = response.sevenDayOpus, let utilization = opus.utilization {
            let resetsAt = Self.parseISO(opus.resetsAt)
            quotas.append(UsageQuota(
                percentRemaining: max(0, 100 - utilization),
                quotaType: .modelSpecific("opus"),
                providerId: "ccs-claude",
                resetsAt: resetsAt,
                resetText: Self.formatResetText(resetsAt)
            ))
        }

        var costUsage: CostUsage?
        if let extra = response.extraUsage, extra.isEnabled == true, let used = extra.usedCredits {
            costUsage = CostUsage(
                totalCost: Decimal(used) / 100,
                budget: extra.monthlyLimit.map { Decimal($0) / 100 },
                apiDuration: 0,
                providerId: "ccs-claude",
                capturedAt: Date(),
                resetsAt: nil,
                resetText: nil
            )
        }

        return UsageSnapshot(
            providerId: "ccs-claude",
            quotas: quotas,
            capturedAt: Date(),
            accountEmail: account.email,
            accountOrganization: nil,
            loginMethod: "ccs",
            accountTier: nil,
            costUsage: costUsage
        )
    }

    private static func parseISO(_ string: String?) -> Date? {
        guard let string else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: string) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
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

    // MARK: - Response models (mirror Anthropic's OAuth /usage payload)

    private struct UsageResponse: Decodable {
        let fiveHour: UsageQuotaData?
        let sevenDay: UsageQuotaData?
        let sevenDaySonnet: UsageQuotaData?
        let sevenDayOpus: UsageQuotaData?
        let extraUsage: ExtraUsageData?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case sevenDaySonnet = "seven_day_sonnet"
            case sevenDayOpus = "seven_day_opus"
            case extraUsage = "extra_usage"
        }
    }

    private struct UsageQuotaData: Decodable {
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    private struct ExtraUsageData: Decodable {
        let isEnabled: Bool?
        let usedCredits: Double?
        let monthlyLimit: Double?

        enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled"
            case usedCredits = "used_credits"
            case monthlyLimit = "monthly_limit"
        }
    }
}
