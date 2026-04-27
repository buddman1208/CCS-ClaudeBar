import Testing
import Foundation
@testable import Domain

@Suite("CCSCodexProvider Tests")
struct CCSCodexProviderTests {

    private final class InMemorySettings: ProviderSettingsRepository, @unchecked Sendable {
        private var enabled: [String: Bool] = [:]
        private var customURLs: [String: String] = [:]
        func isEnabled(forProvider id: String) -> Bool { enabled[id] ?? true }
        func isEnabled(forProvider id: String, defaultValue: Bool) -> Bool { enabled[id] ?? defaultValue }
        func setEnabled(_ value: Bool, forProvider id: String) { enabled[id] = value }
        func customCardURL(forProvider id: String) -> String? { customURLs[id] }
        func setCustomCardURL(_ url: String?, forProvider id: String) { customURLs[id] = url }
    }

    private func makeAccount(_ email: String, isDefault: Bool = false) -> CCSAccount {
        CCSAccount(
            provider: .codex,
            email: email,
            nickname: email,
            tokenFile: "codex-\(email)-pro.json",
            isDefault: isDefault
        )
    }

    private func makeToken(_ email: String) -> CCSToken {
        CCSToken(
            kind: .codex,
            accessToken: "jwt-\(email)",
            accountId: "acct_\(email)",
            expiresAt: Date().addingTimeInterval(3600)
        )
    }

    private func snapshot(for email: String, percent: Double) -> UsageSnapshot {
        UsageSnapshot(
            providerId: "ccs-codex",
            quotas: [UsageQuota(
                percentRemaining: percent,
                quotaType: .session,
                providerId: "ccs-codex"
            )],
            capturedAt: Date(),
            accountEmail: email
        )
    }

    @Test
    func `provider exposes accounts and respects default`() {
        let provider = CCSCodexProvider(
            accountSource: { [self.makeAccount("a@x"), self.makeAccount("b@x", isDefault: true)] },
            tokenSource: { _ in nil },
            fetchUsage: { _, _ in throw ProbeError.noData },
            settingsRepository: InMemorySettings()
        )

        #expect(provider.accounts.count == 2)
        #expect(provider.activeAccount.accountId == "b@x")
    }

    @Test
    func `refreshAllAccounts populates snapshots concurrently`() async {
        let accounts = [self.makeAccount("a@x", isDefault: true), self.makeAccount("b@x")]
        let provider = CCSCodexProvider(
            accountSource: { accounts },
            tokenSource: { account in self.makeToken(account.email) },
            fetchUsage: { _, account in self.snapshot(for: account.email, percent: account.email == "a@x" ? 70 : 40) },
            settingsRepository: InMemorySettings()
        )

        await provider.refreshAllAccounts()

        #expect(provider.accountSnapshots.count == 2)
        #expect(provider.accountSnapshots["a@x"]?.quotas.first?.percentRemaining == 70)
        #expect(provider.accountSnapshots["b@x"]?.quotas.first?.percentRemaining == 40)
        #expect(provider.snapshot?.quotas.first?.percentRemaining == 70)
    }

    @Test
    func `switchAccount syncs snapshot and lastError together`() async {
        let accounts = [self.makeAccount("a@x", isDefault: true), self.makeAccount("b@x")]
        let provider = CCSCodexProvider(
            accountSource: { accounts },
            tokenSource: { account in self.makeToken(account.email) },
            fetchUsage: { _, account in
                if account.email == "b@x" { throw ProbeError.sessionExpired(hint: "test") }
                return self.snapshot(for: account.email, percent: 80)
            },
            settingsRepository: InMemorySettings()
        )
        await provider.refreshAllAccounts()

        // Initially: active is a@x with snapshot present, no error
        #expect(provider.snapshot != nil)
        #expect(provider.lastError == nil)

        // Switch to failing account: snapshot should clear, lastError should populate
        let switched = provider.switchAccount(to: "b@x")
        #expect(switched == true)
        #expect(provider.snapshot == nil)
        #expect(provider.lastError != nil)
    }

    @Test
    func `refreshAllAccounts clears stale snapshot when active account fails`() async {
        let flag = MutableFlag()
        let accounts = [self.makeAccount("a@x", isDefault: true)]
        let provider = CCSCodexProvider(
            accountSource: { accounts },
            tokenSource: { account in self.makeToken(account.email) },
            fetchUsage: { _, account in
                if flag.value { throw ProbeError.sessionExpired(hint: "expired") }
                return self.snapshot(for: account.email, percent: 90)
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

    @Test
    func `setting isEnabled persists`() {
        let settings = InMemorySettings()
        let provider = CCSCodexProvider(
            accountSource: { [] },
            tokenSource: { _ in nil },
            fetchUsage: { _, _ in throw ProbeError.noData },
            settingsRepository: settings
        )
        provider.isEnabled = false
        #expect(settings.isEnabled(forProvider: "ccs-codex") == false)
    }
}

private final class MutableFlag: @unchecked Sendable {
    var value: Bool = false
}
