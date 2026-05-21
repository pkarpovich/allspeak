import Foundation

struct Subtitle: Identifiable, Hashable, Codable {
    let index: Int
    let start: TimeInterval
    let end: TimeInterval
    let text: String

    var id: Int { index }
}
