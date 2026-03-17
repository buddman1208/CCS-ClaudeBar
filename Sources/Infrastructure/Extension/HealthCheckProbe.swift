import Foundation
import Domain

/// A built-in UsageProbe that pings a URL endpoint and reports latency, status code, and up/down state.
/// No external script needed — just declare a URL in manifest.json.
public final class HealthCheckProbe: UsageProbe, @unchecked Sendable {
    private let url: URL
    private let providerId: String
    private let timeout: TimeInterval

    public init(url: URL, providerId: String, timeout: TimeInterval = 10) {
        self.url = url
        self.providerId = providerId
        self.timeout = timeout
    }

    public func probe() async throws -> UsageSnapshot {
        let result = await performHealthCheck()
        let metrics = result.toExtensionMetrics()
        return UsageSnapshot(
            providerId: providerId,
            quotas: [],
            capturedAt: Date(),
            extensionMetrics: metrics
        )
    }

    public func isAvailable() async -> Bool {
        true
    }

    // MARK: - Private

    private func performHealthCheck() async -> HealthCheckResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let latencyMs = Int(elapsed * 1000)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            return HealthCheckResult(
                url: url,
                statusCode: statusCode,
                latencyMs: latencyMs,
                checkedAt: Date()
            )
        } catch {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let latencyMs = Int(elapsed * 1000)

            return HealthCheckResult(
                url: url,
                statusCode: 0,
                latencyMs: latencyMs,
                checkedAt: Date()
            )
        }
    }
}
