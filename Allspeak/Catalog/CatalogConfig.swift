import Foundation

struct CatalogConfig: Sendable, Equatable {
    let baseURL: URL
    let readToken: String

    enum Error: Swift.Error, Equatable {
        case missingURL
        case invalidURL(String)
        case missingToken
    }

    static let urlKey = "AllspeakCatalogURL"
    static let tokenKey = "AllspeakCatalogReadToken"

    init(info: [String: Any]) throws {
        guard let urlString = info[Self.urlKey] as? String, !urlString.isEmpty else {
            throw Error.missingURL
        }
        guard let url = URL(string: urlString), url.scheme != nil, url.host != nil else {
            throw Error.invalidURL(urlString)
        }
        guard let token = info[Self.tokenKey] as? String else {
            throw Error.missingToken
        }
        self.baseURL = url
        self.readToken = token
    }

    init(bundle: Bundle = .main) throws {
        try self.init(info: bundle.infoDictionary ?? [:])
    }
}
