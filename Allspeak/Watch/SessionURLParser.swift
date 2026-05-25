import Foundation

enum SessionURLParser {
    static let scheme = "allspeak"
    static let sessionHost = "session"

    static func parseSessionURL(_ url: URL) -> UUID? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        guard url.host?.lowercased() == sessionHost else { return nil }
        let trimmed = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return nil }
        return UUID(uuidString: trimmed)
    }

    static func sessionURL(for id: UUID) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = sessionHost
        components.path = "/\(id.uuidString)"
        return components.url!
    }
}
