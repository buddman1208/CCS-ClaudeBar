import Testing
import Foundation
import Mockable
@testable import Infrastructure
@testable import Domain

@Suite("MistralUsageProbe Tests")
struct MistralUsageProbeTests {

    private func makeTempSessionDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-probe-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeReport(todayTokens: Int = 50_000, todayCost: Decimal = 0.05) -> DailyUsageReport {
        let today = DailyUsageStat(
            date: Date(),
            totalCost: todayCost,
            totalTokens: todayTokens,
            workingTime: 3600,
            sessionCount: 1
        )
        let yesterday = DailyUsageStat.empty(for: Calendar.current.date(byAdding: .day, value: -1, to: Date())!)
        return DailyUsageReport(today: today, previous: yesterday)
    }

    // MARK: - isAvailable Tests

    @Test func `isAvailable returns true when vibe sessions directory exists`() async {
        let tempDir = makeTempSessionDir()
        defer { cleanup(tempDir) }

        let probe = MistralUsageProbe(
            vibeLogAnalyzer: MockDailyUsageAnalyzing(),
            vibeSessionsDir: tempDir
        )

        #expect(await probe.isAvailable() == true)
    }

    @Test func `isAvailable returns false when directory does not exist`() async {
        let nonExistentDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-nonexistent-\(UUID().uuidString)")

        let probe = MistralUsageProbe(
            vibeLogAnalyzer: MockDailyUsageAnalyzing(),
            vibeSessionsDir: nonExistentDir
        )

        #expect(await probe.isAvailable() == false)
    }

    // MARK: - probe Tests

    @Test func `probe returns UsageSnapshot with costUsage and dailyUsageReport`() async throws {
        let mockAnalyzer = MockDailyUsageAnalyzing()
        let report = makeReport()
        given(mockAnalyzer)
            .analyzeToday()
            .willReturn(report)

        let probe = MistralUsageProbe(vibeLogAnalyzer: mockAnalyzer)

        let snapshot = try await probe.probe()

        #expect(snapshot.providerId == "mistral")
        #expect(snapshot.quotas.isEmpty)
        #expect(snapshot.costUsage == nil)
        #expect(snapshot.dailyUsageReport != nil)
    }

    @Test func `probe throws when log analyzer throws`() async {
        let mockAnalyzer = MockDailyUsageAnalyzing()
        given(mockAnalyzer)
            .analyzeToday()
            .willThrow(ProbeError.noData)

        let probe = MistralUsageProbe(vibeLogAnalyzer: mockAnalyzer)

        await #expect(throws: ProbeError.self) {
            try await probe.probe()
        }
    }
}
