import Foundation

/// A single CCS-managed account for a particular provider (claude or codex).
///
/// CCS stores accounts at `~/.ccs/cliproxy/accounts.json`. Each account has an
/// associated OAuth token file under `~/.ccs/cliproxy/auth/<tokenFile>` which
/// holds the access/refresh token CCS uses when proxying requests.
///
/// We never write to or refresh CCS-owned token files; CCS owns that lifecycle.
public struct CCSAccount: Sendable, Equatable, Identifiable {
    public enum Provider: String, Sendable, Equatable {
        case claude
        case codex
    }

    public let provider: Provider
    public let email: String
    public let nickname: String
    public let tokenFile: String
    public let createdAt: Date?
    public let lastUsedAt: Date?
    public let paused: Bool
    public let isDefault: Bool

    /// Stable identifier within a provider scope. The full domain ID
    /// (`{providerId}.{accountId}`) is composed by the provider.
    public var id: String { email }

    public init(
        provider: Provider,
        email: String,
        nickname: String,
        tokenFile: String,
        createdAt: Date? = nil,
        lastUsedAt: Date? = nil,
        paused: Bool = false,
        isDefault: Bool = false
    ) {
        self.provider = provider
        self.email = email
        self.nickname = nickname
        self.tokenFile = tokenFile
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.paused = paused
        self.isDefault = isDefault
    }

    /// Display label preferring nickname, falling back to email.
    public var displayLabel: String {
        nickname.isEmpty ? email : nickname
    }
}
