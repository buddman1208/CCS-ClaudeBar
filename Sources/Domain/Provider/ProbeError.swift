import Foundation

/// Errors that can occur when probing a CLI
public enum ProbeError: Error, Sendable, LocalizedError {
    /// The CLI binary was not found on the system
    case cliNotFound(String)

    /// User needs to log in to the CLI
    case authenticationRequired

    /// OAuth session has expired - user needs to re-authenticate.
    /// The optional hint provides provider-specific recovery instructions.
    case sessionExpired(hint: String? = nil)

    /// The CLI output could not be parsed
    case parseFailed(String)

    /// The probe timed out waiting for a response
    case timeout

    /// No quota data was available
    case noData

    /// The CLI needs to be updated
    case updateRequired

    /// User needs to trust the current folder
    case folderTrustRequired

    /// Command execution failed
    case executionFailed(String)

    /// Usage data requires a subscription plan (API billing accounts don't support /usage)
    case subscriptionRequired

    /// Upstream returned HTTP 429. `retryAfter` is the cooldown window the
    /// caller MUST honour before probing this account again. When the upstream
    /// did not provide `Retry-After`, the probe SHOULD still pass a sensible
    /// fallback (typically 60s).
    case rateLimited(retryAfter: TimeInterval)

    // MARK: - LocalizedError

    public var errorDescription: String? {
        switch self {
        case .cliNotFound(let binary):
            return "CLI not found: \(binary)"
        case .authenticationRequired:
            return "Authentication required. Please log in."
        case .sessionExpired(let hint):
            if let hint {
                return "Session expired. \(hint)"
            }
            return "Session expired. Please log in again."
        case .parseFailed(let reason):
            return "Failed to parse output: \(reason)"
        case .timeout:
            return "Request timed out"
        case .noData:
            return "No usage data available"
        case .updateRequired:
            return "CLI update required"
        case .folderTrustRequired:
            return "Please trust this folder in Claude CLI"
        case .executionFailed(let reason):
            return reason
        case .subscriptionRequired:
            return "Subscription required for usage data"
        case .rateLimited(let retryAfter):
            let seconds = Int(retryAfter.rounded())
            return "Rate limited — retry in \(seconds)s"
        }
    }
}

// MARK: - Equatable (hint ignored for sessionExpired)

extension ProbeError: Equatable {
    public static func == (lhs: ProbeError, rhs: ProbeError) -> Bool {
        switch (lhs, rhs) {
        case (.cliNotFound(let a), .cliNotFound(let b)):
            return a == b
        case (.authenticationRequired, .authenticationRequired):
            return true
        case (.sessionExpired, .sessionExpired):
            return true
        case (.parseFailed(let a), .parseFailed(let b)):
            return a == b
        case (.timeout, .timeout):
            return true
        case (.noData, .noData):
            return true
        case (.updateRequired, .updateRequired):
            return true
        case (.folderTrustRequired, .folderTrustRequired):
            return true
        case (.executionFailed(let a), .executionFailed(let b)):
            return a == b
        case (.subscriptionRequired, .subscriptionRequired):
            return true
        case (.rateLimited(let a), .rateLimited(let b)):
            return a == b
        default:
            return false
        }
    }
}
