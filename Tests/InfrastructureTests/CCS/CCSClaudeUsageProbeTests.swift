import Testing
import Foundation
import Mockable
@testable import Infrastructure
@testable import Domain

@Suite("CCSClaudeUsageProbe Tests")
struct CCSClaudeUsageProbeTests {

    private func makeAccount(email: String = "user@example.com") -> CCSAccount {
        CCSAccount(
            provider: .claude,
            email: email,
            nickname: email,
            tokenFile: "claude-\(email).json"
        )
    }

    private func validToken() -> CCSToken {
        CCSToken(
            kind: .claude,
            accessToken: "sk-ant-oat01-token",
            refreshToken: "rfsh",
            email: "user@example.com",
            accountId: nil,
            expiresAt: Date().addingTimeInterval(3600),
            disabled: false
        )
    }

    private func okResponse(body: String) -> (Data, URLResponse) {
        let data = body.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }

    // MARK: - Successful parse

    @Test
    func `probe parses session and weekly quotas`() async throws {
        let mock = MockNetworkClient()
        let body = """
        {
          "five_hour": {"utilization": 25.5, "resets_at": "2099-01-15T10:00:00Z"},
          "seven_day": {"utilization": 60.0, "resets_at": "2099-01-22T10:00:00Z"}
        }
        """
        given(mock).request(.any).willReturn(okResponse(body: body))

        let probe = CCSClaudeUsageProbe(networkClient: mock)
        let snapshot = try await probe.probe(token: validToken(), account: makeAccount())

        #expect(snapshot.providerId == "ccs-claude")
        #expect(snapshot.accountEmail == "user@example.com")
        #expect(snapshot.quotas.count == 2)
        let session = snapshot.quotas.first { $0.quotaType == .session }
        #expect(session?.percentRemaining == 74.5)
        let weekly = snapshot.quotas.first { $0.quotaType == .weekly }
        #expect(weekly?.percentRemaining == 40.0)
    }

    @Test
    func `probe parses extra_usage cost`() async throws {
        let mock = MockNetworkClient()
        let body = """
        {
          "extra_usage": {"is_enabled": true, "used_credits": 250, "monthly_limit": 1000}
        }
        """
        given(mock).request(.any).willReturn(okResponse(body: body))

        let probe = CCSClaudeUsageProbe(networkClient: mock)
        let snapshot = try await probe.probe(token: validToken(), account: makeAccount())

        #expect(snapshot.costUsage != nil)
        #expect(snapshot.costUsage?.totalCost == Decimal(string: "2.50"))
        #expect(snapshot.costUsage?.budget == Decimal(string: "10"))
    }

    // MARK: - Auth handling

    @Test
    func `probe throws sessionExpired for expired token`() async {
        let mock = MockNetworkClient()
        let probe = CCSClaudeUsageProbe(networkClient: mock)

        let expiredToken = CCSToken(
            kind: .claude,
            accessToken: "x",
            refreshToken: nil,
            email: nil,
            accountId: nil,
            expiresAt: Date().addingTimeInterval(-60),
            disabled: false
        )

        await #expect(throws: ProbeError.self) {
            try await probe.probe(token: expiredToken, account: makeAccount())
        }
    }

    @Test
    func `probe throws sessionExpired on 401`() async {
        let mock = MockNetworkClient()
        let response = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com")!,
            statusCode: 401,
            httpVersion: nil,
            headerFields: nil
        )!
        given(mock).request(.any).willReturn((Data(), response))

        let probe = CCSClaudeUsageProbe(networkClient: mock)

        await #expect(throws: ProbeError.self) {
            try await probe.probe(token: validToken(), account: makeAccount())
        }
    }

    @Test
    func `probe throws sessionExpired for disabled token`() async {
        let mock = MockNetworkClient()
        let probe = CCSClaudeUsageProbe(networkClient: mock)

        let disabledToken = CCSToken(
            kind: .claude,
            accessToken: "x",
            refreshToken: nil,
            email: nil,
            accountId: nil,
            expiresAt: Date().addingTimeInterval(3600),
            disabled: true
        )

        await #expect(throws: ProbeError.self) {
            try await probe.probe(token: disabledToken, account: makeAccount())
        }
    }
}
