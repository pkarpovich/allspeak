import Foundation
import Testing
@testable import Allspeak

@Suite("Catalog build-time config", .tags(.catalog))
struct CatalogConfigTests {

    @Test("parses base URL and read token from an info dictionary")
    func parsesFromDictionary() throws {
        let config = try CatalogConfig(info: [
            CatalogConfig.urlKey: "https://allspeak.pkarpovich.dev",
            CatalogConfig.tokenKey: "secret-token",
        ])

        #expect(config.baseURL == URL(string: "https://allspeak.pkarpovich.dev"))
        #expect(config.readToken == "secret-token")
    }

    @Test("accepts an empty token so builds without the secret still succeed")
    func acceptsEmptyToken() throws {
        let config = try CatalogConfig(info: [
            CatalogConfig.urlKey: "https://allspeak.pkarpovich.dev",
            CatalogConfig.tokenKey: "",
        ])

        #expect(config.readToken.isEmpty)
    }

    @Test("throws missingURL when the URL key is absent")
    func missingURLKey() {
        #expect(throws: CatalogConfig.Error.missingURL) {
            try CatalogConfig(info: [CatalogConfig.tokenKey: "secret-token"])
        }
    }

    @Test("throws missingURL when the URL value is empty")
    func emptyURLValue() {
        #expect(throws: CatalogConfig.Error.missingURL) {
            try CatalogConfig(info: [
                CatalogConfig.urlKey: "",
                CatalogConfig.tokenKey: "secret-token",
            ])
        }
    }

    @Test("throws invalidURL when the URL has no scheme or host")
    func invalidURLValue() {
        #expect(throws: CatalogConfig.Error.invalidURL("allspeak.pkarpovich.dev")) {
            try CatalogConfig(info: [
                CatalogConfig.urlKey: "allspeak.pkarpovich.dev",
                CatalogConfig.tokenKey: "secret-token",
            ])
        }
    }

    @Test("throws missingToken when the token key is absent")
    func missingTokenKey() {
        #expect(throws: CatalogConfig.Error.missingToken) {
            try CatalogConfig(info: [CatalogConfig.urlKey: "https://allspeak.pkarpovich.dev"])
        }
    }
}
