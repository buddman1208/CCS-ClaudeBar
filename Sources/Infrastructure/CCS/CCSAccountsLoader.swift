import Foundation
import Domain

/// Loads CCS-managed accounts and their OAuth tokens from `~/.ccs/cliproxy`.
///
/// File layout (CCS v12 schema):
/// ```
/// ~/.ccs/cliproxy/
///   accounts.json                        # provider -> accounts map
///   auth/
///     claude-<email>.json                # OAuth token for a claude account
///     codex-<email>-<plan>.json          # JWT token for a codex account
/// ```
///
/// The loader is read-only and treats missing files / malformed payloads as
/// "no accounts available" rather than throwing, so a fresh machine without CCS
/// installed simply yields an empty provider entry.
public struct CCSAccountsLoader: Sendable {
    private let cliproxyURL: URL

    /// - Parameter homeDirectory: The path to use as `$HOME`. Defaults to
    ///   `FileManager.default.homeDirectoryForCurrentUser` so production code
    ///   reads from the real `~/.ccs/cliproxy`. Tests can supply a temp dir.
    public init(homeDirectory: URL? = nil) {
        let home = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        self.cliproxyURL = home
            .appendingPathComponent(".ccs", isDirectory: true)
            .appendingPathComponent("cliproxy", isDirectory: true)
    }

    /// Convenience init using a string home path (for parity with the rest of
    /// the infra layer which passes Strings around).
    public init(homePath: String) {
        self.init(homeDirectory: URL(fileURLWithPath: homePath, isDirectory: true))
    }

    /// Returns `true` when `~/.ccs/cliproxy/accounts.json` is readable. Used
    /// by providers' `isAvailable()`.
    public func hasAccountsFile() -> Bool {
        FileManager.default.fileExists(atPath: accountsFileURL.path)
    }

    /// Loads accounts for a single provider. Returns an empty array if CCS
    /// isn't installed or the provider section is missing.
    public func loadAccounts(provider: CCSAccount.Provider) -> [CCSAccount] {
        guard let accountsRoot = readAccountsRoot() else { return [] }
        guard let providerEntry = accountsRoot.providers[provider.rawValue] else { return [] }
        return providerEntry.accounts
            .map { (email, raw) in
                CCSAccount(
                    provider: provider,
                    email: raw.email ?? email,
                    nickname: raw.nickname ?? "",
                    tokenFile: raw.tokenFile ?? "",
                    createdAt: Self.parseISO(raw.createdAt),
                    lastUsedAt: Self.parseISO(raw.lastUsedAt),
                    paused: raw.paused ?? false,
                    isDefault: providerEntry.default == email
                )
            }
            .sorted { lhs, rhs in
                // Default first, then alphabetical by display label.
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                return lhs.displayLabel.localizedCaseInsensitiveCompare(rhs.displayLabel) == .orderedAscending
            }
    }

    /// Loads the token file for a given account. Returns `nil` if the file is
    /// missing or unparseable; callers should surface `authenticationRequired`.
    public func loadToken(for account: CCSAccount) -> CCSToken? {
        guard !account.tokenFile.isEmpty else { return nil }
        let url = cliproxyURL
            .appendingPathComponent("auth", isDirectory: true)
            .appendingPathComponent(account.tokenFile)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let raw = try? JSONDecoder().decode(RawToken.self, from: data) else { return nil }

        let kind: CCSToken.Kind
        switch (raw.type?.lowercased(), account.provider) {
        case ("claude", _):
            kind = .claude
        case (_, .claude):
            kind = .claude
        default:
            kind = .codex
        }

        let access = raw.access_token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !access.isEmpty else { return nil }

        return CCSToken(
            kind: kind,
            accessToken: access,
            refreshToken: raw.refresh_token,
            email: raw.email ?? account.email,
            accountId: raw.account_id,
            expiresAt: Self.parseISO(raw.expired),
            disabled: raw.disabled ?? false
        )
    }

    // MARK: - Internals

    private var accountsFileURL: URL {
        cliproxyURL.appendingPathComponent("accounts.json")
    }

    private func readAccountsRoot() -> AccountsRoot? {
        guard let data = try? Data(contentsOf: accountsFileURL) else { return nil }
        return try? JSONDecoder().decode(AccountsRoot.self, from: data)
    }

    private static func parseISO(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: string) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    // MARK: - JSON Models

    private struct AccountsRoot: Decodable {
        let version: Int?
        let providers: [String: ProviderEntry]
    }

    private struct ProviderEntry: Decodable {
        let `default`: String?
        let accounts: [String: RawAccount]
    }

    private struct RawAccount: Decodable {
        let email: String?
        let nickname: String?
        let tokenFile: String?
        let createdAt: String?
        let lastUsedAt: String?
        let paused: Bool?
    }

    /// Snake-case fields are present in the CCS JSON; we keep them verbatim
    /// rather than mapping with CodingKeys to keep this trivially auditable.
    private struct RawToken: Decodable {
        let access_token: String
        let refresh_token: String?
        let email: String?
        let expired: String?
        let type: String?
        let disabled: Bool?
        let account_id: String?
    }
}
