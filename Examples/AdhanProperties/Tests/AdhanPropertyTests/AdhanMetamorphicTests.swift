import Testing
import Hegel
import Adhan
import Foundation

// Metamorphic relations for adhan-swift. There is no oracle for prayer
// times — nobody can say what fajr at (51.5, -0.1) on 2024-03-09 *should*
// be — but there is a lot to say about how the times must respond to a
// change of input: shift the longitude, and every time shifts; raise the
// fajr angle, and fajr moves earlier and nothing else moves; add a
// k-minute adjustment, and exactly one time moves by exactly k minutes.
// Each relation is a value; the engine draws one per case along with the
// source scenario, and a violation shrinks to the minimal metamorphic
// group (source, follow-up, both outputs).

extension CalculationParameters: @retroactive @unchecked Sendable {}

/// A full prayer-times query: where, when, and how.
struct Query: CustomStringConvertible {
    var latitude: Double
    var longitude: Double
    var year: Int
    var month: Int
    var day: Int
    var params: CalculationParameters

    var coordinates: Coordinates { Coordinates(latitude: latitude, longitude: longitude) }
    var dateComponents: DateComponents { DateComponents(year: year, month: month, day: day) }

    var description: String {
        let isha = params.ishaInterval > 0 ? "isha +\(params.ishaInterval)min" : "isha \(params.ishaAngle)°"
        let adjustments = params.adjustments == PrayerAdjustments()
            ? "" : " adjustments \(params.adjustments)"
        return "(\(latitude), \(longitude)) \(year)-\(month)-\(day) \(params.method)"
            + " fajr \(params.fajrAngle)° \(isha)\(adjustments)"
    }
}

/// The six times, with a one-line UTC rendering for failure reports.
struct Times: Equatable, CustomStringConvertible {
    let fajr, sunrise, dhuhr, asr, maghrib, isha: Date

    init(_ p: PrayerTimes) {
        fajr = p.fajr; sunrise = p.sunrise; dhuhr = p.dhuhr
        asr = p.asr; maghrib = p.maghrib; isha = p.isha
    }

    var all: [(Prayer, Date)] {
        [(.fajr, fajr), (.sunrise, sunrise), (.dhuhr, dhuhr), (.asr, asr), (.maghrib, maghrib), (.isha, isha)]
    }

    subscript(prayer: Prayer) -> Date {
        all.first { $0.0 == prayer }!.1
    }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "dd'T'HH:mm"
        return f
    }()

    var description: String {
        all.map { "\($0.0) \(Self.formatter.string(from: $0.1))" }.joined(separator: "  ")
    }
}

extension Prayer: @retroactive @unchecked Sendable {}

/// The subject: adhan's constructor, as a total function on the temperate
/// band. `nil` (no times for this day) rejects the case.
let prayerTimes: @Sendable (Query) throws -> Times = { q in
    guard let p = PrayerTimes(
        coordinates: q.coordinates, date: q.dateComponents, calculationParameters: q.params)
    else { throw HegelError.assume }
    return Times(p)
}

let temperateQuery: Gen<Query> = temperateScenario.map { s in
    Query(latitude: s.latitude, longitude: s.longitude,
          year: s.year, month: s.month, day: s.day,
          params: s.method.params)
}

private let minute: TimeInterval = 60

private func expectEqual(_ a: Times, _ b: Times, except moved: Set<Prayer>) throws {
    for (prayer, time) in a.all where !moved.contains(prayer) {
        guard time == b[prayer] else {
            throw RelationViolated("\(prayer) moved but only \(moved) may")
        }
    }
}

@Suite struct AdhanMetamorphicProperties {
    /// Change direction: a larger fajr angle (deeper twilight) gives an
    /// earlier — or, where a high-latitude rule has taken over, equal —
    /// fajr, and moves nothing else.
    static let fajrAngleUp = Relation<Query, Times>(
        "fajr angle up ⇒ fajr earlier or equal, nothing else moves",
        followUp: { q, tc in
            var q = q
            q.params.fajrAngle += Double(try tc.drawInteger(in: Int64(1)...6))
            return q
        },
        holds: { a, b in
            guard b.fajr <= a.fajr else { throw RelationViolated("fajr moved later") }
            try expectEqual(a, b, except: [.fajr])
        })

    /// Change direction: a larger isha angle gives a later — or equal, for
    /// interval-based methods and high-latitude rules — isha, nothing else.
    static let ishaAngleUp = Relation<Query, Times>(
        "isha angle up ⇒ isha later or equal, nothing else moves",
        followUp: { q, tc in
            var q = q
            q.params.ishaAngle += Double(try tc.drawInteger(in: Int64(1)...6))
            return q
        },
        holds: { a, b in
            guard b.isha >= a.isha else { throw RelationViolated("isha moved earlier") }
            try expectEqual(a, b, except: [.isha])
        })

