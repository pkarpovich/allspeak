import Testing
import UniformTypeIdentifiers
@testable import Allspeak

@Suite("UTType+Catalog", .tags(.storage))
struct UTTypeCatalogTests {

    @Test("shazamCatalog resolves to the ShazamKit system identifier")
    func identifierMatches() {
        #expect(UTType.shazamCatalog.identifier == "com.apple.shazamcatalog")
    }

    @Test("shazamCatalog recognizes the .shazamcatalog file extension")
    func filenameExtensionMatches() {
        let recognized = UTType.shazamCatalog.preferredFilenameExtension == "shazamcatalog"
            || (UTType.shazamCatalog.tags[.filenameExtension]?.contains("shazamcatalog") ?? false)
        #expect(recognized)
    }

    @Test("dtwMap is the JSON system type so .dtwmap.json files surface in the picker")
    func dtwMapIsJSON() {
        #expect(UTType.dtwMap == .json)
    }
}
