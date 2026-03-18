import Foundation
import Domain

/// Persists extension config values using JSONSettingsStore (non-secrets)
/// and UserDefaults (secrets), following the same dual-storage pattern as built-in providers.
public final class JSONExtensionConfigRepository: ExtensionConfigRepository, @unchecked Sendable {
    private let settingsStore: JSONSettingsStore
    private let userDefaults: UserDefaults

    public init(
        settingsStore: JSONSettingsStore,
        userDefaultsSuiteName: String? = nil
    ) {
        self.settingsStore = settingsStore
        if let suiteName = userDefaultsSuiteName {
            self.userDefaults = UserDefaults(suiteName: suiteName) ?? .standard
        } else {
            self.userDefaults = .standard
        }
    }

    // MARK: - Non-Secret Values

    public func value(forFieldId fieldId: String, extensionId: String) -> String? {
        settingsStore.read(key: "extensions.\(extensionId).\(fieldId)")
    }

    public func setValue(_ value: String?, forFieldId fieldId: String, extensionId: String) {
        settingsStore.write(value: value, key: "extensions.\(extensionId).\(fieldId)")
    }

    // MARK: - Secret Values

    public func secretValue(forFieldId fieldId: String, extensionId: String) -> String? {
        userDefaults.string(forKey: secretKey(fieldId: fieldId, extensionId: extensionId))
    }

    public func setSecretValue(_ value: String?, forFieldId fieldId: String, extensionId: String) {
        let key = secretKey(fieldId: fieldId, extensionId: extensionId)
        if let value {
            userDefaults.set(value, forKey: key)
        } else {
            userDefaults.removeObject(forKey: key)
        }
    }

    // MARK: - All Values

    public func allValues(forExtensionId extensionId: String, fields: [ConfigField]) -> [String: String] {
        var result: [String: String] = [:]
        for field in fields {
            let stored: String? = if field.isSecret {
                secretValue(forFieldId: field.id, extensionId: extensionId)
            } else {
                value(forFieldId: field.id, extensionId: extensionId)
            }
            if let effective = field.effectiveValue(stored: stored) {
                result[field.id] = effective
            }
        }
        return result
    }

    // MARK: - Private

    private func secretKey(fieldId: String, extensionId: String) -> String {
        "com.claudebar.credentials.ext-\(extensionId)-\(fieldId)"
    }
}