    /// Exact: a k-minute adjustment to one prayer moves that prayer by
    /// exactly k minutes and nothing else. (Adjustments are applied before
    /// rounding to the minute; an integer number of minutes commutes with it.)
    static let adjustmentShifts = Relation<Query, Times>(
        "a k-minute adjustment moves exactly that prayer by exactly k minutes",
        followUp: { q, tc in
            var q = q
            let k = Int(try tc.drawInteger(in: Int64(-30)...30))
            switch Prayer.allCases[Int(try tc.drawInteger(in: Int64(0)...5))] {
            case .fajr: q.params.adjustments.fajr += k
            case .sunrise: q.params.adjustments.sunrise += k
            case .dhuhr: q.params.adjustments.dhuhr += k
            case .asr: q.params.adjustments.asr += k
            case .maghrib: q.params.adjustments.maghrib += k
            case .isha: q.params.adjustments.isha += k
            }
            return q
        },
        relates: { x, a, x2, b in
            for (prayer, time) in a.all {
                let k: Int
                switch prayer {
                case .fajr: k = x2.params.adjustments.fajr - x.params.adjustments.fajr
                case .sunrise: k = x2.params.adjustments.sunrise - x.params.adjustments.sunrise
                case .dhuhr: k = x2.params.adjustments.dhuhr - x.params.adjustments.dhuhr
                case .asr: k = x2.params.adjustments.asr - x.params.adjustments.asr
                case .maghrib: k = x2.params.adjustments.maghrib - x.params.adjustments.maghrib
                case .isha: k = x2.params.adjustments.isha - x.params.adjustments.isha
                }
                let shift = b[prayer].timeIntervalSince(time)
                guard abs(shift - Double(k) * minute) < 0.5 else {
                    throw RelationViolated("\(prayer) moved \(shift / minute) min, expected \(k)")
                }
            }
        })

    /// Translation: moving Δ° east on the same date and latitude shifts every
    /// time earlier by 4Δ minutes, within rounding (each side rounds to the
    /// minute independently, so up to a minute apart) and the sun's movement
    /// over those minutes (seconds).
    static let longitudeShift = Relation<Query, Times>(
        "Δ° east ⇒ every time 4Δ min earlier (±1 min rounding)",
        followUp: { q, tc in
            var q = q
            let delta = Double(try tc.drawInteger(in: Int64(1)...10))
            // FOUND (see dateLineBoundaryIsDiscontinuous below): at -180 and
            // within floating-point ulps of it the times are a day off, so
            // the relation keeps a hair's margin from that boundary.
            guard q.longitude > -179.9999, q.longitude + delta <= 180 else { throw HegelError.assume }
            q.longitude += delta
            return q
        },
        relates: { x, a, x2, b in
            let expected = -(x2.longitude - x.longitude) * 4 * minute
            for (prayer, time) in a.all {
                let shift = b[prayer].timeIntervalSince(time)
                guard abs(shift - expected) <= 90 else {
                    throw RelationViolated(
                        "\(prayer) shifted \(shift / minute) min, expected \(expected / minute)")
                }
            }
        })

    /// Approximate (a hypothesized relation in Chen's sense, not a necessary
    /// property): the same calendar date four years later has the same times
    /// of day to within a few minutes. Four years, not one: a year later the
    /// sun is ~6 h (or, across a leap day, ~18 h) of orbit away from where it
    /// was, which near grazing twilight at the latitude edge moves fajr by
    /// tens of minutes — the first run shrank exactly to (-55, 0), 2000-02-02
    /// → 2001, fajr 24 min later. After four years the leap cycle has
    /// realigned the calendar with the sun to within ~45 min of orbit.
    static let fourYearsLater = Relation<Query, Times>(
        "same date four years later ⇒ same times of day (±5 min)",
        followUp: { q, _ in
            var q = q
            q.year += 4
            return q
        },
        relates: { x, a, x2, b in
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            let days = utc.dateComponents(
                [.day], from: utc.date(from: x.dateComponents)!, to: utc.date(from: x2.dateComponents)!).day!
            for (prayer, time) in a.all {
                let drift = b[prayer].timeIntervalSince(time) - Double(days) * 86400
                guard abs(drift) <= 5 * minute else {
                    throw RelationViolated("\(prayer) drifted \(drift / minute) min over four years")
                }
            }
        })

    @Test func prayerTimesSatisfyTheirMetamorphicRelations() throws {
        try forAll(
            source: temperateQuery,
            relations: [
                Self.fajrAngleUp,
                Self.ishaAngleUp,
                Self.adjustmentShifts,
                Self.longitudeShift,
                Self.fourYearsLater,
            ],
            testCases: 1000,
            database: "",
            subject: prayerTimes)
    }

    /// FOUND by the longitude relation on its first run, shrunk to the
    /// generator's bound: at longitude -180 (and within a few ulps of it —
    /// -179.9999999 is already fine) adhan computes the times of the
    /// previous local day, behaving as +180, the same meridian on the other
    /// side of the date line; a 1° step east then moves every prayer ~24 h
    /// later. The transit-date heuristic in `Astronomical.approximateTransit`
    /// wraps its expected transit to 0 at L = -180 while the computed one
    /// sits just past midnight. An edge case rather than a practical bug —
    /// nobody asks for prayer times at -180.000 — but a discontinuity in a
    /// function that should be continuous in longitude. This test pins it;
    /// if upstream changes the boundary handling it starts failing and the
    /// margin above can go.
    @Test func dateLineBoundaryIsDiscontinuous() throws {
        let atTheDateLine = Relation<Query, Times>(
            "1° east of -180 ⇒ every time 4 min earlier",
            followUp: { q, _ in
                var q = q
                q.longitude = -179
                return q
            },
            relates: { _, a, _, b in
                for (prayer, time) in a.all {
                    let shift = b[prayer].timeIntervalSince(time)
                    guard abs(shift + 4 * minute) <= 90 else {
                        throw RelationViolated("\(prayer) shifted \(shift / minute) min")
                    }
                }
            })
        let source = temperateQuery.map { q in
            var q = q
            q.longitude = -180
            return q
        }
        do {
            try forAll(source: source, relations: [atTheDateLine], testCases: 50, database: "",
                       subject: prayerTimes)
            Issue.record("the date-line boundary appears FIXED upstream — drop the -180 guard in longitudeShift")
        } catch let failure as PropertyFailure {
            let group = try #require(failure.failures.first?.counterexample)
            #expect(group.contains("shifted 143"))  // ~1436-1437 min: a day later
        }
    }
}
