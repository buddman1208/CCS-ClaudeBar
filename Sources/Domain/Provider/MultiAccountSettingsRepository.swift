import Foundation
import Mockable

/// Settings repository extension for multi-account provider configuration.
///
/// Stores account definitions per provider in the settings JSON.
/// Settings key pattern: `providers.{providerId}.accounts` (array of account configs).
///
/// Each account config contains:
/// - `accountId`: Unique identifier within the provider
/// - `label`: Human-readable name
/// - `email`: Optional email
/// - `organization`: Optional organization
/// - `probeConfig`: Provider-specific probe configuration (e.g., CLI profile, API token env var)
@Mockable
public protocol MultiAccountSettingsRepository: ProviderSettingsRepository {
    /// Gets all configured accounts for a provider.
    /// Returns an empty array for single-account providers (backward compatible).
    func accounts(forProvider id: String) -> [ProviderAccountConfig]

    /// Adds an account configuration for a provider.
    func addAccount(_ config: ProviderAccountConfig, forProvider id: String)

    /// Removes an account configuration by account ID.
    func removeAccount(accountId: String, forProvider id: String)

    /// Updates an existing account configuration.
    func updateAccount(_ config: ProviderAccountConfig, forProvider id: String)

    /// Gets the active account ID for a provider (nil = default/first account).
    func activeAccountId(forProvider id: String) -> String?

    /// Sets the active account ID for a provider.
    func setActiveAccountId(_ accountId: String?, forProvider id: String)
}

/// Configuration for a single account within a provider.
/// Serializable to/from the settings JSON.
public struct ProviderAccountConfig: Sendable, Equatable, Codable {
    /// Unique identifier within the provider
    public let accountId: String

    /// Human-readable label
    public let label: String

    /// Optional email
    public let email: String?

    /// Optional organization
    public let organization: String?

    /// Provider-specific probe configuration.
    /// For CLI-based providers: could be a profile name or config path.
    /// For API-based providers: could be an env var name for the token.
    /// Stored as a dictionary for flexibility across provider types.
    public let probeConfig: [String: String]

    public init(
        accountId: String,
        label: String,
        email: String? = nil,
        organization: String? = nil,
        probeConfig: [String: String] = [:]
    ) {
        self.accountId = accountId
        self.label = label
        self.email = email
        self.organization = organization
        self.probeConfig = probeConfig
    }

    /// Converts to a ProviderAccount domain model
    public func toProviderAccount(providerId: String) -> ProviderAccount {
        ProviderAccount(
            accountId: accountId,
            providerId: providerId,
            label: label,
            email: email,
            organization: organization
        )
    }
}
