import Foundation
import Observation

/// Generic CCS provider for kinds without a usable upstream usage endpoint.
///
/// Today this covers `gemini`, `antigravity`, `kimi`, and `vertex`. We can
/// still tell the user *which accounts are connected* and *when each was last
/// used* (from `~/.ccs/cliproxy/accounts.json`'s `lastUsedAt`), but we cannot
/// surface remaining quota / cost.
///
/// Throttling and per-account cooldown logic mirror `CCSClaudeProvider` so
/// behavior stays consistent across all CCS providers.
@MainActor
@Observable
public final class CCSConnectionProvider: @preconcurrency MultiAccountProvider, @unchecked Sendable {
    // MARK: - Identity

    public let id: String
    public let name: String
    public let cliCommand: String = "ccs"
    public var dashboardURL: URL? { URL(string: "https://github.com/kaitranntt/ccs") }
    public var statusPageURL: URL? { nil }

    public var isEnabled: Bool {
        didSet { settingsRepository.setEnabled(isEnabled, forProvider: id) }
    }

    // MARK: - State

    public private(set) var isSyncing: Bool = false
    public private(set) var snapshot: UsageSnapshot?
    public private(set) var lastError: Error?
    public private(set) var accounts: [ProviderAccount] = []
    public private(set) var accountSnapshots: [String: UsageSnapshot] = [:]
    public private(set) var accountErrors: [String: Error] = [:]
    public private(set) var activeAccount: ProviderAccount

    // MARK: - Throttling

    /// Same minimum interval contract as the Claude/Codex CCS providers, even
    /// though our "probe" only reads local files: keeps refresh button mashing
    /// from churning observable state needlessly.
    public static let minRefreshInterval: TimeInterval = 30
    public private(set) var nextEligibleProbeAt: [String: Date] = [:]

    // MARK: - Dependencies

    public typealias AccountSource = @Sendable () -> [CCSAccount]
    public typealias TokenSource = @Sendable (CCSAccount) -> CCSToken?

    private let providerKind: CCSAccount.Provider
    private let accountSource: AccountSource
    private let tokenSource: TokenSource
    private let settingsRepository: any ProviderSettingsRepository

    // MARK: - Initialization

    /// - Parameters:
    ///   - providerKind: Which CCS provider this instance speaks for.
    ///   - id: Stable provider identifier (`ccs-gemini`, `ccs-kimi`, ...).
    ///   - name: Display label.
    ///   - accountSource: Returns the current list of CCS accounts for this kind.
    ///   - tokenSource: Loads the token file for an account (used to detect
    ///     "connected but expired" vs "connected and live").
    ///   - settingsRepository: For persisting `isEnabled`.
    public init(
        providerKind: CCSAccount.Provider,
        id: String,
        name: String,
        accountSource: @escaping AccountSource,
        tokenSource: @escaping TokenSource,
        settingsRepository: any ProviderSettingsRepository
    ) {
        self.providerKind = providerKind
        self.id = id
        self.name = name
        self.accountSource = accountSource
        self.tokenSource = tokenSource
        self.settingsRepository = settingsRepository
        // Default OFF for connection-only providers so first-run users don't
        // see a wall of empty cards.
        self.isEnabled = settingsRepository.isEnabled(forProvider: id, defaultValue: false)
        self.activeAccount = ProviderAccount(providerId: id, label: "No CCS accounts")
        rebuildAccounts()
    }

    // MARK: - AIProvider Protocol

    public func isAvailable() async -> Bool {
        rebuildAccounts()
        return !accounts.isEmpty
    }

    @discardableResult
    public func refresh() async throws -> UsageSnapshot {
        await refreshAllAccounts()
        return snapshot ?? UsageSnapshot.empty(for: id)
    }

    /// Test-only hook (mirrors the Claude/Codex providers).
    public func simulateCooldownExpired(for accountId: String) {
        nextEligibleProbeAt[accountId] = Date(timeIntervalSince1970: 0)
    }

    // MARK: - MultiAccountProvider Protocol

    @discardableResult
    public func switchAccount(to accountId: String) -> Bool {
        guard let match = accounts.first(where: { $0.accountId == accountId }) else {
            return false
        }
        activeAccount = match
        snapshot = accountSnapshots[match.accountId]
        lastError = accountErrors[match.accountId]
        return true
    }

