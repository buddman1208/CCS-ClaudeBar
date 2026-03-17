import Foundation
import Testing
@testable import Infrastructure
@testable import Domain

@Suite
struct HealthCheckProbeTests {
    @Test
    func `probe returns snapshot with health metrics on success`() async throws {
        let url = URL(string: "https://httpbin.org/get")!
        let probe = HealthCheckProbe(url: url, providerId: "ext-test", timeout: 10)

        // This test hits a real endpoint — skip in CI if needed
        let snapshot = try await probe.probe()

        #expect(snapshot.providerId == "ext-test")
        #expect(snapshot.extensionMetrics != nil)
        #expect(snapshot.extensionMetrics!.count == 2)
        #expect(snapshot.extensionMetrics![0].label == "Status")
        #expect(snapshot.extensionMetrics![1].label == "Latency")
    }

    @Test
    func `probe returns down status for unreachable host`() async throws {
        let url = URL(string: "https://this-host-does-not-exist-at-all.invalid/health")!
        let probe = HealthCheckProbe(url: url, providerId: "ext-test", timeout: 3)

        let snapshot = try await probe.probe()

        #expect(snapshot.extensionMetrics != nil)
        let statusMetric = snapshot.extensionMetrics![0]
        #expect(statusMetric.value == "DOWN")
    }

    @Test
    func `isAvailable always returns true`() async {
        let probe = HealthCheckProbe(
            url: URL(string: "https://example.com")!,
            providerId: "ext-test",
            timeout: 5
        )

        let available = await probe.isAvailable()
        #expect(available == true)
    }
}
