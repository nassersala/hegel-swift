import Testing
import Hegel
import Adhan
import Foundation

// Stateful dogfood: a state machine probes one generated day's prayer
// times, moving a clock around by engine-chosen rules; after every move an
// invariant pins the currentPrayer/nextPrayer contract. A violation shrinks
// to a minimal (scenario, rule sequence) — typically a single jump to the
// offending instant.

@Suite struct AdhanStatefulProperties {
    struct DayProbe: CustomStringConvertible {
        let scenario: Scenario
        let prayers: PrayerTimes
        var now: Date

        var description: String { "\(scenario), probing \(now)" }
    }

    /// A temperate-band day where the constructor produced times, with the
    /// probe clock starting well before fajr.
    static let dayProbe: Gen<DayProbe> = temperateScenario
        .map { s in
            (s, PrayerTimes(
                coordinates: s.coordinates, date: s.dateComponents,
                calculationParameters: s.method.params))
        }
        .filter { $0.1 != nil }
        .map { s, p in
            DayProbe(scenario: s, prayers: p!, now: p!.fajr.addingTimeInterval(-6 * 3600))
        }

    /// currentPrayer/nextPrayer must tell one consistent story at any
    /// instant: before fajr it's (nil, fajr); from isha on it's (isha, nil);
    /// otherwise next is current's successor and now sits in
    /// [time(current), time(next)).
    static let consistent = Invariant<DayProbe>("current/next consistent") { probe in
        let p = probe.prayers
        let now = probe.now
        let order = Prayer.allCases  // [fajr, sunrise, dhuhr, asr, maghrib, isha]
        let current = p.currentPrayer(at: now)
        let next = p.nextPrayer(at: now)

        switch current {
        case nil:
            guard next == .fajr, now < p.fajr else {
                throw HegelError.internalError("before-fajr contract broken at \(now)")
            }
        case .isha?:
            guard next == nil, now >= p.isha else {
                throw HegelError.internalError("after-isha contract broken at \(now)")
            }
        case let prayer?:
            let index = order.firstIndex(of: prayer)!
            guard let next, next == order[index + 1] else {
                throw HegelError.internalError("next is not current's successor at \(now)")
            }
            guard p.time(for: prayer) <= now, now < p.time(for: next) else {
                throw HegelError.internalError("now outside [current, next) at \(now)")
            }
        }
    }

    @Test func currentAndNextPrayerStayConsistentAcrossTheDay() throws {
        try forAll(
            initial: Self.dayProbe,
            rules: [
                Rule("advance") { probe, tc in
                    let minutes = try tc.drawInteger(in: Int64(1)...360)
                    probe.now.addTimeInterval(Double(minutes) * 60)
                },
                Rule("rewind") { probe, tc in
                    let minutes = try tc.drawInteger(in: Int64(1)...360)
                    probe.now.addTimeInterval(Double(minutes) * -60)
                },
                Rule("jumpToPrayer") { probe, tc in
                    let index = try tc.drawInteger(in: Int64(0)...5)
                    probe.now = probe.prayers.time(for: Prayer.allCases[Int(index)])
                },
                Rule("jumpJustBeforePrayer") { probe, tc in
                    let index = try tc.drawInteger(in: Int64(0)...5)
                    probe.now = probe.prayers
                        .time(for: Prayer.allCases[Int(index)])
                        .addingTimeInterval(-1)
                },
            ],
            invariants: [Self.consistent],
            testCases: 150,
            database: "")
    }
}
