import CHegel
import Foundation

/// A proleptic Gregorian calendar date, mirroring `hegel_date_t`.
/// `year` may be negative (astronomical numbering); the engine accepts
/// bounds with years in [-999999, 999999].
public struct CalendarDate: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var year: Int
    public var month: Int  // 1...12
    public var day: Int    // 1...days-in-month

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Default draw bounds, per the ABI's suggestion.
    public static let distantPast = CalendarDate(year: 1, month: 1, day: 1)
    public static let distantFuture = CalendarDate(year: 9999, month: 12, day: 31)

    public static func < (a: CalendarDate, b: CalendarDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public var dateComponents: DateComponents {
        DateComponents(year: year, month: month, day: day)
    }

    var raw: hegel_date_t {
        hegel_date_t(year: Int32(year), month: UInt8(month), day: UInt8(day))
    }

    init(raw: hegel_date_t) {
        self.init(year: Int(raw.year), month: Int(raw.month), day: Int(raw.day))
    }
}

/// A time of day, mirroring `hegel_time_t`.
public struct TimeOfDay: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var hour: Int         // 0...23
    public var minute: Int       // 0...59
    public var second: Int       // 0...59
    public var microsecond: Int  // 0...999999

    public init(hour: Int, minute: Int, second: Int = 0, microsecond: Int = 0) {
        self.hour = hour
        self.minute = minute
        self.second = second
        self.microsecond = microsecond
    }

    public static let midnight = TimeOfDay(hour: 0, minute: 0)
    public static let endOfDay = TimeOfDay(hour: 23, minute: 59, second: 59, microsecond: 999_999)

    public static func < (a: TimeOfDay, b: TimeOfDay) -> Bool {
        (a.hour, a.minute, a.second, a.microsecond) < (b.hour, b.minute, b.second, b.microsecond)
    }

    public var description: String {
        let base = String(format: "%02d:%02d:%02d", hour, minute, second)
        return microsecond == 0 ? base : base + String(format: ".%06d", microsecond)
    }

    public var dateComponents: DateComponents {
        DateComponents(hour: hour, minute: minute, second: second, nanosecond: microsecond * 1000)
    }

    var raw: hegel_time_t {
        hegel_time_t(
            hour: UInt8(hour), minute: UInt8(minute), second: UInt8(second),
            microsecond: UInt32(microsecond))
    }

    init(raw: hegel_time_t) {
        self.init(
            hour: Int(raw.hour), minute: Int(raw.minute), second: Int(raw.second),
            microsecond: Int(raw.microsecond))
    }
}

/// A naive datetime (date + time of day, no timezone), mirroring
/// `hegel_datetime_t`.
public struct CalendarDateTime: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var date: CalendarDate
    public var time: TimeOfDay

    public init(date: CalendarDate, time: TimeOfDay) {
        self.date = date
        self.time = time
    }

    public static func < (a: CalendarDateTime, b: CalendarDateTime) -> Bool {
        (a.date, a.time) < (b.date, b.time)
    }

    public var description: String { "\(date)T\(time)" }

    public var dateComponents: DateComponents {
        DateComponents(
            year: date.year, month: date.month, day: date.day,
            hour: time.hour, minute: time.minute, second: time.second,
            nanosecond: time.microsecond * 1000)
    }

    var raw: hegel_datetime_t {
        hegel_datetime_t(date: date.raw, time: time.raw)
    }

    init(raw: hegel_datetime_t) {
        self.init(date: CalendarDate(raw: raw.date), time: TimeOfDay(raw: raw.time))
    }
}

// MARK: - Draws

extension TestCase {
    /// Draws a date in `range`. Shrinks toward 2000-01-01, or the nearest
    /// bound when that is out of range.
    public func drawDate(
        in range: ClosedRange<CalendarDate> = .distantPast ... .distantFuture
    ) throws(HegelError) -> CalendarDate {
        var out = hegel_date_t()
        try call(hegel_generate_date(ctx.raw, raw, range.lowerBound.raw, range.upperBound.raw, &out))
        return CalendarDate(raw: out)
    }

    /// Draws a time of day in `range`. Shrinks toward the lower bound.
    public func drawTime(
        in range: ClosedRange<TimeOfDay> = .midnight ... .endOfDay
    ) throws(HegelError) -> TimeOfDay {
        var out = hegel_time_t()
        try call(hegel_generate_time(ctx.raw, raw, range.lowerBound.raw, range.upperBound.raw, &out))
        return TimeOfDay(raw: out)
    }

    /// Draws a naive datetime in `range`. Shrinks toward 2000-01-01T00:00:00,
    /// or the nearest bound when that is out of range.
    public func drawDateTime(
        in range: ClosedRange<CalendarDateTime>
    ) throws(HegelError) -> CalendarDateTime {
        var out = hegel_datetime_t()
        try call(hegel_generate_datetime(ctx.raw, raw, range.lowerBound.raw, range.upperBound.raw, &out))
        return CalendarDateTime(raw: out)
    }
}

// MARK: - Generators

extension Gen where Value == CalendarDate {
    /// Calendar dates, shrinking toward 2000-01-01 (or the nearest bound).
    public static func date(
        in range: ClosedRange<CalendarDate> = .distantPast ... .distantFuture
    ) -> Gen {
        Gen { tc in try tc.drawDate(in: range) }
    }
}

extension Gen where Value == TimeOfDay {
    /// Times of day, shrinking toward the lower bound.
    public static func time(
        in range: ClosedRange<TimeOfDay> = .midnight ... .endOfDay
    ) -> Gen {
        Gen { tc in try tc.drawTime(in: range) }
    }
}

extension Gen where Value == CalendarDateTime {
    /// Naive datetimes, shrinking toward 2000-01-01T00:00:00 (or the
    /// nearest bound).
    public static func datetime(
        in range: ClosedRange<CalendarDateTime> =
            CalendarDateTime(date: .distantPast, time: .midnight)
            ... CalendarDateTime(date: .distantFuture, time: .endOfDay)
    ) -> Gen {
        Gen { tc in try tc.drawDateTime(in: range) }
    }
}
