import Testing
import Hegel
import HegelTesting
import Adhan
import Foundation

// Property-based tests for adhan-swift, written with hegel-swift.
// The interesting outcomes here are counterexamples: shrunk
// (coordinates, date, method) triples where an invariant breaks.

// MARK: - Generators

// String-backed value enum; safe to send across the Gen closure boundary.
// (Dogfood note: Gen's @Sendable closures surface any non-Sendable domain
// type immediately — a real cost of the witness design worth documenting.)
extension CalculationMethod: @retroactive @unchecked Sendable {}

struct Scenario: CustomStringConvertible {
    var latitude: Double
    var longitude: Double
    var year: Int
    var month: Int
    var day: Int
    var method: CalculationMethod

    var coordinates: Coordinates { Coordinates(latitude: latitude, longitude: longitude) }
    var dateComponents: DateComponents { DateComponents(year: year, month: month, day: day) }

    var description: String {
        "(\(latitude), \(longitude)) \(year)-\(month)-\(day) \(method)"
    }
}

let methods: [CalculationMethod] = [
    .muslimWorldLeague, .egyptian, .karachi, .ummAlQura, .dubai,
    .moonsightingCommittee, .northAmerica, .kuwait, .qatar, .singapore,
]

/// Scenarios away from the polar bands, where every method is defined.
func scenario(latitudes: ClosedRange<Double>) -> Gen<Scenario> {
    zip(
        zip(.double(in: latitudes), .double(in: -180...180)),
        zip(.int(in: 2000...2030), .int(in: 1...12), .int(in: 1...28)),
        element(of: methods)
    ).map { position, date, method in
        Scenario(
            latitude: position.0, longitude: position.1,
            year: date.0, month: date.1, day: date.2,
            method: method)
    }
}

let temperateScenario = scenario(latitudes: -55...55)

// MARK: - Properties

@Suite struct AdhanProperties {
    /// The five daily prayers plus sunrise come out strictly ordered:
    /// fajr < sunrise < dhuhr < asr < maghrib < isha.
    @Test func prayerTimesAreOrdered() throws {
        try forAll(temperateScenario, testCases: 300, database: "") { s in
            guard let p = PrayerTimes(
                coordinates: s.coordinates, date: s.dateComponents,
                calculationParameters: s.method.params) else {
                throw HegelError.internalError("no times for \(s)")
            }
            let times = [p.fajr, p.sunrise, p.dhuhr, p.asr, p.maghrib, p.isha]
            guard times == times.sorted(), Set(times).count == times.count else {
                throw HegelError.internalError("unordered/coincident times")
            }
        }
    }

    /// All six times land within the requested UTC day ± 1 day.
    @Test func timesBelongToTheRequestedDay() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        try forAll(temperateScenario, testCases: 300, database: "") { s in
            guard let p = PrayerTimes(
                coordinates: s.coordinates, date: s.dateComponents,
                calculationParameters: s.method.params) else {
                throw HegelError.internalError("no times for \(s)")
            }
            let dayStart = utc.date(from: s.dateComponents)!
            for t in [p.fajr, p.sunrise, p.dhuhr, p.asr, p.maghrib, p.isha] {
                let delta = t.timeIntervalSince(dayStart)
                guard delta > -86400, delta < 2 * 86400 else {
                    throw HegelError.internalError("time far from requested day")
                }
            }
        }
    }

    /// The madhab knob moves ONLY asr, and monotonically: the Hanafi asr
    /// (shadow length 2x) is never earlier than the Shafi asr (1x).
    @Test func madhabMovesOnlyAsr() throws {
        try forAll(temperateScenario, testCases: 300, database: "") { s in
            var shafi = s.method.params
            shafi.madhab = .shafi
            var hanafi = s.method.params
            hanafi.madhab = .hanafi
            guard
                let a = PrayerTimes(coordinates: s.coordinates, date: s.dateComponents,
                                    calculationParameters: shafi),
                let b = PrayerTimes(coordinates: s.coordinates, date: s.dateComponents,
                                    calculationParameters: hanafi)
            else {
                throw HegelError.internalError("no times for \(s)")
            }
            guard b.asr >= a.asr else {
                throw HegelError.internalError("hanafi asr earlier than shafi")
            }
            guard a.fajr == b.fajr, a.sunrise == b.sunrise, a.dhuhr == b.dhuhr,
                  a.maghrib == b.maghrib, a.isha == b.isha else {
                throw HegelError.internalError("madhab moved a non-asr time")
            }
        }
    }

    /// Qibla direction is a finite bearing in [0, 360) everywhere outside
    /// the poles. Written with expectAll: bare #expect failures shrink, and
    /// the .propertyTesting trait keeps the search phase out of the results.
    @Test(.propertyTesting) func qiblaIsAlwaysABearing() {
        let anywhere = zip(.double(in: -89...89), .double(in: -180...180))
            .map { Coordinates(latitude: $0, longitude: $1) }
        expectAll(anywhere, testCases: 500, database: "") { c in
            let direction = Qibla(coordinates: c).direction
            #expect(direction.isFinite)
            #expect(direction >= 0 && direction < 360)
        }
    }

    /// FOUND BUG (filed upstream as
    /// https://github.com/batoulapps/adhan-swift/issues/102): in the
    /// high-latitude band (±75°) the constructor can return non-nil times
    /// with asr OUT OF ORDER — before dhuhr on the same day
    /// ((-75, 0), 2029-05-01: dhuhr 11:58Z, asr 04:17Z), or days after
    /// the requested date ((-72, 0), 2000-08-01: asr lands on Aug 3).
    /// A correct API would return nil (as it does elsewhere) or ordered
    /// times. This test documents the bug and prints Hegel's shrunk
    /// minimal counterexample; it will start failing if upstream fixes
    /// it — then promote it to a real ordering property.
    @Test func highLatitudeUnorderedTimesBugIsStillPresent() throws {
        let gen = scenario(latitudes: -75...75)
        do {
            try forAll(gen, testCases: 500, database: "") { s in
                guard let p = PrayerTimes(
                    coordinates: s.coordinates, date: s.dateComponents,
                    calculationParameters: s.method.params) else {
                    return  // nil is an acceptable answer up here
                }
                let times = [p.fajr, p.sunrise, p.dhuhr, p.asr, p.maghrib, p.isha]
                guard times == times.sorted() else {
                    throw HegelError.internalError("unordered high-latitude times")
                }
            }
            Issue.record("upstream bug appears FIXED — promote this test to an ordering property")
        } catch let failure as PropertyFailure {
            print("shrunk counterexample: \(failure.failures.first?.counterexample ?? "?")")
        }
    }
}
