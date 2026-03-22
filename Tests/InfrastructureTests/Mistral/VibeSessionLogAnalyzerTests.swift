import Testing
import Foundation
@testable import Infrastructure
@testable import Domain

@Suite("VibeSessionLogAnalyzerTests")
struct VibeSessionLogAnalyzerTests {

    // MARK: - Helpers

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeSessionDir(
        in baseDir: URL,
        date: Date = Date(),
        suffix: String = "abcdef"
    ) -> URL {
        // Directory name mirrors Vibe format: session_YYYYMMDD_HHMMSS_sessionid (UTC)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let dateStr = formatter.string(from: date)
        let name = "session_\(dateStr)_\(suffix)"
        let dir = baseDir.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeMetadata(
        to dir: URL,
        promptTokens: Int,
        completionTokens: Int
    ) {
        let json = """
        {
            "stats": {
                "session_prompt_tokens": \(promptTokens),
                "session_completion_tokens": \(completionTokens)
            }
        }
        """
        let data = json.data(using: .utf8)!
        let metadataURL = dir.appendingPathComponent("meta.json")
        try? data.write(to: metadataURL)
    }

    // MARK: - Tests

    @Test func `analyzes today's sessions and sums tokens correctly`() async throws {
        let tempDir = makeTempDir()
        defer { cleanup(tempDir) }

        let sessionDir = makeSessionDir(in: tempDir)
        writeMetadata(to: sessionDir, promptTokens: 1000, completionTokens: 500)

        let analyzer = VibeSessionLogAnalyzer(
            vibeSessionsDir: tempDir,
            now: { Date() }
        )

        let report = try await analyzer.analyzeToday()

        #expect(report.today.totalTokens == 1500)
    }

    @Test func `ignores sessions from other days`() async throws {
        let tempDir = makeTempDir()
        defer { cleanup(tempDir) }

        // Today's session
        let todayDir = makeSessionDir(in: tempDir, date: Date(), suffix: "today")
        writeMetadata(to: todayDir, promptTokens: 1000, completionTokens: 500)

        // Yesterday's session
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let yesterdayDir = makeSessionDir(in: tempDir, date: yesterday, suffix: "yesterday")
        writeMetadata(to: yesterdayDir, promptTokens: 2000, completionTokens: 1000)

        let analyzer = VibeSessionLogAnalyzer(
            vibeSessionsDir: tempDir,
            now: { Date() }
        )

        let report = try await analyzer.analyzeToday()

        #expect(report.today.totalTokens == 1500)
        #expect(report.previous.totalTokens == 3000)
    }

    @Test func `sums multiple today sessions correctly`() async throws {
        let tempDir = makeTempDir()
        defer { cleanup(tempDir) }

        let session1 = makeSessionDir(in: tempDir, suffix: "sess1")
        writeMetadata(to: session1, promptTokens: 1000, completionTokens: 500)

        let session2 = makeSessionDir(in: tempDir, suffix: "sess2")
        writeMetadata(to: session2, promptTokens: 2000, completionTokens: 1000)

        let analyzer = VibeSessionLogAnalyzer(
            vibeSessionsDir: tempDir,
            now: { Date() }
        )

        let report = try await analyzer.analyzeToday()

        #expect(report.today.totalTokens == 4500)
        #expect(report.today.sessionCount == 2)
    }

    @Test func `returns empty report when no sessions exist`() async throws {
        let tempDir = makeTempDir()
        defer { cleanup(tempDir) }

        let analyzer = VibeSessionLogAnalyzer(
            vibeSessionsDir: tempDir,
            now: { Date() }
        )

        let report = try await analyzer.analyzeToday()

        #expect(report.today.totalTokens == 0)
        #expect(report.today.totalCost == 0)
    }

    @Test func `handles malformed metadata json without throwing`() async throws {
        let tempDir = makeTempDir()
        defer { cleanup(tempDir) }

        // Valid session
        let goodDir = makeSessionDir(in: tempDir, suffix: "good")
        writeMetadata(to: goodDir, promptTokens: 1000, completionTokens: 500)

        // Malformed session
        let badDir = makeSessionDir(in: tempDir, suffix: "bad")
        let badMetadata = badDir.appendingPathComponent("metadata.json")
        try? "{ not valid json !! }".data(using: .utf8)!.write(to: badMetadata)

        let analyzer = VibeSessionLogAnalyzer(
            vibeSessionsDir: tempDir,
            now: { Date() }
        )

        // Should not throw - just skip the malformed file
        let report = try await analyzer.analyzeToday()
        #expect(report.today.totalTokens == 1500)
    }

    @Test func `computes cost with correct Devstral pricing`() async throws {
        let tempDir = makeTempDir()
        defer { cleanup(tempDir) }

        let sessionDir = makeSessionDir(in: tempDir)
        // 1M prompt tokens at $0.40/M + 1M completion tokens at $2.00/M = $2.40
        writeMetadata(to: sessionDir, promptTokens: 1_000_000, completionTokens: 1_000_000)

        let analyzer = VibeSessionLogAnalyzer(
            vibeSessionsDir: tempDir,
            now: { Date() }
        )

        let report = try await analyzer.analyzeToday()

        // $0.40 + $2.00 = $2.40
        #expect(report.today.totalCost == Decimal(string: "2.40")!)
    }


}
