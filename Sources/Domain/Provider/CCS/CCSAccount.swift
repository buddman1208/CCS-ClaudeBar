import Foundation

/// A single CCS-managed account. CCS supports six provider kinds; ClaudeBar
///
/// CCS stores accounts at `~/.ccs/cliproxy/accounts.json`. Each account has an
/// associated OAuth token file under `~/.ccs/cliproxy/auth/<tokenFile>` which
/// holds the access/refresh token CCS uses when proxying requests.
///
/// We never write to or refresh CCS-owned token files; CCS owns that lifecycle.
public struct CCSAccount: Sendable, Equatable, Identifiable {
    /// All provider kinds CCS (`CLIProxyAPI`) currently supports. Keep the
    /// raw values aligned with the keys CCS writes to `accounts.json`.
    public enum Provider: String, Sendable, Equatable, CaseIterable {
        case claude
        case codex
        case gemini
        case antigravity
        case kimi
        case vertex

        /// Whether this provider has a usable upstream `usage` endpoint we
        /// know how to call. Connection-only providers (gemini, antigravity,
        /// kimi, vertex) only show "connected + last used" in the menu.
        public var hasUsageProbe: Bool {
            switch self {
            case .claude, .codex: return true
            case .gemini, .antigravity, .kimi, .vertex: return false
            }
        }

        /// User-facing display name (capitalised forms used in the menu UI).
        public var displayName: String {
            switch self {
            case .claude: return "Claude"
            case .codex: return "Codex"
            case .gemini: return "Gemini"
            case .antigravity: return "Antigravity"
            case .kimi: return "Kimi"
            case .vertex: return "Vertex"
            }
        }
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
