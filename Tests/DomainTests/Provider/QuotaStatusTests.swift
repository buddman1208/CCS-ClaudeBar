import Testing
import Foundation
@testable import Domain

@Suite
struct QuotaStatusTests {

    // MARK: - Factory Method Tests

    @Test
    func `healthy status for percentage above 50`() {
        #expect(QuotaStatus.from(percentRemaining: 100) == .healthy)
        #expect(QuotaStatus.from(percentRemaining: 75) == .healthy)
        #expect(QuotaStatus.from(percentRemaining: 51) == .healthy)
        #expect(QuotaStatus.from(percentRemaining: 50) == .healthy)
    }

    @Test
    func `warning status for percentage between 20 and 50`() {
        #expect(QuotaStatus.from(percentRemaining: 49) == .warning)
        #expect(QuotaStatus.from(percentRemaining: 35) == .warning)
        #expect(QuotaStatus.from(percentRemaining: 20) == .warning)
    }

    @Test
    func `critical status for percentage between 0 and 20`() {
        #expect(QuotaStatus.from(percentRemaining: 19) == .critical)
        #expect(QuotaStatus.from(percentRemaining: 10) == .critical)
        #expect(QuotaStatus.from(percentRemaining: 1) == .critical)
    }

    @Test
    func `depleted status for zero or negative percentage`() {
        #expect(QuotaStatus.from(percentRemaining: 0) == .depleted)
        #expect(QuotaStatus.from(percentRemaining: -1) == .depleted)
        #expect(QuotaStatus.from(percentRemaining: -100) == .depleted)
    }

    // MARK: - Needs Attention Tests

    @Test
    func `healthy status does not need attention`() {
        #expect(QuotaStatus.healthy.needsAttention == false)
    }

    @Test
    func `warning status needs attention`() {
        #expect(QuotaStatus.warning.needsAttention == true)
    }

    @Test
    func `critical status needs attention`() {
        #expect(QuotaStatus.critical.needsAttention == true)
    }

    @Test
    func `depleted status needs attention`() {
        #expect(QuotaStatus.depleted.needsAttention == true)
    }

    // MARK: - Comparison Tests (Severity Order)

    @Test
    func `healthy is less severe than warning`() {
        #expect(QuotaStatus.healthy < QuotaStatus.warning)
    }

    @Test
    func `warning is less severe than critical`() {
        #expect(QuotaStatus.warning < QuotaStatus.critical)
    }

    @Test
    func `critical is less severe than depleted`() {
        #expect(QuotaStatus.critical < QuotaStatus.depleted)
    }

    @Test
    func `depleted is most severe`() {
        #expect(QuotaStatus.depleted > QuotaStatus.healthy)
        #expect(QuotaStatus.depleted > QuotaStatus.warning)
        #expect(QuotaStatus.depleted > QuotaStatus.critical)
    }

    @Test
    func `max of multiple statuses returns worst status`() {
        let statuses: [QuotaStatus] = [.healthy, .warning, .critical]
        #expect(statuses.max() == .critical)

        let mixedStatuses: [QuotaStatus] = [.warning, .depleted, .healthy]
        #expect(mixedStatuses.max() == .depleted)
    }

    // MARK: - Equality Tests

    @Test
    func `status equals itself`() {
        #expect(QuotaStatus.healthy == .healthy)
        #expect(QuotaStatus.warning == .warning)
        #expect(QuotaStatus.critical == .critical)
        #expect(QuotaStatus.depleted == .depleted)
    }

    @Test
    func `different statuses are not equal`() {
        #expect(QuotaStatus.healthy != .warning)
        #expect(QuotaStatus.warning != .critical)
        #expect(QuotaStatus.critical != .depleted)
    }

    // MARK: - Hashable Tests

    @Test
    func `status can be used as dictionary key`() {
        var dict: [QuotaStatus: String] = [:]
        dict[.healthy] = "green"
        dict[.warning] = "yellow"

        #expect(dict[.healthy] == "green")
        #expect(dict[.warning] == "yellow")
    }

    @Test
    func `status can be used in set`() {
        let statuses: Set<QuotaStatus> = [.healthy, .warning, .healthy]
        #expect(statuses.count == 2)
    }

    // MARK: - Burn Rate (Pace-Aware) Tests

    @Test
    func `pace aware status is healthy when burn rate is below threshold`() {
        // 57% used, 85% time elapsed → burn rate 0.67 → HEALTHY (issue example: Claude SESSION)
        let status = QuotaStatus.from(percentRemaining: 43, percentTimeElapsed: 85, burnRateThreshold: 1.5)
        #expect(status == .healthy)
    }

    @Test
    func `pace aware status is warning when burn rate exceeds threshold`() {
        // 53% used, 8.5% time elapsed → burn rate 6.2 → WARNING (issue example: Codex WEEKLY)
        let status = QuotaStatus.from(percentRemaining: 47, percentTimeElapsed: 8.5, burnRateThreshold: 1.5)
        #expect(status == .warning)
    }

    @Test
    func `pace aware status is depleted regardless of burn rate`() {
        // Depleted is always depleted, even if burn rate is low
        let status = QuotaStatus.from(percentRemaining: 0, percentTimeElapsed: 99, burnRateThreshold: 1.5)
        #expect(status == .depleted)
    }

    @Test
    func `pace aware status is critical regardless of burn rate`() {
        // Below 20% remaining is always critical (absolute safety net)
        let status = QuotaStatus.from(percentRemaining: 15, percentTimeElapsed: 90, burnRateThreshold: 1.5)
        #expect(status == .critical)
    }

    @Test
    func `pace aware status is healthy when plenty remaining despite high burn rate`() {
        // 10% used, 5% elapsed → burn rate 2.0, but 90% remaining — no warning yet
        let status = QuotaStatus.from(percentRemaining: 90, percentTimeElapsed: 5, burnRateThreshold: 1.5)
        #expect(status == .healthy)
    }

    @Test
    func `pace aware status handles zero time elapsed gracefully`() {
        // At the very start of a period, fall back to absolute thresholds
        let status = QuotaStatus.from(percentRemaining: 43, percentTimeElapsed: 0, burnRateThreshold: 1.5)
        #expect(status == .warning) // 43% remaining → absolute threshold says warning
    }

    @Test
    func `pace aware status uses configurable threshold`() {
        // 55% used, 30% elapsed → burn rate ~1.83, remaining = 45% < 50
        // With threshold 1.5 → warning (1.83 > 1.5)
        let warningStatus = QuotaStatus.from(percentRemaining: 45, percentTimeElapsed: 30, burnRateThreshold: 1.5)
        #expect(warningStatus == .warning)

        // With threshold 2.5 → healthy (1.83 < 2.5)
        let healthyStatus = QuotaStatus.from(percentRemaining: 45, percentTimeElapsed: 30, burnRateThreshold: 2.5)
        #expect(healthyStatus == .healthy)
    }

    @Test
    func `pace aware status warns at boundary with remaining below 50`() {
        // Burn rate matters only when remaining < 50% (meaningful warning zone)
        // 55% used, 30% elapsed → burn rate ~1.83 > 1.5, remaining = 45% < 50 → warning
        let status = QuotaStatus.from(percentRemaining: 45, percentTimeElapsed: 30, burnRateThreshold: 1.5)
        #expect(status == .warning)
    }
}
