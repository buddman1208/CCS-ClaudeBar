import Foundation

/// OAuth token for a single CCS-managed account, parsed from
/// `~/.ccs/cliproxy/auth/<tokenFile>`.
///
/// Two flavors are supported:
/// - Claude: `{access_token, refresh_token, expired, email, type:"claude"}`
/// - Codex (OpenAI JWT): `{access_token, account_id, expired, ...}`
///
/// We treat tokens as opaque bearer credentials. Refresh is exclusively the
/// responsibility of the CCS proxy; if a token is expired we surface a
/// `ProbeError.sessionExpired` to the user so they can run `ccs auth ...`.
public struct CCSToken: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case claude
        case codex
    }

    public let kind: Kind
    public let accessToken: String
    public let refreshToken: String?
    public let email: String?
    public let accountId: String?
    public let expiresAt: Date?
    public let disabled: Bool

    public init(
        kind: Kind,
        accessToken: String,
        refreshToken: String? = nil,
        email: String? = nil,
        accountId: String? = nil,
        expiresAt: Date? = nil,
        disabled: Bool = false
    ) {
        self.kind = kind
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.email = email
        self.accountId = accountId
        self.expiresAt = expiresAt
        self.disabled = disabled
    }

    /// Whether the token is currently expired according to the locally stored
    /// `expired` field. Probes treat this as authoritative and short-circuit
    /// rather than firing a doomed request — CCS will refresh the token on its
    /// next use, after which a subsequent probe sees the new expiry.
    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt < Date()
    }

    /// Treat anything within the next 60 seconds as effectively expired so we
    /// don't fire a doomed request.
    public var isExpiringSoon: Bool {
        guard let expiresAt else { return false }
        return expiresAt < Date().addingTimeInterval(60)
    }
}
