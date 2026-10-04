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

    @Test("hall id is its key")
    func idIsKey() {
        #expect(Hall.manufaktura.allSatisfy { $0.id == $0.key })
    }
}
