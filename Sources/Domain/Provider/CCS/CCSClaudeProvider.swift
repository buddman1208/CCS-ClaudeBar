import Foundation
import Observation

/// Multi-account Claude provider backed by CCS (`~/.ccs/cliproxy`).
///
/// Each CCS-managed Claude account is exposed as a separate `ProviderAccount`.
/// Snapshots are fetched concurrently so the menu reflects every account
/// without serialising network calls.
///
/// We intentionally re-discover accounts on every refresh: CCS users add/remove
/// accounts via the `ccs auth` CLI while ClaudeBar is running, and we want
/// those changes to surface without a restart.
@Observable
public final class CCSClaudeProvider: MultiAccountProvider, @unchecked Sendable {
    // MARK: - Identity

    public let id: String = "ccs-claude"
    public let name: String = "CCS Claude"
    public let cliCommand: String = "ccs"

    public var dashboardURL: URL? {
        URL(string: "https://github.com/kaitranntt/ccs")
    }

    public var statusPageURL: URL? {
        URL(string: "https://status.anthropic.com")
    }

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

    /// The currently active account. Defaults to the CCS "default" account
    /// when present; falls back to the first account discovered.
    public private(set) var activeAccount: ProviderAccount

    // MARK: - Throttling

    /// Minimum interval between successful upstream probes for the SAME
    /// account. Hammering Refresh inside this window returns the cached
    /// snapshot silently — no extra API calls, no UI noise.
    public static let minRefreshInterval: TimeInterval = 30

    /// `Date` after which each account becomes eligible for an upstream probe.
    /// Updated on success (now + minRefreshInterval) and on 429 (now + retryAfter).
    /// Reads/writes are serialized via the provider's main-actor reentrancy:
    /// `refreshAllAccounts` reads BEFORE the task group, applies AFTER — the
    /// task group itself never mutates this dictionary.
    public private(set) var nextEligibleProbeAt: [String: Date] = [:]

    // MARK: - Dependencies

    /// Loader used to discover accounts and read OAuth tokens. Injected so
    /// tests can point at a fixture directory.
    public typealias AccountSource = @Sendable () -> [CCSAccount]
    public typealias TokenSource = @Sendable (CCSAccount) -> CCSToken?
    public typealias UsageFetcher = @Sendable (CCSToken, CCSAccount) async throws -> UsageSnapshot

    private let accountSource: AccountSource
    private let tokenSource: TokenSource
    private let fetchUsage: UsageFetcher
    private let settingsRepository: any ProviderSettingsRepository

    // MARK: - Initialization

    /// Test-friendly initializer with explicit dependencies.
    public init(
        accountSource: @escaping AccountSource,
        tokenSource: @escaping TokenSource,
        fetchUsage: @escaping UsageFetcher,
        settingsRepository: any ProviderSettingsRepository
    ) {
        self.accountSource = accountSource
        self.tokenSource = tokenSource
        self.fetchUsage = fetchUsage
        self.settingsRepository = settingsRepository
        self.isEnabled = settingsRepository.isEnabled(forProvider: "ccs-claude")

        let placeholder = ProviderAccount(
            providerId: "ccs-claude",
            label: "No CCS accounts"
        )
        self.activeAccount = placeholder
        rebuildAccounts()
    }

    // MARK: - AIProvider Protocol

    public func isAvailable() async -> Bool {
        rebuildAccounts()
        return !accounts.isEmpty
    }

    /// Test-only hook: forces the per-account throttle window to be expired.
    /// Production code paths NEVER call this; only the test suite uses it to
    /// simulate "the cooldown elapsed" without actually sleeping for 30s.
    public func simulateCooldownExpired(for accountId: String) {
        nextEligibleProbeAt[accountId] = Date(timeIntervalSince1970: 0)
    }

    @discardableResult
    public func refresh() async throws -> UsageSnapshot {
        await refreshAllAccounts()
        if let snapshot {
            return snapshot
        }
        if let error = lastError {
            throw error
        }
        return UsageSnapshot.empty(for: id)
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
        await MainActor.run { rebuildAccounts() }
        guard let providerAccount = accounts.first(where: { $0.accountId == accountId }),
              let ccsAccount = ccsAccountsByEmail[accountId] else {
            throw ProbeError.noData
        }
        if !isEligible(accountId) {
            if let cached = accountSnapshots[accountId] {
                return cached
            }
            throw ProbeError.noData
        }
        guard let token = tokenSource(ccsAccount) else {
            let error = ProbeError.authenticationRequired
            await MainActor.run { accountErrors[accountId] = error }
            throw error
        }
        do {
            let result = try await fetchUsage(token, ccsAccount)
            await MainActor.run {
                accountSnapshots[accountId] = result
                accountErrors.removeValue(forKey: accountId)
                nextEligibleProbeAt[accountId] = Date().addingTimeInterval(Self.minRefreshInterval)
                if providerAccount.accountId == activeAccount.accountId {
                    snapshot = result
                    lastError = nil
                }
            }
            return result
        } catch let error as ProbeError {
            await MainActor.run {
                applyErrorCooldown(error, for: accountId)
                accountErrors[accountId] = error
                if providerAccount.accountId == activeAccount.accountId {
                    snapshot = accountSnapshots[accountId]
                    lastError = error
                }
            }
            throw error
        } catch {
            await MainActor.run {
                nextEligibleProbeAt[accountId] = Date().addingTimeInterval(Self.minRefreshInterval)
                accountErrors[accountId] = error
                if providerAccount.accountId == activeAccount.accountId {
                    snapshot = accountSnapshots[accountId]
                    lastError = error
                }
            }
            throw error
        }
    }