    @discardableResult
    public func refreshAccount(_ accountId: String) async throws -> UsageSnapshot {
        rebuildAccounts()
        guard let providerAccount = accounts.first(where: { $0.accountId == accountId }),
              let ccsAccount = ccsAccountsByEmail[accountId] else {
            throw ProbeError.noData
        }
        if !isEligible(accountId), let cached = accountSnapshots[accountId] {
            return cached
        }
        let result = makeSnapshot(for: ccsAccount)
        accountSnapshots[accountId] = result
        accountErrors.removeValue(forKey: accountId)
        nextEligibleProbeAt[accountId] = Date().addingTimeInterval(Self.minRefreshInterval)
        if providerAccount.accountId == activeAccount.accountId {
            snapshot = result
            lastError = nil
        }
        return result
    }

    public func refreshAllAccounts() async {
        rebuildAccounts()
        guard !accounts.isEmpty else {
            snapshot = nil
            lastError = nil
            return
        }
        isSyncing = true
        defer { isSyncing = false }

        let now = Date()
        for providerAccount in accounts {
            guard isEligible(providerAccount.accountId, now: now),
                  let ccsAccount = ccsAccountsByEmail[providerAccount.accountId] else { continue }
            let result = makeSnapshot(for: ccsAccount)
            accountSnapshots[providerAccount.accountId] = result
            accountErrors.removeValue(forKey: providerAccount.accountId)
            nextEligibleProbeAt[providerAccount.accountId] = now.addingTimeInterval(Self.minRefreshInterval)
        }

        snapshot = accountSnapshots[activeAccount.accountId]
        lastError = accountErrors[activeAccount.accountId]
    }

    // MARK: - Throttle helpers

    public func isEligible(_ accountId: String, now: Date = Date()) -> Bool {
        guard let nextOk = nextEligibleProbeAt[accountId] else { return true }
        return now >= nextOk
    }

    // MARK: - Snapshot construction

    /// Builds a placeholder `UsageSnapshot` carrying only "connected" metadata.
    /// We expose the CCS account email + a derived `loginMethod` string that
    /// includes the last-used date so the menu can render something useful
    /// even though we never call an upstream usage API.
    private func makeSnapshot(for account: CCSAccount) -> UsageSnapshot {
        let loginMethod: String
        if let last = account.lastUsedAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            loginMethod = "ccs · last used \(formatter.string(from: last))"
        } else {
            loginMethod = "ccs · never used"
        }
        let token = tokenSource(account)
        let tier: AccountTier? = {
            guard let token else { return nil }
            if token.disabled { return .custom("DISABLED") }
            if token.isExpired { return .custom("EXPIRED") }
            return .custom("CONNECTED")
        }()
        return UsageSnapshot(
            providerId: id,
            quotas: [],
            capturedAt: Date(),
            accountEmail: account.email,
            accountOrganization: nil,
            loginMethod: loginMethod,
            accountTier: tier,
            costUsage: nil
        )
    }

    // MARK: - Account list

    private var ccsAccountsByEmail: [String: CCSAccount] = [:]

    private func rebuildAccounts() {
        let raw = accountSource()
        var byEmail: [String: CCSAccount] = [:]
        let providerAccounts = raw.map { ccs -> ProviderAccount in
            byEmail[ccs.email] = ccs
            return ProviderAccount(
                accountId: ccs.email,
                providerId: id,
                label: ccs.displayLabel + (ccs.paused ? " (paused)" : ""),
                email: ccs.email,
                organization: nil
            )
        }
        ccsAccountsByEmail = byEmail
        if providerAccounts.isEmpty {
            accounts = []
            activeAccount = ProviderAccount(providerId: id, label: "No CCS accounts")
            accountSnapshots = [:]
            accountErrors = [:]
            return
        }
        accounts = providerAccounts
        if let existing = providerAccounts.first(where: { $0.accountId == activeAccount.accountId }) {
            activeAccount = existing
        } else if let preferred = raw.first(where: { $0.isDefault && !$0.paused }),
                  let match = providerAccounts.first(where: { $0.accountId == preferred.email }) {
            activeAccount = match
        } else if let firstActive = raw.first(where: { !$0.paused }),
                  let match = providerAccounts.first(where: { $0.accountId == firstActive.email }) {
            activeAccount = match
        } else if let first = providerAccounts.first {
            activeAccount = first
        }
    }
}
