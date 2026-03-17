import Foundation
import Testing
@testable import Domain

@Suite
struct HealthCheckResultTests {
    @Test
    func `healthy status for 200 response`() {
        let result = HealthCheckResult(
            url: URL(string: "https://api.example.com/health")!,
            statusCode: 200,
            latencyMs: 142,
            checkedAt: Date()
        )

        #expect(result.isUp == true)
        #expect(result.status == .healthy)
        #expect(result.statusText == "UP")
        #expect(result.formattedLatency == "142ms")
        #expect(result.statusCodeText == "200 OK")
    }

    @Test
    func `healthy for all 2xx status codes`() {
        for code in [200, 201, 204, 299] {
            let result = HealthCheckResult(
                url: URL(string: "https://example.com")!,
                statusCode: code,
                latencyMs: 50,
                checkedAt: Date()
            )
            #expect(result.isUp == true, "Expected \(code) to be up")
            #expect(result.status == .healthy, "Expected \(code) to be healthy")
        }
    }

    @Test
    func `warning for slow response`() {
        let result = HealthCheckResult(
            url: URL(string: "https://example.com")!,
            statusCode: 200,
            latencyMs: 2500,
            checkedAt: Date()
        )

        #expect(result.isUp == true)
        #expect(result.status == .warning)
        #expect(result.formattedLatency == "2.5s")
    }

    @Test
    func `critical for server error`() {
        let result = HealthCheckResult(
            url: URL(string: "https://example.com")!,
            statusCode: 500,
            latencyMs: 80,
            checkedAt: Date()
        )

        #expect(result.isUp == false)
        #expect(result.status == .critical)
        #expect(result.statusText == "DOWN")
        #expect(result.statusCodeText == "500 Server Error")
    }

    @Test
    func `critical for connection failure`() {
        let result = HealthCheckResult(
            url: URL(string: "https://example.com")!,
            statusCode: 0,
            latencyMs: 0,
            checkedAt: Date()
        )

        #expect(result.isUp == false)
        #expect(result.status == .critical)
        #expect(result.statusText == "DOWN")
        #expect(result.statusCodeText == "No Response")
    }

    @Test
    func `warning for 4xx client errors`() {
        let result = HealthCheckResult(
            url: URL(string: "https://example.com")!,
            statusCode: 404,
            latencyMs: 30,
            checkedAt: Date()
        )

        #expect(result.isUp == false)
        #expect(result.status == .warning)
        #expect(result.statusCodeText == "404 Client Error")
    }

    @Test
    func `latency formats seconds for large values`() {
        let result = HealthCheckResult(
            url: URL(string: "https://example.com")!,
            statusCode: 200,
            latencyMs: 5200,
            checkedAt: Date()
        )

        #expect(result.formattedLatency == "5.2s")
    }

    @Test
    func `converts to extension metrics`() {
        let result = HealthCheckResult(
            url: URL(string: "https://api.example.com/health")!,
            statusCode: 200,
            latencyMs: 142,
            checkedAt: Date()
        )

        let metrics = result.toExtensionMetrics()

        #expect(metrics.count == 2)
        #expect(metrics[0].label == "Status")
        #expect(metrics[0].value == "UP")
        #expect(metrics[0].unit == "200 OK")
        #expect(metrics[1].label == "Latency")
        #expect(metrics[1].value == "142ms")
    }
}
