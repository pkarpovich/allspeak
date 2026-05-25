import Foundation
import Testing
@testable import Allspeak

@Suite("SessionURLParser")
struct AllspeakWatchAppURLTests {

    @Test("parses a well-formed session URL into the embedded UUID")
    func parsesWellFormedURL() throws {
        let id = UUID()
        let url = try #require(URL(string: "allspeak://session/\(id.uuidString)"))
        #expect(SessionURLParser.parseSessionURL(url) == id)
    }

    @Test("scheme is matched case-insensitively")
    func acceptsUppercaseScheme() throws {
        let id = UUID()
        let url = try #require(URL(string: "ALLSPEAK://session/\(id.uuidString)"))
        #expect(SessionURLParser.parseSessionURL(url) == id)
    }

    @Test("host is matched case-insensitively")
    func acceptsUppercaseHost() throws {
        let id = UUID()
        let url = try #require(URL(string: "allspeak://SESSION/\(id.uuidString)"))
        #expect(SessionURLParser.parseSessionURL(url) == id)
    }

    @Test("rejects URL with wrong scheme")
    func rejectsWrongScheme() throws {
        let id = UUID()
        let url = try #require(URL(string: "https://session/\(id.uuidString)"))
        #expect(SessionURLParser.parseSessionURL(url) == nil)
    }

    @Test("rejects URL with wrong host")
    func rejectsWrongHost() throws {
        let id = UUID()
        let url = try #require(URL(string: "allspeak://track/\(id.uuidString)"))
        #expect(SessionURLParser.parseSessionURL(url) == nil)
    }

    @Test("rejects URL without a UUID path component")
    func rejectsEmptyPath() throws {
        let url = try #require(URL(string: "allspeak://session/"))
        #expect(SessionURLParser.parseSessionURL(url) == nil)
    }

    @Test("rejects URL whose path is not a valid UUID")
    func rejectsNonUUIDPath() throws {
        let url = try #require(URL(string: "allspeak://session/not-a-uuid"))
        #expect(SessionURLParser.parseSessionURL(url) == nil)
    }

    @Test("rejects URL with trailing path components beyond the UUID")
    func rejectsExtraPathComponents() throws {
        let id = UUID()
        let url = try #require(URL(string: "allspeak://session/\(id.uuidString)/extra"))
        #expect(SessionURLParser.parseSessionURL(url) == nil)
    }

    @Test("round-trips a UUID through sessionURL(for:)")
    func roundTripsUUID() {
        let id = UUID()
        let url = SessionURLParser.sessionURL(for: id)
        #expect(SessionURLParser.parseSessionURL(url) == id)
    }
}
