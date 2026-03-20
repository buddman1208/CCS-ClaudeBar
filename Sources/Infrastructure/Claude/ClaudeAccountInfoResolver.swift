import Foundation
import Domain

/// Resolves Claude account identity from the config file (`~/.claude.json` → `oauthAccount`).
/// This is the primary source of account info for CLI v2.1.79+ where the tabbed TUI
/// no longer includes account details in the `/usage` output.
public final class ClaudeAccountInfoResolver: AccountInfoResolving, Sendable {
    private let configURL: URL

    public init(configURL: URL? = nil) {
        self.configURL = configURL ?? {
            let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
                .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            return (configDir ?? FileManager.default.homeDirectoryForCurrentUser)
                .appendingPathComponent(".claude.json")
        }()
    }

    /// Resolves account info from `~/.claude.json` `oauthAccount` section.
    /// Returns `nil` if the file doesn't exist or has no usable account data.
    public func resolve() -> AccountInfo? {
        guard FileManager.default.fileExists(atPath: configURL.path),
              let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauthAccount = root["oauthAccount"] as? [String: Any] else {
            return nil
        }

        let email = oauthAccount["emailAddress"] as? String
        let displayName = oauthAccount["displayName"] as? String

        guard email != nil || displayName != nil else { return nil }

        return AccountInfo(
            email: email,
            organization: displayName
        )
    }
}
