import Foundation
import Domain

/// Analyzes Vibe session log files to produce daily usage reports.
/// Reads from ~/.vibe/logs/session/session_YYYYMMDD_HHMMSS_*/meta.json
public struct VibeSessionLogAnalyzer: DailyUsageAnalyzing, Sendable {
    private let vibeSessionsDir: URL
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    /// Devstral pricing: $0.40 per million input tokens
    private static let inputPricePerMToken: Decimal = 0.40
    /// Devstral pricing: $2.00 per million output tokens
    private static let outputPricePerMToken: Decimal = 2.00

    public init(
        vibeSessionsDir: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".vibe/logs/session"),
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.vibeSessionsDir = vibeSessionsDir
        self.calendar = calendar
        self.now = now
    }

    public func analyzeToday() async throws -> DailyUsageReport {
        let currentDate = now()
        let todayStart = calendar.startOfDay(for: currentDate)
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart)!

        let sessions = loadSessions()
        AppLog.probes.info("VibeSessionLogAnalyzer: found \(sessions.count) sessions")

        let todaySessions = sessions.filter { session in
            session.date >= todayStart && session.date < todayStart.addingTimeInterval(86400)
        }
        let yesterdaySessions = sessions.filter { session in
            session.date >= yesterdayStart && session.date < todayStart
        }

        let todayStat = aggregate(sessions: todaySessions, date: todayStart)
        let yesterdayStat = aggregate(sessions: yesterdaySessions, date: yesterdayStart)

        AppLog.probes.info("VibeSessionLogAnalyzer: today=\(todayStat.formattedCost)/\(todayStat.formattedTokens), yesterday=\(yesterdayStat.formattedCost)/\(yesterdayStat.formattedTokens)")

        return DailyUsageReport(today: todayStat, previous: yesterdayStat)
    }

    // MARK: - Private

    private struct ParsedSession {
        let date: Date
        let promptTokens: Int
        let completionTokens: Int
    }

    private func loadSessions() -> [ParsedSession] {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: vibeSessionsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var sessions: [ParsedSession] = []

        for entry in contents {
            // Only process directories matching session_YYYYMMDD_* pattern
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let name = entry.lastPathComponent
            guard name.hasPrefix("session_") else { continue }

            // Parse full UTC timestamp from directory name: session_YYYYMMDD_HHMMSS_sessionid
            // Using the time component avoids misclassifying sessions created after UTC midnight
            // but before local midnight (e.g. a 5pm PST session has a UTC date of the next day)
            let parts = name.split(separator: "_", maxSplits: 3)
            guard parts.count >= 3 else { continue }
            guard let sessionDate = parseSessionTimestamp(datePart: String(parts[1]), timePart: String(parts[2])) else {
                AppLog.probes.debug("VibeSessionLogAnalyzer: skipping dir with unparseable timestamp: \(name)")
                continue
            }

            let metadataURL = entry.appendingPathComponent("meta.json")
            guard fileManager.fileExists(atPath: metadataURL.path) else { continue }

            guard let data = try? Data(contentsOf: metadataURL) else { continue }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase

            guard let metadata = try? decoder.decode(VibeSessionMetadata.self, from: data) else {
                AppLog.probes.debug("VibeSessionLogAnalyzer: skipping malformed metadata at \(metadataURL.path)")
                continue
            }

            sessions.append(ParsedSession(
                date: sessionDate,
                promptTokens: metadata.stats.sessionPromptTokens,
                completionTokens: metadata.stats.sessionCompletionTokens
            ))
        }

        return sessions
    }

    private func parseSessionTimestamp(datePart: String, timePart: String) -> Date? {
        guard datePart.count == 8, timePart.count == 6 else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: "\(datePart)\(timePart)")
    }

    private func aggregate(sessions: [ParsedSession], date: Date) -> DailyUsageStat {
        guard !sessions.isEmpty else { return .empty(for: date) }

        var totalCost: Decimal = 0
        var totalTokens = 0

        for session in sessions {
            let promptCost = Decimal(session.promptTokens) * Self.inputPricePerMToken / 1_000_000
            let completionCost = Decimal(session.completionTokens) * Self.outputPricePerMToken / 1_000_000
            totalCost += promptCost + completionCost
            totalTokens += session.promptTokens + session.completionTokens
        }

        return DailyUsageStat(
            date: date,
            totalCost: totalCost,
            totalTokens: totalTokens,
            workingTime: 0,
            sessionCount: sessions.count
        )
    }
}

// MARK: - Internal Decodable Types

private struct VibeSessionMetadata: Decodable {
    let stats: VibeSessionStats
}

private struct VibeSessionStats: Decodable {
    let sessionPromptTokens: Int
    let sessionCompletionTokens: Int
}