    public func refreshAllAccounts() async {
        await MainActor.run { rebuildAccounts() }
        guard !accounts.isEmpty else {
            await MainActor.run {
                snapshot = nil
                lastError = nil
            }
            return
        }

        await MainActor.run { isSyncing = true }
        defer { Task { @MainActor in self.isSyncing = false } }

        // Resolve the work items synchronously so the actor-isolated state
        // never leaks into a Sendable closure. Skip accounts whose cooldown
        // hasn't elapsed — they keep their existing snapshot/error.
        let work: [(ProviderAccount, CCSAccount)] = accounts.compactMap { providerAccount in
            guard isEligible(providerAccount.accountId),
                  let ccsAccount = ccsAccountsByEmail[providerAccount.accountId] else { return nil }
            return (providerAccount, ccsAccount)
        }

        // No work to do: leave snapshots/errors untouched, just resync the
        // active provider's exposed snapshot from the cache.
        guard !work.isEmpty else {
            snapshot = accountSnapshots[activeAccount.accountId]
            lastError = accountErrors[activeAccount.accountId]
            return
        }

        let fetcher = self.fetchUsage
        let tokenLookup = self.tokenSource

        // Result<UsageSnapshot, ProbeError> is Sendable because both ends are.
        let results = await withTaskGroup(of: (String, Result<UsageSnapshot, ProbeError>).self) { group in
            for (providerAccount, ccsAccount) in work {
                group.addTask {
                    guard let token = tokenLookup(ccsAccount) else {
                        return (providerAccount.accountId, .failure(ProbeError.authenticationRequired))
                    }
                    do {
                        let snapshot = try await fetcher(token, ccsAccount)
                        return (providerAccount.accountId, .success(snapshot))
                    } catch let error as ProbeError {
                        return (providerAccount.accountId, .failure(error))
                    } catch {
                        return (providerAccount.accountId, .failure(.executionFailed(error.localizedDescription)))
                    }
                }
            }
            var collected: [(String, Result<UsageSnapshot, ProbeError>)] = []
            for await item in group {
                collected.append(item)
            }
            return collected
        }

        // Merge results back into the per-account state. The mutation is
        // routed through MainActor.run so SwiftUI never observes a
        // half-written dictionary mid-render — a race that previously crashed
        // the app with EXC_BAD_ACCESS in Dictionary.subscript.getter.
        let now = Date()
        await MainActor.run {
            for (accountId, result) in results {
                switch result {
                case .success(let snapshot):
                    accountSnapshots[accountId] = snapshot
                    accountErrors.removeValue(forKey: accountId)
                    nextEligibleProbeAt[accountId] = now.addingTimeInterval(Self.minRefreshInterval)
                case .failure(let error):
                    accountErrors[accountId] = error
                    applyErrorCooldown(error, for: accountId, now: now)
                }
            }

            if let activeSnapshot = accountSnapshots[activeAccount.accountId] {
                snapshot = activeSnapshot
                lastError = accountErrors[activeAccount.accountId]
            } else if let activeError = accountErrors[activeAccount.accountId] {
                snapshot = nil
                lastError = activeError
            } else {
                snapshot = nil
                lastError = nil
            }
        }
    }

    // MARK: - Throttle helpers

    /// Whether an account is currently allowed to make an upstream call.
    public func isEligible(_ accountId: String, now: Date = Date()) -> Bool {
        guard let nextOk = nextEligibleProbeAt[accountId] else { return true }
        return now >= nextOk
    }

    /// Updates the per-account cooldown after a probe error. 429 honours the
    /// `Retry-After` window from the upstream; everything else falls back to
    /// the standard `minRefreshInterval` so we don't hammer a broken account.
    private func applyErrorCooldown(_ error: ProbeError, for accountId: String, now: Date = Date()) {
        switch error {
        case .rateLimited(let retryAfter):
            nextEligibleProbeAt[accountId] = now.addingTimeInterval(max(retryAfter, Self.minRefreshInterval))
        default:
            nextEligibleProbeAt[accountId] = now.addingTimeInterval(Self.minRefreshInterval)
        }
    }

    // MARK: - Internals

    private var ccsAccountsByEmail: [String: CCSAccount] = [:]

    /// Rebuilds the cached `accounts` list from the underlying source. Keeps
    /// the active account stable across reloads when possible.
    private func rebuildAccounts() {
        let raw = accountSource()
        var byEmail: [String: CCSAccount] = [:]
        let providerAccounts = raw.map { ccs -> ProviderAccount in
            byEmail[ccs.email] = ccs
            return ProviderAccount(
                accountId: ccs.email,
                providerId: "ccs-claude",
                label: ccs.displayLabel + (ccs.paused ? " (paused)" : ""),
                email: ccs.email,
                organization: nil
            )
        }
        ccsAccountsByEmail = byEmail
        if providerAccounts.isEmpty {
            accounts = []
            activeAccount = ProviderAccount(providerId: "ccs-claude", label: "No CCS accounts")
            accountSnapshots = [:]
            accountErrors = [:]
            return
        }
        accounts = providerAccounts

        // Preserve the existing active account if it still exists.
        if let existing = providerAccounts.first(where: { $0.accountId == activeAccount.accountId }) {
            activeAccount = existing
        } else if let preferred = raw.first(where: { $0.isDefault && !$0.paused }),
                  let match = providerAccounts.first(where: { $0.accountId == preferred.email }) {
            // Default account, but only if not paused (paused tokens live in auth-paused/).
            activeAccount = match
        } else if let firstActive = raw.first(where: { !$0.paused }),
                  let match = providerAccounts.first(where: { $0.accountId == firstActive.email }) {
            // First non-paused account.
            activeAccount = match
        } else if let first = providerAccounts.first {
            // All paused — still surface something so the user sees the list.
            activeAccount = first
        }
    }
}
