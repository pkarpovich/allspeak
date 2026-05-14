import Foundation
import Testing
@testable import Allspeak

@Suite("PlayerTime formatter")
struct TimeFormatterTests {

    @Test(
        "HH:MM:SS formatting across ranges",
        arguments: [
            (0.0,        "00:00:00"),
            (0.4,        "00:00:00"),
            (1.0,        "00:00:01"),
            (5.0,        "00:00:05"),
            (59.0,       "00:00:59"),
            (60.0,       "00:01:00"),
            (65.0,       "00:01:05"),
            (599.0,      "00:09:59"),
            (3599.0,     "00:59:59"),
            (3600.0,     "01:00:00"),
            (3661.0,     "01:01:01"),
            (8048.0,     "02:14:08"),
            (36000.0,    "10:00:00"),
            (-5.0,       "00:00:00"),
        ]
    )
    func formatHHMMSS(seconds: TimeInterval, expected: String) {
        #expect(PlayerTime.formatHHMMSS(seconds) == expected)
    }

    @Test("non-finite input clamps to zero string")
    func nonFinite() {
        #expect(PlayerTime.formatHHMMSS(.infinity) == "00:00:00")
        #expect(PlayerTime.formatHHMMSS(.nan) == "00:00:00")
    }

    @Test(
        "remaining time prefixes a minus sign",
        arguments: [
            (0.0,    100.0, "-00:01:40"),
            (50.0,   100.0, "-00:00:50"),
            (100.0,  100.0, "-00:00:00"),
            (120.0,  100.0, "-00:00:00"),
            (0.0,    8048.0, "-02:14:08"),
            (3661.0, 8048.0, "-01:13:07"),
        ]
    )
    func formatRemaining(current: TimeInterval, duration: TimeInterval, expected: String) {
        #expect(PlayerTime.formatRemaining(current: current, duration: duration) == expected)
    }
}
