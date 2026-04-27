import Foundation
import Observation

/// Multi-account Codex provider backed by CCS (`~/.ccs/cliproxy`).
///
/// Mirrors `CCSClaudeProvider`. Each account fetches from the ChatGPT backend
/// (`/backend-api/wham/usage`) using the JWT minted by CCS.
@Observable
public final class CCSCodexProvider: MultiAccountProvider, @unchecked Sendable {
    // MARK: - Identity

    public let id: String = "ccs-codex"
    public let name: String = "CCS Codex"
    public let cliCommand: String = "ccs"

    public var dashboardURL: URL? {
        URL(string: "https://github.com/kaitranntt/ccs")
    }

    public var statusPageURL: URL? {
        URL(string: "https://status.openai.com")
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
    public private(set) var activeAccount: ProviderAccount

    // MARK: - Dependencies

    public typealias AccountSource = @Sendable () -> [CCSAccount]
    public typealias TokenSource = @Sendable (CCSAccount) -> CCSToken?
    public typealias UsageFetcher = @Sendable (CCSToken, CCSAccount) async throws -> UsageSnapshot

    private let accountSource: AccountSource
    private let tokenSource: TokenSource
    private let fetchUsage: UsageFetcher
    private let settingsRepository: any ProviderSettingsRepository

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
        self.isEnabled = settingsRepository.isEnabled(forProvider: "ccs-codex")

        self.activeAccount = ProviderAccount(providerId: "ccs-codex", label: "No CCS accounts")
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
        if let snapshot { return snapshot }
        if let error = lastError { throw error }
        return UsageSnapshot.empty(for: id)
    }

    // MARK: - MultiAccountProvider Protocol

    @discardableResult
    public func switchAccount(to accountId: String) -> Bool {
        guard let match = accounts.first(where: { $0.accountId == accountId }) else { return false }
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
        guard let token = tokenSource(ccsAccount) else {
            let error = ProbeError.authenticationRequired
            accountErrors[accountId] = error
            throw error
        }
        do {
            let result = try await fetchUsage(token, ccsAccount)
            accountSnapshots[accountId] = result
            accountErrors.removeValue(forKey: accountId)
            if providerAccount.accountId == activeAccount.accountId {
                snapshot = result
                lastError = nil
            }
            return result
        } catch {
            accountErrors[accountId] = error
            if providerAccount.accountId == activeAccount.accountId {
                snapshot = nil
                lastError = error
            }
            throw error
        }
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

        let work: [(ProviderAccount, CCSAccount)] = accounts.compactMap { providerAccount in
            guard let ccsAccount = ccsAccountsByEmail[providerAccount.accountId] else { return nil }
            return (providerAccount, ccsAccount)
        }

        let fetcher = self.fetchUsage
        let tokenLookup = self.tokenSource

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
            for await item in group { collected.append(item) }
            return collected
        }

        var newSnapshots: [String: UsageSnapshot] = [:]
        var newErrors: [String: Error] = [:]
        for (accountId, result) in results {
            switch result {
            case .success(let snapshot): newSnapshots[accountId] = snapshot
            case .failure(let error): newErrors[accountId] = error
            }
        }
        accountSnapshots = newSnapshots
        accountErrors = newErrors

        if let activeSnapshot = newSnapshots[activeAccount.accountId] {
            snapshot = activeSnapshot
            lastError = nil
        } else if let activeError = newErrors[activeAccount.accountId] {
            snapshot = nil
            lastError = activeError
        } else {
            snapshot = nil
            lastError = nil
        }
    }

    // MARK: - Internals

    private var ccsAccountsByEmail: [String: CCSAccount] = [:]

    private func rebuildAccounts() {
        let raw = accountSource()
        var byEmail: [String: CCSAccount] = [:]
        let providerAccounts = raw.map { ccs -> ProviderAccount in
            byEmail[ccs.email] = ccs
            return ProviderAccount(
                accountId: ccs.email,
                providerId: "ccs-codex",
                label: ccs.displayLabel + (ccs.paused ? " (paused)" : ""),
                email: ccs.email,
                organization: nil
            )
        }
        ccsAccountsByEmail = byEmail
        if providerAccounts.isEmpty {
            accounts = []
            activeAccount = ProviderAccount(providerId: "ccs-codex", label: "No CCS accounts")
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
