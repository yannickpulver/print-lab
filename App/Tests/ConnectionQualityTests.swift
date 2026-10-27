import Foundation
import Testing
@testable import PrintLab

struct ConnectionQualityTests {
    typealias Check = ConnectionQuality.Check

    static func checks(_ count: Int = 10, missed: Int = 0, seconds: Double = 0.2) -> [Check] {
        (0..<count).map { Check(answered: $0 >= missed, seconds: seconds) }
    }

    @Test func strongWiFiAndSteadyAnswersAreGood() throws {
        let quality = try #require(ConnectionQuality(signal: 76, linkQuality: 84, checks: Self.checks()))
        #expect(quality.rating == .good)
        #expect(quality.causes.isEmpty)
        #expect(quality.fixes.isEmpty)
    }

    @Test func noRatingBeforeTheFirstCheckOrWhileThePrinterIsGone() {
        #expect(ConnectionQuality(signal: 76, linkQuality: 84, checks: []) == nil)
        let lastMissed = Self.checks(9) + [Check(answered: false, seconds: 5)]
        #expect(ConnectionQuality(signal: 76, linkQuality: 84, checks: lastMissed) == nil)
    }

    @Test func weakSignalIsPoorAndSuggestsMovingCloser() throws {
        let quality = try #require(ConnectionQuality(signal: 35, linkQuality: 80, checks: Self.checks()))
        #expect(quality.rating == .poor)
        #expect(quality.causes == ["weak Wi-Fi signal (35 %)"])
        #expect(quality.fixes.first?.contains("cable") == true)
        #expect(quality.fixes.contains { $0.contains("mesh node") })
    }

    @Test func mediumSignalIsFair() throws {
        let quality = try #require(ConnectionQuality(signal: 55, linkQuality: 80, checks: Self.checks()))
        #expect(quality.rating == .fair)
    }

    @Test func lowLinkQualityOnAGoodSignalPointsToTheChannel() throws {
        let quality = try #require(ConnectionQuality(signal: 80, linkQuality: 45, checks: Self.checks()))
        #expect(quality.rating == .poor)
        #expect(quality.fixes.contains { $0.contains("channel") })
        #expect(!quality.fixes.contains { $0.contains("mesh node") })
    }

    @Test func missedChecksCountInTheWindowOnly() throws {
        let one = try #require(ConnectionQuality(signal: 80, linkQuality: 80, checks: Self.checks(missed: 1)))
        #expect(one.rating == .fair)
        #expect(one.answered == 9)
        let two = try #require(ConnectionQuality(signal: 80, linkQuality: 80, checks: Self.checks(missed: 2)))
        #expect(two.rating == .poor)
        #expect(two.causes == ["2 of the last 10 status checks got no answer"])
        // Older misses fall out of the window.
        let old = try #require(ConnectionQuality(signal: 80, linkQuality: 80, checks: Self.checks(2, missed: 2) + Self.checks()))
        #expect(old.rating == .good)
    }

    @Test func dropoutsWithGoodPrinterWiFiPointToTheMac() throws {
        let quality = try #require(ConnectionQuality(signal: 80, linkQuality: 80, checks: Self.checks(missed: 2)))
        #expect(quality.fixes.contains { $0.contains("Mac") })
    }

    @Test func slowAnswersAreFair() throws {
        let quality = try #require(ConnectionQuality(signal: 80, linkQuality: 80, checks: Self.checks(seconds: 2)))
        #expect(quality.rating == .fair)
        #expect(quality.causes == ["slow answers from the printer (2.0 s)"])
    }

    @Test func zeroWiFiValuesMeanACable() throws {
        let quality = try #require(ConnectionQuality(signal: 0, linkQuality: 0, checks: Self.checks()))
        #expect(quality.rating == .good)
        #expect(quality.signal == nil)
    }
}
