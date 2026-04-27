import Testing
import Foundation
@testable import Domain

@Suite("CCSClaudeProvider Tests")
struct CCSClaudeProviderTests {

    // MARK: - In-memory settings repo (state verification, not method calls)

    private final class InMemorySettings: ProviderSettingsRepository, @unchecked Sendable {
        private var enabled: [String: Bool] = [:]
        private var customURLs: [String: String] = [:]
        func isEnabled(forProvider id: String) -> Bool { enabled[id] ?? true }
        func isEnabled(forProvider id: String, defaultValue: Bool) -> Bool { enabled[id] ?? defaultValue }
        func setEnabled(_ value: Bool, forProvider id: String) { enabled[id] = value }
        func customCardURL(forProvider id: String) -> String? { customURLs[id] }
        func setCustomCardURL(_ url: String?, forProvider id: String) { customURLs[id] = url }
    }

    // MARK: - Helpers

    private func makeAccount(_ email: String, paused: Bool = false, isDefault: Bool = false) -> CCSAccount {
        CCSAccount(
            provider: .claude,
            email: email,
            nickname: email,
            tokenFile: "claude-\(email).json",
            paused: paused,
            isDefault: isDefault
        )
    }

    private func makeToken(_ email: String) -> CCSToken {
        CCSToken(
            kind: .claude,
            accessToken: "token-\(email)",
            refreshToken: nil,
            email: email,
            accountId: nil,
            expiresAt: Date().addingTimeInterval(3600),
            disabled: false
        )
    }

    private func snapshot(for email: String, percentRemaining: Double) -> UsageSnapshot {
        UsageSnapshot(
            providerId: "ccs-claude",
            quotas: [UsageQuota(
                percentRemaining: percentRemaining,
                quotaType: .session,
                providerId: "ccs-claude"
            )],
            capturedAt: Date(),
            accountEmail: email
        )
    }

    // MARK: - Account discovery

    @Test
    func `provider exposes accounts from source`() {
        let provider = CCSClaudeProvider(
            accountSource: { [self.makeAccount("a@x", isDefault: true), self.makeAccount("b@x")] },
            tokenSource: { _ in nil },
            fetchUsage: { _, _ in throw ProbeError.noData },
            settingsRepository: InMemorySettings()
        )

        #expect(provider.accounts.count == 2)
        #expect(provider.activeAccount.accountId == "a@x") // default first
    }

    @Test
    func `provider with no accounts is unavailable`() async {
        let provider = CCSClaudeProvider(
            accountSource: { [] },
            tokenSource: { _ in nil },
            fetchUsage: { _, _ in throw ProbeError.noData },
            settingsRepository: InMemorySettings()
        )

        let available = await provider.isAvailable()
        #expect(available == false)
        #expect(provider.accounts.isEmpty)
    }

    // MARK: - refreshAllAccounts

    @Test
    func `refreshAllAccounts populates snapshots for every account`() async {
        let accounts = [self.makeAccount("a@x", isDefault: true), self.makeAccount("b@x")]
        let provider = CCSClaudeProvider(
            accountSource: { accounts },
            tokenSource: { account in self.makeToken(account.email) },
            fetchUsage: { _, account in self.snapshot(for: account.email, percentRemaining: account.email == "a@x" ? 80 : 50) },
            settingsRepository: InMemorySettings()
        )

        await provider.refreshAllAccounts()

        #expect(provider.accountSnapshots.count == 2)
        #expect(provider.accountSnapshots["a@x"]?.quotas.first?.percentRemaining == 80)
        #expect(provider.accountSnapshots["b@x"]?.quotas.first?.percentRemaining == 50)
        // Active account snapshot exposed via top-level snapshot property
        #expect(provider.snapshot?.quotas.first?.percentRemaining == 80)
    }

    @Test
    func `refreshAllAccounts records errors per account without throwing`() async {
        let accounts = [self.makeAccount("a@x", isDefault: true), self.makeAccount("b@x")]
        let provider = CCSClaudeProvider(
            accountSource: { accounts },
            tokenSource: { account in self.makeToken(account.email) },
            fetchUsage: { _, account in
                if account.email == "b@x" {
                    throw ProbeError.sessionExpired(hint: "test")
                }
                return self.snapshot(for: account.email, percentRemaining: 90)
            },
            settingsRepository: InMemorySettings()
        )

        await provider.refreshAllAccounts()

        #expect(provider.accountSnapshots["a@x"] != nil)
        #expect(provider.accountErrors["b@x"] != nil)
    }

