import Foundation
import Testing
@testable import Allspeak

@Suite("Sessions list formatters")
struct SessionsListBindingTests {

    struct DurationCase: CustomStringConvertible {
        let input: Double?
        let expected: String?
        var description: String { "duration(\(String(describing: input))) → \(String(describing: expected))" }
    }

    @Test(
        "duration formatter produces H:MM:SS or nil",
        arguments: [
            DurationCase(input: nil,    expected: nil),
            DurationCase(input: -1,     expected: nil),
            DurationCase(input: 0,      expected: "0:00:00"),
            DurationCase(input: 59,     expected: "0:00:59"),
            DurationCase(input: 65,     expected: "0:01:05"),
            DurationCase(input: 3725,   expected: "1:02:05"),
            DurationCase(input: 8048,   expected: "2:14:08"),
            DurationCase(input: 6942,   expected: "1:55:42"),
            DurationCase(input: 12900,  expected: "3:35:00"),
            DurationCase(input: 0.4,    expected: "0:00:00"),
            DurationCase(input: 0.6,    expected: "0:00:01")
        ]
    )
    func durationFormatter(_ kase: DurationCase) {
        #expect(SessionFormatters.duration(seconds: kase.input) == kase.expected)
    }

    struct DateCase: CustomStringConvertible {
        let y: Int
        let m: Int
        let d: Int
        let expected: String
        var description: String { "\(y)-\(m)-\(d) → \(expected)" }
    }

    @Test(
        "monthDay returns abbreviated English MMM d",
        arguments: [
            DateCase(y: 2025, m: 5,  d: 11, expected: "May 11"),
            DateCase(y: 2025, m: 4,  d: 28, expected: "Apr 28"),
            DateCase(y: 2025, m: 4,  d: 2,  expected: "Apr 2"),
            DateCase(y: 2025, m: 1,  d: 1,  expected: "Jan 1"),
            DateCase(y: 2025, m: 12, d: 31, expected: "Dec 31")
        ]
    )
    func monthDayFormatter(_ kase: DateCase) throws {
        var components = DateComponents()
        components.year = kase.y
        components.month = kase.m
        components.day = kase.d
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone.current
        let date = try #require(calendar.date(from: components))
        #expect(SessionFormatters.monthDay(date) == kase.expected)
    }
}
