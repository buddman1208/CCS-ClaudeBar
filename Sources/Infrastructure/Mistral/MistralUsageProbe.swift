import Foundation
import Domain

/// Probes Vibe session logs for daily cost and token usage.
/// Reads from ~/.vibe/logs/session/*/metadata.json using Devstral pricing.
///
/// This probe is available when Vibe is installed (i.e. the session log directory exists).
/// No API key or network access is required.
public struct MistralUsageProbe: UsageProbe {
    private let vibeLogAnalyzer: any DailyUsageAnalyzing
    private let vibeSessionsDir: URL

    public init(
        vibeLogAnalyzer: any DailyUsageAnalyzing = VibeSessionLogAnalyzer(),
        vibeSessionsDir: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".vibe/logs/session")
    ) {
        self.vibeLogAnalyzer = vibeLogAnalyzer
        self.vibeSessionsDir = vibeSessionsDir
    }

    // MARK: - UsageProbe

    public func isAvailable() async -> Bool {
        let exists = FileManager.default.fileExists(atPath: vibeSessionsDir.path)
        if !exists {
            AppLog.probes.debug("Mistral: Not available - Vibe session directory not found at \(vibeSessionsDir.path)")
        }
        return exists
    }

    public func probe() async throws -> UsageSnapshot {
        AppLog.probes.info("Starting Mistral (Vibe log) probe...")

        let report = try await vibeLogAnalyzer.analyzeToday()

        AppLog.probes.info("Mistral Vibe logs: \(report.today.totalTokens) tokens today, cost \(report.today.formattedCost)")

        return UsageSnapshot(
            providerId: "mistral",
            quotas: [],
            capturedAt: Date(),
            dailyUsageReport: report
        )
    }
}