    @Test
    func `refreshAllAccounts surfaces auth error when token missing`() async {
        let accounts = [self.makeAccount("a@x", isDefault: true)]
        let provider = CCSClaudeProvider(
            accountSource: { accounts },
            tokenSource: { _ in nil },
            fetchUsage: { _, _ in self.snapshot(for: "a@x", percentRemaining: 90) },
            settingsRepository: InMemorySettings()
        )

        await provider.refreshAllAccounts()

        #expect(provider.accountErrors["a@x"] is ProbeError)
    }

    // MARK: - switchAccount

    @Test
    func `switchAccount changes active account and updates exposed snapshot`() async {
        let accounts = [self.makeAccount("a@x", isDefault: true), self.makeAccount("b@x")]
        let provider = CCSClaudeProvider(
            accountSource: { accounts },
            tokenSource: { account in self.makeToken(account.email) },
            fetchUsage: { _, account in self.snapshot(for: account.email, percentRemaining: account.email == "a@x" ? 80 : 30) },
            settingsRepository: InMemorySettings()
        )
        await provider.refreshAllAccounts()

        let switched = provider.switchAccount(to: "b@x")

        #expect(switched == true)
        #expect(provider.activeAccount.accountId == "b@x")
        #expect(provider.snapshot?.quotas.first?.percentRemaining == 30)
    }

    @Test
    func `switchAccount returns false for unknown account`() {
        let provider = CCSClaudeProvider(
            accountSource: { [] },
            tokenSource: { _ in nil },
            fetchUsage: { _, _ in throw ProbeError.noData },
            settingsRepository: InMemorySettings()
        )

        #expect(provider.switchAccount(to: "ghost@x") == false)
    }

    @Test
    func `switchAccount syncs lastError when target account has error`() async {
        let accounts = [self.makeAccount("a@x", isDefault: true), self.makeAccount("b@x")]
        let provider = CCSClaudeProvider(
            accountSource: { accounts },
            tokenSource: { account in self.makeToken(account.email) },
            fetchUsage: { _, account in
                if account.email == "b@x" { throw ProbeError.sessionExpired(hint: "test") }
                return self.snapshot(for: account.email, percentRemaining: 80)
            },
            settingsRepository: InMemorySettings()
        )
        await provider.refreshAllAccounts()

        #expect(provider.snapshot != nil)
        #expect(provider.lastError == nil)

        provider.switchAccount(to: "b@x")

        // After switching to a failed account: snapshot should be nil, lastError populated
        #expect(provider.snapshot == nil)
        #expect(provider.lastError != nil)
    }

    @Test
    func `refreshAllAccounts clears stale snapshot when active account starts failing`() async {
        let accounts = [self.makeAccount("a@x", isDefault: true)]
        let flag = MutableFlag()
        let provider = CCSClaudeProvider(
            accountSource: { accounts },
            tokenSource: { account in self.makeToken(account.email) },
            fetchUsage: { _, account in
                if flag.value { throw ProbeError.sessionExpired(hint: "expired") }
                return self.snapshot(for: account.email, percentRemaining: 90)
            },
            settingsRepository: InMemorySettings()
        )

        await provider.refreshAllAccounts()
        #expect(provider.snapshot != nil)

        flag.value = true
        await provider.refreshAllAccounts()

        #expect(provider.snapshot == nil)
        #expect(provider.lastError != nil)
    }

    // MARK: - isEnabled persistence

    @Test
    func `setting isEnabled persists via repository`() {
        let settings = InMemorySettings()
        let provider = CCSClaudeProvider(
            accountSource: { [] },
            tokenSource: { _ in nil },
            fetchUsage: { _, _ in throw ProbeError.noData },
            settingsRepository: settings
        )

        provider.isEnabled = false

        #expect(settings.isEnabled(forProvider: "ccs-claude") == false)
    }
}

/// Tiny mutable cell so test closures can flip behavior without capturing
/// a `var`, which Swift 6 strict concurrency rejects.
private final class MutableFlag: @unchecked Sendable {
    var value: Bool = false
}
