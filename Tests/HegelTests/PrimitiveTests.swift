import Testing
import Foundation
@testable import Hegel

// Dates/times/datetimes, UUIDs, IPs, big integers — bounds, wellformedness,
// and (for each family) a known-minimum shrink so the marshalling can't
// pass vacuously.

@Suite struct TemporalTests {
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    @Test func datesAreValidAndInRange() throws {
        let lo = CalendarDate(year: 1900, month: 1, day: 1)
        let hi = CalendarDate(year: 2100, month: 12, day: 31)
        try forAll(.date(in: lo...hi), database: "") { d in
            #expect(d >= lo && d <= hi)
            #expect((1...12).contains(d.month))
            // Round-trips through a real calendar: rejects 2001-02-29 etc.
            var components = d.dateComponents
            components.calendar = Self.utc
            #expect(components.isValidDate)
        }
    }

    /// The engine documents date shrinking toward 2000-01-01 (or nearest
    /// bound): "year >= 2010 fails" must shrink to exactly 2010-01-01.
    @Test func datesShrinkTowardKnownMinimum() throws {
        let gen = Gen<CalendarDate>.date()
        do {
            try forAll(gen, database: "") { d in
                if d.year >= 2010 { throw HegelError.internalError("year >= 2010") }
            }
            Issue.record("property should have failed")
        } catch let failure as PropertyFailure {
            let blob = try #require(failure.failures.first?.reproduceBlob)
            #expect(try replay(gen, blob: blob) == CalendarDate(year: 2010, month: 1, day: 1))
        }
    }

    @Test func timesRespectBounds() throws {
        let lo = TimeOfDay(hour: 9, minute: 30)
        let hi = TimeOfDay(hour: 17, minute: 0)
        try forAll(.time(in: lo...hi), database: "") { t in
            #expect(t >= lo && t <= hi)
            #expect((0...999_999).contains(t.microsecond))
        }
    }

    /// Times shrink toward the lower bound: "hour >= 12 fails" → 12:00:00.
    /// Generation is strongly biased toward the bound (~2% of draws reach
    /// hour 12), so this needs a big case budget to fail reliably.
    @Test func timesShrinkTowardKnownMinimum() throws {
        let gen = Gen<TimeOfDay>.time()
        do {
            try forAll(gen, testCases: 2000, database: "") { t in
                if t.hour >= 12 { throw HegelError.internalError("hour >= 12") }
            }
            Issue.record("property should have failed")
        } catch let failure as PropertyFailure {
            let blob = try #require(failure.failures.first?.reproduceBlob)
            #expect(try replay(gen, blob: blob) == TimeOfDay(hour: 12, minute: 0))
        }
    }

    @Test func datetimesRespectBoundsAcrossFields() throws {
        let lo = CalendarDateTime(
            date: CalendarDate(year: 2020, month: 6, day: 15),
            time: TimeOfDay(hour: 12, minute: 0))
        let hi = CalendarDateTime(
            date: CalendarDate(year: 2021, month: 6, day: 15),
            time: TimeOfDay(hour: 12, minute: 0))
        try forAll(.datetime(in: lo...hi), database: "") { dt in
            #expect(dt >= lo && dt <= hi)
        }
    }
}

@Suite struct IdentifierTests {
    @Test func uuidVersionAndVariantAreStamped() throws {
        try forAll(.uuid(version: 4), database: "") { (u: UUID) in
            let s = u.uuidString  // 8-4-4-4-12, uppercase hex
            #expect(s[s.index(s.startIndex, offsetBy: 14)] == "4")
            #expect("89AB".contains(s[s.index(s.startIndex, offsetBy: 19)]))
        }
    }

    @Test func unversionedUUIDIsNeverNil() throws {
        try forAll(.uuid, database: "") { (u: UUID) in
            #expect(u != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
        }
    }

    @Test func ipv4IsDottedDecimal() throws {
        try forAll(Gen<String>.ipv4, database: "") { s in
            let parts = s.split(separator: ".")
            #expect(parts.count == 4)
            #expect(parts.allSatisfy { UInt8($0) != nil })
        }
    }

    @Test func ipv6RoundTripsThroughInetPton() throws {
        try forAll(zip(Gen<String>.ipv6, .ipv6Bytes), database: "") { s, _ in
            var addr = in6_addr()
            #expect(inet_pton(AF_INET6, s, &addr) == 1)
        }
    }
}

@Suite struct BigIntegerTests {
    @Test func uint64FullRangeRespectsA_HighBound() throws {
        // A range whose bounds don't fit in Int64 exercises the extra
        // (unsigned) sign byte on both buffers.
        let lo = UInt64(Int64.max)
        try forAll(Gen<UInt64>.int(in: lo...UInt64.max), database: "") { n in
            #expect(n >= lo)
        }
    }

    /// Big-integer draws shrink like ordinary ones: "n >= 10 fails" over
    /// the full UInt64 range must shrink to exactly 10.
    @Test func uint64ShrinksToKnownMinimum() throws {
        let gen = Gen<UInt64>.int()
        do {
            try forAll(gen, database: "") { n in
                if n >= 10 { throw HegelError.internalError("n >= 10") }
            }
            Issue.record("property should have failed")
        } catch let failure as PropertyFailure {
            let blob = try #require(failure.failures.first?.reproduceBlob)
            #expect(try replay(gen, blob: blob) == 10)
        }
    }

    @Test func int128RespectsBoundsBeyondInt64() throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        let lo = Int128(Int64.min) * 4
        let hi = Int128(Int64.max) * 4
        try forAll(Gen<Int128>.int(in: lo...hi), database: "") { n in
            #expect(n >= lo && n <= hi)
        }
    }

    @Test func int128NegativeBoundsWork() throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        try forAll(Gen<Int128>.int(in: -5...(-1)), database: "") { n in
            #expect((-5...(-1)).contains(n))
        }
    }

    @Test func uint128ShrinksToKnownMinimum() throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        let gen = Gen<UInt128>.int()
        do {
            try forAll(gen, database: "") { n in
                if n >= 10 { throw HegelError.internalError("n >= 10") }
            }
            Issue.record("property should have failed")
        } catch let failure as PropertyFailure {
            let blob = try #require(failure.failures.first?.reproduceBlob)
            #expect(try replay(gen, blob: blob) == 10)
        }
    }
}
