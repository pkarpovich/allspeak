import Foundation
import Testing
@testable import Allspeak

@Suite("Hall list")
struct HallTests {

    @Test("manufaktura lists 15 halls with unique keys")
    func fifteenUniqueHalls() {
        let keys = Hall.manufaktura.map(\.key)
        #expect(keys.count == 15)
        #expect(Set(keys).count == 15)
    }

    @Test("IMAX comes first, then halls 1 to 14 in order")
    func imaxFirstThenNumbered() {
        let keys = Hall.manufaktura.map(\.key)
        #expect(keys.first == "IMAX")
        #expect(Array(keys.dropFirst()) == (1...14).map(String.init))
    }

    @Test("a session asks for its hall while it has none or one that is not in the list", arguments: [
        (nil, true), ("4", false), ("IMAX", false), ("99", true),
    ] as [(String?, Bool)])
    func needsSelection(key: String?, expected: Bool) {
        #expect(Hall.needsSelection(key) == expected)
    }

    @Test("hall id is its key")
    func idIsKey() {
        #expect(Hall.manufaktura.allSatisfy { $0.id == $0.key })
    }
}
